# ADR-006: Gateway as Sole Credential Holder with Automatic Sensitivity Classification

- **Status:** Accepted
- **Date:** 2026-02-17
- **Deciders:** Sondre

## Context

[ADR-001](001-information-is-the-threat.md) establishes that information exposure is the primary threat to LLM agents. Credentials are a particularly dangerous form of information: an agent that holds an API token can use it to access data beyond its intended scope, and a prompt-injected agent that holds credentials can exfiltrate them directly.

Beyond credential leakage, there is a subtler problem: even when an agent uses credentials legitimately, the *response data* it receives may be sensitive. A database query returns user PII. An internal API returns deployment secrets. The agent does not have the database password, but it now has the data the password protects. The system must track this exposure — but manually classifying every tool response as "sensitive" or "not sensitive" is error-prone and does not scale.

TriOnyx needs a credential management model that eliminates credential leakage as an attack class entirely, and a sensitivity classification model that determines data sensitivity automatically from observable properties of the tool call rather than content inspection.

## Decision

1. The **gateway is the sole custodian of all credentials**. Agents never receive, hold, or transmit credentials. The gateway attaches credentials to tool calls on the agent's behalf and strips them from responses before returning results.

2. **Sensitivity is classified automatically** based on whether the gateway attached credentials to the tool call:
   - **No authentication required** → low sensitivity
   - **Authentication required** → medium sensitivity
   - **Authentication required + tool declares sensitive data** → high sensitivity

## Rationale

### Credential leakage is eliminated structurally, not behaviorally

If agents never receive credentials, they cannot leak them — not through prompt injection, not through file writes, not through inter-agent messages, not through any output channel. This is not a policy that relies on the agent behaving correctly. It is a structural property: the information does not exist in the agent's context.

The gateway executes tool calls in a six-step flow:

1. Agent requests a tool call (e.g., "query the user database")
2. Gateway checks the agent's permissions — is this agent authorized to use this tool?
3. Gateway retrieves the necessary credentials from its secure store
4. Gateway executes the tool call with credentials attached
5. Gateway returns the response to the agent — **without the credentials**
6. Gateway updates the agent's sensitivity level based on the tool's declared data sensitivity

Steps 3-5 happen entirely within the gateway process. The agent sees only the request and the response. The credentials exist in the gateway's memory for the duration of the tool call and nowhere else.

### Authentication is an observable, binary signal for sensitivity

The key insight is that whether a tool call required authentication is a reliable proxy for data sensitivity, and the gateway knows this without inspecting the response content:

- **No auth required** → the data is public. Anyone could access it. Low sensitivity.
- **Auth required** → the data is non-public by definition. If it were public, it would not require authentication. Medium sensitivity.
- **Auth required + sensitive declaration** → the tool definition declares that responses contain PII, financial data, or security-sensitive information. High sensitivity.

The low/medium boundary is **fully automatic**. The gateway attached credentials — therefore the data is non-public — therefore sensitivity is at least medium. No content inspection, no classification model, no heuristics. The medium/high boundary is set by the **tool definition** at configuration time, which declares the sensitivity class of its response data.

### Sensitivity classification drives downstream containment

Once an agent's sensitivity level is elevated, the consequences cascade through the security model:

- The agent's **effective risk** increases (sensitivity feeds into `taint x sensitivity`)
- **Bell-LaPadula checks** restrict where the agent can write — it cannot produce output readable by lower-sensitivity agents with network access
- The **FUSE driver** can deny reads of files tagged with this sensitivity level to agents whose `max_read_sensitivity` threshold is lower
- The **risk manifest** records the sensitivity level on every file the agent writes, propagating the classification to downstream consumers

All of this flows from the single observation: "the gateway attached credentials to this tool call."

### Tool metadata is the configuration surface

Each tool registered with the gateway declares:

```elixir
%{
  requires_auth: true,
  data_sensitivity: :high
}
```

`requires_auth` determines whether the gateway attaches credentials. `data_sensitivity` declares the response data classification. These are set once at tool definition time and do not change at runtime. The classification rule is deterministic: given the tool metadata, the sensitivity level is fully determined.

## Alternatives Considered

### Pass credentials to agents via environment variables

The standard approach in most agent frameworks. Simple but fundamentally insecure: the credentials exist in the agent's process environment and can be read by any code the agent executes, exfiltrated through tool calls, or leaked through prompt injection. A single compromised agent can exfiltrate every credential it holds.

### Content-based sensitivity classification

Scan tool responses for sensitive data patterns (SSNs, credit card numbers, email addresses). Produces false negatives (novel sensitive data formats) and false positives (test data that looks real). Requires maintaining and updating pattern libraries. The authentication-based heuristic is simpler, more reliable, and catches the common case: if data requires auth to access, it is non-public.

### Agent-declared sensitivity ("I just saw sensitive data")

Let the agent self-report when it encounters sensitive information. Relies on the agent behaving correctly — the exact property that prompt injection attacks compromise. A manipulated agent could under-report sensitivity to avoid write restrictions. The gateway's classification is authoritative because it is based on what the gateway did (attach credentials), not what the agent claims.

### Per-response classification by a second LLM

Route every tool response through a classification LLM that labels it as low/medium/high sensitivity. Adds latency and cost to every tool call. The classifier itself could be manipulated if the tool response contains adversarial content. The authentication-based rule achieves the same boundary with zero additional computation.

## Consequences

- **Positive:** Credential leakage is structurally impossible. No behavioral assumptions about agents are needed.
- **Positive:** The low/medium sensitivity boundary is fully automatic with zero false negatives — every authenticated tool call elevates sensitivity.
- **Positive:** Sensitivity classification is deterministic and auditable. Given the tool metadata, the classification is predictable.
- **Negative:** The authentication-based heuristic over-classifies. A tool that requires auth but returns non-sensitive data (e.g., a health check endpoint behind auth) will be classified as medium sensitivity. This is conservative — false positives restrict agent behavior unnecessarily but do not create security gaps.
- **Negative:** The medium/high boundary depends on correct tool definitions. A tool that returns PII but declares `data_sensitivity: :low` will be under-classified. Mitigated by treating tool definitions as security-critical configuration reviewed at definition time.
- **Accepted trade-off:** The gateway becomes a single point of failure for credential access. If the gateway is compromised, all credentials are exposed. This is the standard trade-off of centralized secret management (vault pattern) — the attack surface is concentrated but hardened, rather than distributed across every agent process.
