#!/usr/bin/env bash
# TOOL 06 - dump_meta (OURS) : make the tree look like a REAL dump
# all_files.txt + board-info.txt + README.md + proprietary-files.txt + kernel config
# usage: 06_dump_meta.sh <dumpdir>
set -uo pipefail
DUMP="$1"
cd "$DUMP" || exit 1

prop() {
  local key="$1"
  local f
  for f in system/system/build.prop system/build.prop vendor/build.prop \
           system_ext/etc/build.prop product/etc/build.prop odm/etc/build.prop \
           vendor/odm/etc/build.prop system/system/etc/build.prop; do
    [ -f "$f" ] || continue
    local v
    v=$(grep -m1 "^${key}=" "$f" 2>/dev/null | cut -d= -f2-)
    if [ -n "${v:-}" ]; then printf '%s' "$v"; return 0; fi
  done
  printf ''
}

first() {
  local k
  for k in "$@"; do
    local v
    v=$(prop "$k")
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  done
  printf ''
}

FP=$(first ro.build.fingerprint ro.system.build.fingerprint ro.vendor.build.fingerprint)
DESC=$(first ro.build.description ro.system.build.description)
BRAND_P=$(first ro.product.brand ro.product.system.brand ro.product.vendor.brand)
DEVICE_P=$(first ro.product.device ro.product.system.device ro.product.vendor.device ro.build.product)
MODEL_P=$(first ro.product.model ro.product.system.model ro.product.vendor.model)
PLATFORM_P=$(first ro.board.platform ro.hardware)
SDK=$(first ro.build.version.sdk ro.system.build.version.sdk)
REL=$(first ro.build.version.release ro.system.build.version.release)
INC=$(first ro.build.version.incremental ro.system.build.version.incremental)
SEC=$(first ro.build.version.security_patch)
BL=$(first ro.bootloader ro.boot.bootloader)
BB=$(first ro.baseband gsm.version.baseband ro.vendor.build.version.incremental)
ABILIST=$(first ro.product.cpu.abilist ro.system.product.cpu.abilist)
DENSITY=$(first ro.sf.lcd_density ro.vendor.sf.lcd_density)

# hard-locked identity wins over MSSI placeholders in build.prop
BRAND_F="${BRAND:-${BRAND_P:-unknown}}"
CODE_F="${CODENAME:-${DEVICE_P:-unknown}}"
MODEL_F="${MODEL:-${MODEL_P:-unknown}}"
PLAT_F="${PLATFORM:-${PLATFORM_P:-unknown}}"
FP_F="${FINGERPRINT:-$FP}"
BID_F="${BUILD_ID:-$(first ro.build.id)}"
AV_F="${ANDROID_VER:-$REL}"
KV_F="${KERNEL_VER:-}"
if [ -z "$KV_F" ] && [ -f boot/kernel ]; then
  KV_F=$(strings -n 20 boot/kernel 2>/dev/null | grep -m1 -oE 'Linux version [0-9][^ ]*' | awk '{print $3}')
fi

# ---------- board-info.txt (real dumps always have this) ----------
{
  [ -n "$PLAT_F" ] && echo "require board=${PLAT_F}"
  [ -n "$BL" ] && echo "require version-bootloader=${BL}"
  [ -n "$BB" ] && echo "require version-baseband=${BB}"
} > board-info.txt

# ---------- kernel config + version (nice-to-have, never fatal) ----------
if [ -f boot/kernel ]; then
  K=/tmp/x6886_kernel.raw
  { lz4 -d -c boot/kernel > "$K" 2>/dev/null \
    || gzip -dc boot/kernel > "$K" 2>/dev/null \
    || xz -dc boot/kernel > "$K" 2>/dev/null \
    || cp boot/kernel "$K"; } || true
  strings -n 20 "$K" 2>/dev/null | grep -m1 -E '^Linux version ' > kernel_version.txt || true
  python3 - "$K" <<'IKCFG' > kernel_config.txt 2>/dev/null || true
import sys, zlib
try:
    d = open(sys.argv[1], 'rb').read()
except OSError:
    raise SystemExit(1)
i = d.find(b'IKCFG_ST')
if i < 0:
    raise SystemExit(1)
blob = d[i + 8:]
sys.stdout.write(zlib.decompressobj(16 + 15).decompress(blob).decode('utf-8', 'replace'))
IKCFG
  [ -s kernel_config.txt ] || rm -f kernel_config.txt
  [ -s kernel_version.txt ] || rm -f kernel_version.txt
  rm -f "$K"
fi

# ---------- proprietary-files.txt ----------
find vendor vendor_dlkm odm odm_dlkm product system_ext system \
  -type f \( -name '*.so' -o -name '*.ko' -o -name '*.apk' -o -name '*.bin' \
             -o -name '*.xml' -o -name '*.rc' -o -name '*.conf' \) 2>/dev/null \
  | sed 's|^\./||' | sort > proprietary-files.txt || true

# ---------- README.md (AndroidDumps style) ----------
{
  echo "## ${DESC:-$FP_F}"
  echo
  echo "- Manufacturer: ${BRAND_F}"
  echo "- Platform: ${PLAT_F}"
  echo "- Codename: ${CODE_F}"
  echo "- Brand: ${BRAND_F}"
  echo "- Model: ${MODEL_F}"
  echo "- Release Version: ${AV_F}"
  echo "- SDK: ${SDK}"
  echo "- Kernel Version: ${KV_F}"
  echo "- Id: ${BID_F}"
  echo "- Incremental: ${INC}"
  echo "- Security Patch: ${SEC}"
  echo "- CPU Abilist: ${ABILIST}"
  echo "- Screen Density: ${DENSITY}"
  echo "- A/B Device: true"
  echo "- Treble Device: true"
  echo "- Fingerprint: ${FP_F}"
  echo "- Bootloader: ${BL}"
  echo "- Baseband: ${BB}"
  echo
  echo "### Dump contents"
  echo
  echo "| Path | Files | Size |"
  echo "| --- | --- | --- |"
  for d in $(find . -maxdepth 1 -mindepth 1 -type d -not -name '.git' -printf '%P\n' | sort); do
    echo "| ${d}/ | $(find "$d" -type f 2>/dev/null | wc -l) | $(du -sh "$d" 2>/dev/null | cut -f1) |"
  done
  echo
  echo "Raw partition images kept in this dump:"
  echo
  for f in $(ls -1 *.img 2>/dev/null | sort); do
    echo "- ${f} ($(du -h "$f" | cut -f1))"
  done
  echo
  echo "Dumped with our own tools on GitHub Actions (payload/bootimg/ramdisk/fs extractors written from scratch)."
} > README.md

# ---------- all_files.txt (must be LAST - it indexes everything) ----------
find . -type f -not -path './.git/*' -printf '%P\n' 2>/dev/null | sort > all_files.txt

echo ">> TOOL 06 OK"
echo "   fingerprint : ${FP_F}"
echo "   board-info  : $(tr '\n' ' ' < board-info.txt)"
echo "   files       : $(wc -l < all_files.txt)"
echo "   dump size   : $(du -sh --exclude=.git . | cut -f1)"
