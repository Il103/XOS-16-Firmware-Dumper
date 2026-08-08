#!/usr/bin/env bash
# TOOL 03b - THE REAL magiskboot
#
# Why this works where DumprX's magiskboot died with "Illegal instruction":
# DumprX ships a prebuilt magiskboot for the wrong CPU/libc. The OFFICIAL
# magiskboot inside the Magisk APK is a statically linked Linux binary, and
# lib/x86_64/libmagiskboot.so runs natively on any x86_64 Linux host. This is
# the documented way to run magiskboot on a PC (KernelSU install docs, and
# magiskboot_build's own release notes point at the official APK binary).
#
# usage:
#   03b_magiskboot.sh get
#   03b_magiskboot.sh unpack <image.img> <outdir>
#   03b_magiskboot.sh cpio   <ramdisk.cpio> <outdir>
set -uo pipefail

BINDIR="${BINDIR:-/usr/local/bin}"
MB="${BINDIR}/magiskboot"
SCHEME="https"
GH_HOST="github.com"
REL_PATH="topjohnwu/Magisk/releases/download"
VERSIONS="${MAGISK_VERSIONS:-v30.7 v29.0 v28.1 v27.0}"

usable() { [ -x "$MB" ] && "$MB" 2>&1 | head -1 | grep -qi 'usage'; }

get_magiskboot() {
  if usable; then
    echo ">> magiskboot already here: $("$MB" 2>&1 | head -1)"
    return 0
  fi

  local lib
  case "$(uname -m)" in
    x86_64|amd64)  lib="lib/x86_64/libmagiskboot.so" ;;
    aarch64|arm64) lib="lib/arm64-v8a/libmagiskboot.so" ;;
    i?86)          lib="lib/x86/libmagiskboot.so" ;;
    *) echo "::warning::unknown CPU $(uname -m) - magiskboot skipped"; return 1 ;;
  esac
  echo ">> host CPU is $(uname -m), so we need ${lib} from the official Magisk APK"

  local apk="/tmp/magisk.apk" v url ok=0
  for v in $VERSIONS; do
    url="${SCHEME}://${GH_HOST}/${REL_PATH}/${v}/Magisk-${v}.apk"
    echo "   trying Magisk ${v}"
    rm -f "$apk"
    if curl -fsSL --retry 3 --retry-delay 3 -o "$apk" "$url" && [ -s "$apk" ]; then
      if unzip -p "$apk" "$lib" > "$MB" 2>/dev/null && [ -s "$MB" ]; then
        chmod 0755 "$MB"
        if usable; then ok=1; echo "   got magiskboot from Magisk ${v}"; break; fi
      fi
      rm -f "$MB"
    fi
  done
  rm -f "$apk"

  if [ "$ok" != 1 ]; then
    echo "::warning::could not get a working magiskboot - our python parser will do the whole job"
    rm -f "$MB"
    return 1
  fi
  echo ">> REAL magiskboot is live:"
  "$MB" 2>&1 | sed -n '1,8p' | sed 's/^/     /'
  return 0
}

do_unpack() {
  local img="$1" out="$2" abs rc
  usable || { echo "   (magiskboot unavailable)"; return 1; }
  [ -s "$img" ] || return 1
  abs="$(readlink -f "$img")"
  mkdir -p "$out" || return 1
  echo "   ---- magiskboot unpack -h $(basename "$img") ----"
  ( cd "$out" && "$MB" unpack -h "$abs" ) 2>&1 | sed 's/^/     /'
  rc=${PIPESTATUS[0]}
  [ "$rc" -eq 0 ] || { echo "::warning::magiskboot unpack exit ${rc} on $(basename "$img")"; return 1; }
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
