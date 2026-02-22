# ADR-007: Independent Biba and Bell-LaPadula Violation Detection

- **Status:** Accepted
- **Date:** 2026-02-17
- **Deciders:** Sondre

## Context

TriOnyx tracks two independent information exposure axes: taint (integrity, from the Biba model) and sensitivity (confidentiality, from Bell-LaPadula). [ADR-001](001-information-is-the-threat.md) defines what these axes measure. [ADR-006](006-gateway-credential-secrecy.md) defines how sensitivity is classified. But tracking exposure is only useful if the system can detect when information flows in dangerous directions.

Two distinct threats exist in a multi-agent topology:

1. **Inbound threat (integrity contamination):** A clean, trusted agent reads data produced by a tainted agent. The clean agent is now exposed to potentially adversarial content — prompt injection can propagate through the data.

2. **Outbound threat (data exfiltration):** An agent that has seen sensitive data writes to a location readable by an agent with network access. The sensitive data can now leave the system through the network-capable agent.

These threats are independent. A topology can have integrity violations without confidentiality violations and vice versa. A system that only checks one dimension misses an entire class of attacks.

## Decision

Implement **two independent violation detection systems** that run against the agent topology:

1. **Biba violation detection** (integrity axis): flag any data flow where the source's taint level exceeds the reader's taint level.
2. **Bell-LaPadula violation detection** (confidentiality axis): flag any data flow where the source's sensitivity level exceeds the reader's sensitivity level *and* the reader has network capability.

Both checks run across two data flow channels: filesystem path overlaps and declared inter-agent messaging.

## Rationale

### Biba violations catch prompt injection propagation

A Biba violation occurs when a low-taint agent reads data from a higher-taint source. The detection rule:

```
if level_rank(writer_taint) > level_rank(reader_taint) → violation
```

Example: Agent A ingested a raw webhook payload (high taint) and wrote a summary file. Agent B (low taint, trusted) reads this file. B is now contaminated — the summary may contain prompt injection attempts that influence B's behavior. This is flagged as a Biba violation regardless of the file's content. The violation is a property of the data flow, not the data.

Biba violations are checked on both channels:

- **Filesystem:** The analyzer finds overlapping paths between one agent's `fs_write` patterns and another agent's `fs_read` patterns. If the writer's taint exceeds the reader's taint, it is a violation. Taint per file is looked up from the risk manifest when available, falling back to the agent definition's worst-case taint.
- **Messaging:** If agent A declares `send_to: [B]` and agent B declares `receive_from: [A]`, and A's taint exceeds B's taint, it is a violation.

### Bell-LaPadula violations catch data exfiltration paths

A Bell-LaPadula violation occurs when sensitive data can reach an agent capable of sending it outside the system. The detection rule:

```
if level_rank(writer_sensitivity) > level_rank(reader_sensitivity)
   AND reader has network capability → violation
```

The network capability check is critical. A high-sensitivity agent writing to a location readable by a low-sensitivity agent that has *no* network access is not an exfiltration risk — the data stays inside the system. The violation requires both a sensitivity mismatch *and* an exfiltration-capable reader.

Network capability is determined from the agent definition: agents with tools like WebFetch, WebSearch, or Bash (with outbound network policy) are flagged as network-capable.

Like Biba, BLP violations are checked across both filesystem path overlaps and declared messaging channels.

### Both checks must be independent

The two violation types catch fundamentally different threats:

| | Biba (integrity) | Bell-LaPadula (confidentiality) |
|---|---|---|
| **Guards against** | Inbound threats: malicious data corrupting trusted agents | Outbound threats: sensitive data reaching agents that could exfiltrate it |
| **Direction** | Untrusted → trusted (taint flows down) | Sensitive → exposed (sensitivity flows down to network) |
| **Trigger** | Taint mismatch between writer and reader | Sensitivity mismatch + reader has network access |

An agent topology can have Biba violations without BLP violations (untrusted data flowing to trusted agents that have no sensitive data) and BLP violations without Biba violations (sensitive data flowing to network-capable agents that are all equally trusted). Checking only one dimension leaves the other unguarded.

### Violations are computed statically over the topology

Both checks run against agent definitions and the risk manifest — they do not require runtime interception. The graph analyzer examines:

1. Every agent's declared `fs_write` and `fs_read` patterns to find overlapping paths
2. Every agent's declared `send_to` and `receive_from` to find messaging channels
3. The risk manifest for per-file taint and sensitivity levels

This means violations can be detected *before* agents run, at definition time. The graph visualization (`graph.html`) renders Biba and BLP violations as highlighted edges, and a matrix panel shows which (writer, reader) pairs violate each policy.

### Self-writes are excluded

An agent reading its own output is not a violation — it cannot contaminate itself or exfiltrate to itself. The analyzer skips pairs where writer and reader are the same agent.

## Alternatives Considered

### Single combined "risk level" check

Collapse taint and sensitivity into one dimension and check a single threshold. Loses the ability to distinguish between integrity threats (prompt injection propagation) and confidentiality threats (data exfiltration). A topology that is safe on one axis but dangerous on the other would be either over-flagged or missed entirely.

### Runtime-only violation detection

Check violations only when data actually flows (file read, message delivery) rather than statically analyzing the topology. Catches violations but only after the damage is done — the reader has already ingested the data. Static analysis catches violations at definition time, before any agent runs.

### Content-based violation detection

Scan file contents or message bodies for injections (Biba) or sensitive data patterns (BLP). Probabilistic and brittle. The structural approach — checking taint and sensitivity levels attached to the data, not the data itself — is deterministic and cannot be evaded by encoding tricks.

## Consequences

- **Positive:** Both inbound (integrity) and outbound (confidentiality) threats are detected independently. Neither can mask the other.
- **Positive:** Violations are detected statically at definition time, before agents run. Dangerous topologies are flagged before they can cause harm.
- **Positive:** The violation model is simple and auditable: two comparisons (taint levels, sensitivity levels + network check) across two channels (filesystem, messaging).
- **Negative:** Static analysis over-approximates. Two agents whose `fs_write` and `fs_read` patterns overlap may never actually write/read the same file at runtime. The analyzer flags the *potential* for violation, not confirmed data flow.
- **Negative:** The BLP check requires accurate network capability classification. An agent with indirect network access (e.g., writes to a file that triggers a webhook) may not be flagged as network-capable. Mitigated by conservative tool classification.
- **Accepted trade-off:** Over-approximation (false positives) is preferable to under-approximation (false negatives). A flagged violation that never materializes at runtime costs an operator a review. A missed violation that materializes costs a data breach or integrity compromise.
