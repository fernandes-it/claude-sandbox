#!/usr/bin/env bash
# claude-sandbox Feature — runtime post-create hook.
# Runs after the workspace is mounted and $GH_TOKEN is available.
# Dispatched via devcontainer-feature.json "postCreateCommand".
set -euo pipefail

# Load recorded option values
# shellcheck disable=SC1091
. /etc/claude-sandbox/env

workspace="${WORKSPACEFOLDER:-/workspaces}"

# 1. Drop project-scope .mcp.json if none exists.
# DevPod/Coder may bind the workspace to a subdir of $workspace — find the repo root.
mcp_target=""
if [ -d "$workspace" ]; then
  # Prefer an immediate subdir with a .git — that's the project root
  for d in "$workspace"/* "$workspace"/.; do
    [ -d "$d/.git" ] && { mcp_target="$d/.mcp.json"; break; }
  done
  # Fallback: workspace itself if it's a git repo
  [ -z "$mcp_target" ] && [ -d "$workspace/.git" ] && mcp_target="$workspace/.mcp.json"
fi

if [ -n "$mcp_target" ] && [ ! -f "$mcp_target" ]; then
  install -m 0644 /etc/claude-sandbox/mcp.json "$mcp_target"
  echo "claude-sandbox: wrote $mcp_target"
fi

# 2. Apply personal dotfiles (noop if URL empty).
if [ -n "${DOTFILES_URL:-}" ]; then
  dest="${CLAUDE_SANDBOX_HOME}/.dotfiles"
  if [ ! -d "$dest/.git" ]; then
    # The git credential helper will pick up $GH_TOKEN
    sudo -u "$CLAUDE_SANDBOX_USER" git clone "$DOTFILES_URL" "$dest"
  else
    sudo -u "$CLAUDE_SANDBOX_USER" git -C "$dest" pull --ff-only || true
  fi
  if [ -x "$dest/install.sh" ]; then
    sudo -u "$CLAUDE_SANDBOX_USER" bash "$dest/install.sh"
  fi
fi

# 3. Initialise the firewall (idempotent; safe to re-run if IPs rotate).
sudo /usr/local/bin/init-firewall.sh || {
  echo "claude-sandbox: firewall init failed — check NET_ADMIN/NET_RAW capabilities" >&2
}

echo "claude-sandbox: post-create complete"
