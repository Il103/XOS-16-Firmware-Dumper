#!/usr/bin/env bash
# Filesystem stage: magic-byte routing into TOOL 05.
# Every raw .img now lives in images/ instead of being scattered at the dump root.
set -uo pipefail
: "${RAW:?}"
: "${DUMP:?}"
: "${TOOLS:?}"
KEEP="${KEEP_BIG_IMAGES:-false}"
IMGDIR="$DUMP/images"
mkdir -p "$IMGDIR"

BOOTISH=" boot init_boot vendor_boot vendor_kernel_boot recovery "

for img in "$RAW"/*.img; do
  [ -f "$img" ] || continue
  base="$(basename "$img" .img)"

  case "$BOOTISH" in
    *" $base "*)
      mv -f "$img" "$IMGDIR/${base}.img"
      echo ">> ${base}.img -> images/   (boot image, always kept raw)"
      continue
      ;;
  esac

  m0=$(od -An -tx1 -N4 -j0    "$img" 2>/dev/null | tr -d ' \n')
  m1024=$(od -An -tx1 -N4 -j1024 "$img" 2>/dev/null | tr -d ' \n')
  m1080=$(od -An -tx1 -N2 -j1080 "$img" 2>/dev/null | tr -d ' \n')

  fs=""
  [ "$m0" = "3aff26ed" ] && fs="sparse"
  if [ -z "$fs" ]; then
    case "$m1024" in
      e2e1f5e0) fs="erofs" ;;
      1020f5f2) fs="f2fs" ;;
    esac
  fi
  [ -z "$fs" ] && [ "$m1080" = "53ef" ] && fs="ext4"

  if [ -z "$fs" ]; then
    mv -f "$img" "$IMGDIR/${base}.img"
    echo ">> ${base}.img -> images/   (firmware blob, magic ${m0} - not a filesystem, never fed to 7z)"
    continue
  fi

  echo
  echo "==== ${base}.img : ${fs} ===="
  bash "$TOOLS/05_unpack_fs.sh" "$img" "$DUMP/$base" 2>&1 | sed 's/^/   /'

  if [ -d "$DUMP/$base" ] && [ -n "$(ls -A "$DUMP/$base" 2>/dev/null)" ]; then
    n=$(find "$DUMP/$base" -type f | wc -l)
    echo ">> ${base}/ has ${n} real files"
    if [ "$KEEP" = "true" ]; then
      mv -f "$img" "$IMGDIR/${base}.img" 2>/dev/null || true
      echo "   KEEP_BIG_IMAGES=true -> raw ${base}.img also copied to images/"
    else
      rm -f "$img"
      echo "   raw ${base}.img dropped (the extracted tree IS the content)"
    fi
  else
    mv -f "$img" "$IMGDIR/${base}.img" 2>/dev/null || true
    echo "::warning::${base} could not be extracted - the raw image is kept in images/ so nothing is lost"
  fi
done

echo
echo "==== dump root now ===="
ls -la "$DUMP" | sed 's/^/   /'
echo "==== images/ ===="
ls -lh "$IMGDIR" 2>/dev/null | sed 's/^/   /'
