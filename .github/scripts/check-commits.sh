#!/usr/bin/env bash
# Reads commit subjects on stdin, one per line, and fails if any is not a Conventional Commit.
set -u
pattern='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9._/-]+\))?!?: [^ ].*$'
status=0
while IFS= read -r subject || [ -n "$subject" ]; do
  [ -z "$subject" ] && continue
  if ! [[ $subject =~ $pattern ]]; then
    echo "Not a Conventional Commit: $subject" >&2
    status=1
  fi
done
exit "$status"
