#!/usr/bin/env bash
# TOOL 04 - ramdisk_extract (OURS) : any compressed ramdisk -> real files
# handles lz4_legacy (MTK), lz4, gzip, xz, zstd, lzma, bzip2 and raw cpio
# usage: 04_ramdisk.sh <ramdisk-blob> <dest-dir>
set -uo pipefail
RD="$1"
DEST="$2"

[ -f "$RD" ] || exit 0
SZ=$(stat -c%s "$RD" 2>/dev/null || echo 0)
if [ "$SZ" -lt 512 ]; then
  echo ">> skip $(basename "$RD") - empty ($SZ bytes, normal for a GKI boot.img)"
  rm -f "$RD"
  exit 0
fi

MAGIC=$(od -An -tx1 -N4 "$RD" | tr -d ' \n')
TMP=$(mktemp /tmp/x6886_rd.XXXXXX)
USED=""
for m in "lz4 -d -c" "gzip -dc" "xz -dc" "zstd -dc" "lzma -dc" "bzip2 -dc" "cat"; do
  if $m "$RD" > "$TMP" 2>/dev/null && [ "$(stat -c%s "$TMP" 2>/dev/null || echo 0)" -gt 512 ]; then
    USED="$m"
    break
  fi
done

if [ -z "$USED" ]; then
  echo "::warning::could not decompress $(basename "$RD") (magic=$MAGIC) - keeping it raw"
  rm -f "$TMP"
  exit 0
fi

mkdir -p "$DEST"
if ( cd "$DEST" && cpio -idmu --no-absolute-filenames --quiet < "$TMP" ) 2>/dev/null; then
  N=$(find "$DEST" -mindepth 1 | wc -l)
  echo ">> EXTRACTED $(basename "$RD") -> $DEST  ($N entries, magic=$MAGIC, via: $USED)"
  find "$DEST" -maxdepth 2 \( -name 'fstab*' -o -name 'init*.rc' -o -name '*.recovery.rc' \) 2>/dev/null | head -8
  rm -f "$RD"
else
  echo "::warning::$(basename "$RD") decompressed with '$USED' but is not a cpio archive - kept raw"
  rmdir "$DEST" 2>/dev/null || true
fi
rm -f "$TMP"
