#!/usr/bin/env bash
# GLUE - refuse to start unless the token really works, then print the locked identity
set -uo pipefail
SCHEME="https"
HOST="${GITLAB_HOST:?GITLAB_HOST is required}"
echo "=================== PREFLIGHT ==================="
if [ -z "${GITLAB_TOKEN:-}" ]; then
  echo "::error::secret GITLAB_TOKEN is missing. Add it in Settings -> Secrets and variables -> Actions with scopes: api + write_repository"
  exit 1
fi
ME=$(curl -sS --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "${SCHEME}://${HOST}/api/v4/user")
LOGIN=$(printf '%s' "$ME" | jq -r '.username // empty')
if [ -z "$LOGIN" ]; then
  echo "::error::${HOST} rejected GITLAB_TOKEN. The server answered:"
  printf '%s\n' "$ME" | head -5
  exit 1
fi
echo "GitLab user   : $LOGIN"
echo "GITLAB_USER=$LOGIN" >> "$GITHUB_ENV"
echo "device        : ${BRAND:-?} ${CODENAME:-?} (${MODEL:-?})"
echo "build         : ${BUILD_ID:-?} | Android ${ANDROID_VER:-?} | kernel ${KERNEL_VER:-?}"
echo "platform      : ${PLATFORM:-?}"
echo "branch        : ${BRANCH_NAME:-?}"
echo "================================================="
