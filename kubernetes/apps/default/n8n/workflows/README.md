# n8n workflows

Snapshots of the n8n workflows running in this cluster.

## These are records, not a source of truth

**Nothing here is applied by Flux.** The `cluster-apps-n8n` Kustomization points at
`./kubernetes/apps/default/n8n/app` and lists its resources explicitly, so this
directory is outside anything Flux reads.

n8n stores workflows in its Postgres database and reads them from nowhere else.
That means:

- Editing a file here does **not** change the running workflow.
- Editing a workflow in the n8n UI does **not** update the file here.
- The two drift apart the moment someone touches the UI.

Treat these as restorable backups and as a way to review workflow logic in a diff.
Re-export after changing a workflow, or the snapshot goes stale silently.

## Secrets are redacted

Credential values are stripped before committing. `X-API-TOKEN` header values read
`<REDACTED - see 1Password: invoiceninja>` and must be filled in before import.

Node `credentials` blocks reference n8n credentials by id and name only (no secret
material), so they are left intact — the referenced credential must already exist
in the target n8n instance.

## Re-exporting

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
churn like `versionId` and `updatedAt`) and redact the token values.

## Restoring

`PUT /api/v1/workflows/$ID` with the same four fields, token values filled back in.
BusyBox `wget` in the n8n image cannot send a request body — use `node` with `fetch`
inside the pod, or run the request from somewhere with `curl`.

## Workflows

| File | Workflow id | What it does |
| --- | --- | --- |
| `add-expense-from-email.json` | `Gx0uRQGiKKHGwCYdJjRRM` | Reads forwarded vendor receipts over IMAP, parses the vendor, charged total and receipt date, then posts an expense to Invoice Ninja. Vendors are matched by name against the Invoice Ninja vendor list. Add a vendor by adding a matcher in `ShouldProcess` and an amount pattern in `ParseEmail`. |
