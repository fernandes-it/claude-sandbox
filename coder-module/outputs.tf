output "agent_id" {
  value       = coder_agent.main.id
  description = "ID of the workspace agent for downstream resources."
}

output "handoff_app_slug" {
  value       = coder_app.handoff.slug
  description = "Slug of the Review & push coder_app button."
}
