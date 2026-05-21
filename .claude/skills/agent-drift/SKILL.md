---
name: agent-drift
description: Detects when TriOnyx agents have learned runtime workarounds that should be backpropagated into their definitions. Use this skill whenever the user asks about agent drift, definition consistency, agent workarounds, or wants to audit whether agent memory/HEARTBEAT files contain coping mechanisms that indicate broken or incomplete instructions. Also trigger when the user mentions "backpropagate", "sync definitions", or asks why an agent is behaving differently from its definition.
---

# Agent Drift Detector

Scan each agent's runtime memory (HEARTBEAT.md + memory/*.md files) for learned workarounds that indicate the agent definition is wrong, incomplete, or out of date. The goal is to surface places where agents have been forced to cope with bad instructions so the operator can fix the root cause in the definition file.

## Why this matters

When an agent hits a problem at runtime — a tool that gets rejected, a messaging path that's blocked, a filesystem path that doesn't exist — it learns to work around it. The agent records the workaround in HEARTBEAT.md or daily memory files: "do NOT attempt SendMessage", "use conversational output instead", "path doesn't exist, skip it". These are symptoms of a definition that doesn't match reality. If nobody backpropagates the fix into the definition, the agent accumulates coping mechanisms that mask the real issue.

## File locations

- **Agent definitions**: `workspace/agent-definitions/<name>.md` — YAML frontmatter (tools, fs_read, fs_write, send_to, receive_from, network, plugins, etc.) + markdown body (system prompt)
- **Agent runtime state**: `workspace/agents/<name>/HEARTBEAT.md` — running state, updated at shutdown
- **Agent memory**: `workspace/agents/<name>/memory/*.md` — daily memory files and topic notes
- **Shared context**: `workspace/AGENTS.md` — routing rules and inter-agent metadata

## How to run the audit

### Step 1: Inventory agents

List all `.md` files in `workspace/agent-definitions/`. Each file defines one agent. Extract the agent name from the YAML frontmatter `name:` field.

### Step 2: For each agent, gather files

Read these files (skip if they don't exist):
1. The definition file: `workspace/agent-definitions/<name>.md`
2. The HEARTBEAT: `workspace/agents/<name>/HEARTBEAT.md`
3. All memory files: `workspace/agents/<name>/memory/*.md`
4. Any other `.md` files directly in the agent's workspace dir (e.g., PREFERENCES.md, TODO.md)

### Step 3: Parse the definition

From the YAML frontmatter, extract these fields into a structured summary:
- `tools` — list of allowed tools
- `network` — network policy (none, outbound, or host list)
- `fs_read` / `fs_write` — filesystem access globs
- `send_to` / `receive_from` — messaging peers
- `plugins` — declared plugins
- `bcp_channels` — BCP query peers and roles

From the markdown body, note any specific claims about what the agent can/cannot do, paths it references, tools it describes, or agents it says it can communicate with.

### Step 4: Scan memory for drift signals

Read every HEARTBEAT and memory file. Look for these categories of drift:

**Category 1: Explicit workarounds**
Phrases that indicate the agent learned something doesn't work:
- "do NOT attempt", "do not use", "don't try", "avoid"
- "returns error", "returns :error", "not allowed", ":receive_not_allowed", ":send_not_allowed"
- "blocked", "rejected", "denied", "failed", "timed out"
- "doesn't work", "does not work", "won't work", "broken"
- "instead use", "workaround", "alternative", "use X instead of Y"
- "skip", "ignore", "bypass"

**Category 2: Behavioral overrides**
Notes that contradict or override what the definition says:
- "Reply via conversational output instead" (contradicts SendMessage being listed)
- "Cannot reach agent X" (contradicts send_to listing)
- "Path does not exist" (contradicts fs_read/fs_write)
- "Tool X not available" or "tool X rejected"

**Category 3: Pending/unresolved issues**
Items in "Pending" or "Next Session Notes" sections that describe systemic issues rather than task-specific follow-ups. These often indicate the agent has been living with a problem for multiple sessions.

**Category 4: Messaging topology mismatches**
Cross-reference send_to/receive_from across ALL agent definitions. If agent A lists agent B in send_to, but agent B does NOT list agent A in receive_from, that's a topology mismatch — messages will be rejected at runtime.

**Exception**: The main agent intentionally omits `receive_from` to avoid receiving taint from other agents. This is by design — main commands other agents via SendMessage (one-way) and uses BCP queries for taint-neutral responses. Do NOT flag main's missing `receive_from` as drift. DO flag the downstream consequence: if another agent (e.g., email) has SendMessage in its tools and main in send_to, that agent's definition is wrong — it should not have those fields since main won't accept the messages.

### Step 5: Cross-reference findings with definition

For each drift signal found, check whether the definition is actually wrong:

1. **Tool listed but doesn't work** — Is the tool in the frontmatter `tools:` list? If yes, why is it failing? (missing peer in topology, missing network access, etc.)
2. **Messaging peer unreachable** — Is the peer in `send_to:`? Does the peer have the agent in `receive_from:`? Check BOTH sides.
3. **Path referenced but inaccessible** — Is the path covered by `fs_read:` or `fs_write:` globs? Remember every agent implicitly gets write access to `/agents/<name>/**`.
4. **System prompt claims don't match frontmatter** — Does the markdown body describe capabilities that the YAML doesn't grant?

### Step 6: Generate the report

Output a report with this structure:

```
# Agent Drift Report

## Summary
- X agents scanned
- Y drift findings across Z agents
- N agents clean

## Findings

### <agent-name>

**Finding 1: <short description>**
- Source: <file where the workaround was found>
- Workaround: <what the agent learned to do>
- Root cause: <what's wrong in the definition>
- Suggested fix: <specific change to the definition YAML or body>

**Finding 2: ...**

### <next agent>
...

## Topology Mismatches

| Agent A | send_to | Agent B | receive_from | Status |
|---------|---------|---------|--------------|--------|
| email   | main    | main    | (missing)    | BROKEN |

## Clean Agents
- <agents with no findings>
```

### Important guidelines

- Be specific in suggested fixes. Don't say "fix the definition" — say "add `email` to main.md's `receive_from:` list" or "remove `SendMessage` from email.md's `tools:` field".
- Distinguish between **definition bugs** (the YAML is wrong) and **system prompt drift** (the markdown body describes something that doesn't match the YAML). Both need fixing but they're different problems.
- Don't flag task-specific memory entries as drift. "Need to follow up with Sondre about UID 23" is not drift — it's a pending task. "SendMessage to main returns :receive_not_allowed — do NOT attempt" IS drift — it's a systemic workaround.
- When scanning memory files, focus on the most recent ones first. Old workarounds may have already been fixed.
- Always do the full topology cross-reference (Step 4, Category 4) even if no memory files mention messaging issues — silent mismatches are the most insidious kind of drift.
