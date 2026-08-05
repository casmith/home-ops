# Talos Linux Upgrade Guide

This guide documents the process for upgrading Talos Linux nodes in this cluster.

## Overview

The cluster uses different Talos factory images (schematics) based on node type:

- **VM Control Plane Nodes** (k8s-cp-1, k8s-cp-2): iscsi-tools + qemu-guest-agent
- **Physical Control Plane Node** (k8s-cp-3): iscsi-tools only
- **Raspberry Pi Workers** (k8s-pi-1 through k8s-pi-8): iscsi-tools only

## Prerequisites

### Required Tools

1. **talosctl** - Talos CLI tool
   ```bash
   # Install via mise (recommended)
   mise use -g talos@latest

   # Or download directly
   # https://github.com/siderolabs/talos/releases
   ```

2. **yq** - YAML processor
   ```bash
   # macOS
   brew install yq

   # Linux
   wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
   chmod +x /usr/local/bin/yq
   ```

3. **talhelper** - Talos configuration generator
   ```bash
   # Install via mise
   mise use -g talhelper@latest
   ```

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
done. A commit that only moves `kubernetesVersion` therefore upgrades
Kubernetes without rebooting anything.

The runners live in this cluster, so the workflow pins each phase to the nodes
it is *not* touching: control plane jobs run on `home-ops-runners-arm64` (the
Pis) and worker jobs on `home-ops-runners-amd64` (the control plane). Without
that split, a job would eventually evict itself. See
`kubernetes/apps/actions-runner-system/home-ops-runners/`.

### Longhorn interactions (read this before upgrading)

Both failures seen on the first real run came from Longhorn, and neither is a
workflow bug. Expect them until the drain policy is changed.

**1. The drain is refused, not slow.** Longhorn gives each `instance-manager`
pod a PodDisruptionBudget. With `node-drain-policy: block-if-contains-last-replica`
those PDBs report `ALLOWED DISRUPTIONS: 0`, so `talosctl upgrade`'s built-in
drain can never evict them and fails after `--drain-timeout`:

```
error draining node "k8s-cp-3": error when evicting pods/"instance-manager-..."
-n "longhorn-system": client rate limiter Wait returned an error
```

Raising the timeout does not help. Check the policy and the budgets with:

```bash
kubectl -n longhorn-system get settings.longhorn.io node-drain-policy -o jsonpath='{.value}'
kubectl -n longhorn-system get pdb
```

Note that `allow-if-replica-is-stopped` does **not** help while replicas are
running, which is the normal case. Only `always-allow` (or moving replicas off
the node first) unblocks it.

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

**Recovering a halted rollout.** `fail-fast` stops the remaining nodes, so the
cluster is left partly upgraded but stable. Fix the cause, then re-run the
workflow: nodes already on the target version are skipped, so it resumes rather
than restarting. Check for a node left cordoned first (`kubectl get nodes`) --
the workflow uncordons on failure, but not if its runner was killed outright.

## Manual Upgrade Process (script)

The steps below drive the upgrade from a workstation. They remain useful for
recovery and one-off work, but the workflow above is the normal path.

> **Note:** `upgrade-talos.sh` upgrades workers before the control plane, the
> reverse of the workflow's order. Either is safe; the workflow's order matches
> the usual Kubernetes convention of moving the control plane first.

### 1. Update Talos Version

Edit `talenv.yaml` to set the new version:

```yaml
# renovate: datasource=docker depName=ghcr.io/siderolabs/installer
talosVersion: v1.13.0  # Update this version
# renovate: datasource=docker depName=ghcr.io/siderolabs/kubelet
kubernetesVersion: v1.35.0  # Update if needed
```

### 2. Regenerate Configurations

```bash
cd talos
talhelper genconfig
```

This regenerates all node configurations in `clusterconfig/` with the new version.

> **Note:** `clusterconfig/` is gitignored — the generated per-node configs and
> `talosconfig` are local build artifacts, not committed. They contain secrets in
> plaintext. Regenerate them with `talhelper genconfig` (or `task
> talos:generate-config`) whenever you need them; the source of truth is
> `talconfig.yaml` + `talenv.yaml` + `talsecret.sops.yaml`.

### 3. Run Automated Upgrade

```bash
cd talos
./upgrade-talos.sh
```

The script will:
1. Read the target version from `talenv.yaml`
2. Parse node configurations from `talconfig.yaml`
3. Show an upgrade plan with all nodes and their schematics
4. Ask for confirmation
5. Upgrade all worker nodes in parallel
6. Upgrade control plane nodes one at a time (with 30s wait between)
7. Verify all nodes are on the correct version
8. Display extension summary

### 4. Apply Updated Configurations (if needed)

After upgrading the OS, apply any configuration changes:

```bash
# For all nodes
for node in 192.168.10.{33,44,4,71..78}; do
  config_file=$(ls clusterconfig/kubernetes-k8s-*.yaml | grep -E "$(echo $node | sed 's/192.168.10.//')")
  if [ -f "$config_file" ]; then
    echo "Applying config to $node..."
    talosctl apply-config --nodes $node --file "$config_file"
  fi
done
```

## Manual Upgrade Process

If you prefer to upgrade manually or need to upgrade specific nodes:

### Upgrade Individual Node

```bash
# Get the schematic from talconfig.yaml for the specific node
NODE_IP="192.168.10.33"
SCHEMATIC="dc7b152cb3ea99b821fcb7340ce7168313ce393d663740b791c36f6e95fc8586"
VERSION="v1.12.0"

talosctl upgrade --nodes $NODE_IP \
  --image factory.talos.dev/installer/${SCHEMATIC}:${VERSION} \
  --wait
```

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

This is the order the GitHub Actions workflow uses. `upgrade-talos.sh` predates
it and does the reverse; both work, since the Talos version does not create
kubelet version skew.

Example:
```bash
# Control plane (one at a time)
talosctl upgrade --nodes 192.168.10.33 --image factory.talos.dev/installer/SCHEMATIC:VERSION --wait
talosctl upgrade --nodes 192.168.10.44 --image factory.talos.dev/installer/SCHEMATIC:VERSION --wait
talosctl upgrade --nodes 192.168.10.4 --image factory.talos.dev/installer/SCHEMATIC:VERSION --wait

# Workers (one at a time)
for node in 192.168.10.{71..78}; do
  talosctl upgrade --nodes $node --image factory.talos.dev/installer/SCHEMATIC:VERSION --wait
done
```

## Creating/Updating Schematics

### When to Update Schematics

Update schematics when you need to:
- Add new extensions
- Remove extensions
- Change extension versions

### Creating a New Schematic

1. Create an extensions configuration file:
   ```bash
   cat > extensions.yaml << 'EOF'
   customization:
     systemExtensions:
       officialExtensions:
         - siderolabs/iscsi-tools
         - siderolabs/qemu-guest-agent
   EOF
   ```

2. Generate the schematic:
   ```bash
   curl -X POST --data-binary @extensions.yaml https://factory.talos.dev/schematics
   ```

3. Update `talconfig.yaml` with the new schematic ID:
   ```yaml
   nodes:
     - hostname: "k8s-cp-1"
       talosImageURL: factory.talos.dev/installer/NEW_SCHEMATIC_ID
   ```

4. Regenerate configs:
   ```bash
   talhelper genconfig
   ```

### Current Schematics

| Schematic ID | Extensions | Used By |
|-------------|-----------|---------|
| `dc7b152cb3ea99b821fcb7340ce7168313ce393d663740b791c36f6e95fc8586` | iscsi-tools, qemu-guest-agent | k8s-cp-1, k8s-cp-2 (VMs) |
| `c9078f9419961640c712a8bf2bb9174933dfcf1da383fd8ea2b7dc21493f8bac` | iscsi-tools | k8s-cp-3 (physical) |
| `f47e6cd2634c7a96988861031bcc4144468a1e3aef82cca4f5b5ca3fffef778a` | iscsi-tools | k8s-pi-1 through k8s-pi-8 |

You can verify a schematic's extensions at:
```
https://factory.talos.dev/schematics/SCHEMATIC_ID
```

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
   talosctl upgrade-k8s --to v1.35.0
   ```

4. **Commit changes**
   ```bash
   git add talos/talenv.yaml
   git commit -m "chore: upgrade Talos to v1.13.0"
   ```

   Only `talenv.yaml` is committed. Do **not** try to add `talos/clusterconfig/` —
   it is gitignored (see the note in step 2). In practice the version bump usually
   arrives as a Renovate PR against `talenv.yaml`, so this step is just merging it.

## References

- [Talos Upgrade Documentation](https://www.talos.dev/latest/talos-guides/upgrading-talos/)
- [Talos Image Factory](https://factory.talos.dev/)
- [Talos Extensions](https://www.talos.dev/latest/talos-guides/configuration/system-extensions/)
- [talhelper Documentation](https://budimanjojo.github.io/talhelper/latest/)

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

# Full automated upgrade
cd talos
vim talenv.yaml  # Update version
talhelper genconfig
./upgrade-talos.sh

# Manual single node upgrade
talosctl upgrade --nodes 192.168.10.71 \
  --image factory.talos.dev/installer/SCHEMATIC:VERSION \
  --wait
```
