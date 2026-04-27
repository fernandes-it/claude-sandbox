# Lefthook Pre-commit Option Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `lefthookVersion` Feature option that installs lefthook plus root-owned `pre-commit` and `commit-msg` dispatchers into the existing `/etc/git-hooks-readonly/` directory, so consumer projects can configure pre-commit/commit-msg checks via `lefthook.yml` without weakening the unbypassable `pre-push` block.

**Architecture:** New string option (empty = disabled), gated install block in `install.sh`, two new shell-script assets that dispatch to `lefthook run <hook>` only when the repo has a `lefthook.yml`. Lives alongside the existing `pre-push` hook so `core.hooksPath` continues to point to a single dir. Tests use `devcontainer features test` scenarios for positive-path coverage and existing default-options smoke test for negative-path coverage.

**Tech Stack:** Bash, devcontainer Features spec, lefthook (https://github.com/evilmartians/lefthook), `devcontainer features test` CLI, GitHub Actions.

**Source spec:** `docs/superpowers/specs/2026-04-27-lefthook-pre-commit-option-design.md`

---

## File Structure

**New files:**
- `src/sandbox/assets/git-hooks/pre-commit` — dispatcher (shell)
- `src/sandbox/assets/git-hooks/commit-msg` — dispatcher (shell)
- `test/sandbox/scenarios.json` — `devcontainer features test` scenario manifest
- `test/sandbox/lefthook-enabled.sh` — positive-path scenario test

**Modified files:**
- `src/sandbox/devcontainer-feature.json` — new `lefthookVersion` option
- `src/sandbox/install.sh` — gated install block + env-file entry
- `test/sandbox/test.sh` — three negative-path assertions
- `README.md` — new "Lefthook integration" subsection
- `CHANGELOG.md` — `[Unreleased]` entry

---

## Task 1: Add `lefthookVersion` option to the Feature manifest and env file

**Files:**
- Modify: `src/sandbox/devcontainer-feature.json`
- Modify: `src/sandbox/install.sh` (env-file block + default for the new env var)

This task only adds the declarative surface and the env recording. No install behavior yet — that's Task 3.

- [ ] **Step 1: Add the option to the manifest**

In `src/sandbox/devcontainer-feature.json`, inside the `"options"` object, after the existing `"dotfilesUrl"` block, add:

```jsonc
    "lefthookVersion": {
      "type": "string",
      "default": "",
      "description": "Install lefthook and wire pre-commit/commit-msg dispatchers into the global hooks dir. Empty = disabled. Use a pinned version (e.g. '1.7.22') or 'latest'."
    }
```

Mind the trailing comma on the previous block: the existing `"dotfilesUrl"` block currently ends without a comma because it's the last entry. Add a comma after its closing `}` and put `"lefthookVersion"` after it.

- [ ] **Step 2: Add the default for the new env var at the top of `install.sh`**

In `src/sandbox/install.sh`, find the block of `: "${VARNAME:=...}"` defaults near the top (lines 6–10) and add one line:

```bash
: "${LEFTHOOKVERSION:=}"
```

The full block becomes:

```bash
: "${FIREWALLEXTRADOMAINS:=}"
: "${ADDITIONALTOOLS:=}"
: "${CLAUDEVERSION:=latest}"
: "${WORKSPACEFOLDER:=/workspaces}"
: "${DOTFILESURL:=}"
: "${LEFTHOOKVERSION:=}"
```

- [ ] **Step 3: Record the option value in `/etc/claude-sandbox/env`**

In `src/sandbox/install.sh`, find the `cat >/etc/claude-sandbox/env <<EOF` heredoc near the bottom (the block that records `WORKSPACEFOLDER`, `FIREWALL_EXTRA_DOMAINS`, etc.). Add one line so the heredoc reads:

```bash
cat >/etc/claude-sandbox/env <<EOF
WORKSPACEFOLDER=$WORKSPACEFOLDER
FIREWALL_EXTRA_DOMAINS=$FIREWALLEXTRADOMAINS
DOTFILES_URL=$DOTFILESURL
LEFTHOOK_VERSION=$LEFTHOOKVERSION
CLAUDE_SANDBOX_USER=$_USER
CLAUDE_SANDBOX_HOME=$_HOME
EOF
```

(Lifecycle scripts don't need this value today — install.sh is where the work happens — but recording it keeps `/etc/claude-sandbox/env` a faithful record of how the Feature was configured. Costs one line.)

- [ ] **Step 4: Validate the manifest is still valid JSON**

Run: `python3 -m json.tool src/sandbox/devcontainer-feature.json > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 5: Validate `install.sh` still parses**

Run: `bash -n src/sandbox/install.sh && echo OK`
Expected: `OK`

- [ ] **Step 6: Commit**

```bash
git add src/sandbox/devcontainer-feature.json src/sandbox/install.sh
git commit -m "feat(sandbox): add lefthookVersion option (declaration only)"
```

---

## Task 2: Write the `pre-commit` and `commit-msg` dispatcher assets

**Files:**
- Create: `src/sandbox/assets/git-hooks/pre-commit`
- Create: `src/sandbox/assets/git-hooks/commit-msg`

These are the shell scripts that will land in `/etc/git-hooks-readonly/` at install time. They must run on whatever `/bin/sh` Debian bookworm provides (POSIX dash), so no bash-isms.

- [ ] **Step 1: Create `src/sandbox/assets/git-hooks/pre-commit`**

Full file contents:

```sh
#!/bin/sh
# claude-sandbox dispatcher — owned by the Feature, lives in
# /etc/git-hooks-readonly/ alongside the unbypassable pre-push hook.
#
# IMPORTANT: pre-push is a security control. This file is NOT.
# It is plumbing to make project-level lefthook configs work despite
# the global core.hooksPath override. Do not add policy logic here.
#
# Behaviour: if the repo has a lefthook.yml, dispatch to lefthook.
# Otherwise exit silently. Never run `lefthook install` per repo —
# core.hooksPath would override its output anyway.
set -e

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

if [ -f "$root/lefthook.yml" ] || [ -f "$root/.lefthook.yml" ]; then
  if ! command -v lefthook >/dev/null 2>&1; then
    echo "claude-sandbox: lefthook config present but lefthook binary missing" >&2
    exit 1
  fi
  exec lefthook run pre-commit "$@"
fi

exit 0
```

- [ ] **Step 2: Create `src/sandbox/assets/git-hooks/commit-msg`**

Full file contents (same shape, different hook name; `$1` is the message-file path that git supplies and lefthook expects):

```sh
#!/bin/sh
# claude-sandbox dispatcher — see pre-commit in this directory for
# the full rationale. This file is plumbing, not a security control.
set -e

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

if [ -f "$root/lefthook.yml" ] || [ -f "$root/.lefthook.yml" ]; then
  if ! command -v lefthook >/dev/null 2>&1; then
    echo "claude-sandbox: lefthook config present but lefthook binary missing" >&2
    exit 1
  fi
  exec lefthook run commit-msg "$@"
fi

exit 0
```

- [ ] **Step 3: Make them readable in source (executable bit not strictly needed in source — `install -m 0555` will set it on the deployed copy — but consistent with the existing `pre-push` asset which has its execute bit set)**

Run: `chmod +x src/sandbox/assets/git-hooks/pre-commit src/sandbox/assets/git-hooks/commit-msg`
Expected: no output

- [ ] **Step 4: Syntax-check both scripts**

Run: `sh -n src/sandbox/assets/git-hooks/pre-commit && sh -n src/sandbox/assets/git-hooks/commit-msg && echo OK`
Expected: `OK`

- [ ] **Step 5: Smoke-test the no-config path against a temp repo**

Run:
```bash
tmp=$(mktemp -d) && (cd "$tmp" && git init -q && \
  ../../../src/sandbox/assets/git-hooks/pre-commit && \
  ../../../src/sandbox/assets/git-hooks/commit-msg /dev/null && \
  echo OK) ; rm -rf "$tmp"
```
(Adjust the relative path if your shell `pwd` is not the repo root — easier: `cd <repo-root>` first.)
Easier form from the repo root:
```bash
tmp=$(mktemp -d); ( cd "$tmp" && git init -q && \
  "$OLDPWD/src/sandbox/assets/git-hooks/pre-commit" && \
  "$OLDPWD/src/sandbox/assets/git-hooks/commit-msg" /dev/null ) && \
  echo OK; rm -rf "$tmp"
```
Expected: `OK` (both dispatchers exit 0 silently because no `lefthook.yml` is present).

- [ ] **Step 6: Commit**

```bash
git add src/sandbox/assets/git-hooks/pre-commit src/sandbox/assets/git-hooks/commit-msg
git commit -m "feat(sandbox): add lefthook pre-commit/commit-msg dispatcher assets"
```

---

## Task 3: Wire install.sh to fetch lefthook + install dispatchers when option is set

**Files:**
- Modify: `src/sandbox/install.sh`

This block lives in the structured numbered-step style the file already uses. Insert it as a new step **before** step 12 (`# 12. additionalTools`) and renumber accordingly — call the new block `# 12. lefthook (optional)` and shift the existing `additionalTools` block to `# 13.` and the env-record block to `# 14.`. Keeping the numbered ordering tidy makes the file easier to read.

- [ ] **Step 1: Insert the new install block**

In `src/sandbox/install.sh`, immediately before the line `# 12. additionalTools`, insert:

```bash
# 12. lefthook (optional) — install binary + dispatchers if version requested
if [ -n "$LEFTHOOKVERSION" ]; then
  lh_arch="$(uname -m)"; case "$lh_arch" in aarch64) lh_arch=arm64 ;; x86_64) lh_arch=x86_64 ;; esac
  if [ "$LEFTHOOKVERSION" = "latest" ]; then
    # Resolve "latest" by following the GitHub releases redirect
    lh_resolved=$(curl -fsSI "https://github.com/evilmartians/lefthook/releases/latest" \
      | awk -F'/' 'tolower($1) ~ /^location:/ {sub(/\r$/, "", $NF); print $NF}' \
      | tail -n1)
    lh_resolved="${lh_resolved#v}"
    : "${lh_resolved:?claude-sandbox: failed to resolve lefthook latest tag}"
  else
    lh_resolved="${LEFTHOOKVERSION#v}"
  fi
  echo "==> claude-sandbox: installing lefthook ${lh_resolved} (${lh_arch})"
  curl -fsSL "https://github.com/evilmartians/lefthook/releases/download/v${lh_resolved}/lefthook_${lh_resolved}_Linux_${lh_arch}.tar.gz" \
    | tar -xz -C /usr/local/bin lefthook
  chmod 0755 /usr/local/bin/lefthook
  chown root:root /usr/local/bin/lefthook

  # Dispatchers — siblings of the existing pre-push hook
  install -m 0555 -o root -g root \
    "$FEATURE_DIR/assets/git-hooks/pre-commit" \
    /etc/git-hooks-readonly/pre-commit
  install -m 0555 -o root -g root \
    "$FEATURE_DIR/assets/git-hooks/commit-msg" \
    /etc/git-hooks-readonly/commit-msg
fi

```

- [ ] **Step 2: Renumber the existing comments after the insertion**

Change `# 12. additionalTools` to `# 13. additionalTools` and change `# 13. Record workspaceFolder and firewallExtraDomains so the lifecycle script can read them` to `# 14. Record workspaceFolder and firewallExtraDomains so the lifecycle script can read them`.

- [ ] **Step 3: Validate `install.sh` still parses**

Run: `bash -n src/sandbox/install.sh && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add src/sandbox/install.sh
git commit -m "feat(sandbox): install lefthook and dispatchers when lefthookVersion set"
```

---

## Task 4: Add negative-path assertions to the default smoke test

**Files:**
- Modify: `test/sandbox/test.sh`

The default-options smoke test runs against the Feature with `lefthookVersion=""`. Add three assertions confirming the disabled path is truly disabled. This protects against accidental regressions where someone wires lefthook unconditionally.

- [ ] **Step 1: Add the negative-path block**

In `test/sandbox/test.sh`, immediately before the final line `echo "All smoke tests passed."`, insert:

```bash
echo "==> smoke test: lefthook disabled by default"
[ ! -e /usr/local/bin/lefthook ] \
  || { echo "FAIL: lefthook installed despite empty lefthookVersion"; exit 1; }
[ ! -e /etc/git-hooks-readonly/pre-commit ] \
  || { echo "FAIL: pre-commit dispatcher installed despite empty lefthookVersion"; exit 1; }
[ ! -e /etc/git-hooks-readonly/commit-msg ] \
  || { echo "FAIL: commit-msg dispatcher installed despite empty lefthookVersion"; exit 1; }

```

- [ ] **Step 2: Syntax-check**

Run: `bash -n test/sandbox/test.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add test/sandbox/test.sh
git commit -m "test(sandbox): assert lefthook is absent when option empty"
```

---

## Task 5: Add the positive-path scenario test

**Files:**
- Create: `test/sandbox/scenarios.json`
- Create: `test/sandbox/lefthook-enabled.sh`

`devcontainer features test --global-scenarios-only=false` (already passed in `.github/workflows/test.yml:21`) discovers per-feature `scenarios.json` and runs each scenario against a fresh container with the named test script.

- [ ] **Step 1: Write the failing scenario test first**

Create `test/sandbox/lefthook-enabled.sh` with full contents:

```bash
#!/usr/bin/env bash
# Scenario: lefthookVersion=latest. Verifies binary installed, dispatchers
# installed with correct perms, and dispatcher runtime semantics.
set -euo pipefail

echo "==> scenario: lefthook binary installed"
[ -x /usr/local/bin/lefthook ] || { echo "FAIL: lefthook binary missing"; exit 1; }
/usr/local/bin/lefthook version >/dev/null \
  || { echo "FAIL: lefthook binary not runnable"; exit 1; }

echo "==> scenario: dispatcher files installed with correct perms"
for hook in pre-commit commit-msg; do
  path="/etc/git-hooks-readonly/$hook"
  [ -f "$path" ] || { echo "FAIL: $path missing"; exit 1; }
  perms=$(stat -c %a "$path")
  [ "$perms" = "555" ] || { echo "FAIL: $path perms $perms != 555"; exit 1; }
  owner=$(stat -c '%U:%G' "$path")
  [ "$owner" = "root:root" ] || { echo "FAIL: $path owner $owner != root:root"; exit 1; }
done

echo "==> scenario: dispatcher silent in repo without lefthook.yml"
tmp=$(mktemp -d)
( cd "$tmp" && git init -q )
out=$(/etc/git-hooks-readonly/pre-commit 2>&1; echo "exit=$?")
case "$out" in
  *"exit=0"*) ;;
  *) echo "FAIL: dispatcher non-zero in repo without lefthook.yml: $out"; exit 1 ;;
esac
rm -rf "$tmp"

echo "==> scenario: dispatcher dispatches to lefthook with passing config"
tmp=$(mktemp -d)
( cd "$tmp" && git init -q && cat >lefthook.yml <<'EOF'
pre-commit:
  commands:
    ok:
      run: "true"
EOF
)
( cd "$tmp" && /etc/git-hooks-readonly/pre-commit ) \
  || { echo "FAIL: dispatcher non-zero with passing lefthook.yml"; rm -rf "$tmp"; exit 1; }
rm -rf "$tmp"

echo "==> scenario: dispatcher fails closed on failing config"
tmp=$(mktemp -d)
( cd "$tmp" && git init -q && cat >lefthook.yml <<'EOF'
pre-commit:
  commands:
    fail:
      run: "false"
EOF
)
if ( cd "$tmp" && /etc/git-hooks-readonly/pre-commit ); then
  echo "FAIL: dispatcher exit 0 when lefthook command failed"; rm -rf "$tmp"; exit 1
fi
rm -rf "$tmp"

echo "All lefthook-enabled scenario tests passed."
```

Make it executable:

Run: `chmod +x test/sandbox/lefthook-enabled.sh`
Expected: no output

- [ ] **Step 2: Write the scenarios manifest**

Create `test/sandbox/scenarios.json` with full contents:

```json
{
  "lefthook-enabled": {
    "image": "mcr.microsoft.com/devcontainers/base:bookworm",
    "features": {
      "sandbox": {
        "lefthookVersion": "latest"
      }
    }
  }
}
```

The scenario name (`"lefthook-enabled"`) MUST match the test script filename minus the `.sh`. That mapping is how `devcontainer features test` finds the right script per scenario.

- [ ] **Step 3: Validate JSON**

Run: `python3 -m json.tool test/sandbox/scenarios.json > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 4: Syntax-check the bash test**

Run: `bash -n test/sandbox/lefthook-enabled.sh && echo OK`
Expected: `OK`

- [ ] **Step 5: Run both smoke tests via devcontainer CLI (optional, requires Docker)**

If Docker is available locally:

```bash
devcontainer features test \
  --features sandbox \
  --base-image mcr.microsoft.com/devcontainers/base:bookworm \
  --project-folder . \
  --global-scenarios-only=false
```

Expected: both the default scenario and `lefthook-enabled` scenario report all checks passing. If Docker is not available locally, skip — CI runs the same command on push (`.github/workflows/test.yml`).

- [ ] **Step 6: Commit**

```bash
git add test/sandbox/scenarios.json test/sandbox/lefthook-enabled.sh
git commit -m "test(sandbox): add lefthook-enabled scenario covering install + runtime"
```

---

## Task 6: Update README and CHANGELOG

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add a "Lefthook integration" subsection to README**

In `README.md`, immediately before the `## Threat model (what this isn't)` heading (currently around line 21), insert a new H2 section:

```markdown
## Lefthook integration (optional)

Set `lefthookVersion` in your `devcontainer.json` to install `lefthook` plus root-owned `pre-commit` and `commit-msg` dispatchers next to the unbypassable `pre-push` hook:

```jsonc
{
  "features": {
    "ghcr.io/fernandes-it/claude-sandbox/sandbox:1": {
      "lefthookVersion": "latest"
    }
  }
}
```

Drop a `lefthook.yml` at the project root and it just works. **Do not run `lefthook install`** — the Feature sets `core.hooksPath` globally, which makes `lefthook install`'s per-repo output a no-op. The dispatchers shipped by the Feature handle that for you.

Only `pre-commit` and `commit-msg` are wired. `pre-push` is owned by the Feature and unconditionally blocks pushes; lefthook does not override it.

```

(Note: the inner code block uses triple-backticks too. When pasting, ensure the outer block's opening/closing fences are unique enough that markdown parses correctly. The example above uses three backticks for both — that's standard markdown and renders fine.)

- [ ] **Step 2: Add a CHANGELOG entry**

In `CHANGELOG.md`, under `## [Unreleased]`, add an `### Added` block (the file currently has no Unreleased entries):

```markdown
## [Unreleased]

### Added
- `lefthookVersion` Feature option: when set, installs lefthook and root-owned `pre-commit`/`commit-msg` dispatchers in `/etc/git-hooks-readonly/` that run project `lefthook.yml` checks. `pre-push` remains an unbypassable Feature-owned hook.

```

- [ ] **Step 3: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs(sandbox): document lefthookVersion option"
```

---

## Self-review

Spec coverage check (all spec sections vs. tasks):

- Option surface (spec § Option surface) → Task 1
- Install-time behavior, binary fetch (spec § Install-time behavior, point 1) → Task 3
- Install-time behavior, dispatchers (spec § Install-time behavior, point 2) → Tasks 2 + 3
- "No per-repo `lefthook install`" (spec § Install-time behavior, point 3) → Documented in dispatcher comments (Task 2) and README (Task 6)
- Runtime semantics table (spec § Runtime semantics) → Tested by Task 5 (no-config silent, passing config 0, failing config non-zero, missing-binary case is covered by the dispatcher's `command -v` guard from Task 2; not exercised at runtime in the tests, since the binary is always present in the positive scenario — acceptable since the guard's correctness is visible by inspection and the real-world failure path is "user manually deleted the binary," which is outside the threat model)
- Interaction with `block-destructive.sh` (spec § Interaction, point 1) → No change needed; spec is explicit
- `core.hooksPath` documentation (spec § Interaction, point 2) → Task 6 README
- Egress firewall (spec § Interaction, point 3) → No change needed; spec is explicit
- Negative-path tests (spec § Tests) → Task 4
- Positive-path tests (spec § Tests) → Task 5
- README / CHANGELOG (spec § Documentation) → Task 6

All spec sections covered.

Placeholder scan: no TBD, no "implement later", no "similar to Task N", no missing code blocks. Type/name consistency: dispatcher filenames (`pre-commit`, `commit-msg`) consistent across Tasks 2/3/4/5; option name (`lefthookVersion`) consistent across Tasks 1/5/6; env var (`LEFTHOOKVERSION`) consistent in Tasks 1 and 3; install path (`/etc/git-hooks-readonly/`) consistent throughout.
