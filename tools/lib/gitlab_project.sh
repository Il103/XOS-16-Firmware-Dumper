#!/usr/bin/env bash
# GLUE - create or reuse the GitLab project, then hand its id to TOOL 07
set -uo pipefail
SCHEME="https"
HOST="${GITLAB_HOST:?}"
TOK="${GITLAB_TOKEN:?}"
API="${SCHEME}://${HOST}/api/v4"
NAME="${PROJECT_NAME:?}"
VIS="${VISIBILITY:-public}"
NS_ID=""

if [ -n "${GITLAB_GROUP:-}" ]; then
  NS_PATH="$GITLAB_GROUP"
  NS_ID=$(curl -sS --header "PRIVATE-TOKEN: ${TOK}" --get \
    --data-urlencode "search=${GITLAB_GROUP}" "${API}/namespaces" \
    | jq -r --arg g "${GITLAB_GROUP}" 'map(select(.full_path==$g or .path==$g)) | .[0].id // empty')
  if [ -z "$NS_ID" ]; then
    echo "::error::namespace '${GITLAB_GROUP}' was not found or is not visible to this token"
    exit 1
  fi
else
  NS_PATH="${GITLAB_USER:?}"
fi

SLUG="${NS_PATH}/${NAME}"
ENC=$(printf '%s' "$SLUG" | jq -sRr @uri)
J=$(curl -sS --header "PRIVATE-TOKEN: ${TOK}" "${API}/projects/${ENC}")
PID=$(printf '%s' "$J" | jq -r '.id // empty')

if [ -n "$PID" ]; then
  echo ">> reusing existing project ${SLUG} (id ${PID})"
else
  echo ">> creating ${SLUG} ..."
  if [ -n "$NS_ID" ]; then
    J=$(curl -sS --header "PRIVATE-TOKEN: ${TOK}" -X POST "${API}/projects" \
      --data-urlencode "name=${NAME}" \
      --data-urlencode "path=${NAME}" \
      --data-urlencode "namespace_id=${NS_ID}" \
      --data-urlencode "visibility=${VIS}" \
      --data "lfs_enabled=true&initialize_with_readme=false")
  else
    J=$(curl -sS --header "PRIVATE-TOKEN: ${TOK}" -X POST "${API}/projects" \
      --data-urlencode "name=${NAME}" \
      --data-urlencode "path=${NAME}" \
      --data-urlencode "visibility=${VIS}" \
      --data "lfs_enabled=true&initialize_with_readme=false")
  fi
  PID=$(printf '%s' "$J" | jq -r '.id // empty')
fi

if [ -z "$PID" ]; then
  echo "::error::could not create or find the project. GitLab answered:"
  printf '%s\n' "$J" | head -20
  exit 1
fi

{
  echo "GITLAB_SLUG=$SLUG"
  echo "GITLAB_PID=$PID"
  echo "GITLAB_URL=${SCHEME}://${HOST}/${SLUG}"
} >> "$GITHUB_ENV"
echo ">> project ready: ${SCHEME}://${HOST}/${SLUG} (id ${PID})"
