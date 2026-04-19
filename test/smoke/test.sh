#!/usr/bin/env bash
# Smoke test executed inside a container built with the Feature.
# Invoked by .github/workflows/test.yml via `devcontainer features test`.
set -euo pipefail

echo "==> smoke test: block-destructive hook"
[ -x "$HOME/.claude/hooks/block-destructive.sh" ] || { echo "FAIL: hook not installed"; exit 1; }

# Verify the hook blocks `git push`
out=$(printf '{"command":"git push origin main"}' | "$HOME/.claude/hooks/block-destructive.sh" 2>&1 && echo "exit=0" || echo "exit=$?")
[[ "$out" =~ exit=2 ]] || { echo "FAIL: hook did not block git push (got $out)"; exit 1; }

# Verify the hook allows `git status`
out=$(printf '{"command":"git status"}' | "$HOME/.claude/hooks/block-destructive.sh" 2>&1 && echo "exit=0" || echo "exit=$?")
[[ "$out" =~ exit=0 ]] || { echo "FAIL: hook blocked git status (got $out)"; exit 1; }

echo "==> smoke test: managed-settings policy"
[ -f /etc/claude-code/managed-settings.json ] || { echo "FAIL: managed-settings not installed"; exit 1; }
grep -q '"allowManagedHooksOnly":[[:space:]]*true' /etc/claude-code/managed-settings.json \
  || { echo "FAIL: allowManagedHooksOnly not set"; exit 1; }

echo "==> smoke test: read-only pre-push hook"
[ -f /etc/git-hooks-readonly/pre-push ] || { echo "FAIL: pre-push missing"; exit 1; }
perms=$(stat -c %a /etc/git-hooks-readonly/pre-push)
[ "$perms" = "555" ] || { echo "FAIL: pre-push perms $perms != 555"; exit 1; }

echo "==> smoke test: credential helper"
git config --global --get credential.helper | grep -q GH_TOKEN \
  || { echo "FAIL: credential helper not configured"; exit 1; }

echo "==> smoke test: tmux wrapper on PATH ahead of real claude"
[ "$(command -v claude)" = "/opt/sandbox-bin/claude" ] \
  || { echo "FAIL: wrapper not fronting real claude (got $(command -v claude))"; exit 1; }

echo "==> smoke test: firewall script + sudoers"
[ -x /usr/local/bin/init-firewall.sh ] || { echo "FAIL: firewall script missing"; exit 1; }
sudo -n /usr/local/bin/init-firewall.sh </dev/null >/dev/null 2>&1 \
  || echo "note: firewall init skipped — CI runner lacks NET_ADMIN. Not a failure."

echo "==> smoke test: github-mcp-server binary"
[ -x /usr/local/bin/github-mcp-server ] || { echo "FAIL: github-mcp-server missing"; exit 1; }

echo "All smoke tests passed."
