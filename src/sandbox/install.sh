#!/usr/bin/env bash
# claude-sandbox Feature — build-phase installer.
# Runs as root during image build. Option values are exposed as env vars.
set -euo pipefail

: "${FIREWALLEXTRADOMAINS:=}"
: "${ADDITIONALTOOLS:=}"
: "${CLAUDEVERSION:=latest}"
: "${WORKSPACEFOLDER:=/workspaces}"
: "${DOTFILESURL:=}"

FEATURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect the non-root container user the base image already created.
# Dev Containers convention: vscode, node, codespace — pick the first that exists.
for candidate in vscode node codespace; do
  if id -u "$candidate" >/dev/null 2>&1; then
    _USER="$candidate"
    break
  fi
done
: "${_USER:?claude-sandbox: no vscode/node/codespace user on the base image}"
_HOME="$(getent passwd "$_USER" | cut -d: -f6)"

echo "==> claude-sandbox Feature installing for user $_USER ($_HOME)"

# 1. System packages
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  iptables ipset tmux curl ca-certificates python3 jq
rm -rf /var/lib/apt/lists/*

# 2. Claude CLI + wrapper relocation
#
# The official installer lands the binary at "$_HOME/.local/bin/claude". That
# directory is on PATH via the user's .profile, which wins over anything we
# prepend through containerEnv. Instead of fighting PATH ordering, move the
# real binary to a sandbox-owned path and put our tmux wrapper in its place
# at /usr/local/bin/claude (always on PATH, no shell-init override).
sudo -u "$_USER" bash -c 'curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh && bash /tmp/claude-install.sh && rm /tmp/claude-install.sh'
if [ "$CLAUDEVERSION" != "latest" ]; then
  echo "==> claudeVersion pinning is recorded ($CLAUDEVERSION) — upstream installer does not yet accept a version flag; revisit when it does." >&2
fi
install -d -o root -g root -m 0755 /usr/local/lib/claude-sandbox
mv "$_HOME/.local/bin/claude" /usr/local/lib/claude-sandbox/claude-real
chown root:root /usr/local/lib/claude-sandbox/claude-real
chmod 0755 /usr/local/lib/claude-sandbox/claude-real

# 3. GitHub MCP server binary
# Upstream goreleaser uses x86_64/arm64 in the asset name.
mcp_arch="$(uname -m)"; case "$mcp_arch" in aarch64) mcp_arch=arm64 ;; esac
mcp_version="v1.0.0"
curl -fsSL "https://github.com/github/github-mcp-server/releases/download/${mcp_version}/github-mcp-server_Linux_${mcp_arch}.tar.gz" \
  | tar -xz -C /usr/local/bin github-mcp-server
chmod 755 /usr/local/bin/github-mcp-server

# 4. Read-only global pre-push hook
mkdir -p /etc/git-hooks-readonly
install -m 0555 -o root -g root \
  "$FEATURE_DIR/assets/git-hooks/pre-push" \
  /etc/git-hooks-readonly/pre-push
# Global config so every repo picks it up
sudo -u "$_USER" git config --global core.hooksPath /etc/git-hooks-readonly

# 5. Global credential helper consuming $GH_TOKEN (token not available at build time;
#    the helper reads $GH_TOKEN at invocation time from the user's environment).
sudo -u "$_USER" git config --global credential.helper \
  '!f() { [ -n "${GH_TOKEN:-}" ] || exit 0; printf "username=x-access-token\npassword=%s\n" "$GH_TOKEN"; }; f'

# 6. Install user-scope Claude settings + hooks into container user's ~/.claude
install -d -o "$_USER" -g "$_USER" -m 0755 "$_HOME/.claude" "$_HOME/.claude/hooks"
install -m 0644 -o "$_USER" -g "$_USER" \
  "$FEATURE_DIR/assets/claude/settings.json" "$_HOME/.claude/settings.json"
install -m 0755 -o "$_USER" -g "$_USER" \
  "$FEATURE_DIR/assets/claude/hooks/block-destructive.sh" "$_HOME/.claude/hooks/block-destructive.sh"

# 7. Claude Code managed-settings policy (tamper-resistance, L1)
install -d -o root -g root -m 0755 /etc/claude-code
install -m 0644 -o root -g root \
  "$FEATURE_DIR/assets/managed-settings.json" /etc/claude-code/managed-settings.json

# 8. Stage project-scope .mcp.json for runtime deployment
install -d -o root -g root -m 0755 /etc/claude-sandbox
install -m 0644 -o root -g root \
  "$FEATURE_DIR/assets/mcp/mcp.json" /etc/claude-sandbox/mcp.json

# 9. Firewall script + sudoers entry
install -m 0755 -o root -g root \
  "$FEATURE_DIR/assets/firewall/init-firewall.sh" /usr/local/bin/init-firewall.sh
echo "$_USER ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" \
  > /etc/sudoers.d/claude-sandbox-firewall
chmod 0440 /etc/sudoers.d/claude-sandbox-firewall

# 10. tmux claude wrapper as /usr/local/bin/claude (real binary moved aside in step 2)
install -m 0755 -o root -g root \
  "$FEATURE_DIR/assets/tmux/claude-wrapper.sh" /usr/local/bin/claude

# 11. Lifecycle hook (runtime step) — dispatched via devcontainer-feature.json postCreateCommand
install -d -o root -g root -m 0755 /usr/local/share/claude-sandbox/lifecycle
install -m 0755 -o root -g root \
  "$FEATURE_DIR/lifecycle/post-create.sh" /usr/local/share/claude-sandbox/lifecycle/post-create.sh

# 12. additionalTools
if [ -n "$ADDITIONALTOOLS" ]; then
  IFS=',' read -ra tools <<<"$ADDITIONALTOOLS"
  for t in "${tools[@]}"; do
    t="${t// /}"; [ -z "$t" ] && continue
    case "$t" in
      goose)
        sudo -u "$_USER" bash -lc 'go install github.com/pressly/goose/v3/cmd/goose@latest' ;;
      golangci-lint)
        sudo -u "$_USER" bash -lc 'go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest' ;;
      *)
        echo "claude-sandbox: unsupported additionalTool '$t' — skipping" >&2 ;;
    esac
  done
fi

# 13. Record workspaceFolder and firewallExtraDomains so the lifecycle script can read them
cat >/etc/claude-sandbox/env <<EOF
WORKSPACEFOLDER=$WORKSPACEFOLDER
FIREWALL_EXTRA_DOMAINS=$FIREWALLEXTRADOMAINS
DOTFILES_URL=$DOTFILESURL
CLAUDE_SANDBOX_USER=$_USER
CLAUDE_SANDBOX_HOME=$_HOME
EOF
chmod 0644 /etc/claude-sandbox/env

echo "==> claude-sandbox Feature install complete"
