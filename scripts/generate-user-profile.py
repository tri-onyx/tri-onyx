# /// script
# requires-python = ">=3.11"
# dependencies = ["anthropic>=0.52", "pyyaml>=6"]
# ///
"""Generate workspace/personality/USER.md from agent session logs.

Two-phase pipeline:
  Phase 1: Summarize each session into per-user signals (parallel, cached)
  Phase 2: Aggregate all signals into a cohesive USER.md
"""

import argparse
import asyncio
import json
import os
import sys
import time
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
LOGS_DIR = ROOT / "logs"
CACHE_DIR = ROOT / ".cache" / "user-profile"
OUTPUT_PATH = ROOT / "workspace" / "personality" / "USER.md"
DEFINITIONS_DIR = ROOT / "workspace" / "agent-definitions"

SUMMARIZER_MODEL = "claude-haiku-4-5-20251001"
AGGREGATOR_MODEL = "claude-sonnet-4-6"
MAX_CONCURRENT = 20

EXTRACTION_PROMPT = """\
You are extracting user personalization signals from a conversation log.
Focus on what this reveals about the USER (not the assistant). Extract:
- Personal details (name, location, job, relationships)
- Interests and topics they care about
- Communication style and preferences
- Current projects or focus areas
- Opinions, values, pet peeves
- Technical skills and tools they use

Return a JSON object with: {"signals": ["signal 1", "signal 2", ...]}
Only include signals that are clearly evidenced. Return {"signals": []} if
the conversation reveals nothing about the user."""

AGGREGATION_PROMPT = """\
You are synthesizing a user profile from personalization signals extracted \
across many conversation sessions. Produce a Markdown document that gives AI \
agents deep context about this user.

Structure the profile as follows:

# User

## Work Context
What they do professionally, their technical stack, current projects, and \
how they prefer to work.

## Personal Context
Name, interests, personality traits, values, relationships, and anything \
that helps agents understand who they are as a person.

## Top of Mind
What they're currently focused on or excited about — topics that come up \
repeatedly in recent sessions.

## Brief History

### Recent Months
Key projects, milestones, and shifts in focus from the last few months.

### Earlier Context
Older background that still informs current work or preferences.

### Long-term Background
Enduring interests, career arc, and foundational preferences.

Guidelines:
- Write in third person ("Sondre prefers..." not "You prefer...")
- Be specific and concrete — cite actual projects, tools, and opinions
- Deduplicate and consolidate overlapping signals
- Omit signals that are too vague or trivial
- Keep the total length under 800 words
- Do NOT include any preamble or explanation — output only the Markdown profile"""


def get_client():
    """Create Anthropic async client, preferring OAuth token."""
    import anthropic

    token = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN")
    api_key = os.environ.get("ANTHROPIC_API_KEY")

    if token:
        return anthropic.AsyncAnthropic(api_key=token)
    elif api_key:
        return anthropic.AsyncAnthropic()
    else:
        sys.exit("Set CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY")


def load_excluded_agents() -> set[str]:
    """Read agent definitions and return names with exclude_from_personalization: true."""
    excluded = set()
    if not DEFINITIONS_DIR.is_dir():
        return excluded
    for path in DEFINITIONS_DIR.glob("*.md"):
        text = path.read_text()
        match = __import__("re").match(r"\A---\s*\n(.*?)\n---", text, __import__("re").DOTALL)
        if not match:
            continue
        try:
            frontmatter = yaml.safe_load(match.group(1))
        except yaml.YAMLError:
            continue
        if isinstance(frontmatter, dict) and frontmatter.get("exclude_from_personalization"):
            name = frontmatter.get("name", path.stem)
            excluded.add(name)
    return excluded


def extract_conversation(log_path: Path) -> str | None:
    """Extract user_prompt and text events from a JSONL log, return as conversation text."""
    lines = []
    for raw_line in log_path.read_text().splitlines():
        if not raw_line.strip():
            continue
        try:
            event = json.loads(raw_line)
        except json.JSONDecodeError:
            continue
        etype = event.get("type")
        content = event.get("content", "")
        if etype == "user_prompt" and content:
            lines.append(f"USER: {content}")
        elif etype == "text" and content:
            lines.append(f"ASSISTANT: {content}")
    return "\n".join(lines) if lines else None


def discover_sessions(excluded: set[str]) -> list[tuple[str, str, Path]]:
    """Return (agent, session_id, log_path) for all unprocessed sessions."""
    sessions = []
    if not LOGS_DIR.is_dir():
        return sessions
    for agent_dir in sorted(LOGS_DIR.iterdir()):
        if not agent_dir.is_dir():
            continue
        agent_name = agent_dir.name
        if agent_name in excluded:
            continue
        for log_file in sorted(agent_dir.glob("*.jsonl")):
            session_id = log_file.stem
            sessions.append((agent_name, session_id, log_file))
    return sessions


def needs_processing(agent: str, session_id: str, force: bool) -> bool:
    """Check whether a session needs to be summarized."""
    if force:
        return True
    cache_path = CACHE_DIR / agent / f"{session_id}.json"
    return not cache_path.exists()


class Progress:
    """Thread-safe progress counter with terminal output."""

    def __init__(self, total: int):
        self.total = total
        self.done = 0
        self.signals_found = 0
        self.skipped = 0
        self._lock = asyncio.Lock()

    async def tick(self, agent: str, session_id: str, signal_count: int, skipped: bool = False):
        async with self._lock:
            self.done += 1
            if skipped:
                self.skipped += 1
            self.signals_found += signal_count
            pct = (self.done * 100) // self.total
            print(
                f"\r  [{pct:3d}%] {self.done}/{self.total}  "
                f"signals: {self.signals_found}  skipped: {self.skipped}  "
                f"last: {agent}/{session_id}    ",
                end="",
                flush=True,
            )


async def summarize_session(
    client, semaphore: asyncio.Semaphore, agent: str, session_id: str, log_path: Path,
    progress: Progress,
) -> dict | None:
    """Summarize a single session and write cache."""
    conversation = extract_conversation(log_path)
    cache_path = CACHE_DIR / agent / f"{session_id}.json"
    cache_path.parent.mkdir(parents=True, exist_ok=True)

    # No user prompts → empty cache
    has_user_prompt = any(
        line.startswith("USER: ") for line in (conversation or "").split("\n")
    )
    if not conversation or not has_user_prompt:
        cache_path.write_text(json.dumps({"signals": [], "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}))
        await progress.tick(agent, session_id, 0, skipped=True)
        return None

    # Truncate very long conversations to avoid token limits
    if len(conversation) > 50_000:
        conversation = conversation[:50_000] + "\n[... truncated]"

    async with semaphore:
        response = await client.messages.create(
            model=SUMMARIZER_MODEL,
            max_tokens=1024,
            messages=[
                {"role": "user", "content": f"{EXTRACTION_PROMPT}\n\n<conversation>\n{conversation}\n</conversation>"}
            ],
        )

    text = response.content[0].text.strip()

    # Parse the JSON response
    try:
        # Handle cases where model wraps in markdown code block
        if text.startswith("```"):
            text = text.split("\n", 1)[1].rsplit("```", 1)[0].strip()
        result = json.loads(text)
    except json.JSONDecodeError:
        result = {"signals": [], "parse_error": True}

    result["timestamp"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    cache_path.write_text(json.dumps(result, indent=2))

    signal_count = len(result.get("signals", []))
    await progress.tick(agent, session_id, signal_count)
    return result if result.get("signals") else None


async def phase1(client, sessions: list[tuple[str, str, Path]], force: bool) -> int:
    """Phase 1: summarize all sessions in parallel. Returns count processed."""
    to_process = [
        (agent, sid, path)
        for agent, sid, path in sessions
        if needs_processing(agent, sid, force)
    ]

    if not to_process:
        print("Phase 1: all sessions cached, nothing to process.")
        return 0

    print(f"Phase 1: summarizing {len(to_process)} sessions...")
    t0 = time.monotonic()
    semaphore = asyncio.Semaphore(MAX_CONCURRENT)
    progress = Progress(len(to_process))
    tasks = [
        summarize_session(client, semaphore, agent, sid, path, progress)
        for agent, sid, path in to_process
    ]
    results = await asyncio.gather(*tasks, return_exceptions=True)
    print()  # newline after progress line
    elapsed = time.monotonic() - t0

    errors = sum(1 for r in results if isinstance(r, Exception))
    if errors:
        print(f"  Warning: {errors} sessions failed to process")
        for r in results:
            if isinstance(r, Exception):
                print(f"    {r}")

    processed = len(to_process) - errors
    print(f"  Done: {processed} sessions summarized in {elapsed:.1f}s")
    return processed


def collect_all_signals() -> list[str]:
    """Read all cache files and collect signals into a flat list."""
    signals = []
    if not CACHE_DIR.is_dir():
        return signals
    for cache_file in sorted(CACHE_DIR.rglob("*.json")):
        try:
            data = json.loads(cache_file.read_text())
        except (json.JSONDecodeError, OSError):
            continue
        for signal in data.get("signals", []):
            if signal and isinstance(signal, str):
                signals.append(signal)
    return signals


async def phase2(client, signals: list[str]) -> str:
    """Phase 2: aggregate signals into USER.md content."""
    if not signals:
        print("Phase 2: no signals found, skipping aggregation.")
        return ""

    print(f"Phase 2: aggregating {len(signals)} signals...", flush=True)
    t0 = time.monotonic()
    signal_text = "\n".join(f"- {s}" for s in signals)

    response = await client.messages.create(
        model=AGGREGATOR_MODEL,
        max_tokens=2048,
        messages=[
            {
                "role": "user",
                "content": f"{AGGREGATION_PROMPT}\n\nHere are all extracted signals:\n\n{signal_text}",
            }
        ],
    )

    elapsed = time.monotonic() - t0
    print(f"  Done in {elapsed:.1f}s")
    return response.content[0].text.strip()


async def main():
    parser = argparse.ArgumentParser(description="Generate user profile from agent session logs")
    parser.add_argument("--force", action="store_true", help="Regenerate all caches")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be processed")
    args = parser.parse_args()

    excluded = load_excluded_agents()
    if excluded:
        print(f"Excluding agents: {', '.join(sorted(excluded))}")

    sessions = discover_sessions(excluded)
    print(f"Found {len(sessions)} total sessions across {len(set(a for a, _, _ in sessions))} agents")

    if args.dry_run:
        to_process = [
            (agent, sid, path)
            for agent, sid, path in sessions
            if needs_processing(agent, sid, args.force)
        ]
        print(f"\nWould process {len(to_process)} sessions:")
        for agent, sid, path in to_process:
            print(f"  {agent}/{sid}")

        cached = len(sessions) - len(to_process)
        if cached:
            print(f"\nAlready cached: {cached} sessions")

        existing_signals = collect_all_signals()
        if existing_signals:
            print(f"\nExisting cached signals: {len(existing_signals)}")
        return

    client = get_client()

    await phase1(client, sessions, args.force)

    signals = collect_all_signals()
    profile = await phase2(client, signals)

    if profile:
        OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT_PATH.write_text(profile + "\n")
        print(f"\nProfile written to {OUTPUT_PATH}")
    else:
        print("\nNo profile generated (no signals).")


if __name__ == "__main__":
    asyncio.run(main())
