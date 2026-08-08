#!/usr/bin/env bash
# Boot stage: REAL magiskboot first, our python parser for the vendor_boot v4
# fragment table (magiskboot merges vendor ramdisk fragments, so it alone would
# lose the separate recovery ramdisk), then TOOL 04 turns every ramdisk into files.
set -uo pipefail
: "${RAW:?}"
: "${DUMP:?}"
: "${TOOLS:?}"
MB="/usr/local/bin/magiskboot"

echo "#################### getting the REAL magiskboot ####################"
bash "$TOOLS/03b_magiskboot.sh" get || true

BOOTISH="boot init_boot vendor_boot vendor_kernel_boot recovery"
for b in $BOOTISH; do
  img="$RAW/${b}.img"
  if [ ! -s "$img" ]; then
    echo ">> no ${b}.img in this OTA - skipping"
    continue
  fi
  out="$DUMP/$b"
  mkdir -p "$out"
  echo
  echo "#################### ${b}.img ($(du -h "$img" | cut -f1)) ####################"

  mbdir="$(mktemp -d /tmp/mb_XXXXXX)"
  if [ -x "$MB" ]; then
    if bash "$TOOLS/03b_magiskboot.sh" unpack "$img" "$mbdir"; then
      echo "   magiskboot produced:"
      ls -lh "$mbdir" 2>/dev/null | sed 's/^/     /'
      [ -s "$mbdir/header" ] && cp -f "$mbdir/header" "$out/magiskboot_header.txt"
    fi
  fi

  echo "   ---- our parser (keeps the v4 fragment table intact) ----"
  python3 "$TOOLS/03_bootimg_unpack.py" "$img" "$out" 2>&1 | sed 's/^/     /' \
    || echo "::warning::parser failed on ${b}.img"

  # magiskboot decompresses on the fly, so its kernel/dtb are the nicer artifacts
  if [ -s "$mbdir/kernel" ]; then
    cp -f "$mbdir/kernel" "$out/kernel"
    echo "   kernel: using magiskboot's copy (auto-decompressed)"
  fi
  for c in dtb kernel_dtb recovery_dtbo second extra; do
    if [ ! -s "$out/$c" ] && [ -s "$mbdir/$c" ]; then
      cp -f "$mbdir/$c" "$out/$c"
      echo "   ${c}: taken from magiskboot"
    fi
  done
  if [ ! -s "$out/ramdisk" ] && [ -s "$mbdir/ramdisk.cpio" ]; then
    cp -f "$mbdir/ramdisk.cpio" "$out/ramdisk"
    echo "   ramdisk: taken from magiskboot (already decompressed)"
  fi
  rm -rf "$mbdir"

  # every ramdisk blob -> a real directory
  for rd in "$out"/ramdisk "$out"/*_ramdisk; do
    [ -f "$rd" ] || continue
    bash "$TOOLS/04_ramdisk_extract.sh" "$rd" "${rd}.d" 2>&1 | sed 's/^/     /'
    if [ -d "${rd}.d" ] && [ -n "$(ls -A "${rd}.d" 2>/dev/null)" ]; then
      rm -f "$rd"
      mv "${rd}.d" "$rd"
    else
      rm -rf "${rd}.d"
    fi
  done

  if [ -s "$out/dtb" ] && command -v dtc >/dev/null 2>&1; then
    dtc -q -I dtb -O dts -o "$out/dtb.dts" "$out/dtb" 2>/dev/null \
      && echo "   dtb decompiled -> dtb.dts"
  fi

  echo "   ---- ${b} result ----"
  du -sh "$out"/* 2>/dev/null | sed 's/^/     /'
done

echo
if [ -d "$DUMP/vendor_boot/recovery_ramdisk" ] && [ -n "$(ls -A "$DUMP/vendor_boot/recovery_ramdisk" 2>/dev/null)" ]; then
  echo "::notice::recovery_ramdisk extracted OK - $(find "$DUMP/vendor_boot/recovery_ramdisk" -type f | wc -l) files. The recovery tree can be built from this."
  ls "$DUMP/vendor_boot/recovery_ramdisk" | sed 's/^/     /'
  find "$DUMP/vendor_boot/recovery_ramdisk" -maxdepth 3 -name 'recovery.fstab' -o -maxdepth 3 -name '*fstab*' 2>/dev/null | sed 's/^/     found: /'
else
  echo "::warning::no recovery_ramdisk was produced - check the fragment table output above"
fi
