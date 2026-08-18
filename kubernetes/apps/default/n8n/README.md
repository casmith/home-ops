# n8n

Two directories hold workflows, under two different contracts. Read which one you
are in before editing.

| Directory | Contract |
| --- | --- |
| `app/workflows/` | **Git is the source of truth.** Flux applies these and an init container imports them into n8n on every rollout. Editing one of these workflows in the n8n UI is temporary — the next deploy overwrites it. |
| `workflows/` | **Snapshots only.** Nothing applies these. They are restorable backups and a way to review logic in a diff. They drift the moment someone touches the UI. |

New workflows should go in `app/workflows/`. The snapshot directory exists for
workflows that cannot be managed declaratively — see below.

## How `app/workflows/` reaches n8n

n8n has no filesystem source of truth for workflows; it reads them from Postgres
and nowhere else. So the declarative path is an importer, not a mount:

```
git commit
  └─ Flux applies kubernetes/apps/default/n8n/app
      └─ configMapGenerator -> ConfigMap n8n-workflows
          └─ reloader.stakater.com/auto rolls the Deployment
              └─ initContainer init-workflows:
                   n8n import:workflow --separate --input=/workflows
                     └─ upsert into Postgres, then n8n starts
```

Three things about this are load-bearing:

- **Every workflow JSON must carry a stable `id`.** The import upserts on it
  (`ImportService` does `tx.upsert(WorkflowEntity, ..., ['id'])`). A file with no
  `id` gets a freshly generated nanoid instead, so it lands as a **brand new
  workflow on every single deploy** rather than updating the existing one.
- **The ConfigMap name is not hashed** (`disableNameSuffixHash: true`). The
  HelmRelease references it by name inside `values:`, and Kustomize's
  nameReference transformer does not rewrite references buried in Helm values. A
  hashed name would leave the init container unable to mount. The rollout is
  driven by the reloader annotation instead.
- **`DB_TYPE: postgresdb` is repeated on the init container.** It is set on the
  app container, not in `n8n-secret`. Without it the CLI silently falls back to
  its sqlite default, imports into a throwaway file inside the init container,
  and exits 0 — a green deploy that changed nothing.

### Consequences worth knowing

- **UI edits to a managed workflow are lost** on the next rollout. Either stop
  editing it in the UI, or export it back to `app/workflows/` afterwards.
- **Import deactivates workflows.** `--activeState` defaults to `false`, which
  clears `active` on everything it imports. Harmless for a manual-trigger
  workflow; if a managed workflow ever needs to stay active, the flag has to
  become `--activeState=fromJson` and the JSON has to carry `"active": true`.
- **Deleting a file does not delete the workflow.** The importer only upserts.
  Removing a workflow from n8n is a manual step (or an API call).
- **Credentials are not in git and should not be.** The JSON references them by
  id; the credential must already exist in the instance.
- A malformed workflow fails the init container, so the new pod never goes Ready.
  With `replicas: 1` and `RollingUpdate` the old pod keeps serving, so a bad
  commit blocks the deploy rather than taking n8n down.

## Why not n8n's built-in Source Control

n8n ships a real git integration (Settings → Source Control), and it is the right
answer — but it is **Enterprise-licensed**. This instance is community: there is no
license key in `n8n-secret` or the HelmRelease env, and `/rest/settings` reports
only `ldap`, `oidc` and `saml` under `enterprise`. The importer above is the
community-edition substitute.

## Why `add-expense-from-email.json` is still a snapshot

It has **redacted secrets inline**: its `X-API-TOKEN` header values read
`<REDACTED - see 1Password: invoiceninja>`. Moving that file into `app/workflows/`
would import those literal strings over a working workflow and break the Invoice
Ninja calls on the next deploy. Making it declarative means first moving the token
out of the node parameters and into an n8n credential. Until then it stays here.

## Re-exporting a snapshot

Needs an n8n API key (Settings -> n8n API). The public API is enabled and listens on
the pod's port 5678.

```bash
KEY=<n8n api key>
ID=Gx0uRQGiKKHGwCYdJjRRM   # Add expense from email

kubectl exec -n default deploy/n8n -c app -- \
  wget -qO- --header="X-N8N-API-KEY: $KEY" --header='Accept: application/json' \
  "http://localhost:5678/api/v1/workflows/$ID"
```

Then keep only `name`, `nodes`, `connections`, `settings` (the rest is per-instance
churn like `versionId` and `updatedAt`) and redact the token values. A managed
workflow in `app/workflows/` keeps its `id` as well, since the import needs it.

## Restoring

`PUT /api/v1/workflows/$ID` with the same four fields, token values filled back in.
BusyBox `wget` in the n8n image cannot send a request body — use `node` with `fetch`
inside the pod, or run the request from somewhere with `curl`. For anything in
`app/workflows/`, prefer just rolling the Deployment — the importer is the restore.

## Workflows

| File | Workflow id | Managed | What it does |
| --- | --- | --- | --- |
| `workflows/add-expense-from-email.json` | `Gx0uRQGiKKHGwCYdJjRRM` | snapshot | Reads forwarded vendor receipts over IMAP, parses the vendor, charged total and receipt date, then posts an expense to Invoice Ninja. Vendors are matched by name against the Invoice Ninja vendor list. Add a vendor by adding a matcher in `ShouldProcess` and an amount pattern in `ParseEmail`. |
| `app/workflows/minecraft-world-reset.json` | `MinecraftReset01` | git | Manually triggered. SSHs to `pve5-ubuntu-highmem-1` and runs `~/minecraft-reset-worlds.sh --dry-run`, which lists the Minecraft world folders a reset would delete without touching them, then parses the output into one item per world. See the note below. |

## Note on the Minecraft reset workflow

The script is owned by **calypso-deploy**
(`ansible/files/minecraft-reset-worlds.sh`); this workflow only invokes it. The
SSH command is `./minecraft-reset-worlds.sh --dry-run`. **Without `--dry-run` that
same command permanently deletes every Minecraft world on the host** — the main
level (which since 26.x contains the nether and the end) and every Multiverse
world. There is no undo; `--backup` moves the worlds aside instead, and is the
safer thing to reach for first.

The SSH node needs an `sshPrivateKey` credential for `192.168.10.50` as user
`ubuntu`, and its `authentication` parameter must stay `privateKey` — the node
defaults to `password`. The `credentials.id` in the committed JSON is a
placeholder until that credential exists.
