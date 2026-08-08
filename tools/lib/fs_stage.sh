#!/usr/bin/env bash
# GLUE - decide what each remaining .img really is, then run TOOL 05 on filesystems
# A firmware blob is NEVER fed to an extractor, it is kept raw at the dump root.
set -uo pipefail
RAW="${RAW:?}"
DUMP="${DUMP:?}"
TOOLS="${TOOLS:?}"
KEEP_BIG="${KEEP_BIG_IMAGES:-false}"
BOOTISH=" boot init_boot vendor_boot vendor_kernel_boot recovery "
cd "$RAW" || exit 1
shopt -s nullglob

for f in *.img; do
  base="${f%.img}"
  case "$BOOTISH" in *" $base "*) continue ;; esac
  m0=$(od -An -tx1 -N4 -j0 "$f" 2>/dev/null | tr -d ' \n')
  m1024=$(od -An -tx1 -N4 -j1024 "$f" 2>/dev/null | tr -d ' \n')
  m1080=$(od -An -tx1 -N2 -j1080 "$f" 2>/dev/null | tr -d ' \n')
  ISFS=0
  [ "$m0" = "3aff26ed" ] && ISFS=1
  [ "$m1024" = "e2e1f5e0" ] && ISFS=1
  [ "$m1024" = "1020f5f2" ] && ISFS=1
  [ "$m1080" = "53ef" ] && ISFS=1
  if [ "$ISFS" = 0 ]; then
    echo "--- $f : firmware blob ($(du -h "$f" | cut -f1)) -> kept RAW at the dump root"
    mv -f "$f" "$DUMP/"
    continue
  fi
  bash "$TOOLS/05_unpack_fs.sh" "$f" "$DUMP/$base"
  if [ -d "$DUMP/$base" ]; then
    if [ "$KEEP_BIG" = "true" ]; then mv -f "$f" "$DUMP/"; else rm -f "$f"; fi
  else
    mv -f "$f" "$DUMP/"
  fi
  df -h "$DUMP" | tail -1
done

for base in boot init_boot vendor_boot vendor_kernel_boot recovery; do
  if [ -f "$base.img" ]; then mv -f "$base.img" "$DUMP/"; fi
done

echo
echo ">> the dump root now looks like a normal dump:"
ls -la "$DUMP"
echo ">> total on disk: $(du -sh "$DUMP" | cut -f1)"
exit 0
