# claude-sandbox Coder module

Drop-in Terraform module for Coder workspace templates. Provides:

- A `coder_agent` that clones the project repo and applies personal dotfiles.
- A `coder_devcontainer` pointing at the consumer's `.devcontainer/` (which references the `claude-sandbox` Feature by tag).
- A `Review & push` `coder_app` that runs `scripts/claude-handoff.sh` inside the workspace.

## Pre-requirements on the Coder admin

The `external_auth_id` provider must be configured against a GitHub **OAuth app** whose scopes cover:

- `read:user` — identify the authenticated user
- `repo` — needed to push to a private repo and open a PR (narrower scopes like `public_repo` do not cover private-repo writes)
- `workflow` — only if handoffs ever push changes that modify `.github/workflows/*`; skip otherwise

Users who authorise a narrower scope will see 403 at handoff time.

## Usage

```hcl
module "claude_sandbox" {
  source = "git::https://github.com/fernandes-it/claude-sandbox.git//coder-module?ref=v1.0.0"

  project_git_url  = "https://github.com/my-org/my-repo.git"
  dotfiles_url     = "https://github.com/my-org/dotfiles"
  external_auth_id = "github"
}
```

## Variables

See `variables.tf`.
