# Vendored Home Assistant custom components

## `hermes_conversation`

Makes **Jarvis** — a [Hermes Agent](https://github.com/NousResearch/hermes-agent)
instance on `192.168.10.56` — selectable as the **Conversation agent** for a
Home Assistant voice assistant, so the Voice PE's brain is Hermes instead of HA
Assist. Home Assistant keeps the hardware, wake word, Whisper and Piper.

Full architecture: `calypso-deploy` → `hermes/README.md`.

| | |
|---|---|
| Upstream | [WolframRavenwolf/hermes-ha-integration](https://github.com/WolframRavenwolf/hermes-ha-integration) (MIT) |
| Vendored at | `97bb3c74c6f966e2d8c709d06694ff2c5a8fef77` |
| Integration version | `1.1.0` |

### Why vendored instead of HACS

HACS is not installed here, and installing it would put this integration outside
GitOps — the one thing this repo exists to avoid. Vendoring keeps the code
reviewable in a pull request and reproducible from a clean cluster.

It is viable specifically because the integration declares `"requirements": []`.
It talks to Hermes over Home Assistant's own HTTP client with no external Python
dependencies, so it works from a **read-only** ConfigMap mount — HA could not
`pip install` into one.

### How it's mounted

`kustomization.yaml` generates a ConfigMap from these files with flat keys
(ConfigMap keys cannot contain `/`). The HelmRelease's `persistence.hermes-conversation.items`
maps those keys back onto the nested layout HA's loader expects, which is how
`translations/en.json` ends up in a subdirectory.

The ConfigMap name is **not** content-hashed, matching the dashboards ConfigMap
alongside it. That means a change here does *not* automatically roll the pod, and
Python is only imported at startup — so an update needs a restart (below).

### Updating

Renovate does not track this — it is copied source, not a pinned image or chart.
To pick up a new upstream release:

```bash
REPO=WolframRavenwolf/hermes-ha-integration
PIN=<new-commit-sha>
DEST=kubernetes/apps/default/home-assistant/app/custom_components/hermes_conversation

for f in __init__.py api.py compat.py config_flow.py const.py \
         conversation.py manifest.json strings.json; do
  gh api "repos/$REPO/contents/custom_components/hermes_conversation/$f?ref=$PIN" \
    --jq '.content' | base64 -d > "$DEST/$f"
done
gh api "repos/$REPO/contents/custom_components/hermes_conversation/translations/en.json?ref=$PIN" \
  --jq '.content' | base64 -d > "$DEST/translations/en.json"
```

Then:

1. If upstream **added or removed a file**, update *both* the `files:` list in
   `kustomization.yaml` and the `items:` list in `helmrelease.yaml`. They must
   stay in sync — a key present in one and not the other silently yields a
   missing file, and HA fails to load the integration with an import error.
2. Check `manifest.json` still has `"requirements": []`. If upstream adds a
   dependency, the read-only ConfigMap approach stops working and this needs
   rethinking (an init container copying onto the NFS config volume, or HACS).
3. Update the commit SHA and version in the table above.
4. Restart Home Assistant to reimport:
   `kubectl -n default rollout restart deployment home-assistant`

### Configuration

Connection settings are entered in the HA UI (**Settings → Devices & Services →
Add Integration → Hermes Agent**), not here — which is deliberate, since it keeps
the Hermes API key out of git. Point it at host `192.168.10.56`, port `8642`,
**Use HTTPS off** (Hermes' API server is plain HTTP on the LAN, behind a Proxmox
firewall rule), and the API key matching `HERMES_API_SERVER_KEY` in
calypso-deploy.
