---
name: design-review
description: >
  Reviews the TriOnyx frontend UI against Laws of UX principles by screenshotting every page
  and running a multi-agent design audit. Use this skill whenever the user asks for a UX review,
  design review, UI audit, usability check, or mentions "laws of UX", "design critique",
  "UX audit", "review the frontend", "review the UI", "how does the UI look", or wants to
  evaluate the visual design quality of any frontend pages. Also trigger when the user asks
  about accessibility, visual hierarchy, cognitive load, or layout issues in the frontend.
---

# Design Review — Laws of UX Audit

Screenshot every frontend page and review each against 30 Laws of UX principles using a
multi-agent workflow. Produces a consolidated report with per-page scores, top issues,
positive patterns, recurring themes, and a prioritized action plan with code-level fix
recommendations.

## Prerequisites

The frontend must be running on `http://localhost:8080` before starting. If it's not running,
tell the user and ask them to start it (e.g., `docker compose up -d`). Verify with:

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/
```

If the response is not `200`, stop and inform the user.

## Step 1: Discover pages dynamically

Don't hardcode pages. Scrape the running dashboard to find all agent links, then build
the page list:

```bash
# Get all agent URLs from the dashboard
curl -s http://localhost:8080/ | grep -oP '/agents/[^/"]+/' | sort -u
```

Build a page list from the results. Always include these fixed pages:
- **Dashboard**: `http://localhost:8080/` — main dashboard with agent grid
- **Graph**: `http://localhost:8080/graph/` — agent relationship graph
- **Error page**: `http://localhost:8080/agents/nonexistent-agent-xyz/` — 404 error view

Plus one chat view per discovered agent: `http://localhost:8080/agents/<name>/`

To keep the review focused and fast, sample the chat views rather than reviewing all of them.
The chat views share a single template (`chat.html`), so reviewing every one produces near-
identical findings. Pick 2-3 representative agents:
- One that is currently active/running (if any)
- One that is inactive
- One with the most sessions (likely has richer UI state)

If you can't determine status from the dashboard HTML, just pick 3 alphabetically diverse agents.

## Step 2: Create output directory

```bash
mkdir -p ./tmp/ux-review
```

## Step 3: Run the workflow

Use the `Workflow` tool to orchestrate the review. The workflow has three phases:

### Phase 1: Screenshot (parallel)

Screenshot every page in the list. Use the screenshot tool:

```
uv run scripts/browser.py navigate <url> --screenshot ./tmp/ux-review/<page-name>.png -W 1440 -H 900
```

Run all screenshots in parallel via the workflow's `parallel()` helper.

### Phase 2: Review (parallel)

For each screenshot, spawn a review agent that:

1. Reads the screenshot file using the Read tool (it can see images)
2. Evaluates it against all Laws of UX — read `references/laws-of-ux.md` for the full
   reference to include in the reviewer prompt
3. Returns structured findings via the schema below

Each reviewer should produce at least 8 findings (mix of violations and positive patterns).
The findings must be specific — reference actual UI elements, colors, CSS classes, and layout
details visible in the screenshot.

Use this structured output schema for each reviewer:

```json
{
  "type": "object",
  "properties": {
    "page": { "type": "string" },
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "law": { "type": "string", "description": "Name of the UX law" },
          "element": { "type": "string", "description": "Specific UI element affected" },
          "severity": { "type": "string", "enum": ["critical", "major", "minor", "positive"] },
          "observation": { "type": "string", "description": "What you observed" },
          "recommendation": { "type": "string", "description": "How to fix (empty for positive)" }
        },
        "required": ["law", "element", "severity", "observation", "recommendation"]
      }
    },
    "overall_score": { "type": "number", "description": "Overall UX score 1-10" },
    "summary": { "type": "string", "description": "2-3 sentence assessment" }
  },
  "required": ["page", "findings", "overall_score", "summary"]
}
```

### Phase 3: Synthesize

Spawn a single synthesis agent that receives all per-page reviews and produces a
consolidated report. The synthesis prompt should ask for:

1. **TOP 5 most impactful issues** across all pages — with specific file paths, line numbers,
   and code-level fix recommendations (CSS changes, template edits, view modifications)
2. **TOP 5 things done well** — positive patterns to preserve, with key file references
3. **Recurring themes** — cross-cutting issues that appear on multiple pages (one fix
   addresses many pages)
4. **Overall UX maturity assessment** — weighted score and narrative summary
5. **Prioritized action plan** — organized into sprints by impact/effort, with specific
   files to change and estimated effort per fix

The audience is the developer who will implement the fixes, so be concrete and actionable.

## Step 4: Save and present results

Save the synthesis report:

```bash
# Report goes here
./tmp/ux-review/UX_AUDIT_REPORT.md
```

Present a summary to the user with:
- Per-page score table (page name, score, finding counts by severity)
- The top 5 issues (short form)
- The top 5 positives (short form)
- Quick-win list (fixes under 30 minutes)
- Path to the full report

## Workflow script template

Here's the skeleton for the Workflow tool call. Fill in `PAGES` dynamically from Step 1,
and read `references/laws-of-ux.md` to populate the `UX_LAWS` prompt constant:

```javascript
export const meta = {
  name: 'ux-design-review',
  description: 'Screenshot frontend pages and review against Laws of UX',
  phases: [
    { title: 'Screenshot', detail: 'Capture screenshots of all frontend pages' },
    { title: 'Review', detail: 'Review each page against Laws of UX principles' },
    { title: 'Synthesize', detail: 'Consolidate findings into prioritized report' },
  ],
}

const SCREENSHOT_CMD = 'uv run scripts/browser.py navigate'
const OUT_DIR = './tmp/ux-review'

// PAGES: populated dynamically from Step 1
const PAGES = [
  // { name: 'dashboard', url: 'http://localhost:8080/', desc: '...' },
  // ... discovered pages ...
]

const UX_LAWS = `...` // Full reviewer prompt with all 30 laws from references/laws-of-ux.md

const REVIEW_SCHEMA = { /* ... schema from Step 3 ... */ }

// Phase 1: Screenshot
phase('Screenshot')
const screenshots = await parallel(PAGES.map(page => () =>
  agent(`Run: ${SCREENSHOT_CMD} ${page.url} -o ${OUT_DIR}/${page.name}.png -W 1440 -H 900
Confirm the file was created. Return the file path.`,
    { label: `screenshot:${page.name}`, phase: 'Screenshot' })
))

// Phase 2: Review
phase('Review')
const reviews = await parallel(PAGES.map(page => () =>
  agent(`${UX_LAWS}

Review: "${page.desc}"
Screenshot: ${OUT_DIR}/${page.name}.png

Read the screenshot file first, then conduct your review. Provide 8+ findings.`,
    { label: `review:${page.name}`, phase: 'Review', schema: REVIEW_SCHEMA })
))

// Phase 3: Synthesize
phase('Synthesize')
const validReviews = reviews.filter(Boolean)
const reviewSummary = validReviews.map(r =>
  `## ${r.page} (Score: ${r.overall_score}/10)\n${r.summary}\n\nFindings:\n${
    r.findings.map(f => `- [${f.severity.toUpperCase()}] ${f.law}: ${f.observation} -> ${f.recommendation}`).join('\n')
  }`
).join('\n\n---\n\n')

const synthesis = await agent(`Synthesize these page reviews into a consolidated UX audit report.
[include full synthesis prompt from Step 3]

${reviewSummary}`,
  { label: 'synthesize', phase: 'Synthesize' })

return { reviews: validReviews, synthesis }
```

## Important guidelines

- **Read references/laws-of-ux.md** and include the full law descriptions in the reviewer
  prompt — reviewers need the "Look for:" hints to produce specific findings.
- **Don't review all chat views** — they share a template. Sample 2-3 and note that findings
  apply to all chat views via the shared `chat.html` template.
- **Be code-specific in recommendations** — reference actual CSS classes, template files,
  view functions, and line numbers. "Make the button bigger" is not actionable;
  "Change `.btn-send` background from `rgba(88,166,255,0.15)` to `var(--accent)`" is.
- **Screenshots go to ./tmp/ux-review/** — never use /tmp/ or other system directories.
- **The report goes to ./tmp/ux-review/UX_AUDIT_REPORT.md** — overwrite any previous report.
- **Use absolute paths** for the project root in the workflow script since agents run in the
  project directory.
