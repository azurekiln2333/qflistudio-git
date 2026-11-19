#!/usr/bin/env bash
# Runs a command and, when it fails, publishes the tail of its output as a
# GitHub annotation. Annotations are public; job logs need admin rights.
# Usage: tool/ci/run_annotated.sh <title> <command> [args...]
set -uo pipefail
title="$1"
shift
log="$(mktemp)"
"$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
if [ "$status" -ne 0 ] && [ -n "${GITHUB_ACTIONS:-}" ]; then
  tail -n 60 "$log" | python3 -c 'import sys
text = sys.stdin.read()[-3500:]
text = text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
print("::error title=" + sys.argv[1] + "::" + text)' "$title"
fi
rm -f "$log"
exit "$status"
