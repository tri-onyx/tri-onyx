# Cloud Architecture Design

**Status:** Draft — research complete, backend decision pending spike
**Date:** 2026-06-12
**Scope:** Moving the TriOnyx agent pattern (gateway-orchestrated, per-repo agents with Slack channels) to the cloud, with multi-user access, real-time interaction, and the same agent lifecycle as today.

---

## 1. Background

TriOnyx today runs on a single workstation:

- An **Elixir gateway** owns all orchestration: triggers (Slack, schedule, frontend), one
  session GenServer per agent, the idle timeout (the gateway schedules `:idle_timeout`
  and issues `docker stop` itself), approvals, and real-time fan-out to Slack and the
  web frontend.
- Each agent session is a **Docker container** started on trigger and stopped after
  idle timeout (30 min – 2 h per agent definition). `AgentPort` shells out to the
  Docker CLI with host bind mounts.
- Agents are **long-lived identities**: per-agent memory files, git clones under
  `workspace/repos/{owner}/{repo}`, and a Slack channel that serves as the full
  activity record (native messages, inter-agent mirrors, frontend mirrors).
- A **FUSE driver** (`tri-onyx-fs`) enforces per-agent path-based filesystem access
  control inside the container, requiring `/dev/fuse` + `CAP_SYS_ADMIN`.
- Agents are built on the **Claude Agent SDK** (a binding we accept and keep).

The orchestration model is the asset. Docker is just the last mile. "Move to the
cloud" therefore decomposes into three swappable concerns:

1. **Container backend** — replace "Docker CLI on this host" with an API.
2. **Agent state** — replace host bind mounts with per-agent cloud storage.
3. **Transport** — replace the stdin/stdout Port with a network channel.

## 2. Goals

- **Same lifecycle:** start a sandbox on trigger, stop after ~30 min inactivity,
  gateway-driven. Near-zero cost while all agents are idle.
- **Real-time interaction:** streamed output to Slack and frontend within seconds of
  a trigger; multiple humans interacting with the same agent.
- **Multi-user:** authenticated frontend access; the Slack channel remains the shared
  activity record; approvals carry user identity.
- **Agent learning persists across sessions:** memory files, and ideally the tools the
  agent installed for itself.
- **Agent autonomy in the sandbox:** root inside its own environment, free to
  `apt`/`pip`/`uv` install. Isolation comes from the sandbox boundary, not path policy.
- **AWS-first:** we are an AWS shop; prefer AWS-native services where they fit.
- **Low vendor lock-in:** the Claude Agent SDK binding is as much coupling as we
  accept. No platform whose removal requires rewriting orchestration or agents.

## 3. Non-goals

- **FUSE is dropped.** Per-agent path-based access control is replaced by
  one-filesystem-per-agent plus IAM-scoped storage. The FUSE driver, path trie,
  policy expansion, and `Sandbox.build_fuse_policy/1` are retired in the cloud
  deployment. (This also reopens platforms that ban privileged containers.)
- **A shared workspace filesystem.** Repo agents don't need one: each agent's state
  is its own clone + memory, and inter-agent communication is already
  message-passing through the gateway. The host-wide `workspace/` bind mount is
  retired, not ported.
- **Rewriting the gateway as FaaS.** The gateway is a stateful real-time process
  (WebSockets, session GenServers, idle timers, approval waits). Lambda / Step
  Functions are wrong-shaped for it. "Serverless" for the gateway means a small
  always-on container service, not functions.

## 4. What we learned (research, June 2026)

### 4.1 Platform landscape

- **Without FUSE, the whole container PaaS market opens up.** With FUSE, only
  microVM platforms (Fly Machines, E2B, Cloud Run gen2) and Kubernetes on real
  nodes qualified. Plain containers with root-but-unprivileged run fine on Fargate.
- **Git working trees must never live on NFS-class storage** (EFS, Filestore,
  Azure Files). Git is metadata-IOPS-bound; ~ms per op × tens of thousands of ops
  per `git status` produces seconds-per-command. GitLab dropped NFS support for
  this reason. Small memory files on EFS are fine.
- **Fargate cold start is 10–25 s** even with SOCI lazy loading and a slim ARM
  image (no image cache; fresh pull per task). A warm EC2 host with cached images
  starts tasks in 3–10 s. Only AgentCore Runtime reaches 1–5 s on AWS.
- **The lifecycle needs no platform feature.** The gateway already stops idle
  sessions; the backend only needs fast programmatic start/stop. KEDA/Knative-style
  autoscalers would fight the gateway, not help it.

### 4.2 AWS Bedrock AgentCore

AgentCore Runtime (GA Oct 2025; Stockholm/Frankfurt/Ireland since Jan 2026) is a
Firecracker-microVM-per-session host for BYO ARM64 containers exposing
`POST /invocations` + `GET /ping`. Claude Agent SDK is officially documented on it.

- **Lifecycle match is exact:** `idleRuntimeSessionTimeout` configurable to 1800 s;
  sessions stay warm between invocations; CPU is free while idle or waiting on the
  model (memory-only billing, ≤ ~$0.08/h); cold start ~2–5 s.
- **Autonomy:** the agent is the sole user in its microVM; installs work.
- **Constraints:** 8 h hard session lifetime (state survives only on mounts),
  2 vCPU / 8 GB cap, ARM64 only, invoke/SSE protocol (not our dial-back WebSocket).
- **Persistence is the weak spot:** ephemeral by default. Per-session managed
  storage is preview (1 GB, wiped on deploy). BYO EFS / S3 Files mounts shipped
  May 2026 but force VPC mode + NAT, and are EU-preview-lagged.
- **AgentCore Memory: skip.** It's an opaque LLM-extraction pipeline for end-user
  conversations (~20–40 s extraction, poor inspectability). Our agent-authored
  memory files are the better pattern.
- **Lock-in: low if Runtime-only.** The container is a portable OCI image with a
  trivial HTTP contract; migrating off means swapping one `AgentPort` backend.

### 4.3 Claude Managed Agents (Anthropic platform)

Public beta April 2026 (`/v1/agents`). Hosts the *agent loop itself* — agent
definitions, sessions, Memory Stores (file-like per-agent memory mounted into the
sandbox), git-proxy repo mounts (token never enters the container), Vaults,
scheduled Deployments, managed idle/sleep. Sandboxes run on Anthropic's infra or
partners (Cloudflare, Modal, Daytona, Vercel) or self-hosted workers.

It independently validates the TriOnyx architecture almost feature-for-feature —
and is the wrong choice for us today:

- It **does not run Claude Agent SDK code** (different API surface; agents would be
  re-expressed as Agent/Session configs, not lifted).
- **No Slack ingress** — our connector/gateway survives anyway, as a thin bridge.
- **Maximal lock-in:** it replaces exactly the layer we own (orchestration,
  scheduler, sandbox, memory) with first-party beta APIs, unavailable via Bedrock.

Decision: re-evaluate in ~12 months; do not adopt now. Anthropic's own Agent SDK
hosting guidance leaves hosting to the user and recommends sandbox providers.

### 4.4 Validation from production agent platforms

Devin (snapshot-per-agent VMs, sleep-on-idle, ~200 ms wake via blockdiff), Claude
Code on the web (per-session VM, git proxy keeps tokens outside the sandbox,
egress allowlist), and Codex cloud (cached environments + setup scripts, network-
restricted agent phase) all converge on the same pattern we're building: persistent
agent identity, ephemeral fast-waking sandboxes, credentials held outside the
sandbox, environment-as-replayable-setup.

## 5. Design

### 5.1 The gateway stays the control plane

The Elixir gateway remains the orchestrator and moves to AWS as a small always-on
container service (~0.25 vCPU Fargate service, or on the warm EC2 host in option C).
It keeps: trigger routing, session supervision, idle timeout, approvals, inter-agent
messaging, Slack/frontend fan-out, and the GitHub credential mediation (tokens
never enter the sandbox — the pattern Claude Code web and Managed Agents both use).

This is deliberate lock-in strategy: owning the orchestration layer is what makes
every backend a swappable adapter.

Public ingress in AWS also unblocks the postponed **Phase 2 GitHub webhooks**
(issue @mention triggers) — either directly on the gateway or via a Lambda front
door.

### 5.2 Backend abstraction

`AgentPort` becomes a behaviour with pluggable backends:

```
@callback start_session(definition, session_id, opts) :: {:ok, handle} | {:error, _}
@callback stop_session(handle) :: :ok
@callback transport(handle) :: :port | {:websocket, ...} | {:sse, ...}
```

- `Docker` — current behavior, kept for local dev and as the escape hatch.
- `EcsFargate` — `RunTask` / `StopTask` (option A).
- `AgentCore` — `InvokeAgentRuntime` with one stable `runtimeSessionId` per agent
  (option B).

Each backend must be testable locally against the same protocol-level test harness
(`scripts/test-agent.py`).

### 5.3 Transport inversion

Replace the stdin/stdout Port with the agent runtime **dialing back to the gateway
over WebSocket**, reusing the existing JSONL protocol verbatim. Benefits: survives
gateway restarts, works across any network boundary, identical across Docker and
ECS backends. (The AgentCore backend instead consumes the SSE stream from
`InvokeAgentRuntime`; the protocol frames ride inside it.)

### 5.4 Per-agent state model

Agent state is decomposed by reconstructibility — this is the core design and it is
identical across all backends, which is what keeps them swappable:

| State | Property | Storage | Session start |
|---|---|---|---|
| Memory files (`/agents/{name}/**`) | small, precious | per-agent EFS access point (or S3 tarball) | mount (or restore) |
| Git clones | large, reconstructible | **not persisted** | clone / tarball-restore to ephemeral disk |
| Installed tools | learned, replayable | manifest + user-prefix installs on the persistent mount | replay `setup.sh` |
| Slack channel, GitHub | already durable | Slack / GitHub | — |

The **installed-tools pattern** is how agent autonomy and persistence reconcile:
the agent owns a `setup.sh` / tool manifest *inside its memory directory* and is
instructed to update it when it installs something it wants to keep. User-prefix
installs (`~/.local`, `uv tool`) land on the persistent mount directly; system
packages are replayed from the manifest at session start (10–60 s, hidden behind
the first streamed response). Stable toolsets get periodically baked into a
per-agent ECR image. The agent's learned environment is thereby inspectable,
reviewable files — the same shape as its memory.

Hard rule carried over from research: **no git working trees on EFS.** Clones go
to task-local ephemeral storage every session; GitHub is the source of truth.

### 5.5 Multi-user

- **Frontend:** OIDC in front of the gateway (Phoenix handles N-user real-time
  fan-out natively; the broadcast/mirror model already centralizes visibility).
- **Sessions:** unchanged model — one shared session per agent; all users see the
  same conversation, mirrored to the agent's channel.
- **Approvals:** carry the approving user's identity (Slack user ID or OIDC
  subject) into the approval record.
- **Slack:** already multi-user; no change.

### 5.6 Security model without FUSE

- Isolation boundary = the sandbox (task/microVM), one per agent.
- Storage scoping = IAM: each agent's task role can reach only its own EFS access
  point / S3 prefix.
- Credentials (GitHub tokens, Slack) stay gateway-side, exactly as today.
- Egress control = security groups / egress proxy per task (replaces the
  `network:` definition field's iptables implementation).

## 6. Backend options

### Option A — ECS Fargate `RunTask` (default landing zone)

Gateway calls `RunTask` on trigger, `StopTask` on idle timeout. Root +
`apt install` inside the task is allowed (only privileged/cap-add is banned, which
we no longer need). ARM + Spot with on-demand fallback; SOCI-indexed image.

- First response: 10–25 s cold. Mitigate with an immediate Slack
  acknowledgment ("on it 👀") and a slim image.
- Cost: ~$0 idle; ~$0.05/session-hour; EFS pennies at our scale.
- Lock-in: minimal (plain containers + one AWS API).

### Option B — AgentCore Runtime (latency play; needs a spike)

Same gateway; `AgentPort.AgentCore` backend; one stable session per agent;
`idleRuntimeSessionTimeout=1800`. Persistence via BYO EFS mount (VPC mode).

- First response: 1–5 s cold, sub-second warm. Idle CPU free.
- Risks to spike-test in eu-central-1: BYO EFS mount maturity, the 8 h lifetime
  rollover (state must survive microVM re-provisioning via the mount), silent-
  restart/health-ping behavior with a long-running Agent SDK process, deploy
  semantics.
- Lock-in: low (Runtime only; AgentCore Memory/Identity/Gateway not used).

### Option C — Warm EC2 host (own-the-infra fallback)

One t4g/m7g instance (~$25–30/mo flat) running the current Docker stack, gateway
included. Task start 3–10 s, local-NVMe git speed, per-agent Docker volumes
persist installs natively. Cheapest path off the workstation and the zero-risk
stepping stone; gives up per-second scaling we don't need at this fleet size,
costs AMI/patching ops.

### Comparison

| | A: Fargate | B: AgentCore | C: EC2 host |
|---|---|---|---|
| First response (cold) | 10–25 s | **1–5 s** | 3–10 s |
| Idle cost | ~$0 | ~$0 | ~$25–30/mo flat |
| Tool persistence | setup.sh replay | EFS prefix + setup.sh | **native (volumes)** |
| Gateway changes | RunTask backend | Invoke/SSE backend | ~none |
| Lock-in | minimal | low | none |
| Ops burden | low | low | medium |

**Decision:** A is the default landing zone. Run a one-week spike on B — if BYO
EFS + session semantics hold up in eu-central-1, B becomes the runtime (the
container runs unmodified on either, so this is a config-level switch). C is the
immediate stepping stone if we want off the workstation before the state-model
work lands.

## 7. Migration plan

Each step is independently shippable and testable against the local Docker backend.

1. **State model** — move agent state to the per-agent layout (memory dir +
   `setup.sh` manifest + ephemeral clones). Retire the shared-workspace
   assumption and FUSE policy generation behind a feature flag.
2. **Transport inversion** — WebSocket dial-back from the agent runtime to the
   gateway, JSONL protocol unchanged. Docker backend first.
3. **Backend behaviour** — extract `AgentPort` backends; `Docker` + `EcsFargate`.
4. **Gateway to AWS** — Fargate service (or EC2 host), OIDC on the frontend,
   approval user identity, secrets to SSM/Secrets Manager.
5. **AgentCore spike** — parallel to 4; decide A vs B.
6. **GitHub webhooks (old Phase 2)** — public ingress now exists; issue-@mention
   triggers with `author_association` tainting as originally designed.

## 8. Risks and open questions

- **Cold-start UX (option A):** is 10–25 s acceptable for Slack @mentions with an
  immediate acknowledgment? If not, B is forced, or a small warm pool.
- **AgentCore preview lag in EU:** BYO EFS/session storage are new (Mar–May 2026)
  and EU availability of previews trails us-east-1. Spike must run in-region.
- **Setup-replay drift:** agents may install tools without updating the manifest.
  Mitigation: the existing agent-drift audit pattern, plus a session-end diff of
  installed packages vs manifest surfaced to the agent.
- **Browser sessions:** today's bind-mounted `~/.browser-sessions` needs a home
  (per-agent EFS dir, or AgentCore's managed Browser as a later option).
- **Spot interruptions (A):** 2-min SIGTERM warning; agent must flush memory on
  SIGTERM (the `memory_save_timeout` path already exists).
- **Claude Managed Agents trajectory:** re-evaluate in ~12 months; if it gains
  Agent SDK execution or Bedrock availability, the calculus changes.

## 9. References

- AgentCore Runtime sessions / lifecycle: <https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-sessions.html>, <https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-lifecycle-settings.html>
- AgentCore filesystem configurations (session storage, BYO EFS/S3 Files): <https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/runtime-filesystem-configurations.html>
- AgentCore pricing (idle CPU free): <https://aws.amazon.com/bedrock/agentcore/pricing/>
- Claude Agent SDK on AgentCore: <https://builder.aws.com/content/30O5JJPjEeCugL5MAfSM9TTcd9p/deploying-claude-agent-sdk-on-amazon-bedrock-agentcore-runtime>
- Hosting coding agents on AgentCore: <https://aws.amazon.com/blogs/machine-learning/its-safe-to-close-your-laptop-now-hosting-coding-agents-on-amazon-bedrock-agentcore/>
- Anthropic Managed Agents: <https://www.anthropic.com/engineering/managed-agents>; Cloudflare environments: <https://blog.cloudflare.com/claude-managed-agents/>
- Anthropic Agent SDK hosting guidance: <https://platform.claude.com/docs/en/agent-sdk/hosting>
- Claude Code sandboxing (git proxy, egress): <https://www.anthropic.com/engineering/claude-code-sandboxing>
- Devin blockdiff (snapshot-per-agent validation): <https://cognition.ai/blog/blockdiff>
- Fargate SOCI lazy loading: <https://aws.amazon.com/blogs/aws/aws-fargate-enables-faster-container-startup-using-seekable-oci/>
- ECS task launch optimization: <https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-recommendations.html>
- Git-on-EFS anti-pattern: <https://dev.to/tielec-takashi/how-git-temp-files-killed-our-jenkins-performance-efs-metadata-iops-hell-3ff4>; EFS performance: <https://docs.aws.amazon.com/efs/latest/ug/performance-tips.html>
- Amazon S3 Files (managed NFS on S3): <https://www.infoq.com/news/2026/04/aws-s3-files/>
- Kubernetes agent-sandbox (considered, not chosen): <https://github.com/kubernetes-sigs/agent-sandbox>
- Fly Machines (considered, not chosen — non-AWS): <https://fly.io/docs/machines/overview/>
