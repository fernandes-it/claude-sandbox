#!/usr/bin/env bash
# Tmux wrapper for the Claude CLI — manages a named, persistent session per task.
# Installed as /usr/local/bin/claude by the Feature installer; the real binary
# is moved to /usr/local/lib/claude-sandbox/claude-real so this wrapper can
# front it without PATH-ordering ambiguity.
set -euo pipefail

REAL_CLAUDE="/usr/local/lib/claude-sandbox/claude-real"
if [ ! -x "$REAL_CLAUDE" ]; then
  echo "claude-wrapper: real claude CLI missing at $REAL_CLAUDE" >&2
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
