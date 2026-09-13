# Talos Patches

Strategic merge patches that [topf](https://postfinance.github.io/topf/) layers
onto each node's generated machine config.

## Directories

- `all/`: every node
- `control-plane/`: control plane nodes only
- `worker/`: worker nodes only (none yet)
- `node/<host>/`: a single node, where `<host>` matches `nodes[].host` in `../topf.yaml`

Patches merge in that order, and in lexicographical order within a directory,
so the numeric filename prefixes decide which patch wins.

## File types

- `*.yaml`: a plain patch. `*.sops.yaml` files are decrypted on the fly.
- `*.yaml.tpl`: a Go template (sprig functions included) rendered with
  `.Node.Host`, `.Node.Role`, `.Node.Data` and friends. Templates skip SOPS
  decryption, so keep secrets out of them. A template that renders empty is
  skipped, which is how `all/30-longhorn-mounts.yaml.tpl` reaches only some nodes.

Delete fields with `$patch: delete` -- a single `$`. The `$$patch` spelling was
only needed to get past talhelper's envsubst. JSON patches (RFC 6902) are not
supported.

<https://postfinance.github.io/topf/configuration-model/>
