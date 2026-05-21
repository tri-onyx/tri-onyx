---
name: findings-review
description: Reviews the latest analyzer and introspector agent reports and implements fixes for actionable findings. Use this skill whenever the user asks to review agent findings, fix agent issues, triage diagnostics, act on analyzer/introspector reports, or mentions "findings", "agent health", "what needs fixing", "review reports", or "agent issues". Also trigger when the user asks about the state of the system, what's broken, or what agents need attention.
---

# Findings Review

Read the latest diagnostic reports from the analyzer and introspector agents, identify actionable findings, and implement fixes directly in the codebase. Findings that require manual operator intervention get presented as a prioritized checklist.

## Why this exists

The analyzer runs daily and produces comprehensive per-agent health reports with severity-tagged findings. The introspector runs every 6 hours and produces infrastructure audit reports. Together they surface dozens of findings — but nobody acts on them unless an operator reads through multi-hundred-line reports and manually applies fixes. This skill closes the loop: it reads both reports, decides what can be fixed in code, fixes it, and presents the rest as a clear action list.

## File locations

- **Analyzer reports**: `workspace/agents/analyzer/reports/YYYY-MM-DD-agent-analysis.md`
- **Introspector reports**: `workspace/agents/introspector/reports/YYYY-MM-DD-log-audit.md`
- **Agent definitions**: `workspace/agent-definitions/<name>.md` (YAML frontmatter + markdown body)
- **Agent NOTES.md**: `workspace/agents/<name>/NOTES.md` (corrections learned at runtime)
- **Main agent template**: `workspace.template/agent-definitions/main.md` (not deployed — lives here, not in `workspace/agent-definitions/`)

## How to run the review

### Step 1: Load the latest reports

Find the most recent analyzer report and most recent introspector report:

```bash
ls -t workspace/agents/analyzer/reports/*.md | head -1
ls -t workspace/agents/introspector/reports/*.md | head -1
```

Read both reports in full. These are the primary inputs.

### Step 2: Extract and classify findings

Parse every finding from both reports. Each finding has a severity (critical, high, medium, low) and belongs to one of two categories:

**Category A — Code-fixable**: Findings that can be resolved by editing files in this repository. These are the ones you will actually fix.

Examples:
- Missing `receive_from` or `send_to` fields in agent definitions → edit the YAML frontmatter
- Cron label mismatches → edit the label in the definition
- Definition not deployed → copy from `workspace.template/` to `workspace/agent-definitions/`
- NOTES.md corrections that should be backpropagated → incorporate the correction into the definition's system prompt or frontmatter
- Missing agents in routing table → update `workspace/AGENTS.md`
- HEARTBEAT bloat → not code-fixable per se, but can note for definition-level mitigations

**Category B — Operator-required**: Findings that require manual human action, external service interaction, or infrastructure commands that shouldn't be run automatically.

Examples:
- Manual re-authentication (LinkedIn reCAPTCHA, OAuth flows)
- External account issues (suspended accounts, expired mailboxes, appeals)
- Docker infrastructure commands (container restarts, image pruning)
- Hardware/resource constraints (memory pressure, disk space)
- Decisions that only the operator can make (deprecate an agent, change cron frequency, create new accounts)

### Step 3: Present the plan before acting

Before making any changes, present a summary to the operator:

```
## Findings Summary

### Will fix (N findings)
1. [severity] Short description → what you'll change and in which file
2. ...

### Needs your action (M findings)
1. [severity] Short description → what the operator needs to do
2. ...

### Informational (K findings)
1. [severity] Short description → context only, no action needed
```

Wait for the operator to confirm or adjust before proceeding. They may want to skip certain fixes or reprioritize.

### Step 4: Implement the code fixes

Work through the confirmed Category A fixes. For each one:

1. **Read the file** you're about to edit (definition, AGENTS.md, etc.)
2. **Make the change** — be precise and minimal. Don't rewrite entire files when a targeted edit suffices.
3. **Explain what changed** in a short line after each fix.

Common fix patterns:

**Adding `receive_from` to a definition:**
```yaml
# In the YAML frontmatter, add the field
receive_from:
  - main
```

**Adding agents to `send_to`:**
```yaml
send_to:
  - email
  - news
  - new_agent_here  # added
```

**Backpropagating a NOTES.md correction:**
Read the NOTES.md, identify the correction, then integrate it into the definition's markdown body (system prompt section) or frontmatter as appropriate. The correction should be expressed as a natural part of the instructions, not as "Note from NOTES.md: ...".

**Deploying an undeployed definition:**
Copy from `workspace.template/agent-definitions/<name>.md` to `workspace/agent-definitions/<name>.md`. Review the template first — it may need updates (missing `send_to` entries, stale references) before deployment.

**Fixing a cron label:**
Edit the `label:` field in the definition's `cron_schedules` to match the actual schedule.

### Step 5: Present operator action items

After completing all code fixes, present the Category B items as a prioritized checklist the operator can work through:

```
## Operator Action Required

### Critical
- [ ] **Twitter @tri_onyx suspended** — File appeal at <URL> or decide to deprecate the agent
- [ ] ...

### High
- [ ] **LinkedIn session expired (70 days)** — Manual reCAPTCHA re-login required
- [ ] ...

### Medium
- [ ] ...

### Infrastructure commands (safe to run)
These are commands the introspector recommends. Run them if appropriate:
- `docker exec trionyx-gateway-1 sh -c "cd /workspace && git reset"` — regenerate corrupted git index
- `docker image prune -f` — clean up 13 dangling images
```

### Step 6: Summary

End with a brief summary: how many findings total, how many fixed, how many remain for the operator, and any trends worth noting (worsening metrics, long-standing unresolved items, etc.).

## Important guidelines

- **Read the actual report** — don't assume findings from previous conversations are still current. Reports change daily.
- **Don't fix what you're not sure about** — if a finding is ambiguous or you're unsure whether the fix is correct, put it in the "Needs your action" category and explain why.
- **Respect the workspace boundary** — `workspace/` is tracked by a separate git repo. Don't `git add` or `git commit` workspace files from the main repo. Just edit them.
- **Don't touch HEARTBEAT.md or memory files** — those are written by agents at runtime. Only edit definition files, AGENTS.md, and NOTES.md (and only NOTES.md to remove entries that have been backpropagated).
- **Cross-reference both reports** — the analyzer and introspector sometimes surface the same underlying issue from different angles (e.g., "email SendMessage broken" in analyzer + "no email sessions in 4 days" in introspector). Don't present these as separate findings — merge them and note both sources.
- **Severity ordering matters** — always present critical findings first, then high, medium, low. Within the same severity, put older/longer-standing issues first since they represent accumulated tech debt.
- **Check before backpropagating** — before incorporating a NOTES.md correction into a definition, read the NOTES.md yourself to verify the correction is still relevant and accurate. Agents sometimes record temporary workarounds that get fixed later.
