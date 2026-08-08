#!/usr/bin/env bash
# TOOL 05 - unpack_fs (OURS) : partition image -> real file tree
# detects sparse / EROFS / ext4 / f2fs by magic bytes and uses the right
# extractor, with real fallbacks. Never guesses, never silently "succeeds".
# usage: 05_unpack_fs.sh <image> <dest-dir>
set -uo pipefail
IMG="$1"
DEST="$2"
[ -f "$IMG" ] || exit 0

name=$(basename "$IMG")
m0=$(od -An -tx1 -N4 -j0 "$IMG" 2>/dev/null | tr -d ' \n')
m1024=$(od -An -tx1 -N4 -j1024 "$IMG" 2>/dev/null | tr -d ' \n')
m1080=$(od -An -tx1 -N2 -j1080 "$IMG" 2>/dev/null | tr -d ' \n')

FS="unknown"
case "$m0" in
  3aff26ed) FS="sparse" ;;
esac
if [ "$FS" = "unknown" ]; then
  case "$m1024" in
    e2e1f5e0) FS="erofs" ;;
    1020f5f2) FS="f2fs" ;;
  esac
fi
if [ "$FS" = "unknown" ] && [ "$m1080" = "53ef" ]; then FS="ext4"; fi

echo "--- $name : $(du -h "$IMG" | cut -f1), fs=$FS (magic $m0 / $m1024) ---"

if [ "$FS" = "sparse" ]; then
  if command -v simg2img >/dev/null 2>&1; then
    RAW="${IMG%.img}.raw.img"
    simg2img "$IMG" "$RAW" && rm -f "$IMG" && mv "$RAW" "$IMG"
    echo ">> sparse -> raw done, re-detecting"
    exec "$0" "$IMG" "$DEST"
  fi
  echo "::warning::$name is sparse but simg2img is missing"
  exit 0
fi

mkdir -p "$DEST"
OK=0

if [ "$FS" = "erofs" ] && command -v fsck.erofs >/dev/null 2>&1; then
  if fsck.erofs "--extract=$DEST" --overwrite "$IMG" >/dev/null 2>&1 \
     || fsck.erofs "--extract=$DEST" "$IMG" >/dev/null 2>&1; then
    OK=1; VIA="fsck.erofs"
  fi
fi

if [ "$OK" = 0 ]; then
  MP=$(mktemp -d /tmp/x6886_mnt.XXXXXX)
  if sudo mount -o ro,loop "$IMG" "$MP" 2>/dev/null; then
    sudo cp -a "$MP/." "$DEST/" 2>/dev/null
    sudo umount "$MP" 2>/dev/null
    sudo chown -R "$(id -u):$(id -g)" "$DEST" 2>/dev/null
    OK=1; VIA="kernel mount"
  fi
  rmdir "$MP" 2>/dev/null || true
fi

if [ "$OK" = 0 ] && [ "$FS" = "ext4" ] && command -v debugfs >/dev/null 2>&1; then
  if debugfs -R "rdump / $DEST" "$IMG" >/dev/null 2>&1; then OK=1; VIA="debugfs"; fi
fi

if [ "$OK" = 0 ] && command -v 7z >/dev/null 2>&1; then
  if 7z x -y -o"$DEST" "$IMG" >/dev/null 2>&1; then OK=1; VIA="7z (last resort)"; fi
fi

N=$(find "$DEST" -type f 2>/dev/null | wc -l)
if [ "$OK" = 1 ] && [ "$N" -gt 0 ]; then
  echo ">> $name -> $DEST/  : $N files, $(du -sh "$DEST" | cut -f1)  (via $VIA)"
  exit 0
fi

echo "::warning::$name could not be extracted (fs=$FS) - the raw image is kept so nothing is lost"
rmdir "$DEST" 2>/dev/null || true
exit 0
