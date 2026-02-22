import Config

# TriOnyx configuration
config :tri_onyx,
  agents_dir: "./workspace/agent-definitions",
  audit_dir: "~/.tri-onyx/audit",
  workspace_dir: "./workspace"

# Quantum cron scheduler
config :tri_onyx, TriOnyx.Triggers.CronScheduler,
  jobs: []

# Logger configuration
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :agent_name, :session_id]

# Import environment specific config
import_config "#{config_env()}.exs"
