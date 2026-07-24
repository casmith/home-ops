#!/usr/bin/env bash
# Transmission script-torrent-done hook.
# Stages completed audiobook torrents into an ingest dir for beets.
# Install on 192.168.10.101, chmod 0755, owned by the transmission user.
set -euo pipefail

INGEST=/downloads/ingest/audiobooks
LOG=/var/log/transmission-ingest.log
INGEST_GID=100   # must match the beets pod's runAsGroup

log() { echo "$(date -Is) $*" >>"$LOG"; }

# Transmission 4.x only. On 3.x there is no label env var — filter on
# TR_TORRENT_DIR with a per-torrent download location instead.
case "${TR_TORRENT_LABELS:-}" in
  *audiobook*) ;;
  *) exit 0 ;;
esac

src="${TR_TORRENT_DIR}/${TR_TORRENT_NAME}"
dst="${INGEST}/${TR_TORRENT_NAME}"

mkdir -p "$INGEST"

if [ -e "$dst" ]; then
  log "skip, already staged: ${TR_TORRENT_NAME}"
  exit 0
fi

# Stage under .part and rename into place. Rename within one directory is
# atomic, so the beets cronjob never sees a half-written tree.
stage() {
  if cp -al "$src" "$dst.part" 2>/dev/null; then
    log "linked: ${TR_TORRENT_NAME}"
  else
    # Different filesystem — fall back to a real copy.
    rm -rf "$dst.part"
    cp -r "$src" "$dst.part"
    log "copied: ${TR_TORRENT_NAME}"
  fi
  # beets runs as gid 100 and needs to unlink these after import.
  chgrp -R "$INGEST_GID" "$dst.part" 2>/dev/null || true
  chmod -R g+rwX "$dst.part"
  mv "$dst.part" "$dst"
}

# Hardlinks are instant; a cross-filesystem copy is not, and transmission
# blocks on this script. Background the slow path so the daemon stays
# responsive.
if [ "$(stat -c %d "$src")" = "$(stat -c %d "$INGEST")" ]; then
  stage
else
  stage &
fi
