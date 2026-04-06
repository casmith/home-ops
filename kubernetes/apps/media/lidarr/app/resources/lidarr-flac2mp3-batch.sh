#!/usr/bin/env bash
set -Eeuo pipefail

FLAC2MP3_SCRIPT="${FLAC2MP3_SCRIPT:-/config/scripts/flac2mp3.sh}"
MUSIC_DIR="${MUSIC_DIR:-/music}"

MODE=""
DRY_RUN=0
KEEP_FILE=0
LIMIT=0

function usage() {
    cat <<'EOF'
Usage:
  lidarr-flac2mp3-batch.sh --list
  lidarr-flac2mp3-batch.sh --convert [--dry-run] [--keep-file] [--limit N] [-- FLAC2MP3_ARGS...]

Environment variables:
  FLAC2MP3_SCRIPT   Path to flac2mp3.sh (default: /config/scripts/flac2mp3.sh)
  MUSIC_DIR         Root directory to search for FLAC files (default: /music)

Examples:
  lidarr-flac2mp3-batch.sh --list
  lidarr-flac2mp3-batch.sh --convert
  lidarr-flac2mp3-batch.sh --convert --keep-file -- -b 256k
  lidarr-flac2mp3-batch.sh --convert --dry-run -- -v 0
EOF
}

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

EXTRA_ARGS=()
while (($#)); do
    case "$1" in
        --list)
            MODE="list"
            shift
            ;;
        --convert)
            MODE="convert"
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --keep-file)
            KEEP_FILE=1
            shift
            ;;
        --limit)
            LIMIT="${2:-}"
            if [[ -z "$LIMIT" || ! "$LIMIT" =~ ^[0-9]+$ ]]; then
                echo "Error: --limit requires a positive integer" >&2
                exit 2
            fi
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --)
            shift
            EXTRA_ARGS=("$@")
            break
            ;;
        *)
            echo "Error: Unknown argument '$1'" >&2
            usage
            exit 2
            ;;
    esac
done

if [[ -z "$MODE" ]]; then
    echo "Error: choose one of --list or --convert" >&2
    usage
    exit 2
fi

if [[ ! -d "$MUSIC_DIR" ]]; then
    echo "Error: music directory does not exist: $MUSIC_DIR" >&2
    exit 3
fi

if [[ "$MODE" == "convert" && ! -x "$FLAC2MP3_SCRIPT" ]]; then
    echo "Error: flac2mp3 script is missing or not executable: $FLAC2MP3_SCRIPT" >&2
    exit 4
fi

mapfile -d '' FLAC_FILES < <(find "$MUSIC_DIR" -type f -iname '*.flac' -print0)
TOTAL="${#FLAC_FILES[@]}"

if [[ "$MODE" == "list" ]]; then
    if ((TOTAL == 0)); then
        echo "No .flac files found under $MUSIC_DIR"
        exit 0
    fi

    printf '%s\n' "${FLAC_FILES[@]}"
    echo "Total .flac files: $TOTAL"
    exit 0
fi

if ((TOTAL == 0)); then
    echo "No .flac files found under $MUSIC_DIR"
    exit 0
fi

echo "Found $TOTAL .flac files under $MUSIC_DIR"
if ((LIMIT > 0)); then
    echo "Limit enabled: converting first $LIMIT file(s)"
fi

converted=0
failed=0
processed=0

for file in "${FLAC_FILES[@]}"; do
    ((processed += 1))
    if ((LIMIT > 0 && processed > LIMIT)); then
        break
    fi

    cmd=("$FLAC2MP3_SCRIPT" -f "$file")
    if ((KEEP_FILE == 1)); then
        cmd+=(--keep-file)
    fi
    if ((${#EXTRA_ARGS[@]} > 0)); then
        cmd+=("${EXTRA_ARGS[@]}")
    fi

    echo "[$processed] Converting: $file"

    if ((DRY_RUN == 1)); then
        printf 'DRY RUN: '
        printf '%q ' "${cmd[@]}"
        echo
        continue
    fi

    if "${cmd[@]}"; then
        ((converted += 1))
    else
        ((failed += 1))
        echo "[$processed] Failed: $file" >&2
    fi
done

echo "Finished. Converted: $converted, Failed: $failed"
if ((failed > 0)); then
    exit 1
fi
