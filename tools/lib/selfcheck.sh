#!/usr/bin/env bash
# GLUE - parse every tool BEFORE we spend 40 minutes downloading 8 GB
set -uo pipefail
cd "${TOOLS:?TOOLS is required}" || exit 1
chmod +x ./*.sh ./*.py ./lib/*.sh 2>/dev/null || true
FAIL=0
for f in ./*.sh ./lib/*.sh; do
  [ -f "$f" ] || continue
  if bash -n "$f"; then
    echo "   OK   $f"
  else
    echo "::error::$f has a syntax error"
    FAIL=1
  fi
done
for f in ./*.py; do
  [ -f "$f" ] || continue
  if python3 -m py_compile "$f"; then
    echo "   OK   $f"
  else
    echo "::error::$f has a syntax error"
    FAIL=1
  fi
done
rm -rf __pycache__
if [ "$FAIL" != 0 ]; then exit 1; fi
echo ">> every tool parses clean - safe to start the big job"
