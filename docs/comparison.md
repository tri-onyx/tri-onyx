# How TriOnyx differs from OpenClaw

TriOnyx is a security-first reimagining of the OpenClaw agent runtime. Where OpenClaw sandboxes **capability** (restrict filesystem, disable shell, limit network), TriOnyx tracks **information** -- what enters an agent's context and where it flows next.

| | TriOnyx | OpenClaw |
|---|---|---|
| **Core focus** | Security-first agent runtime with information flow control | Multi-platform AI assistant gateway |
| **Security thesis** | Information is the threat, not capability -- track what agents have *seen*, not just what they can *do* | Capability sandboxing -- restrict filesystem, shell, and network access per session |
| **Primary language** | Elixir/OTP (+ Python, Go) | TypeScript (+ Swift, Kotlin) |
| **Gateway design** | Non-agentic OTP control plane -- no LLM, no autonomy, deterministic security boundary | WebSocket control plane managing sessions, channels, tools, and events |
| **Agent isolation** | Each agent in its own Docker container with per-agent FUSE filesystem, iptables rules, no shared state | Docker sandboxing for non-main sessions; shared-state sessions via JSONL transcripts |
| **Taint tracking** | Biba integrity model -- tracks exposure to untrusted content (prompt injections, web data) | Not implemented |
| **Sensitivity tracking** | Bell-LaPadula confidentiality -- tracks access to secrets, credentials, private data | Not implemented |
| **Information flow enforcement** | Gateway intercepts all inter-agent messages; blocks flows violating integrity or confidentiality constraints; graph analysis for transitive risk | Not implemented at the information-flow level |
| **Credential handling** | Gateway is sole credential holder -- agents never see raw secrets | Agents can access credentials based on session config |
| **Filesystem control** | Custom Go FUSE driver with per-file read/write policy, structured access logging, O(1) path-trie checks | Standard Docker filesystem isolation |
| **Approval workflows** | BCP approvals (bandwidth-constrained trust) + action approvals via REST API | Three-tier tool approval (ask/record/ignore) |
| **Audit trail** | Structured logs for file access, tool calls, message routing, and policy violations; queryable audit API | Session transcripts (JSONL) |
| **Human review** | Explicit review endpoint to reset taint on artifacts; risk manifest for file-level provenance | Not formalized |
| **Messaging platforms** | Matrix (via connector adapter; extensible base class for adding more) | 22+ platforms (WhatsApp, Telegram, Signal, iMessage, Teams, etc.) |
| **Web interface** | Real-time dashboard -- agent topology graph, classification matrix, log viewer | macOS, iOS, Android with voice, camera, device integration |
| **Browser control** | Headless Chromium with persistent host sessions (`browser: true` per agent) | Chrome DevTools Protocol |
| **Skills / plugins** | Skill files loaded at session start; FUSE-enforced -- undeclared skills are unreadable | ClawHub marketplace (bundled, managed, workspace skills) |
| **Deployment** | Docker / docker-compose (single-operator) | Docker, Podman, Fly.io, Render, Cloudflare Workers, Nix, systemd, launchd |
| **LLM support** | Claude (via Claude Agent SDK) | Claude, GPT, DeepSeek, Gemini, and others |

## When to choose TriOnyx

You care more about **what your agents know** than what platforms they connect to. You want formal information flow guarantees, auditable provenance, and a non-agentic security boundary -- and you're willing to trade breadth of platform support and a large contributor ecosystem for those properties.

## When to choose OpenClaw

You want the widest possible platform reach, native mobile apps, and a large community. You're comfortable managing security through capability restrictions and operational discipline rather than information-theoretic enforcement.
