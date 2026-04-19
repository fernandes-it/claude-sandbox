#!/usr/bin/env bash
# Egress allowlist for the claude-sandbox Feature.
# Derived from Anthropic's reference devcontainer init-firewall.sh.
# Requires NET_ADMIN + NET_RAW capabilities (set via runArgs in consumer devcontainer.json).
set -euo pipefail

# Baseline allowlist — the set every Claude Code + GitHub-MCP-read deployment needs.
ALLOWED_DOMAINS=(
  # Anthropic / Claude
  "api.anthropic.com"
  "statsig.anthropic.com"
  "sentry.io"

  # npm (dotfiles / feature install)
  "registry.npmjs.org"

  # GitHub (read — write is gated by token scope + PreToolUse hook)
  "github.com"
  "api.github.com"
  "objects.githubusercontent.com"
  "raw.githubusercontent.com"
  "codeload.github.com"

  # Debian package repos
  "deb.debian.org"
  "security.debian.org"
)

# Extra domains supplied by the consumer via FIREWALL_EXTRA_DOMAINS=a,b,c
if [ -n "${FIREWALL_EXTRA_DOMAINS:-}" ]; then
  IFS=',' read -ra extras <<<"$FIREWALL_EXTRA_DOMAINS"
  for d in "${extras[@]}"; do
    d="${d// /}"
    [ -n "$d" ] && ALLOWED_DOMAINS+=( "$d" )
  done
fi

# Flush existing rules
iptables -F OUTPUT 2>/dev/null || true
ipset destroy allowed-domains 2>/dev/null || true

# Create ipset for DNS-resolved IPs
ipset create allowed-domains hash:ip

for domain in "${ALLOWED_DOMAINS[@]}"; do
  ips=$(getent hosts "$domain" | awk '{print $1}') || true
  for ip in $ips; do
    ipset add allowed-domains "$ip" 2>/dev/null || true
  done
done

iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
# Private nets — docker compose sidecars, VPN ranges
iptables -A OUTPUT -d 172.16.0.0/12 -j ACCEPT
iptables -A OUTPUT -d 10.0.0.0/8 -j ACCEPT
iptables -A OUTPUT -j DROP

echo "Firewall initialised. Allowed domains: ${ALLOWED_DOMAINS[*]}"
