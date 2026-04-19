#!/usr/bin/env bash
# Tmux wrapper for the Claude CLI — manages a named, persistent session per task.
# Installed as /opt/sandbox-bin/claude so it fronts the real CLI on PATH.
set -euo pipefail

# Find the real claude binary — must not be on /opt/sandbox-bin/, that's us.
REAL_CLAUDE=""
IFS=':' read -ra dirs <<<"$PATH"
for dir in "${dirs[@]}"; do
  [ "$dir" = "/opt/sandbox-bin" ] && continue
  cand="$dir/claude"
  if [ -x "$cand" ]; then
    REAL_CLAUDE="$cand"
    break
  fi
done

if [ -z "$REAL_CLAUDE" ]; then
  echo "claude-wrapper: cannot find the real claude CLI on PATH (excluding /opt/sandbox-bin)" >&2
  exit 127
fi

SESSION_NAME="claude-default"
CLAUDE_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-name)      SESSION_NAME="$2"; shift 2 ;;
    --session-name=*)    SESSION_NAME="${1#--session-name=}"; shift ;;
    *)                   CLAUDE_ARGS+=("$1"); shift ;;
  esac
done

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  exec tmux attach-session -t "$SESSION_NAME"
else
  exec tmux new-session -s "$SESSION_NAME" "$REAL_CLAUDE" "${CLAUDE_ARGS[@]}"
fi
