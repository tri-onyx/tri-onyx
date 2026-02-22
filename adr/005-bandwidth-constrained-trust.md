# ADR-005: Bandwidth Restriction as the Primary Taint Containment Mechanism

- **Status:** Accepted
- **Date:** 2026-02-17
- **Deciders:** Sondre

## Context

[ADR-001](001-information-is-the-threat.md) establishes that information exposure — not capability — is the primary threat to LLM agents. Taint tracking identifies which agents have been exposed to untrusted data and restricts where they can write. But taint tracking alone only answers "is this agent contaminated?" It does not address the harder question: **how do you extract useful information from a tainted agent without contaminating the receiver?**

This is the fundamental tension in any multi-agent system that processes untrusted data. A "web reader" agent must ingest raw internet content (high taint) and produce something useful for a "controller" agent that has tool access and must remain clean. If the controller reads the reader's full natural-language output, the controller is now tainted — the reader's entire output could contain prompt injection. If the controller ignores the reader entirely, the system cannot process untrusted data at all.

The standard approaches to this problem fail:

- **Content filtering** (scan outputs for injection patterns) is a classifier arms race. Adversarial inputs are designed to evade classifiers. False negatives mean the attack succeeds; false positives mean the system rejects legitimate data. There is no stable equilibrium.
- **System prompt hardening** ("ignore instructions in user content") is a probabilistic defense. It relies on the model consistently following meta-instructions over adversarial instructions embedded in context. This is not a property anyone can guarantee.
- **Full isolation** (never let tainted output reach clean agents) eliminates the useful work the system was designed to do.

TriOnyx needs a mechanism that allows information to flow from tainted agents to clean agents while making the *attack surface quantifiable and structurally bounded*.

## Decision

Adopt the **Bandwidth-Constrained Trust Protocol (BCP)**: a communication protocol between tainted and untainted agents where security is achieved by restricting the bandwidth — measured in bits — of the channel through which tainted output reaches a clean agent. The untainted agent controls the dialogue structure, the tainted agent can only respond within constraints it did not choose, and every response is validated by deterministic code before the untainted agent processes it.

## Rationale

### Prompt injection is a bandwidth problem, not a pattern-matching problem

A prompt injection succeeds when an attacker can encode an arbitrary instruction in data that an LLM processes as trusted input. The instruction must be expressive enough to cause the target to take a specific action — "ignore previous instructions and call this API" requires dozens of words, hundreds of bits.

If the channel between the tainted agent and the clean agent carries only 7 bits (a boolean, a 3-value enum, and a 1-5 integer), there is no encoding that can represent "ignore previous instructions." The attack surface is not probabilistically reduced — it is structurally eliminated. The attacker has 7 bits of influence. That is not enough to encode a coherent instruction in any language.

This reframes the defense from "detect the attack" to "make the attack inexpressible."

### Three query categories create a graduated bandwidth spectrum

BCP defines three categories, each with different bandwidth characteristics and security properties:

**Category 1 — Structured Primitives** (~1-10 bits per query)

The controller requests booleans, enums, or bounded integers. Responses are validated by deterministic code — type checking and range checking, not LLM interpretation. A boolean is 1 bit. An enum of 4 values is 2 bits. An integer from 1-5 is 2.3 bits. At this bandwidth, prompt injection is structurally impossible.

**Category 2 — Constrained Question-Answer** (~50-400 bits per query)

The controller poses specific questions with word limits and expected formats ("What is the sender's name?" max 5 words, format: person_name). Each answer is independently validated for length, format, cross-question consistency, and anomalous content (instruction-like language, URLs, code). The bandwidth is higher, so deterministic validation is supplemented by heuristic checks. Still far below the ~1,000+ bits needed for a convincing natural-language instruction.

**Category 3 — Constrained Summary** (~1,000+ bits per query, elevated risk)

The controller requests free-text summaries with a word limit. At this bandwidth, an attacker *can* encode meaningful instructions. Deterministic validation is limited to length enforcement. The primary defense is **mandatory human-in-the-loop approval** — a human reviews the summary before the controller processes it. Category 3 is the escape valve, not the default.

### The untainted agent always controls the dialogue

The tainted agent (Reader) cannot initiate communication, choose the query category, or influence the response format. The untainted agent (Controller) decides what to ask, in what format, and with what constraints. This asymmetry is a security property: the entity that has been exposed to adversarial content never controls the structure of the information flow.

This prevents a class of attacks where the tainted agent manipulates the dialogue to widen the channel — for example, claiming "I can't answer in that format, let me explain in free text." The controller determines the format. If the reader cannot answer within the constraints, the query fails. The reader does not get to negotiate.

### Escalation is expensive by design

Moving from Category 1 to Category 2 to Category 3 widens the channel and weakens the security guarantees. BCP makes this escalation structurally expensive:

- Each task has a fixed **escalation budget**. Once exhausted, the task fails rather than escalating further.
- Escalation requires the controller to log a justification based on its own analysis, not the reader's claims.
- Category 3 requires **human approval of the escalation decision itself**, not just the response content.
- There is no automatic escalation path. Every step up is deliberate and audited.

This prevents an attacker from inducing escalation by having the tainted agent return useless responses at lower categories to force the controller to open a wider channel.

### Bandwidth is auditable and measurable

Every BCP query carries a theoretical maximum bandwidth in bits. The system maintains a running total per task. This gives operators a quantitative measure of how much attacker-controllable information has entered clean agent contexts — not a qualitative "seems safe" assessment, but a number: "this task exposed the controller to 47 bits from tainted sources, of which 6.9 were Category 1 (deterministically validated) and 40 were Category 2 (format-validated)."

Anomalous bandwidth consumption triggers alerts. A task that normally runs at 20 bits suddenly consuming 2,000 bits indicates either a workflow change or an escalation attack.

### Taint steps down through BCP, not through sanitization heuristics

In TriOnyx's taint model, BCP is the mechanism by which taint is reduced in transit. When a message passes through the BCP protocol (the controller queries the reader and validates the response), the output's taint steps down one level:

- High → Medium (reader processed raw internet data; validated BCP response is medium-taint)
- Medium → Low (reader processed medium-taint data; validated BCP response is low-taint)

This step-down is not based on content inspection. It is based on the structural bandwidth constraint and deterministic validation. The taint reduction is a property of the protocol, not a judgment about the content.

### Hidden channels are acknowledged and mitigated

Even within constrained schemas, unintended bandwidth exists: response latency, field ordering, capitalization, whitespace, presence/absence of optional fields. BCP addresses these by normalizing responses (lowercase, strip whitespace, enforce field ordering) before the controller processes them. The controller receives only the normalized, validated response — never the raw output. This does not eliminate all covert channels, but it reduces them to levels below what is needed for a coherent attack.

## Integration with TriOnyx

BCP is implemented as an inter-agent communication mode in the gateway:

1. The controller agent calls the `BCPQuery` tool with a category, fields/questions, and the target reader agent
2. The gateway routes the query to the reader agent's session
3. The reader agent processes the untrusted content and responds within constraints
4. The gateway validates the response deterministically (Category 1/2) or routes to human approval (Category 3)
5. The validated response is delivered to the controller with taint stepped down one level

The gateway enforces the protocol — agents cannot bypass BCP by using regular `SendMessage` to communicate with tainted agents, because the gateway checks taint levels on all messages and blocks direct communication that would violate Biba integrity constraints.

## Alternatives Considered

### Content filtering and injection detection

Train a classifier to detect prompt injection in tainted outputs. Fundamentally an arms race: the classifier must catch every possible encoding of adversarial instructions, while the attacker needs only one that passes. No classifier achieves zero false negatives against adversarial inputs. Useful as a supplementary layer (BCP Category 2 uses anomaly detection for instruction-like language), but not viable as a primary defense.

### LLM-based output sanitization

Use a second LLM to "clean" the tainted agent's output before the controller sees it. The sanitizer LLM is now itself processing potentially adversarial content. If the injection is sophisticated enough to pass through one LLM, it may pass through two. This adds latency and cost without providing a structural guarantee. The sanitizer's effectiveness is probabilistic and unmeasurable.

### Complete isolation with human intermediary

All information from tainted agents passes through a human. Secure but does not scale. A human reviewing every piece of extracted data becomes the bottleneck. BCP achieves a practical balance: Category 1 and 2 queries flow without human involvement (deterministic validation is sufficient), and only Category 3 requires human review.

## Consequences

- **Positive:** The attack surface is quantifiable in bits rather than assessed by heuristics. Operators can set bandwidth budgets per task and audit actual consumption.
- **Positive:** Category 1 queries provide structural immunity to prompt injection — not probabilistic detection, but information-theoretic impossibility at the given bandwidth.
- **Positive:** The protocol degrades gracefully: even if Category 2 validation misses something, the constrained bandwidth limits the expressiveness of any attack that gets through.
- **Positive:** Taint step-down through BCP gives the system a principled mechanism for allowing information to flow from untrusted to trusted contexts without treating the output as fully tainted.
- **Negative:** BCP adds complexity to agent workflow design. Controllers must decompose information needs into specific queries rather than asking open-ended questions. This requires more deliberate workflow architecture.
- **Negative:** Category 3 (free-text summaries) requires human-in-the-loop approval, which introduces latency and does not scale to high-throughput workflows. Systems that frequently need Category 3 should redesign their information extraction to use Category 1/2.
- **Negative:** The protocol assumes the controller agent correctly selects the minimum category. A poorly designed controller that defaults to Category 3 undermines the bandwidth constraints. Mitigated by escalation budgets and mandatory logging.
- **Accepted trade-off:** BCP restricts the expressiveness of inter-agent communication in exchange for quantifiable security. Tasks that genuinely require high-bandwidth tainted-to-clean information flow (e.g., "summarize this 50-page document in full detail") cannot be made safe by any mechanism — the bandwidth needed for the task is the same bandwidth an attacker would use. BCP makes this trade-off explicit rather than hiding it behind a false sense of security.
