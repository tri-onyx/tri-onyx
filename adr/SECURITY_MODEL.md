# TriOnyx Security Model

TriOnyx uses a graduated risk model to track and contain the spread of risk across autonomous AI agents. The model rests on three dimensions: **how trustworthy the data is** (taint), **how sensitive the data is** (sensitivity), and **what the agent can do** (capability). This is the "lethal trifecta" — critical risk arises only when all three converge at elevated levels ([ADR-010](010-lethal-trifecta.md)).

The concept originates from Simon Willison's ["The Lethal Trifecta"](https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/), which identifies the combination of private data access, untrusted content exposure, and external communication as the critical threat model for AI agents. TriOnyx operationalizes this insight into a formal, enforceable security model.

## Design Principles

1. **Agents never hold credentials.** The gateway is the sole secret holder. Agents request tool calls; the gateway attaches credentials before dispatching and strips them from responses. An agent cannot leak a token it never had.

2. **Risk is monotonic within a session.** Both taint and sensitivity levels can only increase during a session. You can't un-see a prompt injection or un-learn a database record. Once exposed, the session is permanently marked.

3. **Kill, don't downgrade.** When an agent's effective risk exceeds its policy threshold, the correct response is to terminate the session — not to dynamically revoke capabilities. This is simpler to implement, easier to audit, and avoids race conditions between policy enforcement and agent behavior.

4. **Defense in depth.** The risk model, the per-agent repo mount boundary (the kernel bind-mount ACL), and gateway-level policy checks are independent layers. A failure in one does not compromise the others.

## Taint Level (integrity axis)

Every agent session has a **taint level** that tracks how trustworthy the data it has been exposed to is. This is the Biba integrity dimension.

| Level      | Meaning                            | Examples                                              |
|------------|-------------------------------------|-------------------------------------------------------|
| **Low**    | Only seen trusted, verified data    | Cron triggers, heartbeats, human-reviewed artifacts   |
| **Medium** | Exposed to partially trusted data   | Messages from medium-taint agents, sanitized high-taint data |
| **High**   | Exposed to unverified external data | Webhook payloads, WebFetch results, raw internet data |

The primary threat modeled by taint is **prompt injection**. An agent that has ingested raw internet data may have been influenced by adversarial content embedded in that data. Everything it produces downstream is suspect.

## Sensitivity Level (confidentiality axis)

Every agent session has a **sensitivity level** that tracks how sensitive the data it has been exposed to is. This is the Bell-LaPadula confidentiality dimension. Sensitivity rises when the agent has seen confidential data — data that originated from a high-sensitivity source or file.

| Level      | Meaning                                      | Examples                                                   |
|------------|-----------------------------------------------|------------------------------------------------------------|
| **Low**    | Only seen public or non-sensitive data         | Public documentation, open-source code, published schemas  |
| **Medium** | Seen non-public data from authenticated sources | Internal issue lists, deployment status, config values      |
| **High**   | Seen PII, financial, or security-sensitive data | User records, billing data, audit logs, internal credentials in data |

### Classification rule

Sensitivity is determined by the tool calls an agent makes and the data returned:

- **No authentication required** → low sensitivity floor. The data is public; anyone could access it.
- **Authentication required** → medium sensitivity floor. The gateway attached credentials to make this call, which means the data behind it is non-public by definition. If it were public, it wouldn't need auth.
- **Authentication required + sensitive data classification** → high sensitivity. The tool definition declares that its responses contain PII, financial data, or security-sensitive information.

The gateway knows whether it attached credentials to a tool call. This makes the low/medium boundary **automatic** — no content inspection needed. The medium/high boundary is set by the **tool definition**, which declares the sensitivity of its response data at configuration time.

### Secrets in response data

Although agents never hold credentials directly, tool responses may contain sensitive information *obtained through* those credentials. A database query returns user records. An internal API returns deployment secrets stored as config values. The agent doesn't have the database password, but it now has the data the password protects.

This is why sensitivity tracks **response data sensitivity**, not credential possession. The gateway-as-secret-holder pattern eliminates credential leakage but not data leakage. The sensitivity level ensures that agents who have seen sensitive response data face appropriate write restrictions.

## Effective Risk

**Effective risk** combines three dimensions: taint, sensitivity, and capability — the "lethal trifecta" ([ADR-010](010-lethal-trifecta.md)). Critical risk requires all three axes at elevated levels simultaneously.

Effective risk is computed as: `taint × sensitivity × capability`.

**Step 1:** Compute 2D baseline from `taint × sensitivity`:

|                    | sensitivity: low | sensitivity: medium | sensitivity: high |
|--------------------|-----------------|---------------------|-------------------|
| taint: low         | low             | low                 | moderate          |
| taint: medium      | low             | moderate            | high              |
| taint: high        | moderate        | high                | critical          |

**Step 2:** Modulate by capability (each level shifts the baseline by one step):

#### Capability: low (step down — contained agent)

|            | sens: low | sens: medium | sens: high |
|------------|-----------|--------------|------------|
| taint: low    | low       | low          | low        |
| taint: medium | low       | low          | moderate   |
| taint: high   | low       | moderate     | high       |

#### Capability: medium (no change — baseline)

|            | sens: low | sens: medium | sens: high |
|------------|-----------|--------------|------------|
| taint: low    | low       | low          | moderate   |
| taint: medium | low       | moderate     | high       |
| taint: high   | moderate  | high         | critical   |

#### Capability: high (step up — armed agent)

|            | sens: low | sens: medium | sens: high |
|------------|-----------|--------------|------------|
| taint: low    | low       | moderate     | high       |
| taint: medium | moderate  | high         | critical   |
| taint: high   | high      | critical     | critical   |

- **Low**: the agent is either trusted, has not seen sensitive data, or is contained (or a combination).
- **Critical**: an agent has been exposed to unverified external data *and* highly sensitive internal data *and* has external-facing capabilities — it may be manipulated, it knows things that should not leave the system, and it has the tools to act on it.

Capability is derived from `(tools, network_policy)` per agent and does not propagate between agents. Each agent's capability is determined by its own tool access: Bash + network = high, Bash without network or gateway-mediated external tools = medium, internal-only tools = low.

### Base taint

Each agent definition may declare a `base_taint` level (`:low`, `:medium`, or `:high`, default `:low`) that captures model-level risk — training data provenance, alignment quality, known vulnerability classes. The effective taint for a session is `max(base_taint, session_taint)`, ensuring that a model with poor alignment cannot be treated as low-taint simply because it has not yet encountered adversarial input.

### Kill on threshold

Each agent definition may declare a `max_effective_risk` ceiling (`low`, `moderate`, `high`, or `critical`; default `critical`). When a session's effective risk escalates **above** this level, the gateway kills the session immediately — mid-turn, no grace period — and refuses to start sessions whose initial classification already exceeds it. The default of `critical` can never be exceeded, so enforcement is opt-in per agent: tighten the ceiling on agents whose blast radius warrants it.

## Information Propagation

Risk spreads between agents through two channels. Taint and sensitivity propagate independently — a message from a high-taint, low-sensitivity agent raises the receiver's taint but not its sensitivity.

**Sensitivity decays per hop — in worst-case analysis only.** The static graph analysis (see Graph Analysis below) reduces sensitivity by one level (via `step_down`) at every hop when projecting worst-case propagation. The rationale: unless an agent is already compromised, it will not willingly disclose secrets verbatim, so the likelihood of disclosure attenuates over multi-hop chains. This decay is a property of the analysis model in `GraphAnalyzer.propagate_levels/3`, not of runtime session state — runtime propagation differs per channel (see below).

### File-based propagation

Every write an agent makes to its own repo or a `repos_write` mount is recorded in the risk manifest at session-end commit, tagged with the writing session's taint and sensitivity at that moment (point-in-time labels — a file written before the session's risk escalated keeps the lower label).

There is no per-read observation — the mount set replaces FUSE as the enforcement point (ADR-012). At session start, `InformationClassifier.classify_readable_repos/1` scans the risk manifest for the maximum taint and sensitivity recorded anywhere across the repos the session can read (its own repo plus its `repos_read`/`repos_write` grants) and applies that maximum as a floor for the entire session — reading raw file content is direct disclosure, so the per-hop decay rationale does not apply here. Because the floor already reflects the worst label visible anywhere in the mount set, no read during the session can expose the agent to a higher label than it started with.

Reads are never blocked: an agent may read anything inside its mounted repos, and the start-of-session floor (combined with the kill threshold above) is the enforcement.

### Inter-agent messages

When agents send messages to each other, the routing metadata carries the sender's taint level at full strength, and the receiver's taint escalates to match (`InterAgent.route/2` sets `information_level` in the trigger metadata).

> **Implementation divergence:** the model calls for the receiver's sensitivity to escalate to `step_down(sender's sensitivity)`, but message routing metadata currently carries no sensitivity level at all — the receiver's runtime sensitivity is unchanged by incoming messages. Only the worst-case graph analysis applies the step-down rule to messaging edges. (`InformationClassifier.classify_message/3`, which implements full-strength sensitivity inheritance, is not called from any production path.)

### Sanitization

**Sanitization** is a structural defense that validates message format and rejects malformed payloads. It does **not** reduce taint. Whether a message is sanitized or raw, the receiver inherits the sender's full taint level. The bandwidth constraint (1024-byte strings provide sufficient channel for prompt injection) means structural validation alone cannot step down taint.

Sanitization does **not** reduce sensitivity either. Sensitivity can only be reduced by **redaction** (removing specific sensitive fields) or **aggregation** (replacing individual records with statistical summaries).

### Human review

A human reviewing and approving an artifact resets its taint to **low**. The human has judged the content safe, removing the prompt injection concern. Sensitivity level is unaffected — the data is still sensitive regardless of who reviewed it.

## Policy Violations

TriOnyx detects two classes of security policy violations:

### Biba violations (integrity)

A Biba violation occurs when a **low-taint agent reads data from a higher-taint source**. The concern is integrity contamination: a clean agent ingesting potentially poisoned data.

Example: Agent A ingested a raw webhook payload (high taint) and wrote a summary file. Agent B (low taint, trusted) reads this file. B is now contaminated — the summary may contain prompt injection attempts that influence B's behavior.

Detection: flag any data flow where the source's taint level exceeds the reader's taint level.

### Bell-LaPadula violations (confidentiality)

A Bell-LaPadula violation occurs when an **agent that has seen sensitive data writes to a location readable by a less-privileged, network-capable agent**. The concern is data exfiltration: sensitive information leaking out of the system through an agent that can reach the network.

Example: Agent A queried an internal database and received user PII (high sensitivity). A writes a report file. Agent B (low sensitivity, with WebFetch access) reads this file. B could now inadvertently include PII in an outbound API call.

Detection: flag any data flow where the source's sensitivity level exceeds the reader's sensitivity level *and* the reader has network capability.

### Why both checks are necessary

Biba and Bell-LaPadula catch different threats:

- **Biba** guards against **inbound** threats: malicious external data corrupting trusted agents (prompt injection propagation).
- **Bell-LaPadula** guards against **outbound** threats: sensitive internal data reaching agents that could exfiltrate it.

An agent topology can have Biba violations without BLP violations and vice versa. Both must be checked independently.

## Risk Manifest

Every file written by an agent is tagged in the risk manifest (`TriOnyx.RiskManifest`, an in-memory ETS store in the gateway) with:

- The **taint level** of the writing agent's session at the time of the write
- The **sensitivity level** of the writing agent's session at the time of the write
- Which **agent** wrote it
- **When** it was last updated
- Whether a **human has reviewed** it (resets taint to low; sensitivity unchanged)

Workspace git history is the durable record: provenance commits carry `Taint-Level:` and `Sensitivity-Level:` trailers, and human reviews are recorded as empty commits with `Reviewed-Path:` trailers. The in-memory store is rebuilt from that history at gateway boot and kept current at runtime — `Workspace.Committer` updates it synchronously per write event (so concurrently running sessions resolve fresh labels on read) and batches the corresponding trailer-carrying git commits on a short debounce. See ADR-008 (amended).

## Mount Role

Per ADR-012, filesystem isolation is a kernel bind-mount boundary rather than a userspace filesystem driver: **the mount set is the ACL**. Each agent's own repo is mounted read-write at `/workspace`; `repos_read`/`repos_write` grants mount shared repos or other agents' repos read-only or read-write at `/repos/<name>`. There is no glob-based path policy and no symlink handling to enforce — what isn't mounted doesn't exist inside the container, and nothing more granular than a repo is exposed.

This means there is no read-time observation (see File-based propagation above): the mount set does not filter reads by risk level — there is deliberately no limit on the taint or sensitivity an agent may read within its mounts. Computing the start-of-session floor from the mount set, and killing sessions that exceed their permitted ceiling, is the enforcement mechanism (see Kill on threshold above).

## Graph Analysis

The graph analyzer computes transitive risk propagation across the full agent topology. Given agent A → B → C (where → means "writes files read by"), it traces how taint and sensitivity flow through the chain and identifies the **maximum input risk** each agent faces from all upstream sources on each axis independently. Taint propagates at full strength (except across BCP edges, where it is stepped down). Sensitivity is stepped down by one level at every hop, reflecting the decay principle described above.

> **Known modeling discrepancy:** runtime file-read escalation inherits sensitivity at full strength, while the analyzer's filesystem edges apply the per-hop step-down — so the static projection can slightly *understate* sensitivity propagation relative to runtime behavior on filesystem chains.

This powers the graph visualization in the web frontend, which renders agents as nodes (colored by taint level, bordered by sensitivity level, sized by effective risk) connected by directed edges showing information flow. The Biba and Bell-LaPadula toggles highlight violations in real time.

## Gateway as Secret Holder

The gateway is the sole custodian of credentials in the system. This is a foundational architectural decision that shapes the entire security model.

### How it works

1. An agent requests a tool call (e.g., "query the user database").
2. The gateway checks the agent's permissions — is this agent authorized to use this tool?
3. If authorized, the gateway retrieves the necessary credentials from its secure store.
4. The gateway executes the tool call with credentials attached.
5. The gateway returns the response to the agent — **without the credentials**.
6. The gateway updates the agent's sensitivity level based on the tool's declared data sensitivity.

### What this prevents

- **Credential leakage via prompt injection**: a compromised agent cannot exfiltrate tokens it never received.
- **Credential leakage via file writes**: an agent cannot write credentials to a file because it doesn't have them in context.
- **Lateral credential movement**: agents cannot pass credentials to each other because no agent possesses any.

### What this does not prevent

- **Data leakage**: an agent still receives the *response data* obtained through credentials. A prompt-injected agent with network access could exfiltrate query results. This is what the sensitivity level and BLP checks address.
- **Unauthorized tool use**: a compromised agent could request tool calls it shouldn't. This is handled by the gateway's per-agent permission checks, independent of the risk model.

### Known weaknesses

- **Docker socket proxy exposes container environment variables.** Agents with `docker_socket: true` can run `docker inspect` on other agent containers through the tecnativa/docker-socket-proxy. The proxy operates at the URL-path level (allow/deny entire endpoint categories) and cannot filter fields from response bodies. Since `CONTAINERS: 1` grants access to `/containers/{id}/json`, the full inspect response is returned — including the `Env` array, which contains `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` for every running agent container. This violates the principle that agents never hold credentials: while the agent's own process does not receive other agents' keys through normal channels, the Docker API provides a side channel to read them. A filtering reverse proxy that strips `Config.Env` from inspect responses would close this gap.
- **Agent containers receive the Claude API key as an environment variable.** The gateway passes `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` to every agent container via `-e` flags. The Claude Agent SDK (`SubprocessCLITransport`) merges `os.environ` into the Claude Code subprocess environment, and Claude Code in turn passes its full environment to Bash tool children. There is no interception point: the key must be in the process environment for the SDK to authenticate, and every child process inherits it. Stripping the key from `os.environ` and passing it via `ClaudeAgentOptions(env=...)` is ineffective because the SDK merges both sources into the same subprocess env dict. This is an inherent limitation of the SDK's credential model — credential secrecy (ADR-006) does not extend to the LLM inference credential. The iptables network policy mitigates exfiltration risk: agents with `network: none` cannot reach any endpoint other than `api.anthropic.com`, limiting what a leaked key could be used for.
- **The `/repo` bind mount is not `RepoStore`-mediated.** Agents with `trionyx_repo: true` receive a raw read-only bind mount of the entire TriOnyx source repository at `/repo`. Unlike `/workspace` and `/repos/<name>`, this is a direct host bind mount outside `RepoStore` — it is not scoped by `repos_read`/`repos_write` grants, so any file in the repository tree — including `.env` files, secrets directories, or configuration with embedded credentials — is readable regardless of the agent's repo grants. Sensitive files should not be stored in the repository tree, or the `/repo` mount should be replaced with a filtered, `RepoStore`-managed mount.
