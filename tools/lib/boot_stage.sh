#!/usr/bin/env bash
# GLUE - run TOOL 03 then TOOL 04 over every boot-type image
set -uo pipefail
RAW="${RAW:?}"
DUMP="${DUMP:?}"
TOOLS="${TOOLS:?}"
cd "$RAW" || exit 1

for base in boot init_boot vendor_boot vendor_kernel_boot recovery; do
  [ -f "$base.img" ] || continue
  echo
  python3 "$TOOLS/03_bootimg_unpack.py" "$base.img" "$DUMP/$base"
done

echo
echo ">> turning every ramdisk blob into real files:"
for d in "$DUMP"/boot "$DUMP"/init_boot "$DUMP"/vendor_boot "$DUMP"/vendor_kernel_boot "$DUMP"/recovery; do
  [ -d "$d" ] || continue
  for rd in "$d"/ramdisk "$d"/recovery_ramdisk "$d"/dlkm_ramdisk "$d"/*_ramdisk; do
    [ -f "$rd" ] || continue
    bash "$TOOLS/04_ramdisk_extract.sh" "$rd" "$rd.d"
    if [ -d "$rd.d" ]; then mv "$rd.d" "$rd"; fi
  done
done

echo
echo ">> RECOVERY EVIDENCE (this is what the recovery tree is built from):"
if [ -d "$DUMP/vendor_boot/recovery_ramdisk" ]; then
  ls -la "$DUMP/vendor_boot/recovery_ramdisk" | head -30
else
  echo "   (no vendor_boot/recovery_ramdisk directory)"
fi
find "$DUMP" -maxdepth 4 \( -name 'recovery.fstab' -o -name 'fstab*' -o -name 'init.recovery*.rc' \) 2>/dev/null | head -15
exit 0
