# Talos Configuration

This directory contains the Talos Linux configuration for the Kubernetes cluster.
Machine configs are rendered by [topf](https://postfinance.github.io/topf/).

## Directory Structure

```
talos/
├── topf.yaml                  # Nodes, schematics, Talos & Kubernetes versions
├── talsecret.sops.yaml        # Encrypted cluster secrets bundle (SOPS)
├── patches/                   # Configuration patches (see patches/README.md)
│   ├── all/                   # Applied to all nodes
│   ├── control-plane/         # Applied to control plane only
│   └── node/<host>/           # Applied to one node (network lives here)
├── clusterconfig/             # Rendered machine configs (gitignored, DO NOT EDIT)
├── upgrade-talos.sh           # Manual upgrade script
├── UPGRADE.md                 # Complete upgrade documentation 📖
└── README.md                  # This file
```

## Quick Start

### Render configurations

```bash
task talos:generate-config
```

This writes `clusterconfig/<host>.yaml` for every node plus `clusterconfig/talosconfig`.
The rendered files hold secrets in plaintext and are gitignored.

### Apply to a node

```bash
task talos:apply-node IP=192.168.10.33
```

Merging a change under `patches/` does this for every node through the
**Talos Config Apply** workflow, which dry-runs first and refuses to reboot a
node unless dispatched with `allow-reboot`.

### Upgrading Talos

See [UPGRADE.md](./UPGRADE.md). The normal path is to merge a version bump in
`topf.yaml` and approve the **Talos Upgrade** workflow.

## Configuration Files

### topf.yaml

- `talosVersion` / `kubernetesVersion`, kept current by Renovate
- One entry per node: `host`, `ip`, `role`, and `schematicId`, the Image Factory
  schematic that decides its extensions
- `data.longhornReplicas` per node, which attaches the Longhorn bind mounts

### Patches

Applied in this order, each directory in filename order:
1. `patches/all/` (all nodes)
2. `patches/control-plane/` (control plane only)
3. `patches/node/<host>/` (one node)

**Patch Format**: strategic merge patches (YAML) with `$patch: delete` for
deletions. Files ending in `.yaml.tpl` are Go templates.

## Node Types & Schematics

This cluster uses different Talos factory images based on node type:

| Node Type | Nodes | Extensions |
|-----------|-------|-----------|
| VM Control Plane | k8s-cp-1, k8s-cp-2 | iscsi-tools + qemu-guest-agent |
| Physical Control Plane | k8s-cp-3 | iscsi-tools |
| Raspberry Pi Workers | k8s-pi-1 to k8s-pi-8 | iscsi-tools |

## Common Tasks

### Apply Config Changes

```bash
# Single node -- always pass --nodes with the file rendered for that node
talosctl apply-config --nodes 192.168.10.33 --file clusterconfig/k8s-cp-1.yaml
```

The rendered `talosconfig` lists every node as a default target, so a talosctl
command without `--nodes` reaches all of them
(see [RECOVERY_STEPS.md](./RECOVERY_STEPS.md)).

### Check Node Status

```bash
# Version
talosctl version --nodes 192.168.10.33

# Extensions
talosctl get extensions --nodes 192.168.10.33

# Services
talosctl services --nodes 192.168.10.33

# Logs
talosctl logs --nodes 192.168.10.33 kubelet
```

### Add New Extension

1. Create schematic with extensions:
   ```bash
   cat > extensions.yaml << 'EOF'
   customization:
     systemExtensions:
       officialExtensions:
         - siderolabs/iscsi-tools
         - siderolabs/new-extension
   EOF

   curl -X POST --data-binary @extensions.yaml https://factory.talos.dev/schematics
   ```

2. Update `schematicId` for the node in `topf.yaml`

3. Upgrade the node so it boots the new image:
   ```bash
   task talos:generate-config
   task talos:upgrade-node IP=192.168.10.33
   ```

## Important Notes

⚠️ **Never edit files in `clusterconfig/` directly** - they are rendered by topf
⚠️ **Always upgrade via `talosctl upgrade`** - `apply-config` doesn't change the OS image
⚠️ **Talos 1.14 needs the patches ported first** - see the note in `topf.yaml`

## References

- [Talos Documentation](https://www.talos.dev/latest/)
- [topf Documentation](https://postfinance.github.io/topf/)
- [Talos Image Factory](https://factory.talos.dev/)
- [Upgrade Guide](./UPGRADE.md)

## Getting Help

```bash
# Talos help
talosctl --help

# topf help
topf --help

# Check cluster health
kubectl get nodes
talosctl health --nodes 192.168.10.33,192.168.10.44,192.168.10.4
```
