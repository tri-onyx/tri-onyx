# ADR-001: Information Is the Threat, Not Capability

- **Status:** Accepted
- **Date:** 2026-02-17
- **Deciders:** Falense

## Context

Every mainstream agent framework treats capability as the primary threat vector. The standard approach is to sandbox what an agent *can do* — restrict filesystem access, disable shell execution, limit network calls. The assumption is: a capable agent is a dangerous agent, so reduce capability to reduce risk.

This framing is wrong for LLMs. An LLM with full shell access that has only seen trusted data is safe. An LLM with read-only access that has ingested a prompt injection is dangerous — it can exfiltrate data through its outputs, manipulate downstream agents through its messages, and corrupt decision-making across the entire system. The threat is not what the agent can do. The threat is what the agent has seen.

TriOnyx needs a security model that reflects this reality.

## Decision

Adopt the principle that **information is the threat, not capability**. Security is a function of `taint x sensitivity`, not capability alone. The security model tracks what data each agent has been exposed to and restricts behavior based on exposure. Capability (which tools an agent has) is controlled at the agent definition level and is not part of the runtime risk formula.

## Rationale

### Prompt injection is an information attack, not a capability attack

The defining vulnerability of LLM agents is prompt injection: adversarial instructions embedded in data that the model processes as trusted input. A prompt injection does not require the agent to have dangerous tools. It requires the agent to have *seen* the malicious content. Once the model's context is poisoned, everything it produces — text, tool calls, messages to other agents — is suspect.

Sandboxing tools does not address this. A read-only agent that has been prompt-injected can still:

- Craft messages to other agents containing the injected instructions (propagation)
- Produce misleading summaries that influence human decisions (integrity corruption)
- Encode sensitive data in seemingly innocuous outputs (steganographic exfiltration)
- Manipulate downstream agents that *do* have dangerous tools (privilege escalation through influence)

### Capability-only models create a false sense of security

If security is measured purely by tool access, a read-only agent appears safe by definition. This hides the actual risk: a read-only agent that has ingested raw internet data and communicates with a capable agent is a conduit for prompt injection into that agent's session. The risk exists in the information flow, not in either agent's tool set.

### Two independent information axes capture the real threat surface

TriOnyx tracks information exposure on two orthogonal axes derived from established information security models:

**Taint (integrity, from the Biba model):** How trustworthy is the data the agent has seen? An agent exposed to raw webhook payloads or web-scraped content carries high taint — the data may contain adversarial content. Taint tracks the prompt injection risk.

**Sensitivity (confidentiality, from Bell-LaPadula):** How sensitive is the data the agent has seen? An agent that has queried an internal database carries high sensitivity — it knows things that should not leave the system. Sensitivity rises when the agent has seen confidential data — data that originated from a high-sensitivity source or file. Sensitivity tracks the data exfiltration risk.

These are independent dimensions. An agent can be high-taint and low-sensitivity (ingested untrusted public data), low-taint and high-sensitivity (queried a trusted internal database), or high on both. Each combination produces different risks that require different containment strategies.

### Effective risk is a function of taint and sensitivity

Effective risk combines the two information exposure axes: `effective_risk = taint x sensitivity`. Capability (which tools an agent has) is controlled at the agent definition level — it determines what the agent *can* do, but it is not part of the runtime risk formula. Risk is about what the agent has *seen*.

|                    | sensitivity: low | sensitivity: medium | sensitivity: high |
|--------------------|-----------------|---------------------|-------------------|
| taint: low         | low             | low                 | moderate          |
| taint: medium      | low             | moderate            | high              |
| taint: high        | moderate        | high                | critical          |

An agent with high taint but low sensitivity is *moderate* risk — it may be manipulated but has not seen confidential data. An agent with low taint but high sensitivity is also *moderate* — it has seen confidential data but is not under adversarial influence. The highest risk is an agent that is both manipulable *and* informed.

### Risk is monotonic and session-scoped

Both taint and sensitivity can only increase during a session. You cannot un-see a prompt injection or un-learn a database record. This eliminates an entire class of race conditions and policy bypass attacks that plague dynamic capability revocation systems. If an agent's effective risk exceeds its policy threshold, the gateway kills the session. There is no attempt to downgrade or recover — kill and restart clean.

### The gateway never gives agents credentials

If information is the threat, then credentials are just another form of dangerous information. TriOnyx's gateway holds all credentials and attaches them to tool calls on the agent's behalf. The agent receives the response data but never the credentials themselves. This eliminates credential leakage as an attack surface entirely — a prompt-injected agent cannot exfiltrate tokens it never had.

However, the agent *does* receive the data those credentials access. This is why the sensitivity axis exists: the gateway tracks that authentication was used, marks the agent's sensitivity level accordingly, and restricts where the agent can write based on what it now knows.

## Alternatives Considered

### Capability-first sandboxing (standard approach)

The default in agent frameworks: restrict tools, filesystem access, and network. Simple to implement. Fails to model information flow risks. Creates false confidence in "read-only" agents that may be prompt-injection conduits. Ignores the distinction between trusted and untrusted inputs.

### Content inspection and filtering

Scan all inputs for prompt injections and all outputs for sensitive data. Theoretically complete, practically brittle. Prompt injection detection has a high false-negative rate — adversarial inputs are designed to evade classifiers. Output filtering cannot catch steganographic encoding or influence attacks through seemingly benign content. Content inspection is a useful supplementary layer but cannot be the primary security mechanism.

### Full isolation (no inter-agent communication)

Eliminate information flow between agents entirely. Prevents all propagation attacks. Also prevents useful multi-agent workflows — the entire point of TriOnyx's agent topology. The goal is not to eliminate information flow but to track and contain it.

### Dynamic capability revocation

Reduce an agent's tools as its risk increases (e.g., revoke shell access when taint rises). Sounds elegant. In practice, creates race conditions between detection and revocation, requires complex state machines for capability transitions, and is difficult to audit. TriOnyx's "kill, don't downgrade" approach is simpler, more auditable, and eliminates the window between detection and enforcement.

## Consequences

- **Positive:** The security model captures risks that capability-only approaches miss entirely — prompt injection propagation, influence attacks through read-only agents, and data exfiltration through output channels.
- **Positive:** The monotonic risk property eliminates race conditions and simplifies policy enforcement to a single threshold check.
- **Positive:** The gateway-as-secret-holder pattern eliminates credential leakage as an attack class, independent of agent compromise.
- **Positive:** The two-axis model (taint x sensitivity) is simple enough to reason about, visualize, and audit. Capability is controlled separately at the agent definition level.
- **Negative:** Taint and sensitivity tracking adds overhead to every message and file operation. The gateway must intercept, annotate, and check every data flow.
- **Negative:** The model is conservative — it treats all data from a given source at the same risk level. A webhook payload that happens to be benign still carries high taint. This may terminate sessions that could have safely continued.
- **Accepted trade-off:** False positives (killing safe sessions) are preferable to false negatives (allowing compromised sessions to continue). In autonomous AI systems, the cost of a missed prompt injection propagating through the agent topology vastly exceeds the cost of restarting a session.
