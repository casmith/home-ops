# Talos Patching

Strategic merge patches applied by [`../render.sh`](../render.sh) on top of the
config `talosctl gen config` produces.

<https://www.talos.dev/v1.13/talos-guides/configuration/patching/>

## Patch Directories

Applied in this order, so later files win:

- `cluster.yaml`: cluster-wide settings `gen config` has no flag for
- `global/`: applied to every node
- `controller/`: applied to control plane nodes only
- `storage/`: attached per node -- currently the Longhorn bind mounts, which go
  to the replica-holding nodes listed in `render.sh`
- finally `../nodes/<role>/<hostname>.yaml`, the node's own settings

Files ending in `.sops.yaml` are decrypted before being passed to `talosctl`.

## Deleting a key

Use `$patch: delete`:

```yaml
cluster:
  apiServer:
    admissionControl:
      $patch: delete
```

> Single `$`. Older patches here used `$$patch` to escape talhelper's envsubst;
> nothing substitutes variables any more, so the double form would be applied
> literally and silently fail to delete anything.
