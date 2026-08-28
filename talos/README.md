# Talos Configuration

This directory contains the Talos Linux configuration for the Kubernetes cluster.

Machine configs are **composed from layered patches and rendered on demand** by
[`render.sh`](./render.sh). There is no separate config-generator tool: talhelper
was removed in favour of `talosctl` itself, so nothing here carries a schema that
has to chase Talos releases.

## Directory Structure

```
talos/
├── render.sh                   # Renders machine configs ⭐
├── talenv.yaml                 # Talos & Kubernetes versions (Renovate edits this)
├── talsecret.sops.yaml         # Cluster PKI and tokens (SOPS)
├── schematic.yaml              # Fleet default Image Factory schematic
├── patches/
│   ├── cluster.yaml            # Cluster-wide settings
│   ├── global/                 # Applied to every node
│   ├── controller/             # Applied to control plane nodes
│   └── storage/                # Longhorn mounts, attached per node
├── nodes/
│   ├── controlplane/           # One file per control plane node
│   │   ├── k8s-cp-1.yaml
│   │   └── k8s-cp-1.schematic.yaml   # optional per-node schematic override
│   └── workers/                # One file per worker
│       ├── k8s-pi-1.yaml
│       └── schematic.yaml            # optional per-role schematic override
├── clusterconfig/              # Rendered configs (gitignored, never committed)
├── UPGRADE.md                  # Upgrade documentation 📖
└── README.md                   # This file
```

## How a config is built

```
talsecret.sops.yaml ──sops──┐
                            ├── talosctl gen config ──┐
talenv.yaml ────────────────┘                         │
                                                      ├── machineconfig patch ──> stdout
patches/cluster.yaml                                  │
patches/global/*.yaml                                 │
patches/controller/*.yaml     (control plane only)    │
patches/storage/*.yaml        (replica nodes only)    │
nodes/<role>/<node>.yaml ─────────────────────────────┘
```

Later patches win. Two conventions matter:

- **A node's directory is its role.** `nodes/controlplane/` and `nodes/workers/`
  decide `machine.type`, which patches apply, and how the workflows group the
  node. There is no `controlPlane:` flag to keep in sync.
- **Secrets are never in plaintext here.** `talsecret.sops.yaml` and any
  `*.sops.yaml` patch are decrypted by `render.sh` at render time.

## Quick Start

```bash
# Print one node's config
bash render.sh config k8s-cp-1

# Render every node into clusterconfig/
task talos:generate-config

# Apply to a node
task talos:apply-node NODE=k8s-cp-1
```

> **Note:** tasks take `NODE=<hostname>`, not an IP. `render.sh` resolves the
> address from the node file, so the hostname is the only thing worth typing --
> and it matches what `kubectl get nodes` shows.
>
> `render.sh` is run through `bash` rather than executed directly, the same way
> the Taskfiles run `scripts/bootstrap-apps.sh`.

## Versions

`talenv.yaml` is the single source of truth and carries the Renovate
annotations that open the version-bump PRs:

```yaml
# renovate: datasource=docker depName=ghcr.io/siderolabs/installer
talosVersion: v1.13.9
# renovate: datasource=docker depName=ghcr.io/siderolabs/kubelet
kubernetesVersion: v1.37.0
```

`render.sh` feeds these to `talosctl gen config` and composes
`machine.install.image` from them, so no version is written down twice.

## Schematics

Extensions are declared as YAML and resolved to an Image Factory schematic ID at
render time. The factory hashes the content, so the same file always yields the
same ID -- which is why the IDs no longer need to be pasted into the repo.

Lookup order, most specific first:

| File | Applies to |
|---|---|
| `nodes/<role>/<hostname>.schematic.yaml` | one node |
| `nodes/<role>/schematic.yaml` | a whole role |
| `schematic.yaml` | the fleet |

Current set:

| Schematic | Contents | Nodes | Expected ID |
|---|---|---|---|
| `schematic.yaml` | iscsi-tools | k8s-cp-3 | `c9078f94…` |
| `nodes/controlplane/k8s-cp-{1,2}.schematic.yaml` | iscsi-tools, qemu-guest-agent | the VMs | `dc7b152c…` |
| `nodes/workers/schematic.yaml` | iscsi-tools + `rpi_generic` overlay | k8s-pi-1..8 | `f47e6cd2…` |

The IDs are recorded only so a mismatch is obvious; nothing reads them. Check
one with `bash render.sh image k8s-cp-1`, or inspect a schematic's contents at
`https://factory.talos.dev/schematics/<id>`.

> **Changing a schematic is a two-step.** A new ID changes
> `machine.install.image`, which the config-apply workflow will apply -- but
> `apply-config` never changes the running OS image. The extensions only land on
> the next `talosctl upgrade`. See [UPGRADE.md](./UPGRADE.md).

## Common Tasks

### Add a node

Create `nodes/<role>/<hostname>.yaml` with its hostname, install disk and
interface. The workflows build their matrices from that directory, so nothing
else needs editing.

### Add an extension

Edit the relevant schematic file, then run the upgrade workflow (or
`task talos:upgrade-node NODE=?`) to install the new image.

### Check node status

```bash
talosctl version --nodes 192.168.10.33
talosctl get extensions --nodes 192.168.10.33
talosctl services --nodes 192.168.10.33
talosctl logs --nodes 192.168.10.33 kubelet
```

## Important Notes

⚠️ **Never edit files in `clusterconfig/`** -- they are rendered artifacts and
contain the cluster PKI in plaintext. The whole directory is gitignored.

⚠️ **`apply-config` does not change the OS image.** Use `talosctl upgrade` for
version or extension changes.

⚠️ **Patches are strategic merge patches.** Use `$patch: delete` to remove a
key. (Single `$`, not `$$` -- the old double form was escaping for talhelper's
envsubst, which no longer exists.)

## References

- [Talos Documentation](https://www.talos.dev/latest/)
- [Talos Image Factory](https://factory.talos.dev/)
- [Upgrade Guide](./UPGRADE.md)

## Getting Help

```bash
talosctl --help
bash render.sh             # usage
kubectl get nodes
talosctl health --nodes 192.168.10.33,192.168.10.44,192.168.10.4
```
