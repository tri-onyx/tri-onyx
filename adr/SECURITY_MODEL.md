# TriOnyx Security Model

TriOnyx uses a graduated risk model to track and contain the spread of risk across autonomous AI agents. The model rests on three dimensions: **how trustworthy the data is** (taint), **how sensitive the data is** (sensitivity), and **what the agent can do** (capability). This is the "lethal trifecta" — critical risk arises only when all three converge at elevated levels ([ADR-010](010-lethal-trifecta.md)).

## Design Principles

1. **Agents never hold credentials.** The gateway is the sole secret holder. Agents request tool calls; the gateway attaches credentials before dispatching and strips them from responses. An agent cannot leak a token it never had.

2. **Risk is monotonic within a session.** Both taint and sensitivity levels can only increase during a session. You can't un-see a prompt injection or un-learn a database record. Once exposed, the session is permanently marked.

3. **Kill, don't downgrade.** When an agent's effective risk exceeds its policy threshold, the correct response is to terminate the session — not to dynamically revoke capabilities. This is simpler to implement, easier to audit, and avoids race conditions between policy enforcement and agent behavior.

4. **Defense in depth.** The risk model, FUSE filesystem enforcement, and gateway-level policy checks are independent layers. A failure in one does not compromise the others.

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

When effective risk reaches a threshold defined in the agent's policy, the gateway terminates the session.

## Information Propagation

Risk spreads between agents through two channels. Taint and sensitivity propagate independently — a message from a high-taint, low-sensitivity agent raises the receiver's taint but not its sensitivity.

### File-based propagation

When agent A writes a file and agent B reads it, B inherits A's risk levels. The file is tagged in the risk manifest with the writing agent's taint and sensitivity levels at the time of writing. When B reads the file, B's levels escalate to match.

### Inter-agent messages

When agents send messages to each other, the message carries the sender's taint and sensitivity levels. The receiving agent's levels escalate to match on the respective axes.

### Sanitization

**Sanitization** is the only way to reduce taint in transit. When a message passes through sanitization, its taint steps down one level:

- High → Medium
- Medium → Low
- Low → Low

Sanitization does **not** reduce sensitivity. Rephrasing a database record doesn't make it less sensitive — the information content is preserved even if the exact wording changes. Sensitivity can only be reduced by **redaction** (removing specific sensitive fields) or **aggregation** (replacing individual records with statistical summaries).

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

Every file written by an agent is tagged in `.tri-onyx/risk-manifest.json` with:

- The **taint level** of the writing agent's session
- The **sensitivity level** of the writing agent's session
- Which **agent** wrote it
- **When** it was last updated
- Whether a **human has reviewed** it (resets taint to low; sensitivity unchanged)

Git commits include `Taint-Level:` and `Sensitivity-Level:` trailers so the full provenance history is preserved in version control.

## FUSE Enforcement

As defense-in-depth, the FUSE filesystem layer enforces both taint and sensitivity policies per agent:

- **`max_read_taint`**: the maximum taint level of files this agent may read. Prevents clean agents from reading tainted files (Biba enforcement at the filesystem level).
- **`max_read_sensitivity`**: the maximum sensitivity level of files this agent may read. Prevents low-privilege agents from accessing sensitive data (BLP enforcement at the filesystem level).

These checks use the risk manifest. Even if an agent's glob pattern would allow access to a file, the FUSE layer denies the read if the file's tagged risk exceeds the agent's policy.

## Graph Analysis

The graph analyzer computes transitive risk propagation across the full agent topology. Given agent A → B → C (where → means "writes files read by"), it traces how both taint and sensitivity flow through the chain and identifies the **maximum input risk** each agent faces from all upstream sources on each axis independently.

This powers the visualization in `graph.html`, which renders agents as nodes (colored by taint level, bordered by sensitivity level, sized by effective risk) connected by directed edges showing information flow. The Biba and Bell-LaPadula toggles highlight violations in real time.

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
