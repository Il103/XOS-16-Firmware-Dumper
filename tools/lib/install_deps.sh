#!/usr/bin/env bash
# GLUE - install every extractor we depend on, then REPORT what we really got
set -uo pipefail
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  aria2 curl jq unzip zip cpio rsync p7zip-full \
  lz4 zstd xz-utils brotli bzip2 binutils \
  erofs-utils e2fsprogs f2fs-tools android-sdk-libsparse-utils \
  device-tree-compiler \
  git git-lfs python3
git lfs install --skip-repo || true
echo ">> what we actually have:"
MISS=0
for b in aria2c curl jq unzip 7z cpio lz4 zstd xz fsck.erofs debugfs simg2img dtc python3 git git-lfs; do
  P=$(command -v "$b" 2>/dev/null || true)
  if [ -n "$P" ]; then
    printf '   %-13s %s\n' "$b" "$P"
  else
    printf '   %-13s ** MISSING **\n' "$b"
    MISS=$(( MISS + 1 ))
  fi
done
echo ">> missing: $MISS"
echo ">> note: unzip is what pulls the real magiskboot out of the Magisk APK (TOOL 03b)"
echo ">>       fsck.erofs is what reads Android 16 EROFS partitions (TOOL 05)"
