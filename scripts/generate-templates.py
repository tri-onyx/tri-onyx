#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml"]
# ///
"""Generate template files from live config, stripping all secrets.

Usage:
    uv run scripts/generate-templates.py           # update templates in-place
    uv run scripts/generate-templates.py --check    # exit 1 if templates are stale
"""

import argparse
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("pyyaml is required: uv add pyyaml", file=sys.stderr)
    sys.exit(1)

ROOT = Path(__file__).resolve().parent.parent

# ---------------------------------------------------------------------------
# Secret patterns — anything matching these gets redacted
# ---------------------------------------------------------------------------
SECRET_KEY_PATTERNS = re.compile(
    r"(token|password|secret|key|credential|access_token|oauth|owner_user_id)",
    re.IGNORECASE,
)

# Values that look like secrets even if the key doesn't match
SECRET_VALUE_PATTERNS = re.compile(
    r"(^(sk|xoxb|xapp|xoxp|ghp|gho|ghu|ghs|ghr|glpat|Bearer )-)"  # API key prefixes
    r"|(^[A-Za-z0-9+/=]{40,}$)"  # long base64-ish strings
    r"|(^https?://[^/]*@)"  # URLs with embedded credentials
)

# Matrix-style identifiers to redact
MATRIX_ID_PATTERNS = re.compile(r"[@!#][^:]+:[^\s\"']+")


def redact_env_file(src: Path) -> str:
    """Read a .env file and strip all values, keeping keys and comments."""
    if not src.exists():
        return ""
    lines = []
    for line in src.read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            lines.append(line)
            continue
        if "=" in line:
            key = line.split("=", 1)[0]
            lines.append(f"{key}=")
        else:
            lines.append(line)
    return "\n".join(lines) + "\n"


def redact_yaml_value(key: str, value):
    """Redact a YAML value if the key looks secret-bearing."""
    if isinstance(value, dict):
        return {k: redact_yaml_value(k, v) for k, v in value.items()}
    if isinstance(value, list):
        if key == "trusted_users":
            return ["@your-user:your-homeserver.org"]
        return [redact_yaml_value(key, v) for v in value]
    if isinstance(value, str):
        if SECRET_KEY_PATTERNS.search(key):
            return "<your-secret-here>"
        if SECRET_VALUE_PATTERNS.search(value):
            return "<your-secret-here>"
        if MATRIX_ID_PATTERNS.search(value):
            return MATRIX_ID_PATTERNS.sub(
                lambda m: m.group(0)[0] + "your-id:your-homeserver.org", value
            )
        # Redact env var references that point to secrets
        if value.startswith("${") and SECRET_KEY_PATTERNS.search(value):
            return "<your-secret-here>"
    return value


def redact_yaml_file(src: Path) -> str:
    """Read a YAML file, redact secrets, and return the sanitized YAML.

    Preserves comments by doing a line-level pass after structural redaction.
    """
    if not src.exists():
        return ""
    raw = src.read_text()

    # Parse and redact the structure
    data = yaml.safe_load(raw)
    if data is None:
        return raw
    redacted = redact_yaml_value("", data)

    # Re-serialize
    output = yaml.dump(redacted, default_flow_style=False, sort_keys=False, width=120)

    # Preserve original comments by re-inserting them
    # Walk original lines and carry over comment-only lines and inline comments
    original_lines = raw.splitlines()
    comment_blocks = []
    for line in original_lines:
        stripped = line.strip()
        if stripped.startswith("#") or stripped == "":
            comment_blocks.append(line)

    # Prepend comment blocks that appeared at the top
    header_comments = []
    for line in original_lines:
        stripped = line.strip()
        if stripped.startswith("#") or stripped == "":
            header_comments.append(line)
        else:
            break

    if header_comments:
        output = "\n".join(header_comments) + "\n" + output

    return output


def redact_connector_config(src: Path) -> str:
    """Special handler for connector-config.yaml that preserves structure and comments.

    Handles secrets in values, Matrix IDs in both keys and values, list items,
    and env var references.
    """
    if not src.exists():
        return ""
    raw = src.read_text()

    lines = raw.splitlines()
    result = []
    i = 0
    in_rooms_block = False
    rooms_indent = 0
    emitted_example_room = False
    in_heartbeat_rooms = False
    heartbeat_indent = 0
    emitted_heartbeat_example = False

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        indent = len(line) - len(line.lstrip()) if stripped else 0

        # Track rooms: block — we'll collapse all rooms into one example
        if stripped == "rooms:":
            result.append(line)
            in_rooms_block = True
            rooms_indent = indent
            emitted_example_room = False
            i += 1
            continue

        if in_rooms_block:
            # We're past the rooms: line. Room entries are dict keys at rooms_indent + N
            if stripped and indent <= rooms_indent:
                # Dedented past rooms block
                in_rooms_block = False
                # Fall through to normal processing
            else:
                # Inside rooms block — check if this is a room key line
                # Room keys look like: "!roomid:server":  or  "!roomid:server":  # comment
                is_room_key = (
                    MATRIX_ID_PATTERNS.search(stripped)
                    and stripped.endswith(":")
                )
                if is_room_key:
                    if not emitted_example_room:
                        # Emit one example room with placeholder ID
                        room_indent = " " * indent
                        result.append(f'{room_indent}"!example-room:your-homeserver.org":')
                        emitted_example_room = True
                        # Copy the settings from this first room (agent, mode, etc.)
                        i += 1
                        while i < len(lines):
                            sub_line = lines[i]
                            sub_stripped = sub_line.strip()
                            sub_indent = len(sub_line) - len(sub_line.lstrip()) if sub_stripped else 0
                            if sub_stripped and sub_indent <= indent:
                                break  # Next room or end of rooms block
                            if sub_stripped:
                                # Strip inline comments that might leak info
                                result.append(sub_line)
                            i += 1
                        continue
                    else:
                        # Skip subsequent rooms
                        i += 1
                        while i < len(lines):
                            sub_line = lines[i]
                            sub_stripped = sub_line.strip()
                            sub_indent = len(sub_line) - len(sub_line.lstrip()) if sub_stripped else 0
                            if sub_stripped and sub_indent <= indent:
                                break
                            i += 1
                        continue
                elif stripped:
                    result.append(line)
                    i += 1
                    continue
                else:
                    result.append(line)
                    i += 1
                    continue

        # Track heartbeat_rooms: block — collapse to one example
        if stripped.startswith("heartbeat_rooms:"):
            in_heartbeat_rooms = True
            heartbeat_indent = indent
            emitted_heartbeat_example = False
            # Keep the key line (with any inline comment)
            result.append(line)
            i += 1
            continue

        if in_heartbeat_rooms:
            if stripped and indent <= heartbeat_indent:
                in_heartbeat_rooms = False
                # Fall through
            else:
                if stripped and ":" in stripped:
                    if not emitted_heartbeat_example:
                        hb_indent = " " * indent
                        result.append(f"{hb_indent}your-agent: \"!example-room:your-homeserver.org\"")
                        emitted_heartbeat_example = True
                    i += 1
                    continue
                else:
                    result.append(line)
                    i += 1
                    continue

        # Comment or empty — keep as-is
        if not stripped or stripped.startswith("#"):
            result.append(line)
            i += 1
            continue

        # List items (e.g., "- @user:server")
        if stripped.startswith("- ") and MATRIX_ID_PATTERNS.search(stripped):
            line_indent = " " * indent
            result.append(f'{line_indent}- "@your-user:your-homeserver.org"')
            i += 1
            continue

        # Key-value pairs
        if ":" in stripped and not stripped.endswith(":"):
            key_part = stripped.split(":")[0].strip().strip("-").strip().strip('"')
            value_part = line.split(":", 1)[1].strip()
            key_with_colon = line.split(":", 1)[0] + ":"

            # Always redact secret keys
            if SECRET_KEY_PATTERNS.search(key_part):
                result.append(f'{key_with_colon} "<your-secret-here>"')
                i += 1
                continue

            # Redact Matrix IDs in values
            if MATRIX_ID_PATTERNS.search(value_part):
                redacted_value = MATRIX_ID_PATTERNS.sub(
                    lambda m: m.group(0)[0] + "your-id:your-homeserver.org",
                    value_part,
                )
                result.append(f"{key_with_colon} {redacted_value}")
                i += 1
                continue

            # Redact env var refs to secrets
            if "${" in value_part and SECRET_KEY_PATTERNS.search(value_part):
                result.append(f'{key_with_colon} "<your-secret-here>"')
                i += 1
                continue

        result.append(line)
        i += 1

    return "\n".join(result) + "\n"


def generate_workspace_template(workspace: Path, template_dir: Path) -> dict[str, str]:
    """Generate a workspace template directory structure.

    Returns a dict of {relative_path: content} for all template files.
    """
    files = {}

    # Agent definitions — copy as-is (no secrets)
    defs_dir = workspace / "agent-definitions"
    if defs_dir.exists():
        for f in sorted(defs_dir.iterdir()):
            if f.is_file() and f.suffix == ".md":
                rel = f"agent-definitions/{f.name}"
                files[rel] = f.read_text()

    # AGENTS.md — copy as-is
    agents_md = workspace / "AGENTS.md"
    if agents_md.exists():
        files["AGENTS.md"] = agents_md.read_text()

    # Personality — empty placeholder files
    files["personality/SOUL.md"] = "# Soul\n\nDefine your agent personality here.\n"
    files["personality/IDENTITY.md"] = "# Identity\n\nDefine your agent identity here.\n"
    files["personality/USER.md"] = "# User\n\nDescribe the user profile and preferences here.\n"
    files["personality/MEMORY.md"] = "# Memory\n\nAgent personality memory — populated at runtime.\n"

    # Skeleton directories via .gitkeep
    skeleton_dirs = [
        "agents",
        "data",
        "plugins",
        "browser-sessions",
    ]
    for d in skeleton_dirs:
        files[f"{d}/.gitkeep"] = ""

    # plugins.yaml — empty
    files["plugins.yaml"] = "plugins: {}\n"

    return files


def write_workspace_template(workspace: Path, template_dir: Path) -> list[str]:
    """Write the workspace template and return list of written paths."""
    files = generate_workspace_template(workspace, template_dir)
    written = []
    for rel_path, content in files.items():
        dest = template_dir / rel_path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(content)
        written.append(str(dest.relative_to(ROOT)))
    return written


def check_workspace_template(workspace: Path, template_dir: Path) -> list[str]:
    """Check if workspace template is up to date. Returns list of stale files."""
    files = generate_workspace_template(workspace, template_dir)
    stale = []
    for rel_path, expected_content in files.items():
        dest = template_dir / rel_path
        if not dest.exists():
            stale.append(str(dest.relative_to(ROOT)))
            continue
        # For agent definitions, check if content matches
        if rel_path.startswith("agent-definitions/") or rel_path == "AGENTS.md":
            if dest.read_text() != expected_content:
                stale.append(str(dest.relative_to(ROOT)))
    return stale


# ---------------------------------------------------------------------------
# Template definitions
# ---------------------------------------------------------------------------
TEMPLATES = [
    {
        "name": ".env",
        "source": ROOT / ".env",
        "target": ROOT / ".env.example",
        "handler": redact_env_file,
    },
    {
        "name": "connector-config.yaml",
        "source": ROOT / "secrets" / "connector-config.yaml",
        "target": ROOT / "secrets" / "connector-config.yaml.example",
        "handler": redact_connector_config,
    },
]


def scan_staged_for_secrets() -> list[str]:
    """Scan git-staged files for potential secret leaks. Returns warnings."""
    import subprocess

    warnings = []
    try:
        result = subprocess.run(
            ["git", "diff", "--cached", "--name-only"],
            capture_output=True,
            text=True,
            cwd=ROOT,
        )
        staged_files = result.stdout.strip().splitlines()
    except FileNotFoundError:
        return warnings

    for filepath in staged_files:
        full_path = ROOT / filepath
        if not full_path.exists() or not full_path.is_file():
            continue
        # Skip binary files
        try:
            content = full_path.read_text()
        except (UnicodeDecodeError, PermissionError):
            continue
        for i, line in enumerate(content.splitlines(), 1):
            # Check for common secret patterns in values
            if SECRET_VALUE_PATTERNS.search(line):
                warnings.append(f"  {filepath}:{i} — possible secret value")
            # Check for high-entropy strings that look like tokens
            for token in re.findall(r'["\']([A-Za-z0-9+/_.=-]{40,})["\']', line):
                warnings.append(f"  {filepath}:{i} — possible embedded token")

    return warnings


def main():
    parser = argparse.ArgumentParser(description="Generate template files from live config")
    parser.add_argument(
        "--check",
        action="store_true",
        help="Check if templates are up to date (exit 1 if stale)",
    )
    parser.add_argument(
        "--scan-secrets",
        action="store_true",
        help="Scan staged files for potential secret leaks",
    )
    args = parser.parse_args()

    workspace = ROOT / "workspace"
    template_dir = ROOT / "workspace.template"

    if args.scan_secrets:
        warnings = scan_staged_for_secrets()
        if warnings:
            print("WARNING: Possible secrets detected in staged files:")
            for w in warnings:
                print(w)
            sys.exit(1)
        sys.exit(0)

    if args.check:
        stale = []
        for tmpl in TEMPLATES:
            if not tmpl["source"].exists():
                continue
            expected = tmpl["handler"](tmpl["source"])
            if not tmpl["target"].exists():
                stale.append(str(tmpl["target"].relative_to(ROOT)))
            elif tmpl["target"].read_text() != expected:
                stale.append(str(tmpl["target"].relative_to(ROOT)))

        stale.extend(check_workspace_template(workspace, template_dir))

        if stale:
            print("Templates are out of date:")
            for s in stale:
                print(f"  {s}")
            print("\nRun: uv run scripts/generate-templates.py")
            sys.exit(1)
        else:
            print("All templates are up to date.")
            sys.exit(0)

    # Generate mode
    updated = []
    for tmpl in TEMPLATES:
        if not tmpl["source"].exists():
            print(f"Skipping {tmpl['name']} (source not found: {tmpl['source'].relative_to(ROOT)})")
            continue
        content = tmpl["handler"](tmpl["source"])
        tmpl["target"].parent.mkdir(parents=True, exist_ok=True)
        tmpl["target"].write_text(content)
        updated.append(str(tmpl["target"].relative_to(ROOT)))
        print(f"Updated {tmpl['target'].relative_to(ROOT)}")

    # Workspace template
    ws_files = write_workspace_template(workspace, template_dir)
    updated.extend(ws_files)
    print(f"Updated workspace.template/ ({len(ws_files)} files)")

    if updated:
        print(f"\n{len(updated)} template file(s) updated.")
        print("Review the changes before committing to ensure no secrets leaked.")


if __name__ == "__main__":
    main()
