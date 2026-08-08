#!/usr/bin/env bash
# TOOL 01 - fetch_ota  (OURS) : download + verify the OTA, refuse garbage early
# usage: 01_fetch.sh <link> <out.zip>
set -uo pipefail
LINK="$1"
OUT="$2"
DIR=$(dirname "$OUT")
mkdir -p "$DIR"

if [ -s "$OUT" ]; then
  echo ">> already have $(basename "$OUT") ($(du -h "$OUT" | cut -f1)) - skipping download"
else
  echo ">> downloading with aria2c (16 connections)"
  aria2c -x16 -s16 -k16M --file-allocation=none --console-log-level=warn \
    --summary-interval=30 --retry-wait=5 -m 5 \
    -d "$DIR" -o "$(basename "$OUT")" "$LINK" \
    || { echo ">> aria2c failed, falling back to curl"; curl -fL --retry 3 -o "$OUT" "$LINK"; }
fi

[ -s "$OUT" ] || { echo "::error::download produced no file"; exit 1; }
SZ=$(stat -c%s "$OUT")
echo ">> package: $(du -h "$OUT" | cut -f1) ($SZ bytes)"
if [ "$SZ" -lt 104857600 ]; then
  echo "::error::package is only $SZ bytes - the link is dead or returned an error page"
  head -c 400 "$OUT"
  exit 1
fi

if ! unzip -l "$OUT" >/dev/null 2>&1; then
  echo "::error::not a valid zip archive"
  exit 1
fi
if ! unzip -l "$OUT" | grep -q 'payload\.bin'; then
  echo "::error::no payload.bin inside - this is not a full A/B OTA"
  unzip -l "$OUT" | head -30
  exit 1
fi

META=$(unzip -p "$OUT" META-INF/com/android/metadata 2>/dev/null || true)
if [ -n "$META" ]; then
  printf '%s\n' "$META" > "$DIR/ota_metadata.txt"
  echo ">> OTA metadata:"
  printf '%s\n' "$META" | head -20
  if printf '%s' "$META" | grep -q 'pre-build-incremental'; then
    echo "::error::this is an INCREMENTAL OTA (diffs only) - a FULL OTA is required"
    exit 1
  fi
fi
echo ">> TOOL 01 OK - full A/B OTA verified"
