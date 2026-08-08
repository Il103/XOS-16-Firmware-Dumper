#!/usr/bin/env bash
# TOOL 07 - gitlab_push (OURS) : RESUMABLE, disk-smart, per-partition push
#
# The whole point: every partition is its own commit + its own push.
# - a partition that is pushed can NEVER be lost, even if the job dies later
# - re-running the workflow RESUMES: already-pushed groups are skipped
# - after each push the working copy is deleted, so disk never fills up
#
# usage: 07_gitlab_push.sh <dumpdir>
set -uo pipefail
DUMP="$1"
cd "$DUMP" || exit 1

SCHEME="https"
HOST="${GITLAB_HOST}"
API="${SCHEME}://${HOST}/api/v4"
TOK="${GITLAB_TOKEN}"
BR="${BRANCH_NAME}"
SLUG="${GITLAB_SLUG}"
PID="${GITLAB_PID}"
REMOTE="${SCHEME}://oauth2:${TOK}@${HOST}/${SLUG}.git"
STATE="dump_state.txt"
PUSHED_LIST=""
FAILED_AT=""

export GIT_LFS_SKIP_SMUDGE=1
export GIT_TERMINAL_PROMPT=0
git config --global --add safe.directory "$PWD" 2>/dev/null || true

git_setup() {
  git config user.name "${GIT_AUTHOR:-x6886-dumper}"
  git config user.email "${GIT_EMAIL:-dumper@users.noreply.github.com}"
  git config http.postBuffer 524288000
  git config http.version HTTP/1.1
  git config core.compression 6
  git config gc.auto 0
  git config lfs.concurrenttransfers 12
  git config lfs.activitytimeout 600
  git lfs install --local >/dev/null 2>&1 || true
}

# ---------------- resume or start fresh ----------------
if [ "${RESET_BRANCH:-false}" = "true" ]; then
  echo ">> RESET_BRANCH=true - starting this branch from scratch"
  rm -f "$STATE"
fi

if [ ! -d .git ]; then
  if [ "${RESET_BRANCH:-false}" != "true" ] && git ls-remote --heads "$REMOTE" "$BR" 2>/dev/null | grep -q .; then
    echo ">> RESUME: branch '$BR' already exists on ${HOST} - continuing the SAME dump"
    if git clone --no-checkout --filter=blob:none --depth=1 --branch "$BR" "$REMOTE" .gitclone >/dev/null 2>&1; then
      mv .gitclone/.git .git
      rm -rf .gitclone
      git_setup
      git reset --mixed HEAD >/dev/null 2>&1 || true
      # everything already on the server must never be re-added or deleted
      git ls-files -z | xargs -0 -r -n 500 git update-index --skip-worktree 2>/dev/null || true
      for f in .gitattributes "$STATE"; do
        git update-index --no-skip-worktree "$f" 2>/dev/null || true
        git checkout HEAD -- "$f" 2>/dev/null || true
      done
      echo ">> groups already on ${HOST}:"
      sed 's/^/     - /' "$STATE" 2>/dev/null || echo "     (none recorded)"
    else
      echo "::warning::resume clone failed - starting a fresh history for this branch"
    fi
  fi
  if [ ! -d .git ]; then
    git init -q -b "$BR"
    git_setup
  fi
fi

git remote remove origin 2>/dev/null || true
git remote add origin "$REMOTE"

# ---------------- LFS: heavy types + anything big ----------------
if ! grep -q 'filter=lfs' .gitattributes 2>/dev/null; then
  git lfs track "*.img" "*.so" "*.apk" "*.apex" "*.capex" "*.bin" "*.dat" "*.ko" \
    "*.vdex" "*.odex" "*.oat" "*.art" "*.arsc" "*.pak" "*.jar" "*.ttf" "*.otf" \
    "*.zip" "*.gz" "*.zst" "*.br" "*.xz" "*.lz4" "*.cpio" "*.dtb" "*.dtbo" \
    "*.fw" "*.elf" "*.mbn" "*.mdt" "*.ogg" "*.wav" "*.mp3" "*.mp4" "*.webp" \
    "*.pb" "*.tflite" "*.model" "kernel" "ramdisk" >/dev/null 2>&1 || true
fi
find . -type f -size +40M -not -path './.git/*' -print0 2>/dev/null \
  | xargs -0 -r -n 40 git lfs track >/dev/null 2>&1 || true

touch "$STATE"

storage_report() {
  local j rs lo tot
  j=$(curl -sS --header "PRIVATE-TOKEN: ${TOK}" "${API}/projects/${PID}?statistics=true" 2>/dev/null || true)
  rs=$(printf '%s' "$j" | jq -r '.statistics.repository_size // 0' 2>/dev/null || echo 0)
  lo=$(printf '%s' "$j" | jq -r '.statistics.lfs_objects_size // 0' 2>/dev/null || echo 0)
  tot=$(( rs + lo ))
  echo "   GitLab storage now: repo $(( rs / 1048576 ))MB + LFS $(( lo / 1048576 ))MB = $(( tot / 1048576 ))MB"
  if [ "$tot" -gt 9663676416 ]; then
    echo "::warning::this project is past 9 GiB - free gitlab.com projects are capped at 10 GiB"
  fi
}

already_pushed() { grep -qxF "$1" "$STATE" 2>/dev/null; }

push_group() {
  local name="$1"
  shift
  local paths=("$@")
  local p any=0

  if already_pushed "$name"; then
    echo ">> [$name] already on ${HOST} - skipped (resume)"
    for p in "${paths[@]}"; do rm -rf "$p"; done
    return 0
  fi
  for p in "${paths[@]}"; do [ -e "$p" ] && any=1; done
  if [ "$any" = 0 ]; then
    echo ">> [$name] nothing on disk - skipped"
    return 0
  fi

  echo "=== [$name] staging $(du -sh --exclude=.git "${paths[@]}" 2>/dev/null | tail -1 | cut -f1) ==="
  git add -- "${paths[@]}" 2>/dev/null || true
  echo "$name" >> "$STATE"
  git add -- "$STATE" .gitattributes 2>/dev/null || true
  if ! git commit -qm "x6886: ${name}" 2>/dev/null; then
    echo ">> [$name] nothing new to commit"
    return 0
  fi

  local rc=1 i
  for i in 1 2 3; do
    if git push -u origin "$BR"; then rc=0; break; fi
    echo "::warning::[$name] push attempt ${i} failed - retrying in 20s"
    sleep 20
  done
  if [ "$rc" -ne 0 ]; then
    FAILED_AT="$name"
    echo "::error::[$name] PUSH FAILED. Everything pushed BEFORE this group is safe on ${HOST}."
    echo "::error::Just run this workflow again - it resumes from '${name}' and never redoes finished work."
    return 1
  fi

  PUSHED_LIST="${PUSHED_LIST}${name} "
  # the server has it now: drop the working copy and the local LFS cache
  for p in "${paths[@]}"; do
    git ls-files -z -- "$p" | xargs -0 -r -n 500 git update-index --skip-worktree 2>/dev/null || true
    rm -rf "$p"
  done
  rm -rf .git/lfs/objects 2>/dev/null || true
  git reflog expire --expire=now --all >/dev/null 2>&1 || true
  echo ">> [$name] PUSHED OK   free disk: $(df -h . | awk 'NR==2{print $4}')"
  storage_report
}

# ---------------- order: metadata and boot first (fast wins), giants last ----
mapfile -t METAF < <(ls -1 README.md board-info.txt all_files.txt proprietary-files.txt \
  ota_metadata.txt kernel_config.txt kernel_version.txt 2>/dev/null || true)
if [ "${#METAF[@]}" -gt 0 ]; then push_group meta "${METAF[@]}" || exit 1; fi

mapfile -t BOOTD < <(ls -1d boot vendor_boot init_boot recovery 2>/dev/null || true)
if [ "${#BOOTD[@]}" -gt 0 ]; then push_group boot "${BOOTD[@]}" || exit 1; fi

mapfile -t IMGS < <(ls -1 *.img 2>/dev/null || true)
if [ "${#IMGS[@]}" -gt 0 ]; then push_group images "${IMGS[@]}" || exit 1; fi

mapfile -t DLKM < <(ls -1d vendor_dlkm odm_dlkm system_dlkm 2>/dev/null || true)
if [ "${#DLKM[@]}" -gt 0 ]; then push_group dlkm "${DLKM[@]}" || exit 1; fi

for d in product odm system_ext vendor system; do
  [ -d "$d" ] && { push_group "$d" "$d" || exit 1; }
done

for d in tr_*; do
  [ -d "$d" ] && { push_group "$d" "$d" || exit 1; }
done

mapfile -t REST < <(find . -maxdepth 1 -mindepth 1 -not -name '.git' -not -name '.gitattributes' \
  -not -name "$STATE" -printf '%P\n' 2>/dev/null | sort || true)
if [ "${#REST[@]}" -gt 0 ]; then push_group rest "${REST[@]}" || exit 1; fi

# ---------------- finish: default branch + description ----------------
curl -sS --header "PRIVATE-TOKEN: ${TOK}" -X PUT "${API}/projects/${PID}" \
  --data-urlencode "default_branch=${BR}" \
  --data-urlencode "description=${MODEL:-Android} (${CODENAME:-dump}) - ${BUILD_ID:-} - full firmware dump" \
  --data-urlencode "topics=${BRAND:-android},${CODENAME:-dump},android${ANDROID_VER:-},firmware,dump,${PLATFORM:-}" \
  >/dev/null 2>&1 || true

echo
echo "=== TOOL 07 DONE ==="
echo "pushed this run : ${PUSHED_LIST:-nothing new}"
echo "all groups now  : $(tr '\n' ' ' < "$STATE")"
echo "repo            : ${SCHEME}://${HOST}/${SLUG}/-/tree/${BR}"
storage_report
