# Postmortem: Longhorn volumes unattachable on pi-6 and pi-5, 2026-08-06

## Summary

Mealie and MouseSearch would not start on `k8s-pi-6`. Both pods sat in
`ContainerCreating` / `Init:0/1` with:

```
AttachVolume.Attach failed for volume "pvc-4cb39f25-4dda-44d5-814e-5f6058d3fa1f":
rpc error: code = DeadlineExceeded desc = volume ... failed to attach to node k8s-pi-6
```

Longhorn showed the volumes stuck in `attaching`, robustness `unknown`.

The cause was **not** Longhorn, and not the volumes named in the errors. Four
nodes had accumulated stale iSCSI node records under `/var/lib/iscsi/nodes/`
containing `node.session.conn_reopen_log_freq`, a parameter the running
`libopeniscsiusr` does not recognise. Because `iscsiadm -m node ... -o show`
parses the **entire** node database, a single unreadable record made every iSCSI
operation on that node fail — so no volume could attach there, regardless of
which volume it was.

Resolution: delete the 28 stale record directories across the four affected
nodes. Longhorn rewrites them cleanly on the next attach. Total data loss: none.

## Impact

- **Mealie** and **MouseSearch** were unavailable on `k8s-pi-6`.
- **beets** (`pvc-6efd14ad`) hit the same wall and its volume went
  `detaching` → `faulted` → `detached`. No user impact: `beets-shell` is declared
  `replicas: 0` in Git (`kubernetes/apps/default/beets/app/helmrelease.yaml:75`),
  an on-demand shell, so nothing was trying to run.
- **`k8s-pi-5` was failing identically** and had been for some time — 144 of the
  same error in its `longhorn-manager` log. It just had no pod actively demanding
  an attach, so nobody noticed.
- **`k8s-cp-1` (6 records) and `k8s-cp-2` (14 records) were latent.** Not erroring
  only because nothing had recently tried to attach there. Any volume scheduled
  onto them would have hit the same wall.
- **Silent replica-scheduling damage.** Mealie, MouseSearch and beets all specify
  `numberOfReplicas: 3` but were running on **one** replica each, all on `k8s-cp-3`.
  Longhorn had been unable to build replicas on pi-5 or pi-6 for months. This was
  the more dangerous half of the incident: three volumes sitting at a single
  replica with no alert, presenting as `healthy` whenever they happened to be
  attached.

## Root cause

1. `iscsiadm` wrote node records containing `node.session.conn_reopen_log_freq`.
   The affected records on `k8s-pi-6` are dated **Feb 15 18:33** and **Apr 2 12:03**.

2. The `libopeniscsiusr` in use today does not know that parameter. Reading any
   such record fails hard:

   ```
   iSCSI ERROR: Unknown parameter name node.session.conn_reopen_log_freq
     # ../libopeniscsiusr/idbm.c:_idbm_rec_update_param():780
   iSCSI ERROR: config file /var/lib/iscsi/nodes/iqn.2019-10.io.longhorn:pvc-0a8806ae-.../10.42.8.158,3260,1/default invalid.
     # ../libopeniscsiusr/idbm.c:_idbm_recs_read():919: exit status 7
   ```

3. **This is the crux: `iscsiadm -m node -o show` reads the whole node database,
   not just the record you asked about.** One bad record poisons every query.

4. Longhorn's engine starts fine, connects to its replica, and then dies at
   frontend startup when it queries `node.session.scan`:

   ```
   Failed to startup frontend: Failed to get node.session.scan mode: failed to execute:
     iscsiadm -m node -T iqn.2019-10.io.longhorn:pvc-4cb39f25-... -p 10.42.8.150 -o show
   ```

   Note the mismatch — it queries the **mealie** volume and fails on a record
   belonging to an **unrelated** volume. That mismatch is the diagnostic signature.

5. Engine crashes → volume stays `attaching` → CSI attach times out with
   `DeadlineExceeded` → pod never starts. Longhorn then retries forever, which is
   why `k8s-pi-6` logged 612 instances of the error in a five-minute window.

All 28 poisoned records were **stale**. Every one referenced a dead
instance-manager pod IP (on pi-6: `10.42.8.158` and `10.42.8.62`, against a
current `10.42.8.150`), and none belonged to a volume attached on the node
holding it. Twelve of them — `pvc-4d423b1f`, `pvc-a4737159`, `pvc-c6c6a194` on
`k8s-cp-2` — referenced volumes Longhorn no longer has at all. These were
leftovers from RWX share-manager pods that had since moved to other nodes.

### What wrote the bad parameter

**Not conclusively established.** What is known:

- Records written on the day of the incident (Aug 6 01:32) do **not** contain the
  parameter. Only the Feb/Apr ones do.
- `/etc/iscsi/iscsid.conf` on `k8s-pi-6` does not set it, so it came from
  `iscsiadm`'s built-in defaults at record-creation time.
- The `iscsi-tools` Talos extension reads **v0.2.0 on all 11 nodes** right now, so
  the current state shows no version skew to blame.

The most likely explanation is a change in the iSCSI tooling between April and
now — either an extension rebuild or a Longhorn upgrade altering how records are
created. A second possibility, which the current-state evidence cannot rule out,
is the known open-iscsi split where `iscsiadm`'s own `idbm` parameter table and
`libopeniscsiusr`'s separate copy disagree, letting the same version write records
it cannot read back. Distinguishing these would need the extension's build history,
which the running cluster does not carry.

This is inference, not proof. It does not affect the fix.

## Resolution

Nothing in the repo changed — this was purely host runtime state, so there is no
commit associated with the fix.

### 1. Find the poisoned records

```sh
for ip in <all node IPs>; do
  echo -n "$ip: "
  for f in $(talosctl -n $ip ls -r /var/lib/iscsi/nodes 2>/dev/null | awk '$2 ~ /default$/ {print $2}'); do
    talosctl -n $ip read "/var/lib/iscsi/nodes/$f" 2>/dev/null | grep -q conn_reopen_log_freq && echo "  BAD $f"
  done
done
```

Result: `k8s-cp-1` 6, `k8s-cp-2` 14, `k8s-pi-5` 3, `k8s-pi-6` 5. Twenty-eight total.

### 2. Delete them through an instance-manager pod

`talosctl` has no `rm`. The `instance-manager` pods mount **host `/` at `/host`**,
which is the shortest path to the files without creating a privileged debug pod:

```sh
kubectl exec -n longhorn-system <instance-manager-on-node> -- \
  rm -rf '/host/var/lib/iscsi/nodes/iqn.2019-10.io.longhorn:pvc-0a8806ae-.../10.42.8.158,3260,1'
```

Before deleting, each record was checked against the live attachment map and
skipped if its volume was attached on that same node. All 28 passed. Contents were
backed up first — they are regenerable, but the copy costs nothing.

Empty parent IQN directories were pruned afterwards with
`find /host/var/lib/iscsi/nodes -mindepth 1 -maxdepth 1 -type d -empty -exec rmdir {} \;`.

### 3. Verify

```sh
# rescan all nodes -> expect 0 bad everywhere
# then confirm the error has actually stopped, not just gone quiet:
kubectl logs -n longhorn-system <longhorn-manager-pod> -c longhorn-manager --since=60s \
  | grep -c conn_reopen_log_freq
```

Last error on `k8s-pi-6` was `06:43:41Z`; zero in the following 60 seconds. Mealie
and MouseSearch reached `1/1 Running` within about two minutes, no intervention
needed — the existing pods recovered on their own retry.

### 4. Replicas rebuilt themselves

Once iSCSI worked again, Longhorn immediately built the missing replicas on
exactly the two nodes that had been broken:

```
k8s-cp-3  24 replicas
k8s-pi-6  22 replicas
k8s-pi-5  22 replicas
```

Mealie and MouseSearch returned to `healthy` robustness at the full 3 replicas.
This is strong confirmation that the single-replica state was a symptom of this
bug rather than a separate misconfiguration — no replica settings were touched.

## How to recognise this again

The signature is specific and looks like a Longhorn bug when it is not:

- **`iscsiadm` fails on a config file for a volume other than the one it queried.**
  This is the tell. If the error names a different PVC than the command, you are
  looking at node-database poisoning, not a problem with the volume being attached.
- Volume stuck in `attaching`, engine cycling `starting` → `error` → `stopped`.
- CSI reports `DeadlineExceeded`, not a permission or scheduling failure.
- **Every** volume on that node fails, not just one — but you may only see one if
  only one is being scheduled there.

If it recurs, the same scan in step 1 finds it. Worth running on all nodes rather
than just the one that is visibly broken: three of the four affected nodes here
were not throwing errors at the time.

## Gotchas hit while debugging

- **`nsenter` into the iscsid mount namespace gives you `iscsiadm` and almost
  nothing else.** The Talos extension rootfs has no `ls`, no `sh`. Both
  `nsenter --mount=/host/proc/<pid>/ns/mnt ls ...` and `... /bin/sh -c ...` fail
  with `No such file or directory` — which reads like a missing path rather than a
  missing binary, and briefly looks like the node database is not there. It is.
  Go through the `instance-manager` pod's `/host` mount instead.

- **`longhorn-manager` does not mount `/var/lib/iscsi`.** It mounts `/host/boot`,
  `/host/dev`, `/host/proc`, `/host/etc` and `/var/lib/longhorn` — enough to
  `nsenter`, not enough to edit the node database. `longhorn-csi-plugin` does not
  mount it either. `instance-manager` is the one that mounts host `/`.

- **Latent damage does not show up in logs.** `k8s-cp-1` and `k8s-cp-2` had 20 of
  the 28 bad records between them and zero errors in their manager logs, purely
  because no attach had been attempted. Grepping logs to find affected nodes would
  have found two of four. Scan the filesystem.

- **A `healthy` volume can still be a single replica.** Longhorn reports
  robustness relative to what it has managed to schedule; `degraded` only appeared
  once the volume was attached and actively short. The real check is
  `.spec.numberOfReplicas` against the actual replica count.

- **`talosctl -n <ip>` works fine here** — contrast the 2026-07-14 postmortem's
  note about node names not resolving. IPs were used throughout.

## Follow-ups

- [ ] The trigger was not root-caused (see *What wrote the bad parameter*). If this
      recurs, capture the `iscsi-tools` extension version and Longhorn version at
      the time the bad records appear — the current-state evidence is not enough to
      distinguish a tooling change from the open-iscsi `idbm`/`libopeniscsiusr`
      table split.
- [ ] Consider a periodic scan for poisoned records. This failure is silent until
      a pod happens to schedule onto an affected node, and it degraded replica
      counts for months without surfacing.
- [ ] Longhorn does not garbage-collect node records for volumes that have moved
      away or been deleted. Twelve of the 28 records here referenced volumes that
      no longer exist. Worth periodic pruning independent of this bug.
- [ ] `k8s-pi-1` through `k8s-pi-4` remain `allowScheduling: false` in Longhorn
      (pre-existing drift, unrelated to this incident but it narrows where replicas
      can land, which made the single-replica state worse than it needed to be).
