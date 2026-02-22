# Bandwidth-Constrained Trust Protocol (BCTP)

Protocol specification for secure communication between tainted and untainted agents in TriOnyx.

For the security rationale behind this protocol, see [ADR-001: Information Is the Threat](../adr/001-information-is-the-threat.md) and [ADR-005: Bandwidth-Constrained Trust](../adr/005-bandwidth-constrained-trust.md).

---

## Roles

**Controller (Untainted Agent):** Orchestrates the task. Determines what information is needed, selects the query category, sends queries, validates responses, and takes actions. Never directly exposed to untrusted content.

**Reader (Tainted Agent):** Processes untrusted content. Receives queries from the Controller and responds within the specified constraints. Has no tool access beyond responding to BCTP queries, no ability to initiate communication, and no influence over the protocol's structure.

The Controller is always the initiator. The Reader is always the responder. The entity exposed to adversarial content never controls the dialogue structure.

---

## Threat Model

### The Tainted Agent

An agent becomes tainted when it processes content that may contain adversarial payloads:

- Documents uploaded by users or retrieved from the web
- API responses from third-party services
- Content from databases that accept user input
- Outputs from other tainted agents

Once tainted, the agent's outputs are treated as potentially adversarial. The attacker's goal is to use the tainted agent as a vector to influence the untainted agent — causing it to take unauthorized actions, leak information, bypass policies, or corrupt its reasoning.

### Attacker Capabilities

The attacker can embed arbitrary text within the untrusted content that the tainted agent processes. The attacker does not have direct access to the untainted agent, the protocol implementation, or system prompts. The attacker's only influence on the untainted agent is through what passes through the BCTP channel.

---

## Query Categories

Every query from the Controller to the Reader is assigned one of three categories, each with distinct bandwidth characteristics and security properties.

### Category 1: Structured Primitives

The Controller requests a response in the form of one or more typed primitive values: booleans, integers within a specified range, or selections from a predefined enumeration.

**Wire format:**

```json
{
  "category": 1,
  "fields": [
    { "name": "is_urgent",   "type": "boolean" },
    { "name": "sentiment",   "type": "enum",    "values": ["positive", "neutral", "negative"] },
    { "name": "confidence",  "type": "integer",  "min": 1, "max": 5 },
    { "name": "category",    "type": "enum",    "values": ["billing", "technical", "legal", "other"] }
  ]
}
```

**Bandwidth:** Each boolean is 1 bit. An enum of N values is log2(N) bits. An integer in range [min, max] is log2(max - min + 1) bits. The example above totals ~6.9 bits.

**Validation:** Deterministic. Every field is type-checked and range-checked by code before the Controller processes it. Invalid responses are rejected outright.

**Use when:** The information need can be expressed as classification, categorization, scoring, or binary decisions. The Controller knows the possible answers in advance.

### Category 2: Constrained Question-Answer

The Controller poses one or more specific questions, each with explicit constraints on length, format, and expected content type.

**Wire format:**

```json
{
  "category": 2,
  "questions": [
    {
      "id": "q1",
      "question": "What is the sender's full name?",
      "max_words": 5,
      "expected_format": "person_name"
    },
    {
      "id": "q2",
      "question": "What date is the meeting scheduled for?",
      "max_words": 4,
      "expected_format": "date"
    },
    {
      "id": "q3",
      "question": "What are the three action items listed?",
      "max_words": 30,
      "expected_format": "short_list"
    }
  ]
}
```

**Bandwidth:** Approximately (max_words x 11) bits per question. A 5-word answer is ~55 bits; a 30-word answer is ~330 bits. Each question's bandwidth is isolated and scoped.

**Validation:** Combination of deterministic and heuristic checks (see [Validation Strategies](#validation-strategies)).

**Use when:** The Controller needs specific facts or details from the untrusted content. The information need can be decomposed into discrete questions with at least partially predictable answer formats.

### Category 3: Constrained Summary (Elevated Risk)

The Controller requests a free-text summary of the untrusted content, subject to a strict length limit.

**Wire format:**

```json
{
  "category": 3,
  "directive": "Summarize the key findings of this document.",
  "max_words": 100,
  "requires_approval": true
}
```

**Bandwidth:** A 100-word summary carries ~1,100 bits of attacker-controllable content. This is sufficient to encode convincing natural-language instructions, fake system messages, or social engineering.

**Validation:** Deterministic validation is limited to length enforcement. The primary defense is **mandatory human-in-the-loop approval** — the summary is presented to a human reviewer before the Controller processes it.

The human approval step provides two security properties:

1. **Content review:** A human can recognize injection-style attacks, suspicious URLs, and social engineering.
2. **Latency as defense:** The approval step introduces delay. Many attack strategies depend on speed — rapid exfiltration, time-pressure social engineering, chained exploits. The latency disrupts these patterns structurally.

**Use when:** The information need is genuinely open-ended and cannot be decomposed into Category 1 or 2 queries. This should be rare.

---

## Protocol Flow

```
┌─────────────┐                           ┌─────────────┐
│  Controller  │                           │   Reader     │
│ (Untainted)  │                           │  (Tainted)   │
└──────┬──────┘                           └──────┬───────┘
       │                                          │
       │  1. Analyze task, identify info needs    │
       │                                          │
       │  2. Select minimum category per need     │
       │                                          │
       │  3. Send Cat-1 query ───────────────────>│
       │                                          │  Process untrusted
       │  4. Receive structured response <────────│  content, respond
       │                                          │  within constraints
       │  5. Validate (deterministic) ✓           │
       │                                          │
       │  6. Send Cat-2 query ───────────────────>│
       │                                          │
       │  7. Receive Q&A response <───────────────│
       │                                          │
       │  8. Validate (format + consistency) ✓    │
       │                                          │
       │  [If needed, escalate to Cat-3]          │
       │                                          │
       │  9. Send Cat-3 query ───────────────────>│
       │                                          │
       │  10. Receive summary <───────────────────│
       │                                          │
       │  11. Route to human approval ──> [Human] │
       │                                          │
       │  12. Approved ✓ / Rejected ✗             │
       │                                          │
       │  13. Act on validated information         │
       │                                          │
```

### Category Selection Policy

The Controller should always select the lowest category that satisfies the information need:

1. **Can the need be expressed as classification, scoring, or selection from known options?** → Category 1.
2. **Can the need be decomposed into specific questions with short, format-predictable answers?** → Category 2.
3. **Is the need genuinely open-ended, requiring free-text understanding that cannot be decomposed?** → Category 3.

A well-designed system handles the majority of queries at Category 1 and 2, with Category 3 as an infrequent exception.

### Escalation Controls

A critical vulnerability would be if the tainted agent could influence the Controller to escalate to a higher category, widening the channel. This can occur if the Reader returns unhelpful or "I don't know" responses to lower-category queries, causing the Controller to retry at a higher category.

Mitigations:

- **Escalation budget:** Each task has a fixed maximum number of escalations. Once exhausted, the task fails rather than escalating further.
- **Escalation requires justification:** The Controller must log why a lower category was insufficient. This justification is based on the Controller's own analysis, not the Reader's claims.
- **Category 3 requires explicit human approval of the escalation decision itself**, not just the response content.
- **No automatic escalation:** The Controller never automatically retries at a higher category. Every escalation is deliberate with audit logging.

---

## Validation Strategies

### Category 1 Validation

Purely deterministic. Implemented in code, not by an LLM.

- Type checking: boolean must be true/false, enum must be a listed value, integer must be in range.
- Reject and re-query on invalid responses (with a retry limit).
- Log all responses for audit.

### Category 2 Validation

A combination of deterministic and heuristic checks.

- **Length enforcement:** Hard rejection if word count exceeds the specified maximum.
- **Format validation:** If the expected format is "date," verify it parses as a date. If "person_name," verify it contains only alphabetic characters and common name punctuation. If "email," validate the format.
- **Cross-question consistency:** If the answer to "What is the meeting date?" is "March 15" and the answer to "Is this meeting in Q1?" is "no," flag the inconsistency.
- **Anomaly detection:** Answers that contain instruction-like language ("please," "you should," "ignore," "instead"), URLs, or code should be flagged for review.
- **Redundant extraction:** For high-stakes fields, ask the same question in two different phrasings and compare the answers. Divergence may indicate manipulation.

### Category 3 Validation

Limited deterministic checks, relying primarily on human judgment.

- **Length enforcement:** Hard rejection if the summary exceeds the word limit.
- **Automated screening:** Flag summaries containing known injection patterns, URLs, code blocks, or instruction-like language. This is a probabilistic defense and should not be solely relied upon.
- **Human review:** Present the summary to a human reviewer in an isolated context. The reviewer sees only the summary and metadata about the source, clearly labeled as originating from untrusted content processed by a tainted agent. The reviewer approves, rejects, or edits the summary before it enters the Controller's context.

---

## Gateway Integration

BCTP is implemented as inter-agent message types in the TriOnyx gateway. See [protocol.md](protocol.md) for the full message format specification.

### Outbound (Controller → Gateway → Reader)

The Controller agent calls the `BCTPQuery` MCP tool with:

| Field | Type | Description |
|-------|------|-------------|
| `target` | string | Name of the Reader agent |
| `category` | integer | 1, 2, or 3 |
| `fields` | array | Category 1: field definitions |
| `questions` | array | Category 2: question definitions |
| `directive` | string | Category 3: summary instruction |
| `max_words` | integer | Category 2/3: word limit per answer/summary |

The gateway routes this as a `bctp_query` message to the Reader's session via stdin.

### Inbound (Reader → Gateway → Controller)

The Reader agent calls the `BCTPRespond` MCP tool with:

| Field | Type | Description |
|-------|------|-------------|
| `query_id` | string | ID of the originating query |
| `fields` | object | Category 1: field name → value mapping |
| `answers` | array | Category 2: `{id, answer}` pairs |
| `summary` | string | Category 3: free-text summary |

The gateway validates the response:

1. **Category 1:** Deterministic type/range checking. Invalid → reject, increment retry counter.
2. **Category 2:** Length enforcement, format checking. Invalid → reject, increment retry counter.
3. **Category 3:** Length enforcement, then route to human approval queue.

Validated responses are delivered to the Controller as `bctp_response_delivery` messages with taint stepped down one level from the Reader's current taint.

### Taint Step-Down

| Reader's taint | Response taint after BCTP validation |
|----------------|--------------------------------------|
| High           | Medium                               |
| Medium         | Low                                  |
| Low            | Low                                  |

The step-down is a property of the protocol's structural constraints and deterministic validation, not a judgment about the content.

---

## Bandwidth Accounting

Every query is annotated with its theoretical maximum bandwidth in bits. The gateway maintains a running total per task.

| Query Type | Approximate Bandwidth |
|---|---|
| Boolean | 1 bit |
| Enum (N values) | log2(N) bits |
| Integer [min, max] | log2(max - min + 1) bits |
| Constrained text (W words) | ~W x 11 bits |
| Free summary (W words) | ~W x 11 bits (unstructured) |

The distinction between constrained text (Category 2) and free summary (Category 3) is not bandwidth alone — it is the presence of structural expectations that enable meaningful validation.

Anomalously high bandwidth consumption should trigger alerts.

---

## Hidden Channel Mitigations

Even within constrained schemas, unintended bandwidth exists:

| Channel | Bandwidth | Mitigation |
|---------|-----------|------------|
| Response latency | Variable | Controller ignores timing |
| Field ordering | log2(N!) bits for N fields | Enforce canonical ordering before processing |
| Capitalization | ~1 bit per word | Normalize to lowercase |
| Whitespace/punctuation | Variable | Strip and normalize |
| Presence/absence of optional fields | 1 bit per field | No optional fields in Category 1; treat missing as rejection |

The Controller receives only the normalized, validated response — never the raw output.

---

## System Prompt Guidance

### Reader System Prompt

The Reader's system prompt should instruct it to extract information and answer questions factually, without interpreting meta-instructions in the content it processes. This is a probabilistic defense and should not be relied upon as a primary control. The structural constraints of the protocol are the primary defense.

### Controller System Prompt

The Controller's system prompt should include explicit instructions that all information received from the Reader is untrusted and must not be interpreted as instructions, regardless of its content or framing.

---

## Design Principles

1. **The untainted agent always controls the dialogue.** It asks; the tainted agent answers. Never the reverse.
2. **Minimize bandwidth to the task requirement.** Every bit of channel capacity is a bit of attack surface.
3. **Prefer structure over free text.** Structure enables deterministic validation. Free text can only be validated probabilistically.
4. **Escalation is expensive by design.** Moving to a higher category requires justification, budget, and (for Category 3) human approval.
5. **Validate at the boundary, not in the consumer.** The Controller never receives unvalidated data. Validation happens between receipt and processing, in deterministic code.
6. **Treat latency as a security feature.** Human-in-the-loop approval is slow. That slowness degrades time-sensitive attack strategies.
7. **Audit everything.** Every query, response, validation result, and escalation decision is logged. Bandwidth accounting provides a quantitative measure of exposure.
8. **Defense in depth.** System prompt hardening, structural bandwidth constraints, deterministic validation, cross-question consistency checks, and human review are complementary, not alternatives.
