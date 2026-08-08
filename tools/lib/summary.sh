#!/usr/bin/env bash
# GLUE - always tell the truth in the job summary, even when the job failed
set +e
D="${DUMP:-/nonexistent}"
{
  echo "## Android dump - ${MODEL:-?} (${CODENAME:-?})"
  echo
  echo "| item | value |"
  echo "| --- | --- |"
  echo "| GitLab project | ${GITLAB_URL:-not created} |"
  echo "| branch | ${BRANCH_NAME:-?} |"
  echo "| build | ${BUILD_ID:-?} / Android ${ANDROID_VER:-?} |"
  echo "| still on the runner disk | $(du -sh --exclude=.git "$D" 2>/dev/null | cut -f1) |"
  echo "| files still on the runner | $(find "$D" -type f -not -path '*/.git/*' 2>/dev/null | wc -l) |"
  echo
  echo "### Groups already SAFE on GitLab"
  echo
  if [ -s "$D/dump_state.txt" ]; then
    sed 's/^/- /' "$D/dump_state.txt"
  else
    echo "- nothing pushed yet"
  fi
  echo
  echo "If this job stopped early, run the workflow again with the SAME branch."
  echo "Every group listed above is already on GitLab and gets skipped, so it RESUMES instead of restarting from zero."
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
exit 0
