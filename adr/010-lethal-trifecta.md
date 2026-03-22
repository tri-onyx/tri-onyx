# ADR-010: The Lethal Trifecta — Taint, Sensitivity, and Capability

- **Status:** Accepted
- **Date:** 2026-02-21
- **Deciders:** Falense
- **Supersedes:** Partially revises [ADR-001](001-information-is-the-threat.md)

## Context

This ADR is inspired by Simon Willison's ["The Lethal Trifecta"](https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/), which identifies the convergence of private data access, untrusted content exposure, and external communication ability as the critical threat model for AI agents. TriOnyx generalizes this into three trackable axes — taint, sensitivity, and capability — and enforces containment at the architectural level.

[ADR-001](001-information-is-the-threat.md) established that information is the threat and defined effective risk as `taint × sensitivity`, explicitly excluding capability from the runtime risk formula. This was a deliberate overcorrection against the industry's capability-only security models, and it served its purpose: it shifted design attention from sandboxing to information flow.

However, experience with real agent topologies reveals that the two-axis model is incomplete. A high-taint, high-sensitivity agent with only low capability — writes limited to its own directory, no network access, no external tool calls — cannot cause a critical security failure. It has been poisoned and it knows secrets, but its blast radius is confined to internal effects. The session is compromised in principle but contained in practice.

Conversely, prompt injection research consistently demonstrates that exploitation requires three conditions to converge:

1. **Taint** — adversarial content in the model's context (the attack vector).
2. **Sensitivity** — access to confidential or privileged information (the prize).
3. **Capability** — the ability to effect irreversible external actions (the weapon).

Any combination of two at elevated levels is manageable when the third is constrained:

- **Taint + sensitivity, low capability:** the agent has been poisoned and knows secrets, but can only write to its own directory and send inter-agent messages. It cannot directly exfiltrate data or trigger irreversible external effects. Containment holds through architectural constraint.
- **Taint + capability, low sensitivity:** the agent has been poisoned and has powerful tools, but knows nothing worth stealing. It can be manipulated into making tool calls, but those calls produce no confidential data leakage. The damage is limited to the agent's own low-value domain.
- **Sensitivity + capability, low taint:** the agent knows secrets and has powerful tools, but has not been influenced by adversarial content. Its integrity is intact — it will use its capabilities as designed. This is the normal operating state of a trusted, privileged agent.

The convergence of all three is required for the critical attack surface: a prompt-injected agent that knows sensitive data and has tools to exfiltrate or act on it. This is the **lethal trifecta**.

ADR-001's formulation that "capability is not part of the runtime risk formula" is too strong. Capability should not be the *primary* axis (the industry's mistake), but excluding it entirely from risk assessment means the system cannot distinguish between a compromised-but-contained agent and a compromised-and-armed one.

## Decision

Adopt the **lethal trifecta** as the foundational security heuristic for TriOnyx: for any agent session or pipeline stage, ensure that at least one of taint, sensitivity, or capability is sufficiently constrained. Critical risk arises only when all three legs are elevated simultaneously.

### Revised risk model

Effective risk becomes a three-dimensional function:

```
effective_risk = taint × sensitivity × capability
```

Where capability is derived from `(tools, network_policy)`:

| Combination | Capability | Rationale |
|------------|-----------|-----------|
| Bash + network access | **High** | Unmediated execution + network = can exfiltrate/act externally |
| Bash, no network | **Medium** | Unmediated execution but blast radius is container-local |
| SendEmail / MoveEmail / CreateFolder | **Medium** | Externally visible, gateway-mediated |
| WebFetch / WebSearch (no Bash) | **Medium** | Outbound network, gateway-mediated |
| Read / Write / Edit / Grep / Glob / NotebookEdit | **Low** | Internal filesystem only |
| SendMessage / BCPQuery / BCPRespond / RestartAgent | **Low** | Internal inter-agent effects |

Key insight: Bash is the only tool that executes **unmediated by the gateway**. All other external tools (email, web) go through the gateway which can inspect, throttle, and block. This is why Bash is treated differently — its base capability is medium, promoted to high when the agent has network access.

Every agent has at least low capability — it can write to its own directory and send inter-agent messages. There is no "none" level; an agent with zero capability would not be running.

The 2D baseline (`taint × sensitivity`) is modulated by capability. Each level shifts the baseline by one step:

#### Capability: low (step down one level)

|            | sens: low | sens: medium | sens: high |
|------------|-----------|--------------|------------|
| taint: low    | low       | low          | low        |
| taint: medium | low       | low          | moderate   |
| taint: high   | low       | moderate     | high       |

#### Capability: medium (no modulation — 2D baseline)

|            | sens: low | sens: medium | sens: high |
|------------|-----------|--------------|------------|
| taint: low    | low       | low          | moderate   |
| taint: medium | low       | moderate     | high       |
| taint: high   | moderate  | high         | critical   |

#### Capability: high (step up one level, capped at critical)

|            | sens: low | sens: medium | sens: high |
|------------|-----------|--------------|------------|
| taint: low    | low       | moderate     | high       |
| taint: medium | moderate  | high         | critical   |
| taint: high   | high      | critical     | critical   |

The key insight: a `critical` taint × sensitivity score with `low` capability is only `high` effective risk — the agent is compromised but its blast radius is limited to internal effects. The trifecta reaches `critical` only when capability is medium or high. Conversely, high capability escalates moderate baseline risk to high — an armed agent is more dangerous even at moderate taint × sensitivity.

### Taint decomposition

Taint decomposes into two components that are tracked independently:

- **Base taint** — a property of the model itself: its training data provenance, alignment quality, known vulnerability classes, and version. Base taint is set at agent definition time and does not change during a session. A model with known prompt injection susceptibilities carries higher base taint regardless of runtime inputs.

- **Session taint** — accumulated during runtime from the data the agent processes. This is the taint tracked by the existing gateway logic (webhook payloads, web-scraped content, messages from tainted agents).

Effective taint is the maximum of the two: `effective_taint = max(base_taint, session_taint)`. This ensures that a model with poor alignment cannot be treated as low-taint simply because it has not yet encountered adversarial input in the current session.

### Multi-agent propagation

In multi-agent pipelines, labels propagate across stages:

- **Taint propagates forward** through data flow (as already implemented). Agent B reading Agent A's output inherits A's taint. Sanitization steps taint down one level.
- **Sensitivity decays forward** through data flow. Agent B reading Agent A's output inherits `step_down(A's sensitivity)` — one level lower. An uncompromised agent won't willingly disclose secrets, so sensitivity attenuates per hop.
- **Capability is not inherited.** Each agent has its own capability level determined by its tool access. A high-capability agent receiving a message from a low-capability agent does not reduce its own capability.

The trifecta check applies per-stage: at each agent in the pipeline, verify that the combination of its accumulated taint, accumulated sensitivity, and its own capability does not reach critical. Pipeline design should ensure that agents with high capability receive only low-taint inputs (through sanitization) or only low-sensitivity data (through redaction), breaking at least one leg of the trifecta.

### Design heuristic

For any agent or pipeline stage, ensure at least one of:

1. **Taint is controlled** — the agent receives only trusted, sanitized, or human-reviewed inputs. Break this leg through input sanitization, human-in-the-loop review, or restricting the agent to trusted data sources.

2. **Sensitivity is controlled** — the agent has not been exposed to confidential data. Break this leg through data redaction, aggregation, or restricting the agent to public data sources.

3. **Capability is controlled** — the agent's capability stays at the low level (internal effects only). Break this leg through tool restrictions, approval gates, or scoping the agent's tools to agent-local file writes and inter-agent messages.

## Rationale

### Prompt injection is a hazard to contain, not a problem to solve

The industry treats prompt injection as a model-level problem to be solved through better training, instruction hierarchies, or input filtering. This framing leads to an arms race that defenders cannot win — adversarial inputs will always find novel evasion paths.

The trifecta reframes prompt injection as a **hazard to be contained through architectural constraint**. It does not matter whether the model can resist a specific injection attempt. What matters is that even if injection succeeds (taint is elevated), the architecture ensures that either the agent does not know anything worth stealing (sensitivity is low) or the agent's capability is limited to internal effects (capability is low). The system is secure under the assumption that prompt injection cannot be reliably prevented.

### The two-axis model understates containment

Under ADR-001's `taint × sensitivity` formula, a high-taint, high-sensitivity agent with no external tools is rated `critical` — the same as one with full shell access. This forces unnecessary session terminations for agents that are compromised but architecturally contained. The trifecta distinguishes between "compromised and dangerous" and "compromised but inert," allowing the system to be less conservative where containment holds.

### Capability re-enters the model without becoming the primary axis

The original concern in ADR-001 was valid: the industry's exclusive focus on capability creates a false sense of security around "read-only" agents. The trifecta does not revert to capability-first thinking. Capability alone is never sufficient for critical risk — it requires the convergence of taint and sensitivity. A high-capability agent with low taint and low sensitivity is rated `low` risk, which matches reality: a trusted, unprivileged agent with powerful tools is not a security concern.

### Base taint acknowledges model-level risk

Not all models are equally trustworthy. A model with known jailbreak vulnerabilities, opaque training data, or no alignment testing carries inherent risk independent of runtime inputs. Base taint captures this without requiring a separate trust framework — it folds model provenance into the existing taint axis.

### The heuristic is compositional

The trifecta check applies independently at each stage of a multi-agent pipeline. This makes it tractable for complex topologies: rather than reasoning about end-to-end information flow (which the graph analyzer does for violation detection), each stage can be evaluated locally. If every stage has at least one constrained leg, the pipeline as a whole is secure.

## Alternatives Considered

### Keep the two-axis model unchanged

Continue treating risk as `taint × sensitivity` with capability excluded. Simpler, but cannot distinguish contained agents from armed ones. Forces conservative session termination for agents that pose no practical threat. The operational cost of false positives increases as topologies grow more complex.

### Four-axis model (adding "reach" as separate from capability)

Distinguish between what an agent can do locally (filesystem writes, computation) and what it can do externally (network access, email, webhooks). More precise, but adds complexity without proportionate benefit. The capability axis already captures this distinction through its level gradation (low/medium/high). Network reach is reflected in the medium/high capability levels.

### Probabilistic taint based on injection detection confidence

Instead of binary taint tracking, assign probabilistic taint scores based on content analysis (e.g., "70% likelihood of prompt injection"). More nuanced in theory, but prompt injection detection is unreliable — the confidence scores would be poorly calibrated. Structural taint tracking (based on data source, not data content) is deterministic and cannot be evaded by encoding tricks. The lethal trifecta's power comes from not depending on injection detection at all.

### Capability gating instead of monitoring

Rather than tracking capability as a risk axis, dynamically revoke tools when taint or sensitivity rises. This was rejected in ADR-001 for good reasons: race conditions between detection and revocation, complex state machines, and audit difficulty. The trifecta monitors capability as a risk dimension but does not dynamically modify it. The "kill, don't downgrade" principle from ADR-001 still applies — when the trifecta converges, terminate the session rather than attempting to remove tools.

## Consequences

- **Positive:** The security model now captures all three necessary conditions for critical failure. Agents that are compromised but architecturally contained (low capability) are correctly assessed as high rather than critical risk.
- **Positive:** The trifecta provides a simple, actionable design heuristic: for every agent, break at least one leg. This is easier to communicate and verify than the two-axis risk matrix.
- **Positive:** Prompt injection is reframed from a model-level problem to an architectural containment problem. The system is secure even under the assumption that injection succeeds.
- **Positive:** Base taint folds model provenance into the existing tracking framework without requiring a separate trust model.
- **Positive:** The heuristic is compositional — each pipeline stage can be evaluated independently, making it tractable for complex topologies.
- **Negative:** The three-axis model is more complex than the two-axis model. The risk matrix grows from a 3×3 table to a 3×3×3 space. Visualization and operator comprehension require more effort.
- **Negative:** Capability classification requires judgment. The boundary between "low" (reversible, internal) and "medium" (externally visible) capability is not always clear-cut. Tool definitions must be annotated with capability levels, adding configuration burden.
- **Negative:** This partially revises ADR-001's explicit statement that "capability is not part of the runtime risk formula." Existing documentation, the security model description, and the graph visualization need to be updated to reflect the three-axis model.
- **Accepted trade-off:** The increased complexity is justified by the increased precision. The two-axis model was a necessary overcorrection against capability-only thinking; the trifecta is the synthesis that incorporates all three dimensions in their proper relationship.
