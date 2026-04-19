variable "project_git_url" {
  type        = string
  description = "HTTPS URL of the project repository to clone into the workspace."
}

variable "project_workspace_folder" {
  type        = string
  default     = "/home/coder/project"
  description = "Absolute path inside the workspace where the project is cloned. Must match the consumer's devcontainer.json workspaceFolder."
}

variable "dotfiles_url" {
  type        = string
  default     = ""
  description = "Optional dotfiles repo URL; consumed by `coder dotfiles` in the agent startup script."
}

variable "external_auth_id" {
  type        = string
  default     = "github"
  description = "ID of the coder_external_auth provider that issues the GH_TOKEN."
}

variable "firewall_extra_domains" {
  type        = string
  default     = ""
  description = "Forwarded to the Feature's firewallExtraDomains option (comma-separated)."
}

variable "additional_tools" {
  type        = string
  default     = ""
  description = "Forwarded to the Feature's additionalTools option (comma-separated)."
}

variable "arch" {
  type        = string
  default     = "arm64"
  description = "Agent architecture."
}
