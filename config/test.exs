import Config

# Test-specific configuration
config :tri_onyx,
  agents_dir: "test/fixtures/agents",
  audit_dir: "test/tmp/audit",
  webhooks_file: "test/tmp/webhooks/webhooks.json",
  definition_watcher: false,
  port: 4999

config :logger,
  level: :warning
