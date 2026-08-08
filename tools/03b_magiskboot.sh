#!/usr/bin/env bash
# TOOL 03b - THE REAL magiskboot
#
# Why this works when DumprX's magiskboot died with "Illegal instruction":
# DumprX ships a prebuilt magiskboot for the wrong CPU/libc. The OFFICIAL
# magiskboot inside the Magisk APK is a statically linked Linux binary, and
# lib/x86_64/libmagiskboot.so runs natively on any x86_64 Linux host.
# This is the documented way to get magiskboot on a PC (KernelSU docs, and
# magiskboot_build's own release notes say to use the official APK binary).
#
# usage:
#   03b_magiskboot.sh get
#   03b_magiskboot.sh unpack <image.img> <outdir>
#   03b_magiskboot.sh cpio <ramdisk.cpio> <outdir>
set -uo pipefail

MAGISK_VER="${MAGISK_VER:-v30.7}"
BINDIR="${BINDIR:-/usr/local/bin}"
MB="${BINDIR}/magiskboot"

usable() { [ -x "$MB" ] && "$MB" 2>&1 | head -1 | grep -qi 'usage'; }

get_magiskboot() {
  if usable; then
    echo ">> magiskboot already present: $("$MB" 2>&1 | head -1)"
    return 0
  fi

  local lib
  case "$(uname -m)" in
    x86_64|amd64)  lib="lib/x86_64/libmagiskboot.so" ;;
    aarch64|arm64) lib="lib/arm64-v8a/libmagiskboot.so" ;;
    i?86)          lib="lib/x86/libmagiskboot.so" ;;
    *) echo "::warning::unknown CPU $(uname -m) - magiskboot skipped"; return 1 ;;
  esac
  echo ">> host CPU $(uname -m) -> taking ${lib} from the official Magisk APK"

  local apk="/tmp/magisk.apk" url ok=0
  for url in \
    "https://github.com/topjohnwu/Magisk/releases/download/${MAGISK_VER}/Magisk-${MAGISK_VER}.apk" \
    "https://github.com/topjohnwu/Magisk/releases/download/v29.0/Magisk-v29.0.apk" \
    "https://github.com/topjohnwu/Magisk/releases/download/v28.1/Magisk-v28.1.apk"
  do
    echo "   trying ${url}"
    if curl -fsSL --retry 3 --retry-delay 3 -o "$apk" "$url" && [ -s "$apk" ]; then ok=1; break; fi
  done
  [ "$ok" = 1 ] || { echo "::warning::could not download the Magisk APK"; return 1; }

  if ! unzip -p "$apk" "$lib" > "$MB" 2>/dev/null || [ ! -s "$MB" ]; then
    echo "::warning::${lib} not found inside the APK"; rm -f "$MB" "$apk"; return 1
  fi
  chmod 0755 "$MB"
  rm -f "$apk"

  if ! usable; then
    echo "::warning::the magiskboot binary does not run here - our python tools will do the work"
    rm -f "$MB"; return 1
  fi
  echo ">> REAL magiskboot ready: $("$MB" 2>&1 | head -1)"
  "$MB" 2>&1 | sed -n '1,6p' | sed 's/^/     /'
}

do_unpack() {
  local img="$1" out="$2" abs
  usable || { echo "::warning::magiskboot unavailable - skipping"; return 1; }
  [ -s "$img" ] || { echo "::warning::$img missing"; return 1; }
  abs="$(readlink -f "$img")"
  mkdir -p "$out" || return 1
  echo "---- magiskboot unpack $(basename "$img") ----"
  # -h also dumps the parsed header next to the components
  ( cd "$out" && "$MB" unpack -h "$abs" ) 2>&1 | sed 's/^/     /'
  local rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then
    echo "::warning::magiskboot unpack returned ${rc} for $(basename "$img")"
    return 1
  fi
  ls -lh "$out" | sed 's/^/     /'
  return 0
}

do_cpio() {
  local cpio="$1" out="$2" abs
  usable || return 1
  [ -s "$cpio" ] || return 1
  abs="$(readlink -f "$cpio")"
  mkdir -p "$out" || return 1
  ( cd "$out" && "$MB" cpio "$abs" extract ) >/dev/null 2>&1 || return 1
  [ -n "$(ls -A "$out" 2>/dev/null)" ]
}

case "${1:-get}" in
  get)    get_magiskboot ;;
  unpack) shift; do_unpack "$@" ;;
  cpio)   shift; do_cpio "$@" ;;
  *) echo "usage: 03b_magiskboot.sh get|unpack|cpio"; exit 2 ;;
esac
