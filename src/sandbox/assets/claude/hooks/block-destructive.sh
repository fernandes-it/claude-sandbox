#!/usr/bin/env bash
# PreToolUse hook — rejects destructive Bash commands in the claude-sandbox.
# Claude Code passes tool input as JSON on stdin and treats exit 2 as a block.
# The hook is installed by the claude-sandbox Feature into the container user's ~/.claude/hooks.
set -euo pipefail

input="$(cat)"
command="$(printf '%s' "$input" | python3 -c "import sys,json
try:
    d = json.loads(sys.stdin.read())
    print(d.get('command',''), end='')
except Exception:
    print('', end='')
")"

[ -z "$command" ] && exit 0

# Patterns that would bypass safety hooks, destroy history, or escape the write-gate
BLOCKED_PATTERNS=(
  # git writes
  '(^|[[:space:]])git[[:space:]]+push($|[[:space:]])'
  '(^|[[:space:]])git[[:space:]].*--force($|[[:space:]])'
  '(^|[[:space:]])git[[:space:]].*--force-with-lease'
  '(^|[[:space:]])git[[:space:]]+push[[:space:]]+-[A-Za-z]*f'
  '(^|[[:space:]])git[[:space:]]+reset[[:space:]]+.*--hard'
  '(^|[[:space:]])git[[:space:]]+clean[[:space:]]+.*-[A-Za-z]*f'
  '(^|[[:space:]])git[[:space:]]+branch[[:space:]]+.*-D'
  # gh writes
  '(^|[[:space:]])gh[[:space:]]+pr[[:space:]]+create'
  '(^|[[:space:]])gh[[:space:]]+pr[[:space:]]+merge'
  '(^|[[:space:]])gh[[:space:]]+issue[[:space:]]+create'
  '(^|[[:space:]])gh[[:space:]]+release[[:space:]]+create'
  '(^|[[:space:]])gh[[:space:]]+auth[[:space:]]+login'
  # Hook / signing bypass
  '--no-verify'
)

for pattern in "${BLOCKED_PATTERNS[@]}"; do
  if printf '%s' "$command" | grep -Eq -- "$pattern"; then
    cat >&2 <<EOF
Blocked. This command is not allowed in the Claude sandbox.

Write a handoff manifest at:
  .claude/handoffs/\$(date -u +%Y%m%dT%H%M%SZ)-<slug>.json

…and tell the user to run \`./scripts/claude-handoff.sh\` on the host
(or click "Review & push" on Coder).
EOF
    exit 2
  fi
done

exit 0
