# Project Structure

```
lib/tri_onyx/               Elixir gateway (OTP application)
  application.ex                OTP application supervisor
  router.ex                     HTTP API (Plug/Bandit)
  agent_definition.ex           Agent definition schema, parsing, validation
  agent_session.ex              Per-session GenServer (taint, risk, lifecycle)
  agent_port.ex                 Elixir Port to Python subprocess
  agent_supervisor.ex           DynamicSupervisor for sessions
  agent_loader.ex               Loads agent definitions from disk
  definition_watcher.ex         Watches for definition file changes
  sandbox.ex                    Translates definitions into docker run args
  information_classifier.ex     Taint/sensitivity classification from data sources
  risk_scorer.ex                Risk matrix computation
  risk_manifest.ex              In-memory taint/sensitivity manifest (from Git trailers)
  graph_analyzer.ex             Transitive risk propagation and violation detection
  taint_matrix.ex               Taint state per agent
  sensitivity_matrix.ex         Sensitivity state per agent
  sanitizer.ex                  Input/output sanitization
  workspace.ex                  Risk manifest, Git commits, human review
  tool_registry.ex              Tool metadata registry (incl. brief specs)
  session_events.ex             Canonical session event type registry
  event_bus.ex                  Pub/sub for SSE streaming and connectors
  connector_handler.ex          WebSocket handler for connectors
  session_logger.ex             Structured session logging
  audit_log.ex                  Audit log persistence
  git_provenance.ex             Git-based file provenance tracking
  rate_limiter.ex               Generic rate limiting
  system_command.ex             Host command execution helper
  webhook_receiver.ex           Incoming webhook processing
  webhook_endpoint.ex           Webhook endpoint CRUD
  webhook_registry.ex           Webhook endpoint storage
  webhook_signature.ex          HMAC signature verification
  webhook_rate_limiter.ex       Per-endpoint rate limiting
  trigger_router.ex             Routes triggers to target agents
  bcp/                          Bandwidth-Constrained Protocol
    approval_queue.ex               Human approval queue (BCP and action approvals)
    channel.ex                      BCP channel management
    escalation.ex                   Escalation handling
    query.ex                        Structured query format
    rate_limiter.ex                 BCP rate limiting
    subscription.ex                 BCP subscriptions
    validator.ex                    BCP message validation
  connectors/                   Built-in connectors (Elixir side)
    email.ex                        IMAP/SMTP email connector
    calendar.ex                     CalDAV calendar connector
    github.ex                       Gateway-mediated gh/git execution
    util.ex                         Shared connector helpers
  github/
    command_policy.ex               Per-command GitHub tool policy (allow/approve/deny)
  triggers/                     Trigger subsystem
    webhook.ex                      Webhook trigger handler
    external_message.ex             External message trigger
    inter_agent.ex                  Inter-agent message trigger
    cron_scheduler.ex               Cron-based scheduling
    scheduler.ex                    Heartbeat scheduler
  workspace/
    prompt_assembler.ex             Assembles agent prompts from definitions + skills
    committer.ex                    Workspace Git commits with provenance trailers
    sweeper.ex                      Workspace cleanup

runtime/                      Python agent runtime (bind-mounted into containers)
  agent_runner.py               Claude Agent SDK bridge (stdin/stdout JSON Lines)
  protocol.py                   Message types and emitters
  entrypoint.sh                 Container startup (iptables, exec agent)
  browser-stealth.js            Headless browser anti-detection patches

connector/                    Chat platform bridge (Python)
  connector/main.py             Connector entry point
  connector/gateway_client.py   WebSocket connection to gateway
  connector/protocol.py         Connector-gateway message protocol
  connector/config.py           Configuration loading
  connector/formatting.py       Message formatting and chunking
  connector/tool_briefs.py      Tool brief rendering from gateway specs
  connector/transcriber.py      Conversation transcription
  connector/adapters/           Platform adapters
    base.py                         Abstract adapter interface
    matrix.py                       Matrix (Element) adapter
    slack.py                        Slack adapter

frontend/                     Web dashboard (Django)
  trionyx_ui/gateway.py         HTTP client for the gateway API
  trionyx_ui/schema_cache.py    TTL-cached /agents/schema metadata
  trionyx_ui/tool_briefs.py     Tool brief rendering from gateway specs
  trionyx_ui/views/             Dashboard, chat, graph, builder, approvals views
  trionyx_ui/templates/         HTML templates
  trionyx_ui/static/            CSS and JS assets

scripts/                      Utility scripts
  test-agent.py                 End-to-end test harness
  browser.py                    Browser automation and screenshot tool (Playwright)
  tri-onyx-plugin.py            Plugin management CLI
  explain-risk.py               Risk score explainer
  log-viewer.py                 CLI log viewer
  slack-log.py                  Read Slack bot channel history
  generate-agent-docs.py        Generate docs/agents/ pages from definitions
  generate-templates.py         Generate .env.example, connector config, workspace templates
  install-hooks.sh              Install pre-commit hooks (secret leak prevention)
  safe-push.sh                  Pre-push safety checks

workspace/                    Gateway-managed git repositories (agent state)
  bare/                         Bare repos — source of truth (per-agent + shared:
                                core, definitions, knowledge)
  trees/                        Working trees the gateway manages and mounts
                                (trees/<agent>/self, trees/_ro/..., trees/_gw/...)
  gitdirs/                      Git metadata kept outside the working trees
  data/                         Non-repo data (browser-sessions, github clones at
                                data/github + data/github-ro)
  archive/                      Archived legacy single-repo workspace
```

Agent definitions live in the shared `definitions` repo; plugins live inside the
owning agent's repo (`/workspace/plugins/<name>`) or a shared repo
(`/repos/knowledge/plugins/<name>`).
