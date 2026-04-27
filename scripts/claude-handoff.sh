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

# Collect all unprocessed manifests, sorted oldest first by filename
# (filenames are ISO-date + slug, so a lexical sort is chronological).
shopt -s nullglob
manifests=( "$handoff_dir"/*.json )
shopt -u nullglob
[ ${#manifests[@]} -eq 0 ] && { echo "no manifests in $handoff_dir" >&2; exit 1; }
sorted_manifests=()
while IFS= read -r line; do
  sorted_manifests+=( "$line" )
done < <(printf '%s\n' "${manifests[@]}" | sort)
manifests=( "${sorted_manifests[@]}" )
unset sorted_manifests

# Push a branch to origin only if local exists and origin is missing it or behind.
# Used for stacked-PR base branches so 'gh pr create' doesn't see a missing base ref.
ensure_pushed() {
  local b="$1"
  if ! git rev-parse --verify "$b" >/dev/null 2>&1; then
    echo "branch '$b' does not exist locally — cannot push" >&2; return 1
  fi
  if git rev-parse --verify "origin/$b" >/dev/null 2>&1 \
     && [ "$(git rev-parse "$b")" = "$(git rev-parse "origin/$b")" ]; then
    return 0
  fi
  git push origin "$b":"refs/heads/$b"
}

process_manifest() {
  local manifest="$1"
  local version branch base action title body draft labels

  version=$(jq -r '.version'                "$manifest")
  branch=$(jq  -r '.branch'                 "$manifest")
  base=$(jq    -r '.base'                   "$manifest")
  action=$(jq  -r '.action'                 "$manifest")
  title=$(jq   -r '.title'                  "$manifest")
  body=$(jq    -r '.body'                   "$manifest")
  draft=$(jq   -r '.draft // true'          "$manifest")
  labels=$(jq  -r '.labels // [] | join(",")' "$manifest")

  [ "$version" != "1" ] && { echo "unsupported manifest version: $version" >&2; return 1; }
  [ -z "$branch" ]      && { echo "manifest missing .branch" >&2; return 1; }
  [ -z "$base" ]        && { echo "manifest missing .base"   >&2; return 1; }

  if [ "$action" = "open_pr" ] && ! [[ "$branch" =~ ^(feat|fix|chore|docs|refactor|test|perf|ci|build|style)/ ]]; then
    echo "branch '$branch' does not use a conventional prefix" >&2; return 1
  fi

  if ! git rev-parse --verify "$branch" >/dev/null 2>&1; then
    echo "branch '$branch' does not exist locally" >&2; return 1
  fi

  echo ""
  echo "=========================================="
  echo "Manifest: $(basename "$manifest")"
  echo "=========================================="
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
  read -rp "Proceed with $action on '$branch'? [y/N/q to quit] " yn
  case "$yn" in
    [Yy]*) ;;
    [Qq]*) echo "quitting"; exit 0 ;;
    *)     echo "skipped (manifest left in place)"; return 0 ;;
  esac

  case "$action" in
    push_only)
      git push -u origin "$branch":"refs/heads/$branch"
      ;;
    open_pr)
      # For stacked PRs, ensure the base branch is on origin first — otherwise
      # 'gh pr create' fails with "Base ref must be a branch / Base sha can't be blank".
      if [ "$base" != "main" ] && [ "$base" != "master" ]; then
        ensure_pushed "$base"
      fi
      git push -u origin "$branch":"refs/heads/$branch"

      local existing
      existing=$(gh pr list --head "$branch" --state open \
                   --json number --jq '.[0].number' 2>/dev/null || true)
      if [ -n "$existing" ] && [ "$existing" != "null" ]; then
        echo "PR #$existing is already open for '$branch'."
        read -rp "Update title/body/base on PR #$existing? [y/N] " up
        if [[ "$up" =~ ^[Yy]$ ]]; then
          gh pr edit "$existing" --title "$title" --body "$body" --base "$base"
        else
          echo "leaving PR #$existing unchanged"
        fi
      else
        local gh_args=( --head "$branch" --base "$base" --title "$title" --body "$body" )
        [ "$draft" = "true" ] && gh_args+=( --draft )
        [ -n "$labels" ]      && gh_args+=( --label "$labels" )
        gh pr create "${gh_args[@]}"
      fi
      ;;
    *)
      echo "action '$action' not implemented in v1" >&2; return 1
      ;;
  esac

  local processed_dir
  processed_dir="$(dirname "$manifest")/processed"
  mkdir -p "$processed_dir"
  mv "$manifest" "$processed_dir/"
  echo "Manifest moved to $processed_dir/$(basename "$manifest")"
}

echo "Found ${#manifests[@]} manifest(s) in $handoff_dir."
for manifest in "${manifests[@]}"; do
  if ! process_manifest "$manifest"; then
    echo "manifest $(basename "$manifest") failed — moving on" >&2
  fi
done
echo ""
echo "Done."
