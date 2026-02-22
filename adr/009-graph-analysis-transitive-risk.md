# ADR-009: Graph Analysis for Transitive Risk Propagation

- **Status:** Accepted
- **Date:** 2026-02-17
- **Deciders:** Sondre

## Context

TriOnyx's security model tracks taint and sensitivity per agent session. Violation detection ([ADR-007](007-biba-blp-violation-detection.md)) checks direct data flows between pairs of agents. But risk does not stop at one hop.

Consider: Agent A (high taint, ingests web data) writes a file. Agent B (medium taint) reads it, processes it, and writes output. Agent C (low taint, trusted, has shell access) reads B's output. The direct check between B and C might show a medium-to-low taint flow — concerning but perhaps within policy. The transitive reality is that C is consuming data that originated from A's high-taint web scraping, laundered through B. The effective risk to C is high, not medium.

Without transitive analysis, multi-hop information laundering bypasses pairwise violation checks. An attacker who cannot reach a high-capability agent directly can chain through intermediaries to get there. The system must trace risk through the full agent topology, not just adjacent pairs.

## Decision

Implement a **graph analyzer** that builds a directed graph of all information flows between agents (filesystem, messaging, and BCTP channels), computes transitive risk propagation via depth-first traversal, and identifies the **maximum input risk** each agent faces from all upstream sources on each axis independently.

## Rationale

### The agent topology is a directed graph

Every information flow between agents creates a directed edge:

1. **Filesystem edges:** Agent A's `fs_write` patterns overlap with Agent B's `fs_read` patterns → edge A → B
2. **Messaging edges:** Agent A declares `send_to: [B]` and Agent B declares `receive_from: [A]` → edge A → B
3. **BCTP edges:** Agent A (controller) queries Agent B (reader) via BCTP → edge B → A (data flows from reader to controller), with taint stepped down one level

Each edge carries the risk level of the data in transit — the writer's taint and sensitivity at the time of writing (from the risk manifest) or worst-case levels from the agent definition.

### Transitive propagation catches multi-hop laundering

The analyzer performs depth-first traversal from each agent, accumulating risk along paths. At each hop, the accumulated risk is merged with the edge risk via `max()` — risk can only increase along a path, never decrease (except through BCTP, which explicitly steps taint down one level).

For the A → B → C example:

- Edge A → B: taint = high (A's taint)
- Edge B → C: taint = high (B inherited A's taint via the file read)
- C's max input taint: high

Without transitive analysis, the system might only see B → C and compute C's input taint as medium (B's definition-level taint). The transitive view reveals the actual risk.

### Worst-case taint is computed from input sources, not tools

An agent's worst-case taint is determined by what data it *could* ingest, not what tools it has:

| Input source | Worst-case taint |
|---|---|
| Network access (WebFetch, WebSearch) | High — raw internet data |
| Free-text messages from peers (`receive_from`) | Medium — peer output, possibly tainted |
| BCTP responses | `step_down(peer_taint)` — bandwidth-constrained |
| No external input | Low — only sees trusted data |

Capability (whether the agent can write files or execute shell commands) does **not** affect taint. An agent with Bash access but no external input sources has low taint. An agent with only Read access but WebFetch input has high taint. This is the core principle from [ADR-001](001-information-is-the-threat.md): information is the threat, not capability.

### Worst-case sensitivity is computed from tool metadata

An agent's worst-case sensitivity is determined by the tools it can call and whether those tools require authentication ([ADR-006](006-gateway-credential-secrecy.md)):

| Tool classification | Worst-case sensitivity |
|---|---|
| No tools require auth | Low |
| Some tools require auth | Medium |
| Tools require auth + declare sensitive data | High |

### Cycle detection prevents infinite traversal

Agent topologies can contain cycles (A → B → A, through mutual messaging or shared files). The traversal maintains a visited set and terminates when it encounters an already-visited node. Since risk is monotonically accumulated via `max()`, revisiting a node in a cycle cannot produce a higher risk than was already computed.

### Risk chain tracing supports incident investigation

Beyond computing maximum risk, the analyzer can trace the specific chain of agents that contributes the highest risk to a given target. For agent C, the trace might return `[A, B]` — showing that A is the ultimate source of C's risk, flowing through B. This supports incident investigation: "why was agent C terminated?" → "because it was transitively exposed to high-taint data originating from agent A's web scraping session."

### Static analysis runs at definition time

The graph analysis runs against agent definitions and the risk manifest before agents are started. This means dangerous topologies — where a high-taint source can transitively reach a low-taint agent — are flagged at configuration time. Operators can redesign the topology before any agent processes untrusted data.

### Visualization makes risk visible

The graph analysis powers a visualization (`graph.html`) that renders:

- **Nodes** as split circles: left half colored by taint, right half by sensitivity
- **Node size** proportional to effective risk (low/moderate/high/critical)
- **Edges** as directed arrows colored by type (filesystem, messaging, BCTP)
- **Violation overlays** that highlight Biba violations (taint axis) or BLP violations (sensitivity axis) as toggleable layers
- **A matrix panel** showing all (writer, reader) pairs and which violate each policy

The visualization makes transitive risk chains immediately visible — an operator can see that a high-taint source three hops away influences a high-capability agent without reading log files.

## Alternatives Considered

### Pairwise-only violation detection

Check only direct (A, B) pairs for violation. Simpler but misses multi-hop laundering. An attacker who cannot directly communicate with the target agent can chain through intermediaries. The number of hops is irrelevant — what matters is whether adversarial data reaches the target.

### Runtime-only propagation tracking

Track actual data flows at runtime rather than analyzing the topology statically. More precise (only flags flows that actually happen) but reactive — violations are detected after the data has already flowed. Static analysis is proactive: it flags potential violations before agents run.

### Fixed-depth traversal (e.g., 2-hop limit)

Analyze transitive risk up to N hops to limit computational cost. Arbitrary and insecure: an attacker who knows the depth limit can add intermediate agents to exceed it. The correct approach is unbounded traversal with cycle detection, which terminates naturally on finite graphs.

### Probabilistic risk decay over hops

Reduce risk by some factor at each hop (e.g., high → medium after 2 hops). Tempting but unsound. A prompt injection embedded by agent A and faithfully reproduced by agents B and C is just as dangerous when it reaches agent D. Information does not lose its adversarial potential through reproduction. The only mechanism that legitimately reduces taint in transit is BCTP's bandwidth-constrained validation ([ADR-005](005-bandwidth-constrained-trust.md)).

## Consequences

- **Positive:** Multi-hop information laundering is detected. Transitive risk chains are visible to operators before agents run.
- **Positive:** The analysis cleanly separates taint (input sources) from capability (tools), computing worst-case on each axis independently.
- **Positive:** Risk chain tracing provides actionable incident investigation paths: which upstream agent is the root cause of a downstream agent's risk.
- **Positive:** The visualization makes complex topologies legible to operators who are not reading code or logs.
- **Negative:** Static analysis over-approximates. A path A → B → C in the graph does not guarantee that data actually flows A → B → C at runtime. Agents may write different files than their patterns allow, or messaging channels may go unused. The analysis flags potential, not confirmed flow.
- **Negative:** Worst-case taint computation assumes agents will use their highest-taint input sources. An agent with WebFetch that never calls it still gets high worst-case taint. Mitigated by the risk manifest recording actual session-level taint once agents run.
- **Accepted trade-off:** The graph analysis adds a pre-flight computation step before agents can be started. For large topologies (many agents, many path overlaps), this may add noticeable latency. Acceptable because agent startup is dominated by container creation and LLM initialization, and because catching a risky topology before it runs is worth the computation.
