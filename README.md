# claude-sandbox

A reusable Dev Containers **Feature** + Coder Terraform module + host-side script templates that turn any project's devcontainer into a lockdown sandbox for running Claude Code under `--dangerously-skip-permissions`.

## What it gives you

1. **Feature** (`ghcr.io/fernandes-it/claude-sandbox/sandbox`) installed into a devcontainer image:
   - Claude Code CLI + tmux wrapper (named sessions)
   - PreToolUse hook blocking destructive git / `gh` / `--no-verify`
   - Read-only global `pre-push` hook (`core.hooksPath`)
   - iptables/ipset egress allowlist (configurable extra domains)
   - Official GitHub MCP server in `--read-only` mode
   - Claude Code **managed-settings** policy pinning `allowManagedHooksOnly: true`
   - Git credential helper that consumes `$GH_TOKEN` transparently
   - Optional personal dotfiles clone via `DOTFILES_URL`

2. **Coder Terraform module** (`./coder-module`): drops into a workspace template, wires `coder_external_auth`, `coder_devcontainer`, and a `Review & push` `coder_app` that runs `claude-handoff.sh`.

3. **Script templates** (`./scripts`): `devpod-up.sh` and `claude-handoff.sh`, copied into consumer projects and self-updating from released tags.

## Threat model (what this isn't)

No kernel isolation, no detection evasion, no multi-tenant RBAC. Threat model is: _autonomous agent with full Bash inside a container; must not be able to push, open PRs, or leak credentials._ Defense = container isolation + firewall + credential absence + approval gate.

## Consuming from a project

### `.devcontainer/devcontainer.json`

```jsonc
{
  "features": {
    "ghcr.io/fernandes-it/claude-sandbox/sandbox:1": {
      "firewallExtraDomains": "proxy.golang.org,sum.golang.org",
      "additionalTools": "goose,golangci-lint",
      "dotfilesUrl": "https://github.com/fernandes-it/dotfiles"
    }
  },
  "remoteEnv": { "GH_TOKEN": "${localEnv:GH_TOKEN}" },
  "runArgs": ["--cap-add=NET_ADMIN", "--cap-add=NET_RAW"]
}
```

### Copying the scripts

```bash
curl -fsSL -o scripts/devpod-up.sh      https://raw.githubusercontent.com/fernandes-it/claude-sandbox/v1.0.0/scripts/devpod-up.sh
curl -fsSL -o scripts/claude-handoff.sh https://raw.githubusercontent.com/fernandes-it/claude-sandbox/v1.0.0/scripts/claude-handoff.sh
chmod +x scripts/*.sh
```

Both scripts carry a version pin in their header and a `--self-update` subcommand.

## Required host capabilities

- `NET_ADMIN` and `NET_RAW` on the container — required by the firewall. Non-Docker DevPod providers (Kubernetes, …) may not grant these; the sandbox still works without the firewall layer but with reduced defense-in-depth — pair with shorter-lived tokens (1 h GitHub App installation token instead of a 90-day PAT).

## Install.d ordering (for the dotfiles repo)

The companion dotfiles repo that this Feature clones must source `install.d/*.sh` in POSIX lexicographic order. Numeric prefixes (`10-`, `20-`, …) are load-bearing; later scripts may depend on state set up by earlier ones.

## Publishing

Tag `vX.Y.Z` → `publish-feature.yml` pushes `feature/sandbox` to `ghcr.io/fernandes-it/claude-sandbox/sandbox:X.Y.Z` and `:X` (major rolling).

## License

MIT.
