# Postmortem: Mealie stuck in Multi-Attach, 2026-07-14

## Summary

Mealie would not start. Every new pod failed to schedule with:

```
Multi-Attach error for volume "pvc-4cb39f25-4dda-44d5-814e-5f6058d3fa1f"
Volume is already exclusively attached to one node and can't be attached to another
```

Longhorn reported the volume as `attached` to `k8s-pi-7` even though the mealie
Deployment had been scaled to zero and no pod referencing the PVC existed
anywhere in the cluster.

The cause was **not** Longhorn. Kubelet on `k8s-pi-7` was wedged in a permanent
unmount-retry loop for a pod that no longer existed, which kept the volume pinned
to that node. Longhorn was correctly refusing to detach a volume that a kubelet
still claimed was in use.

Resolution: restart kubelet on `k8s-pi-7`, then clean up a dead mount the restart
left behind. Total data loss: none. The 49M of recipe images/assets on the PVC
came back intact.

## Impact

- Mealie was unavailable until the wedged kubelet was restarted.
- No other workload was affected. The volume's data was never at risk.
- `k8s-pi-7` had been spending a couple of CPU-seconds a minute failing the same
  unmount, silently, for an unknown length of time.

## Root cause

The failure is a chain, and every link has to be understood to see why scaling to
zero could not possibly have fixed it.

1. An earlier mealie pod (UID `ccb49f5e-f304-43ec-915f-3bd381de99e2`) died messily
   on `k8s-pi-7`. Its teardown left an orphaned directory at
   `/var/lib/kubelet/pods/ccb49f5e-.../` whose
   `volumes/kubernetes.io~csi/pvc-4cb39f25-.../vol_data.json` was **missing**.

2. Kubelet needs `vol_data.json` to construct a CSI unmounter. Without it,
   `UnmountVolume` fails immediately and permanently:

   ```
   UnmountVolume.NewUnmounter failed for volume
     "kubernetes.io/csi/driver.longhorn.io^pvc-4cb39f25-..."
     pod "ccb49f5e-f304-43ec-915f-3bd381de99e2":
   kubernetes.io/csi: failed to open volume data file
     [.../pvc-4cb39f25-.../vol_data.json]: no such file or directory
   ```

   Kubelet retried this roughly every two seconds, indefinitely.

3. Because the unmount never succeeded, the volume never left kubelet's
   actual-state-of-world, so the node kept advertising it in
   `node.status.volumesInUse`.

4. **The attach/detach controller will not detach a volume that a node reports as
   in-use.** So it never even issued a detach request — the `VolumeAttachment`
   `csi-e3be7475...` had `attached: true` and *no* `deletionTimestamp`. Nobody had
   ever asked for it to go away.

5. Longhorn, doing exactly as it was told, held the attachment to `k8s-pi-7`.

6. The replacement mealie pod scheduled onto `k8s-cp-2`, tried to attach a volume
   still exclusively held by `k8s-pi-7`, and got the Multi-Attach error.

Scaling the Deployment to zero had no effect because **the thing pinning the
volume was a ghost pod that no longer existed in the Kubernetes API.** There was
nothing left to scale down. The only trace of it was a directory on one node's
disk and an entry in one kubelet's memory.

### What caused the messy teardown

Not conclusively established. The Longhorn CSI plugin logs on `k8s-pi-7` show the
control plane was unhealthy immediately before the bad teardown — `longhorn-backend`
was timing out:

```
NodeGetVolumeStats: ... err: ... failed to get volume pvc-4cb39f25-... for volume statistics:
Get "http://longhorn-backend:9500/v1/volumes/pvc-4cb39f25-...": context deadline exceeded
```

A pod teardown racing a struggling Longhorn control plane is a plausible way to
lose `vol_data.json` partway through cleanup, but this is inference, not proof.

Note the pod that scaled down *cleanly* (`ae5de1a3-...`) logged a successful
`NodeUnpublishVolume` and never appeared in the failure loop. Only the ghost pod
`ccb49f5e-...` was stuck. This is what confirmed the problem was one specific
orphaned directory rather than anything systemic.

## Resolution

### 1. Restart kubelet on the wedged node

```sh
talosctl -e 192.168.10.77 -n 192.168.10.77 service kubelet restart
```

On startup kubelet rebuilds its volume state from disk. Since the volume directory
was already gone, it simply did not recreate the phantom mount, stopped retrying,
and dropped the volume from `volumesInUse`. The attach/detach controller then
detached it normally. This cleared in under 10 seconds. Kubelet also
garbage-collected the orphaned pod directory on its own.

A kubelet restart does **not** kill running containers, so the other workloads on
`k8s-pi-7` were undisturbed.

### 2. Clean up the dead globalmount

The detach happened without kubelet ever calling `NodeUnstageVolume`, which
stranded the CSI staging mount. The kernel had shut the filesystem down when its
backing device vanished:

```
/dev/longhorn/pvc-4cb39f25-... /var/lib/kubelet/plugins/.../globalmount ext4 rw,...,emergency_ro,shutdown
```

`emergency_ro,shutdown` — reads returned `Input/output error`, and
`/dev/longhorn/pvc-4cb39f25-...` no longer existed. This mattered because the
globalmount path is a deterministic hash of the volume ID: if mealie ever
rescheduled onto `k8s-pi-7`, `NodeStageVolume` would target that exact same path.

Unmounted it through the `longhorn-csi-plugin` pod, which mounts `/var/lib/kubelet`
with bidirectional propagation, so the unmount reaches the host — no reboot and no
extra privileged pod required:

```sh
GM=/var/lib/kubelet/plugins/kubernetes.io/csi/driver.longhorn.io/<hash>/globalmount
kubectl exec -n longhorn-system <longhorn-csi-plugin-pod> -c longhorn-csi-plugin -- umount $GM
```

Unmounting was safe: the filesystem was already shut down and read-only, and its
backing device was gone, so there was nothing to flush.

### 3. Scale mealie back up

```sh
kubectl scale deploy mealie -n default --replicas=1
```

Pod came up Ready on `k8s-cp-2`, volume `attached / healthy`, data intact.

## How to recognise this again

The diagnostic signature is specific, and worth committing to memory because it
looks like a Longhorn bug and is not one:

- A `VolumeAttachment` that is `attached: true` with **no `deletionTimestamp`**.
  This is the key tell. It means nothing ever *asked* for a detach — so the
  storage layer is not stuck, the request was never made.
- The volume still listed in some node's `.status.volumesInUse`.
- No pod anywhere in the API referencing the PVC.

That combination always means **a wedged kubelet, not a Longhorn problem.**
Restart kubelet on the node named in `volumesInUse`.

```sh
PV=pvc-xxxxxxxx   # the PV from the Multi-Attach error

# Is a detach even being requested? (empty deletionTimestamp => no)
kubectl get volumeattachment -o json \
  | jq -r --arg pv "$PV" '.items[]
      | select(.spec.source.persistentVolumeName==$pv)
      | {name:.metadata.name, node:.spec.nodeName, attached:.status.attached,
         deletionTimestamp:.metadata.deletionTimestamp}'

# Which node still claims it is in use?
kubectl get nodes -o json \
  | jq -r --arg pv "$PV" '.items[]
      | select(.status.volumesInUse[]? | test($pv)) | .metadata.name'

# Confirm no pod actually references the PVC
kubectl get pods -A -o json \
  | jq -r '.items[] | select(.spec.volumes[]?.persistentVolumeClaim.claimName // "" | test("<pvc-name>"))
      | "\(.metadata.namespace)/\(.metadata.name)"'

# Confirm the kubelet retry loop on the offending node
talosctl -e <node-ip> -n <node-ip> logs kubelet | grep "$PV" | grep -i "UnmountVolume failed"
```

After the kubelet restart, check for a stranded globalmount before declaring
victory — `NodeUnstageVolume` may never have run:

```sh
talosctl -e <node-ip> -n <node-ip> mounts | grep "$PV"
```

If it is still listed with `emergency_ro,shutdown` in `/proc/mounts`, unmount it as
in step 2 above.

## Gotchas hit while debugging

Recording these because both cost real time and both produce *convincingly wrong*
answers rather than errors.

- **`talosctl -n k8s-pi-7` does not work.** Talos node names here do not resolve;
  you must pass the IP (`-e 192.168.10.77 -n 192.168.10.77`). The failure mode is
  nasty: some subcommands return an empty result rather than an error, so
  `talosctl -n k8s-pi-7 mounts | grep <pv>` printed nothing and I briefly concluded
  the volume was not mounted on the node. It was. Always pass the IP, and sanity-check
  that the command returns *something* before trusting a negative result.

- **`talosctl mounts` reports plausible size/usage figures for a dead mount.** The
  stranded globalmount showed `5.20 GB / 1.30% used` as though healthy, because the
  kernel still had the superblock cached. Only `ls` (which returned `EIO`) and the
  `emergency_ro,shutdown` flags in `/proc/mounts` revealed it was dead. Do not treat
  a normal-looking `mounts` line as evidence a mount is healthy.

## Follow-ups

- [ ] Nothing in the repo needed changing — this was purely cluster runtime state,
      so there is no commit associated with the fix.
- [ ] The trigger (Longhorn control-plane timeouts during pod teardown) was not
      root-caused. If Multi-Attach recurs on any app, check whether
      `longhorn-backend` is timing out under load rather than treating each
      occurrence as a one-off.
