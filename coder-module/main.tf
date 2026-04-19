terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 2.21"
    }
  }
}

data "coder_external_auth" "this" {
  id = var.external_auth_id
}

resource "coder_agent" "main" {
  arch = var.arch
  os   = "linux"

  env = {
    GH_TOKEN     = data.coder_external_auth.this.access_token
    DOTFILES_URL = var.dotfiles_url
  }

  startup_script = <<-EOT
    set -euo pipefail

    if [ ! -d "${var.project_workspace_folder}/.git" ]; then
      git clone "${var.project_git_url}" "${var.project_workspace_folder}"
    fi

    if [ -n "$DOTFILES_URL" ]; then
      coder dotfiles "$DOTFILES_URL" || true
    fi
  EOT
}

resource "coder_devcontainer" "project" {
  agent_id         = coder_agent.main.id
  workspace_folder = var.project_workspace_folder
  # The consumer's .devcontainer/ is what coder_devcontainer actually uses —
  # this resource merely tells Coder where to look inside the workspace.
}

resource "coder_app" "handoff" {
  agent_id     = coder_agent.main.id
  slug         = "handoff"
  display_name = "Review & push"
  icon         = "/icon/git.svg"
  command      = "cd ${var.project_workspace_folder} && ./scripts/claude-handoff.sh"
}
