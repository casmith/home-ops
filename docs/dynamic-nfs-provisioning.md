# Proposal: Dynamic NFS Provisioning for App Storage

## Problem

Every new app that needs persistent storage on the Synology requires manual steps:

1. SSH to the NAS, create `/volume1/cluster/<app>/` (and any subdirs).
2. Set ownership/permissions appropriately.
3. Reference the path explicitly in the HelmRelease:

   ```yaml
   persistence:
     config:
       type: nfs
       server: 192.168.10.3
       path: /volume1/cluster/<app>
   ```

This is repetitive, easy to forget, and means the cluster cannot self-bootstrap an app's storage from a clean state.

## Proposal

Install a dynamic NFS provisioner (either `csi-driver-nfs` or `nfs-subdir-external-provisioner`) pointed at `192.168.10.3:/volume1/cluster`. Define a `StorageClass` with a **deterministic** subdirectory path template. Apps then request storage via a normal PVC, and the provisioner creates the NFS subdirectory automatically.

### Why a deterministic path template matters

The default path templates include the PVC's UID, e.g. `default-thelounge-config-<uid>`. Kubernetes assigns a new UID on every PVC creation, so after a cluster rebuild the same PVC manifest produces a *different* directory. The old data is orphaned on the NAS and a restore requires manually renaming directories to match new UIDs.

Overriding the template to use only namespace + PVC name makes the path stable across cluster rebuilds — the provisioner sees the directory already exists and reuses it, so data survives.

### Configuration sketch

Using `csi-driver-nfs`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-cluster
provisioner: nfs.csi.k8s.io
reclaimPolicy: Retain
parameters:
  server: 192.168.10.3
  share: /volume1/cluster
  subDir: ${pvc.metadata.namespace}/${pvc.metadata.name}
```

Using `nfs-subdir-external-provisioner`:

```yaml
parameters:
  pathPattern: ${.PVC.namespace}/${.PVC.name}
```

### App usage

A HelmRelease then drops the explicit `server`/`path` and uses a PVC instead:

```yaml
persistence:
  config:
    enabled: true
    existingClaim: thelounge-config
    globalMounts:
      - path: /var/opt/thelounge
```

…with a sibling PVC manifest referencing `storageClassName: nfs-cluster`. The NFS directory `volume1/cluster/default/thelounge-config/` is created on first claim.

## Disaster recovery story

With deterministic paths + `reclaimPolicy: Retain`:

1. Cluster is destroyed.
2. New cluster bootstrapped from this repo via Flux.
3. PVCs are recreated with the same namespace + name.
4. Provisioner sees `volume1/cluster/default/thelounge-config/` already exists, binds to it.
5. App starts with all prior data intact.

No NAS-side intervention required.

## Trade-offs

| | Current (explicit NFS in HR) | Dynamic NFS provisioning |
|---|---|---|
| Manual NAS setup per app | Yes | No |
| Path layout on NAS | Hand-picked, human-friendly (`/volume1/cluster/thelounge`) | Templated (`/volume1/cluster/default/thelounge-config`) |
| Survives cluster rebuild | Yes (paths are hardcoded) | Yes (with deterministic template) |
| Adds a cluster-wide dependency | No | Yes (provisioner pod must be healthy) |
| Works with multiple PVCs per app | Yes (one path each) | Yes (one PVC each, distinct names) |
| Easy to mass-snapshot from the NAS | Yes (paths are obvious) | Yes (paths still predictable, one level deeper) |

## Open questions

- **Which provisioner?** `csi-driver-nfs` is the modern, Kubernetes-SIG-maintained option; `nfs-subdir-external-provisioner` is older but simpler and battle-tested. Either works.
- **Migration of existing apps:** the existing apps (linkding, nextcloud, etc.) use explicit paths like `/volume1/cluster/linkding`. They can stay as-is — the new provisioner only handles new apps unless we explicitly migrate them by renaming directories on the NAS (`/volume1/cluster/linkding` → `/volume1/cluster/default/linkding-config`) and switching their HelmRelease to PVCs.
- **Permissions:** confirm the NFS export allows the cluster nodes to create subdirectories under `/volume1/cluster` (vs. only existing ones).
- **Multiple PVCs per app:** apps that need several volumes (e.g. kapowarr mounts both config and a media share) would split into multiple PVCs, one per logical volume.

## Decision point

Try this on the next new app deployment. If it works cleanly, leave existing apps alone — no need to migrate working storage just for consistency.
