#!/usr/bin/env bash
# GLUE - free the runner disk and pick the biggest volume as our workspace
set -uo pipefail
echo ">> disk BEFORE cleanup:"
df -h
sudo rm -rf /usr/local/lib/android /usr/share/dotnet /opt/ghc /usr/local/.ghcup \
            /usr/share/swift /usr/local/share/boost /usr/local/lib/node_modules \
            /opt/hostedtoolcache/CodeQL /usr/share/miniconda 2>/dev/null || true
sudo docker image prune -af >/dev/null 2>&1 || true
sudo apt-get clean || true
echo ">> disk AFTER cleanup:"
df -h
BEST=""
BESTKB=0
for c in /mnt "${RUNNER_TEMP:-/tmp}" "$HOME"; do
  [ -d "$c" ] || continue
  KB=$(df -Pk "$c" | awk 'NR==2{print $4}')
  echo "   candidate $c -> $(( ${KB:-0} / 1048576 )) GB free"
  if [ "${KB:-0}" -gt "$BESTKB" ]; then BESTKB="$KB"; BEST="$c"; fi
done
if [ -z "$BEST" ]; then
  echo "::error::could not find a writable volume"
  exit 1
fi
WORK="$BEST/androiddump"
sudo mkdir -p "$WORK"
sudo chown -R "$(id -u):$(id -g)" "$WORK"
mkdir -p "$WORK/dl" "$WORK/raw" "$WORK/dump"
{
  echo "WORK=$WORK"
  echo "DL=$WORK/dl"
  echo "RAW=$WORK/raw"
  echo "DUMP=$WORK/dump"
  echo "TOOLS=$GITHUB_WORKSPACE/tools"
} >> "$GITHUB_ENV"
echo ">> WORKSPACE = $WORK  ($(( BESTKB / 1048576 )) GB free)"
