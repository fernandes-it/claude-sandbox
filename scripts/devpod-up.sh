#!/usr/bin/env bash
# from fernandes-it/claude-sandbox@v1.0.0
# DevPod launcher that fetches GH_TOKEN from the macOS Keychain and forwards
# it to the workspace container.
#
# Self-update:   ./scripts/devpod-up.sh --self-update
# Skip network:  ./scripts/devpod-up.sh --no-version-check [<devpod args>...]
set -euo pipefail

SANDBOX_REPO="fernandes-it/claude-sandbox"
SANDBOX_VERSION="v1.0.0"    # updated by --self-update
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-sandbox"
CACHE_TAG_FILE="$CACHE_DIR/latest-tag"
CACHE_TTL_SECONDS=$((24*60*60))

check_version_notice() {
  [ "${CLAUDE_SANDBOX_NO_VERSION_CHECK:-0}" = "1" ] && return 0
  mkdir -p "$CACHE_DIR"
  local now mtime age latest
  now=$(date +%s)
  if [ -f "$CACHE_TAG_FILE" ]; then
    mtime=$(stat -f %m "$CACHE_TAG_FILE" 2>/dev/null || stat -c %Y "$CACHE_TAG_FILE")
    age=$(( now - mtime ))
  else
    age=$(( CACHE_TTL_SECONDS + 1 ))
  fi
  if [ "$age" -gt "$CACHE_TTL_SECONDS" ]; then
    latest="$(gh api "/repos/$SANDBOX_REPO/releases/latest" --jq .tag_name 2>/dev/null || true)"
    [ -n "$latest" ] && { printf '%s' "$latest" > "$CACHE_TAG_FILE"; }
  else
    latest="$(cat "$CACHE_TAG_FILE" 2>/dev/null || true)"
  fi
  [ -n "$latest" ] && [ "$latest" != "$SANDBOX_VERSION" ] \
    && echo "hint: claude-sandbox scripts are at $SANDBOX_VERSION — latest is $latest. Run '--self-update' to upgrade." >&2 || true
}

self_update() {
  local latest
  latest="$(gh release list --repo "$SANDBOX_REPO" --limit 1 --json tagName --jq '.[0].tagName')"
  [ -z "$latest" ] && { echo "cannot determine latest tag" >&2; exit 1; }
  tmp="$(mktemp)"
  gh api "/repos/$SANDBOX_REPO/contents/scripts/devpod-up.sh?ref=$latest" --jq .content \
    | base64 -d > "$tmp"
  if diff -q "$tmp" "$0" >/dev/null 2>&1; then
    echo "already up-to-date at $latest"; rm -f "$tmp"; exit 0
  fi
  diff -u "$0" "$tmp" || true
  read -rp "Overwrite $0 with $latest? [y/N] " yn
  [[ "$yn" =~ ^[Yy]$ ]] || { echo "aborted"; rm -f "$tmp"; exit 0; }
  # Rewrite the version pin line, then overwrite the script
  sed -i.bak "s|^SANDBOX_VERSION=.*|SANDBOX_VERSION=\"$latest\"    # updated by --self-update|" "$tmp"
  install -m 0755 "$tmp" "$0"
  rm -f "$tmp" "$0.bak"
  echo "updated to $latest"
  exit 0
}

case "${1:-}" in
  --self-update) self_update ;;
  --no-version-check) CLAUDE_SANDBOX_NO_VERSION_CHECK=1; shift ;;
esac

check_version_notice

token="$(security find-generic-password -s hoardly-gh-read-pat -w 2>/dev/null || true)"
if [ -z "$token" ]; then
  echo "warn: no GH_TOKEN in Keychain — container will have anonymous GitHub access only" >&2
fi

exec devpod up . \
  --ide "${HOARDLY_IDE:-goland}" --open-ide \
  --dotfiles "${HOARDLY_DOTFILES:-https://github.com/fernandes-it/dotfiles}" \
  --workspace-env "GH_TOKEN=${token}" \
  "$@"
