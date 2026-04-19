#!/usr/bin/env bash
# from fernandes-it/claude-sandbox@v1.0.0
# Host-side handoff: reads .claude/handoffs/*.json written by the in-container agent,
# reviews the diff, prompts the human, then pushes + opens PRs with host credentials.
#
# Self-update:   ./scripts/claude-handoff.sh --self-update
# Skip network:  ./scripts/claude-handoff.sh --no-version-check
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
  local latest tmp
  latest="$(gh release list --repo "$SANDBOX_REPO" --limit 1 --json tagName --jq '.[0].tagName')"
  [ -z "$latest" ] && { echo "cannot determine latest tag" >&2; exit 1; }
  tmp="$(mktemp)"
  gh api "/repos/$SANDBOX_REPO/contents/scripts/claude-handoff.sh?ref=$latest" --jq .content \
    | base64 -d > "$tmp"
  if diff -q "$tmp" "$0" >/dev/null 2>&1; then
    echo "already up-to-date at $latest"; rm -f "$tmp"; exit 0
  fi
  diff -u "$0" "$tmp" || true
  read -rp "Overwrite $0 with $latest? [y/N] " yn
  [[ "$yn" =~ ^[Yy]$ ]] || { echo "aborted"; rm -f "$tmp"; exit 0; }
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

# Locate handoff dir: prefer local (DevPod local-source, Coder workspace),
# fall back to `devpod ssh` tar extract for DevPod git-source workspaces.
if [ -d .claude/handoffs ]; then
  handoff_dir=".claude/handoffs"
else
  workspace="$(basename "$(pwd)")"
  tmp="$(mktemp -d)"
  devpod ssh "$workspace" -- tar -cC /workspaces .claude/handoffs 2>/dev/null | tar -xC "$tmp" \
    || { echo "no .claude/handoffs — is the workspace running?" >&2; exit 1; }
  handoff_dir="$tmp/.claude/handoffs"
fi

# Pick the most recent unprocessed manifest (filenames are ISO-timestamp + slug, no special chars)
# shellcheck disable=SC2012
manifest="$(ls -1t "$handoff_dir"/*.json 2>/dev/null | head -1 || true)"
[ -z "$manifest" ] && { echo "no manifests in $handoff_dir" >&2; exit 1; }

# Validate schema
version=$(jq -r '.version' "$manifest")
branch=$(jq -r '.branch' "$manifest")
base=$(jq -r '.base' "$manifest")
action=$(jq -r '.action' "$manifest")
title=$(jq -r '.title' "$manifest")
body=$(jq -r '.body' "$manifest")
draft=$(jq -r '.draft // true' "$manifest")
labels=$(jq -r '.labels // [] | join(",")' "$manifest")

[ "$version" != "1" ]      && { echo "unsupported manifest version: $version" >&2; exit 1; }
[ -z "$branch" ]           && { echo "manifest missing .branch" >&2; exit 1; }
[ -z "$base" ]             && { echo "manifest missing .base"   >&2; exit 1; }

# Enforce conventional-commits branch prefix for 'open_pr' actions
if [ "$action" = "open_pr" ] && ! [[ "$branch" =~ ^(feat|fix|chore|docs|refactor|test|perf|ci|build|style)/ ]]; then
  echo "branch '$branch' does not use a conventional prefix" >&2; exit 1
fi

if ! git rev-parse --verify "$branch" >/dev/null 2>&1; then
  echo "branch '$branch' does not exist locally" >&2; exit 1
fi

echo ""
echo "=== commits about to push ($base..$branch) ==="
git log --oneline "$base..$branch"
echo ""
echo "=== diffstat vs $base ==="
git diff --stat "$base..$branch"
echo ""
echo "=== manifest ==="
echo "action:  $action"
echo "title:   $title"
echo "labels:  $labels"
echo "draft:   $draft"
echo ""
echo "body:"
printf '%s\n' "$body" | sed 's/^/  /'

echo ""
read -rp "Proceed with $action on '$branch'? [y/N] " yn
[[ "$yn" =~ ^[Yy]$ ]] || { echo "aborted"; exit 0; }

case "$action" in
  push_only)
    git push -u origin "$branch"
    ;;
  open_pr)
    git push -u origin "$branch"
    gh_args=( --base "$base" --title "$title" --body "$body" )
    [ "$draft" = "true" ] && gh_args+=( --draft )
    [ -n "$labels" ] && gh_args+=( --label "$labels" )
    gh pr create "${gh_args[@]}"
    ;;
  *)
    echo "action '$action' not implemented in v1" >&2; exit 1
    ;;
esac

# Move manifest into processed/
processed_dir="$(dirname "$manifest")/processed"
mkdir -p "$processed_dir"
mv "$manifest" "$processed_dir/"
echo "Done. Manifest moved to $processed_dir/$(basename "$manifest")"
