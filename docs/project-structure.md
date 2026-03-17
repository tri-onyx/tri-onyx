# Project Structure

```
lib/tri_onyx/               Elixir gateway (OTP application)
  application.ex                OTP application supervisor
  router.ex                     HTTP API (Plug/Bandit)
  agent_session.ex              Per-session GenServer (taint, risk, lifecycle)
  agent_port.ex                 Elixir Port to Python subprocess
  agent_supervisor.ex           DynamicSupervisor for sessions
  agent_loader.ex               Loads agent definitions from disk
  definition_watcher.ex         Watches for definition file changes
  sandbox.ex                    Translates definitions into docker run args
  information_classifier.ex     Taint/sensitivity classification from data sources
  risk_scorer.ex                Risk matrix computation
  graph_analyzer.ex             Transitive risk propagation and violation detection
  taint_matrix.ex               Taint state per agent
  sensitivity_matrix.ex         Sensitivity state per agent
  sanitizer.ex                  Input/output sanitization
  workspace.ex                  Risk manifest, Git commits, human review
  tool_registry.ex              Tool metadata registry
  event_bus.ex                  Pub/sub for SSE streaming and connectors
  connector_handler.ex          WebSocket handler for connectors
  session_logger.ex             Structured session logging
  audit_log.ex                  Audit log persistence
  git_provenance.ex             Git-based file provenance tracking
  action_approval_queue.ex      Human-in-the-loop action approvals
  webhook_receiver.ex           Incoming webhook processing
  webhook_endpoint.ex           Webhook endpoint CRUD
  webhook_registry.ex           Webhook endpoint storage
  webhook_signature.ex          HMAC signature verification
  webhook_rate_limiter.ex       Per-endpoint rate limiting
  trigger_router.ex             Routes triggers to target agents
  bcp/                          Bandwidth-Constrained Protocol
    approval_queue.ex               Human approval queue for BCP messages
    bandwidth.ex                    Bandwidth level computation
    channel.ex                      BCP channel management
    escalation.ex                   Escalation handling
    query.ex                        Structured query format
    validator.ex                    BCP message validation
  connectors/                   Built-in connectors (Elixir side)
    email.ex                        IMAP/SMTP email connector
    calendar.ex                     CalDAV calendar connector
  triggers/                     Trigger subsystem
    webhook.ex                      Webhook trigger handler
    external_message.ex             External message trigger
    inter_agent.ex                  Inter-agent message trigger
    cron_scheduler.ex               Cron-based scheduling
    scheduler.ex                    Heartbeat scheduler
  workspace/
    prompt_assembler.ex             Assembles agent prompts from definitions + skills

runtime/                      Python agent runtime (bind-mounted into containers)
  agent_runner.py               Claude Agent SDK bridge (stdin/stdout JSON Lines)
  protocol.py                   Message types and emitters
  entrypoint.sh                 Container startup (FUSE mount, iptables, exec agent)
  browser-stealth.js            Headless browser anti-detection patches

fuse/                         Go FUSE driver
  cmd/tri-onyx-fs/              CLI entry point
  internal/fs/                  FUSE node implementation
  internal/policy/              JSON policy parser and glob expansion
  internal/pathtrie/            Path trie for O(1) access checks

connector/                    Chat platform bridge (Python)
  connector/main.py             Connector entry point
  connector/gateway_client.py   WebSocket connection to gateway
  connector/protocol.py         Connector-gateway message protocol
  connector/config.py           Configuration loading
  connector/formatting.py       Message formatting and chunking
  connector/transcriber.py      Conversation transcription
  connector/adapters/           Platform adapters
    base.py                         Abstract adapter interface
    matrix.py                       Matrix (Element) adapter

webgui/                       Web dashboard (static HTML)
  frontend.html                 Agent overview and control panel
  graph.html                    Agent topology visualization
  matrix.html                   Classification matrix view
  log-viewer.html               Session log browser

scripts/                      Utility scripts
  test-agent.py                 End-to-end test harness
  screenshot.py                 Page screenshot tool (Playwright)
  tri-onyx-plugin.py            Plugin management CLI
  explain-risk.py               Risk score explainer
  log-viewer.py                 CLI log viewer
  generate-templates.py         Generate .env.example, connector config, workspace templates
  install-hooks.sh              Install pre-commit hooks (secret leak prevention)
  safe-push.sh                  Pre-push safety checks

workspace/agent-definitions/  Agent definitions (markdown + YAML frontmatter)
workspace/plugins/            Installed plugins (newsagg, bookmarks, diary, etc.)
```
