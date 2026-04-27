# Optional lefthook pre-commit / commit-msg dispatcher

**Status:** Approved (design)
**Date:** 2026-04-27
**Scope:** `src/sandbox` Feature

## Problem

The Feature already pins `core.hooksPath` to a root-owned, mode-0555 directory (`/etc/git-hooks-readonly/`) holding a single hook: `pre-push`, which unconditionally blocks pushes. That global override is what makes the push block unbypassable, but it has a side effect: a project's own `.git/hooks/` is ignored, so naive `lefthook install` does nothing.

We want consumers to be able to opt in to running pre-commit and commit-msg checks via lefthook, without weakening the existing push block and without requiring per-project `core.hooksPath` workarounds.

## Non-goals

- Driving every git hook lefthook supports. Only `pre-commit` and `commit-msg` — the two hooks ~all real `lefthook.yml`s configure.
- Replacing `pre-push`. That hook is a hard security control owned by the Feature; lefthook does not touch it.
- Provisioning project tooling (linters, formatters). Whatever the project's `lefthook.yml` invokes is the project's responsibility.

## Design

### Option surface

One new option in `src/sandbox/devcontainer-feature.json`:

```jsonc
"lefthookVersion": {
  "type": "string",
  "default": "",
  "description": "Install lefthook and wire pre-commit / commit-msg dispatchers into the global hooks dir. Empty = disabled. Use a pinned version (e.g. '1.7.22') or 'latest'."
}
```

Empty default = disabled. Same disabled-by-empty-string convention as `dotfilesUrl`.

### Install-time behavior (`src/sandbox/install.sh`)

All steps gated on `[ -n "$LEFTHOOKVERSION" ]`.

1. **Fetch the binary.** Mirror the `github-mcp-server` pattern. Pull `https://github.com/evilmartians/lefthook/releases/download/v${LEFTHOOKVERSION}/lefthook_${LEFTHOOKVERSION}_Linux_${arch}.tar.gz`, extract `lefthook` to `/usr/local/bin/lefthook`, mode 0755 root:root. `arch` derived from `uname -m` with `aarch64 → arm64` mapping (matches existing pattern).

   `latest` resolved by following the `Location:` header on `https://github.com/evilmartians/lefthook/releases/latest` (one `curl -sI`).

2. **Install dispatchers.** Two scripts shipped under `src/sandbox/assets/git-hooks/` next to the existing `pre-push`:

   `pre-commit`:
   ```sh
   #!/bin/sh
   # Owned by the claude-sandbox Feature. Dispatches to lefthook ONLY if the
   # repo configures it. This file lives in /etc/git-hooks-readonly/ for
   # plumbing reasons (core.hooksPath); it is NOT a security control —
   # only pre-push is. Do not add policy logic here.
   set -e
   root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
   if [ -f "$root/lefthook.yml" ] || [ -f "$root/.lefthook.yml" ]; then
     command -v lefthook >/dev/null 2>&1 || {
       echo "claude-sandbox: lefthook config present but binary missing" >&2
       exit 1
     }
     exec lefthook run pre-commit "$@"
   fi
   exit 0
   ```

   `commit-msg`: same structure, dispatching to `lefthook run commit-msg "$@"`. The git-supplied message-file path arrives as `$1` and passes through unchanged.

   Both installed to `/etc/git-hooks-readonly/{pre-commit,commit-msg}`, mode 0555 root:root — identical to the existing `pre-push`. `core.hooksPath` is already pointed there, so they take effect with no further git config.

3. **No per-repo `lefthook install`.** The dispatchers *are* the install. The dispatcher comment block makes this explicit so a future reader doesn't try to "fix" it.

### Runtime semantics

| Repo state | Outcome |
|---|---|
| No `lefthook.yml` | Dispatcher exits 0 silently. No noise for projects that don't use lefthook. |
| `lefthook.yml` present, all checks pass | `lefthook run` exits 0 → dispatcher exits 0 → commit proceeds. |
| `lefthook.yml` present, a check fails | `lefthook run` exits non-zero → dispatcher exits non-zero → commit blocked. Fail closed. |
| `lefthook.yml` present, malformed | `lefthook run` exits non-zero → commit blocked with lefthook's error. |
| `lefthook.yml` present, binary missing | Dispatcher exits 1 with a clear claude-sandbox-prefixed message. Defense against manual tampering. |

### Interaction with existing protections

- **`block-destructive.sh` (Claude PreToolUse hook).** Already allows `git commit`, blocks `--no-verify`. Claude can `git commit -m "..."` (which fires the dispatcher and is fail-closed), but cannot `git commit --no-verify` to bypass. **No change.**
- **`core.hooksPath` global override.** Reason the dispatcher pattern exists. Documented in `README.md` under a new "Lefthook integration" subsection so consumers don't waste time wondering why `lefthook install` is a no-op. **Doc-only change.**
- **Egress firewall.** Lefthook itself doesn't phone home; the commands `lefthook.yml` invokes are project tools that already run inside the sandbox. **No allowlist changes.**

### Tests

`test/sandbox/test.sh` runs against the Feature with default options (`lefthookVersion=""`). Add negative-path assertions there; add a positive-path scenario.

**Negative path (`test/sandbox/test.sh`):**
- `/usr/local/bin/lefthook` does not exist
- `/etc/git-hooks-readonly/pre-commit` does not exist
- `/etc/git-hooks-readonly/commit-msg` does not exist

**Positive path (new `test/sandbox/scenarios.json` + `test/sandbox/lefthook-enabled.sh`)** with `lefthookVersion: "latest"`:
- `/usr/local/bin/lefthook` exists, executable, `lefthook version` exits 0
- `/etc/git-hooks-readonly/pre-commit` exists, mode 0555, root:root
- `/etc/git-hooks-readonly/commit-msg` exists, mode 0555, root:root
- In a temp git repo with no `lefthook.yml`, invoking the `pre-commit` dispatcher exits 0 silently
- In a temp git repo with a trivial passing `lefthook.yml`, invoking the dispatcher exits 0 and runs lefthook
- In a temp git repo with a `lefthook.yml` whose command is `exit 1`, invoking the dispatcher exits non-zero (fail closed)

Direct dispatcher invocation rather than going through `git commit` keeps the test focused and fast; `git commit -m` adds nothing the dispatcher itself doesn't already exercise.

### Documentation

`README.md` gains a short "Lefthook integration" subsection covering: the option, how to set it, why `lefthook install` is a no-op (and that it's intentional), and a one-line example `lefthook.yml` showing pre-commit and commit-msg.

`CHANGELOG.md` `[Unreleased]` gets one bullet under `### Added`.

## Files touched

- `src/sandbox/devcontainer-feature.json` — new `lefthookVersion` option
- `src/sandbox/install.sh` — new gated install block (binary fetch + dispatcher install)
- `src/sandbox/assets/git-hooks/pre-commit` (new)
- `src/sandbox/assets/git-hooks/commit-msg` (new)
- `test/sandbox/test.sh` — three negative-path assertions
- `test/sandbox/scenarios.json` (new)
- `test/sandbox/lefthook-enabled.sh` (new)
- `README.md` — new "Lefthook integration" subsection
- `CHANGELOG.md` — `[Unreleased]` entry
