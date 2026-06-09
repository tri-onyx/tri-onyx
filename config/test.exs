import Config

# Test-specific configuration
config :tri_onyx,
  agents_dir: "test/fixtures/agents",
  audit_dir: "test/tmp/audit",
  # Keep the boot-time RiskManifest rebuild away from the real ./workspace
  # repo; individual tests override workspace_dir with their own tmp dirs.
  workspace_dir: "test/tmp/workspace",
  webhooks_file: "test/tmp/webhooks/webhooks.json",
  definition_watcher: false,
  port: 4999

config :logger,
  level: :warning
