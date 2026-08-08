#!/usr/bin/env bash
# TOOL 07 - resumable per-group push to GitLab
#
# Fixed in this version:
#  1. LFS is used ONLY for files bigger than LFS_MIN_MB (default 95 MB), matched
#     by exact path. The old version tracked by EXTENSION (*.so *.apk *.ko ...)
#     which pushed thousands of small files into LFS - and GitLab renders an LFS
#     file as a 3-line pointer, which is why the dump did not look like a dump.
#  2. A failed push is now diagnosed instead of blindly repeated. On
#     "cannot lock ref" / "fetch first" we fetch, and either recognise that the
#     commit already landed, or re-anchor our commit on top of the real remote head.
#  3. FRESH_BRANCH=true deletes the remote branch through the GitLab API and
#     starts the branch over from nothing.
#  4. Raw partition images live in images/ instead of being dumped at the root.
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
LFS_MIN_MB="${LFS_MIN_MB:-95}"
PUSHED_LIST=""

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
  git config push.default current
  git config lfs.locksverify false
  git config lfs.concurrenttransfers 12
  git config lfs.activitytimeout 600
  git lfs install --local >/dev/null 2>&1 || true
}

# ---------------- FRESH_BRANCH: literally delete the old branch ----------------
if [ "${FRESH_BRANCH:-false}" = "true" ]; then
  echo "=== FRESH_BRANCH=true - deleting branch '${BR}' on ${HOST} and starting clean ==="
  code=$(curl -sS -o /tmp/delbr.txt -w '%{http_code}' -X DELETE \
    --header "PRIVATE-TOKEN: ${TOK}" \
    "${API}/projects/${PID}/repository/branches/${BR}" 2>/dev/null || echo 000)
  case "$code" in
    204|202) echo ">> branch '${BR}' deleted" ;;
    404)     echo ">> branch '${BR}' did not exist - nothing to delete" ;;
    *)       echo "::warning::branch delete returned HTTP ${code}: $(head -c 300 /tmp/delbr.txt)" ;;
  esac
  # a protected default branch cannot be deleted - say so honestly
  if curl -sS --header "PRIVATE-TOKEN: ${TOK}" \
       "${API}/projects/${PID}/repository/branches/${BR}" 2>/dev/null | grep -q '"name"'; then
    echo "::warning::branch '${BR}' still exists (probably protected or it is the default branch)."
    echo "::warning::history will be replaced with a force push instead."
    FORCE_PUSH=1
  fi
  rm -f "$STATE"
  rm -rf .git
  sleep 5
fi
FORCE_PUSH="${FORCE_PUSH:-0}"

# ---------------- resume, or start a new history ----------------
if [ ! -d .git ]; then
  if [ "${FRESH_BRANCH:-false}" != "true" ] && [ "${RESET_BRANCH:-false}" != "true" ] \
     && git ls-remote --heads "$REMOTE" "$BR" 2>/dev/null | grep -q .; then
    echo ">> RESUME: branch '$BR' exists on ${HOST} - continuing the SAME dump"
    if git clone --no-checkout --filter=blob:none --depth=1 --branch "$BR" "$REMOTE" .gitclone >/dev/null 2>&1; then
      mv .gitclone/.git .git
      rm -rf .gitclone
      git_setup
      git reset --mixed HEAD >/dev/null 2>&1 || true
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
git_setup
git remote remove origin 2>/dev/null || true
git remote add origin "$REMOTE"
touch "$STATE" .gitattributes

# ---------------- LFS: ONLY genuinely huge files, by exact path ----------------
# Everything else stays a normal git blob so GitLab shows real file contents.
track_big_files() {
  local f line n=0
  while IFS= read -r -d '' f; do
    f="${f#./}"
    case "$f" in .git/*|.gitattributes) continue ;; esac
    line="${f} filter=lfs diff=lfs merge=lfs -text"
    grep -qxF "$line" .gitattributes 2>/dev/null && continue
    printf '%s\n' "$line" >> .gitattributes
    n=$((n+1))
    echo "   LFS (> ${LFS_MIN_MB}M): $f"
  done < <(find . -type f -size +"${LFS_MIN_MB}"M -not -path './.git/*' -print0 2>/dev/null)
  if [ "$n" = 0 ]; then
    echo "   no file above ${LFS_MIN_MB}M in this group - nothing goes to LFS"
  fi
}

storage_report() {
  local j rs lo tot
  j=$(curl -sS --header "PRIVATE-TOKEN: ${TOK}" "${API}/projects/${PID}?statistics=true" 2>/dev/null || true)
  rs=$(printf '%s' "$j" | jq -r '.statistics.repository_size // 0' 2>/dev/null || echo 0)
  lo=$(printf '%s' "$j" | jq -r '.statistics.lfs_objects_size // 0' 2>/dev/null || echo 0)
  tot=$(( rs + lo ))
  echo "   GitLab storage: repo $(( rs / 1048576 ))MB + LFS $(( lo / 1048576 ))MB = $(( tot / 1048576 ))MB"
  echo "   (GitLab statistics lag a few minutes - a small number right after a push is normal)"
  if [ "$tot" -gt 9663676416 ]; then
    echo "::warning::past 9 GiB - free gitlab.com projects are capped at 10 GiB"
  fi
}

# ---------------- a push that actually recovers ----------------
push_now() {
  local name="$1" i rc=1 remote_sha local_sha out
  for i in 1 2 3 4; do
    if [ "$FORCE_PUSH" = "1" ] && [ "$i" = 1 ]; then
      echo "   (force push: replacing remote history for '${BR}')"
      git push --force origin "HEAD:refs/heads/${BR}" && { rc=0; FORCE_PUSH=0; break; }
    else
      git push origin "HEAD:refs/heads/${BR}" && { rc=0; break; }
    fi

    echo "::warning::[$name] push attempt ${i} was rejected - asking the server what it really has"
    git fetch --no-tags --force origin "refs/heads/${BR}:refs/remotes/origin/${BR}" 2>&1 | sed 's/^/     /' || true
    remote_sha=$(git rev-parse --verify -q "refs/remotes/origin/${BR}" || true)
    local_sha=$(git rev-parse HEAD)

    if [ -z "$remote_sha" ]; then
      echo "     server has no '${BR}' yet - retrying"
      sleep 15
      continue
    fi

    if [ "$remote_sha" = "$local_sha" ] || git merge-base --is-ancestor "$local_sha" "$remote_sha" 2>/dev/null; then
      echo "     GOOD NEWS: the server already contains our commit ${local_sha:0:8}."
      echo "     That rejection was a GitLab ref-lock race, not a lost push."
      git reset --soft "$remote_sha" >/dev/null 2>&1 || true
      git update-ref "refs/heads/${BR}" "$remote_sha" 2>/dev/null || true
      rc=0
      break
    fi

    echo "     remote head is ${remote_sha:0:8}, ours is ${local_sha:0:8} - re-anchoring our work on top of the remote"
    if ! git reset --soft "$remote_sha" >/dev/null 2>&1; then
      echo "::warning::     could not re-anchor - retrying plain push"
      sleep 15
      continue
    fi
    git update-ref "refs/heads/${BR}" "$remote_sha" 2>/dev/null || true
    if ! git commit -qm "x6886: ${name}" 2>/dev/null; then
      echo "     after re-anchoring there is nothing left to commit - this group is already on the server"
      rc=0
      break
    fi
    sleep 10
  done
  return "$rc"
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

  echo
  echo "=== [$name] staging $(du -sh --exclude=.git "${paths[@]}" 2>/dev/null | tail -1 | cut -f1) ==="
  track_big_files
  git add -- "${paths[@]}" 2>/dev/null || true
  echo "$name" >> "$STATE"
  git add -- "$STATE" .gitattributes 2>/dev/null || true
  echo "   files staged: $(git diff --cached --name-only | wc -l)"
  if ! git commit -qm "x6886: ${name}" 2>/dev/null; then
    echo ">> [$name] nothing new to commit"
    return 0
  fi

  if ! push_now "$name"; then
    echo "::error::[$name] PUSH FAILED. Everything pushed BEFORE this group is safe on ${HOST}."
    echo "::error::Run this workflow again - it resumes at '${name}' and never redoes finished work."
    return 1
  fi

  PUSHED_LIST="${PUSHED_LIST}${name} "
  for p in "${paths[@]}"; do
    git ls-files -z -- "$p" | xargs -0 -r -n 500 git update-index --skip-worktree 2>/dev/null || true
    rm -rf "$p"
  done
  rm -rf .git/lfs/objects 2>/dev/null || true
  git reflog expire --expire=now --all >/dev/null 2>&1 || true
  echo ">> [$name] PUSHED OK   free disk: $(df -h . | awk 'NR==2{print $4}')"
  storage_report
}

# ---------------- order: metadata and boot first, giants last ----------------
mapfile -t METAF < <(ls -1 README.md board-info.txt all_files.txt proprietary-files.txt \
  ota_metadata.txt kernel_config.txt kernel_version.txt 2>/dev/null || true)
if [ "${#METAF[@]}" -gt 0 ]; then push_group meta "${METAF[@]}" || exit 1; fi

mapfile -t BOOTD < <(ls -1d boot vendor_boot init_boot recovery 2>/dev/null || true)
if [ "${#BOOTD[@]}" -gt 0 ]; then push_group boot "${BOOTD[@]}" || exit 1; fi

[ -d images ] && { push_group images images || exit 1; }

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
