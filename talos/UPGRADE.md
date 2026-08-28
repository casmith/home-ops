# Talos Linux Upgrade Guide

This guide documents the process for upgrading Talos Linux nodes in this cluster.

## Overview

The cluster uses different Talos factory images (schematics) based on node type:

- **VM Control Plane Nodes** (k8s-cp-1, k8s-cp-2): iscsi-tools + qemu-guest-agent
- **Physical Control Plane Node** (k8s-cp-3): iscsi-tools only
- **Raspberry Pi Workers** (k8s-pi-1 through k8s-pi-8): iscsi-tools + the
  `rpi_generic` overlay

Each is declared as a schematic file and resolved to an Image Factory ID at
render time -- see [README.md](./README.md#schematics).

## Prerequisites

### Required Tools

Everything is pinned in [`.mise.toml`](../.mise.toml), so `mise install` from
the repo root is enough. `render.sh` needs `talosctl`, `sops`, `yq`, `jq` and
`curl` on `PATH`.

The same pins are what the workflows download -- `.github/actions/talos-setup`
reads its versions straight out of `.mise.toml`, so there is one place to bump.

## GitHub Actions Workflow (preferred)

`.github/workflows/talos-upgrade.yaml` rolls the whole cluster one node at a
time. Each node appears as its own job, named after its hostname.

**Trigger.** Merging a change to `talos/talenv.yaml` — typically a Renovate PR
for `ghcr.io/siderolabs/installer` — starts the workflow. It can also be run by
hand from the Actions tab, which accepts an optional comma-separated `nodes`
filter and a `dry-run` toggle.

**Approval.** Nothing reboots until the `Approve` job is released. It is bound
to the `talos-upgrade` GitHub Environment, which requires a reviewer, so a
weekend Renovate merge waits for a human. Read the `Plan` job summary first —
it lists the target version and which nodes are behind it.

**Order.** All three control plane nodes upgrade first, one at a time, then the
eight Pi workers, one at a time. The first failure stops the rest.

**Reruns are safe.** Each job skips its node if it already reports the target
version, so re-running after a failure resumes where it stopped rather than
rebooting healthy nodes.

**Kubernetes.** If `kubernetesVersion` in `talenv.yaml` no longer matches the
running kubelets, a final job runs `talosctl upgrade-k8s` after every node is
done. That is a single cluster-wide command which rolls the control plane
static pods and the kubelets in place — no reboots, no draining, and no
per-node jobs.

A commit that only moves `kubernetesVersion` therefore upgrades Kubernetes
without rebooting anything: the node phases are skipped because every node
already runs the target Talos version, and only the Kubernetes job runs. It
still waits on the same approval.

The Kubernetes job is deliberately skipped on a run limited with the `nodes`
input — a partial rollout should not trigger a cluster-wide Kubernetes
upgrade. Bump `kubernetesVersion` and let an unfiltered run handle it, or use
`task talos:upgrade-k8s` by hand.

The runners live in this cluster, so the workflow pins each phase to the nodes
it is *not* touching: control plane jobs run on `home-ops-runners-arm64` (the
Pis) and worker jobs on `home-ops-runners-amd64` (the control plane). Without
that split, a job would eventually evict itself. See
`kubernetes/apps/actions-runner-system/home-ops-runners/`.

### Longhorn interactions (read this before upgrading)

Both failures seen on the first real run came from Longhorn, and neither is a
workflow bug. Expect them until the drain policy is changed.

**1. The drain is refused, not slow.** Longhorn guards each `instance-manager`
pod with a PodDisruptionBudget for as long as that manager runs engines for
attached volumes. Those PDBs report `ALLOWED DISRUPTIONS: 0`, so a drain that
tries to evict the instance manager fails outright:

```
error draining node "k8s-cp-3": error when evicting pods/"instance-manager-..."
-n "longhorn-system": client rate limiter Wait returned an error
```

Raising the timeout does not help — the eviction is refused, not slow.

**This is an ordering problem, not a policy one.** It is the workload pods on
the node that keep those engines alive, and `talosctl upgrade` evicts the
workloads and the instance manager in a single pass, so the manager is still
serving engines at the moment it is asked to leave. The workflow therefore
drains in two phases, and upgrades with `--drain=false`:

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data \
  --pod-selector='longhorn.io/component!=instance-manager' --timeout=10m
# engines fall to zero, Longhorn removes the PDB by itself
talosctl upgrade --nodes <ip> --image ... --drain=false
```

Measured on `k8s-pi-8`: engines reached zero and the PDB disappeared within
ten seconds of the workload drain, and the subsequent Talos drain took two
seconds — against five minutes of failure on `k8s-cp-3`.

Changing `node-drain-policy` does **not** fix this. `always-allow` was tried:
Longhorn recreated the deleted PDB within 15 seconds while that policy was
active, because the instance manager still had running engines.
`allow-if-replica-is-stopped` is no better, since it blocks while replicas are
running, which is the normal state. Inspect the current state with:

```bash
kubectl -n longhorn-system get settings.longhorn.io node-drain-policy -o jsonpath='{.value}'
kubectl -n longhorn-system get pdb | grep instance-manager
```

**2. The unmount can wedge after the drain succeeds.** Longhorn serves RWX
volumes over NFS from a share-manager pod reachable only by ClusterIP. During an
upgrade Talos stops `cri` -- taking the Cilium datapath with it -- and *then*
unmounts pod volumes. A leftover Longhorn CSI `globalmount` therefore points at
an NFS server the node can no longer route to, and the unmount hangs forever:

```
task unmountPodMounts (1/1): unmounting .../csi/driver.longhorn.io/.../globalmount
nfs: server 10.43.x.x not responding, timed out
```

The node sits before the install step, still on the old version, with `etcd`,
`kubelet` and `cri` stopped. It does not recover on its own. Free it with:

```bash
talosctl -n <node-ip> -e <other-cp-ip> reboot --mode powercycle
```

There is no way to predict this from outside the node: the mounts that wedge
look identical to the ones every healthy node carries while running RWX
workloads. Diagnose it from the machine log:

```bash
talosctl -n <node-ip> -e <other-cp-ip> dmesg | tail -20
talosctl -n <node-ip> -e <other-cp-ip> services
```

**Cordons are the workflow's responsibility now.** Because the upgrade runs with
`--drain=false`, `talosctl` no longer cordons or uncordons anything — the
workflow's own drain step cordons, and the health gate uncordons after the node
is healthy. A node cordoned *before* the run is left cordoned deliberately. If a
job dies outright (its runner evicted, say) the node can be left cordoned with
no one to undo it, so check `kubectl get nodes` after any failed run.

**Recovering a halted rollout.** `fail-fast` stops the remaining nodes, so the
cluster is left partly upgraded but stable. Fix the cause, then re-run the
workflow: nodes already on the target version are skipped, so it resumes rather
than restarting. Check for a node left cordoned first (`kubectl get nodes`) --
the workflow uncordons on failure, but not if its runner was killed outright.

## Manual Upgrade Process

The steps below drive the upgrade from a workstation. They remain useful for
recovery and one-off work, but the workflow above is the normal path.

> **Warning:** these steps do **not** drain the node. Read the Longhorn section
> above first -- an undrained upgrade is how both known failure modes start.

### 1. Update Talos Version

Edit `talenv.yaml` to set the new version:

```yaml
# renovate: datasource=docker depName=ghcr.io/siderolabs/installer
talosVersion: v1.13.9  # Update this version
# renovate: datasource=docker depName=ghcr.io/siderolabs/kubelet
kubernetesVersion: v1.37.0  # Update if needed
```

Nothing else records a version, so this is the only edit.

### 2. Upgrade a node

`render.sh` resolves the node's schematic and composes the installer image, so
there is no hash to look up:

```bash
cd talos
bash render.sh image k8s-cp-1     # inspect what will be installed

# Drain first -- see the Longhorn section above for why this is two phases.
kubectl drain k8s-cp-1 --ignore-daemonsets --delete-emptydir-data \
  --pod-selector='longhorn.io/component!=instance-manager' --timeout=10m

task talos:upgrade-node NODE=k8s-cp-1
kubectl uncordon k8s-cp-1
```

### 3. Apply Updated Configurations (if needed)

`talosctl upgrade` does not rewrite machine config, so `install.image` stays
stale until an apply. The config-apply workflow's weekly sweep catches this, or
do it by hand:

```bash
task talos:apply-node NODE=k8s-cp-1
```

To regenerate every config locally:

```bash
task talos:generate-config
```

> **Note:** `clusterconfig/` is gitignored — the rendered per-node configs and
> `talosconfig` are local build artifacts, not committed. They contain secrets in
> plaintext. Regenerate them whenever you need them; the source of truth is
> `talenv.yaml` + `talsecret.sops.yaml` + `patches/` + `nodes/`.

### Verify Upgrade

```bash
# Check version
talosctl version --nodes 192.168.10.33 --short

# Check extensions
talosctl get extensions --nodes 192.168.10.33
```

### Upgrade Order

Upgrade in this order to maintain cluster stability:

1. **Control plane nodes first** (one at a time, wait for each to complete)
2. **Worker nodes after** (one at a time, so capacity is never lost in bulk)

This is the order the GitHub Actions workflow uses, and it matches the usual
Kubernetes convention. Either direction is safe, since the Talos version does
not create kubelet version skew.

Example, one node at a time:
```bash
for node in k8s-cp-1 k8s-cp-2 k8s-cp-3 k8s-pi-{1..8}; do
  task talos:upgrade-node NODE="$node"
done
```

## Creating/Updating Schematics

Schematics are declared in the repo and resolved to an Image Factory ID at
render time -- there is no ID to copy around. See
[README.md](./README.md#schematics) for the file layout and the current set.

To change the extensions on a node or a role:

1. Edit the relevant schematic file (`schematic.yaml`,
   `nodes/<role>/schematic.yaml`, or `nodes/<role>/<hostname>.schematic.yaml`).

2. Confirm the resolved image:
   ```bash
   bash render.sh image k8s-cp-1
   ```

3. Install it. **`apply-config` will not do this** -- it only updates machine
   config, so the new `install.image` lands in config while the node keeps
   running the old one. The extensions arrive on the next upgrade:
   ```bash
   task talos:upgrade-node NODE=k8s-cp-1
   ```

You can inspect any schematic's contents at
`https://factory.talos.dev/schematics/<id>`.

## Troubleshooting

### Upgrade aborts with `ENHANCE_YOUR_CALM` / `too_many_pings`

Hit during the v1.12.6 → v1.13.6 upgrade (2026-07-19). Symptom:

```
New upgrade API is not available, falling back to legacy
WARNING: : server version 1.12.6 is older than client version 1.13.6
"192.168.10.71": waiting for actor ID
ERROR: [transport] Client received GoAway with error code ENHANCE_YOUR_CALM and debug data equal to ASCII "too_many_pings".
```

**Cause**: when the talosctl client is a minor version ahead of the node, it falls
back to the legacy upgrade API. The `--wait` streaming connection then sends gRPC
keepalive pings faster than the older server's ping policy permits, so the server
sends GOAWAY and the client disconnects. The disconnect cancels the node's
in-flight installer pull:

```
[talos] retrying error: failed to pull image "...:v1.13.6": ... context canceled
```

**Impact**: none — the upgrade aborts before writing to disk and the node stays on
the old version, healthy. It is a failed upgrade, not a broken node.

**Solution**: pass `--wait=false` and poll for completion separately (check that
the node reports the target version *and* is `Ready`) rather than holding the
stream open. Verify with:

```bash
talosctl -e <node-ip> -n <node-ip> version --short
kubectl get node <name> -o wide
```

Note this affects **any** cross-minor upgrade, since talosctl is normally kept at
the target version. It is not specific to 1.12→1.13.

### Unknown Keys Error

If you see errors like "unknown keys found during decoding", you're trying to apply a config with fields not supported by the current Talos version.

**Solution**: Upgrade the OS first, then apply configs.

### Extensions Not Installing

If extensions don't appear after `apply-config`:

**Problem**: `apply-config` only updates configuration, not the OS image.

**Solution**: Use `talosctl upgrade` with the factory image URL containing the schematic.

### Config vs Upgrade Confusion

- **`talosctl apply-config`** - Updates machine configuration only (network settings, patches, etc.)
- **`talosctl upgrade --image`** - Updates the Talos OS image (includes extensions)

Always upgrade the OS image first when changing versions or adding extensions.

### Verifying Current Schematic

Check what schematic a node is running:
```bash
talosctl get extensions --nodes 192.168.10.33
```

The schematic ID will be listed as an extension.

## Post-Upgrade Tasks

After upgrading Talos:

1. **Verify cluster health**
   ```bash
   kubectl get nodes
   kubectl get pods -A
   ```

2. **Check Talos services**
   ```bash
   talosctl services
   ```

3. **Upgrade Kubernetes** (if version changed)
   ```bash
   task talos:upgrade-k8s
   ```

4. **Commit changes**
   ```bash
   git add talos/talenv.yaml
   git commit -m "chore: upgrade Talos to v1.13.9"
   ```

   Only `talenv.yaml` is committed. Do **not** try to add `talos/clusterconfig/` —
   it is gitignored (see the note in step 3). In practice the version bump usually
   arrives as a Renovate PR against `talenv.yaml`, so this step is just merging it.

## References

- [Talos Upgrade Documentation](https://www.talos.dev/latest/talos-guides/upgrading-talos/)
- [Talos Image Factory](https://factory.talos.dev/)
- [Talos Extensions](https://www.talos.dev/latest/talos-guides/configuration/system-extensions/)
- [Talos config patching](https://www.talos.dev/v1.13/talos-guides/configuration/patching/)

## Important Notes

- **Upgrade the control plane first, then workers**
- **Upgrade nodes one at a time**
- **Wait for each control plane node to fully come up before upgrading the next**
- **Test in non-production first if possible**
- **Keep backups of etcd** (Talos handles this automatically, but verify)
- **Monitor cluster during upgrade** using `kubectl get nodes -w`

## Quick Reference

```bash
# Check current versions
talosctl version --nodes 192.168.10.33,192.168.10.71

# Check extensions
talosctl get extensions --nodes 192.168.10.33

# Normal upgrade: bump talenv.yaml, merge, approve the workflow
vim talos/talenv.yaml

# See what a node would be installed with
bash talos/render.sh image k8s-pi-1

# Manual single node upgrade (drain first -- see the Longhorn section)
task talos:upgrade-node NODE=k8s-pi-1

# Upgrade Kubernetes only
task talos:upgrade-k8s
```
