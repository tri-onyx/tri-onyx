# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml"]
# ///
"""TriOnyx plugin manager — install, upgrade, and remove workspace plugins.

Plugins live inside per-agent repos or shared repos:
  - agent-owned:  workspace/trees/<agent>/self/plugins/<name>/
  - shared:       workspace/trees/_gw/<repo>/plugins/<name>/  (e.g. knowledge)

Each repo carries its own plugins.yaml ledger at the tree root (next to
plugins/). Working trees contain no .git — all git operations go through
explicit --git-dir/--work-tree, and every change is committed + pushed to
the backing bare repo.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import date
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
WORKSPACE = ROOT / "workspace"
TREES = WORKSPACE / "trees"
GITDIRS = WORKSPACE / "gitdirs"

GIT_IDENTITY = {
    "GIT_AUTHOR_NAME": "TriOnyx",
    "GIT_AUTHOR_EMAIL": "gateway@tri_onyx",
    "GIT_COMMITTER_NAME": "TriOnyx",
    "GIT_COMMITTER_EMAIL": "gateway@tri_onyx",
}


@dataclass
class Target:
    """A plugin install target: one repo working tree plus its git metadata."""

    label: str  # e.g. "agent 'news'" or "shared repo 'knowledge'"
    tree: Path  # working tree root (plugins.yaml lives here)
    gitdir: Path  # git metadata dir used for commit/push

    @property
    def plugins_dir(self) -> Path:
        return self.tree / "plugins"

    @property
    def manifest_path(self) -> Path:
        return self.tree / "plugins.yaml"


def agent_target(name: str) -> Target:
    return Target(
        label=f"agent '{name}'",
        tree=TREES / name / "self",
        gitdir=GITDIRS / name / "self.git",
    )


def shared_target(repo: str) -> Target:
    return Target(
        label=f"shared repo '{repo}'",
        tree=TREES / "_gw" / repo,
        gitdir=GITDIRS / "_gw" / (repo + ".git"),
    )


def resolve_target(args: argparse.Namespace) -> Target | None:
    """Build a Target from --agent/--shared flags, or None if neither given."""
    if args.agent and args.shared:
        print("Error: --agent and --shared are mutually exclusive.", file=sys.stderr)
        sys.exit(1)
    if args.agent:
        target = agent_target(args.agent)
    elif args.shared:
        target = shared_target(args.shared)
    else:
        return None
    if not target.tree.is_dir():
        print(f"Error: no working tree for {target.label} at {target.tree}", file=sys.stderr)
        sys.exit(1)
    return target


def discover_targets() -> list[Target]:
    """All agent trees plus all _gw shared trees that exist on disk."""
    targets = []
    if TREES.is_dir():
        for entry in sorted(TREES.iterdir()):
            if entry.name.startswith("_") or not entry.is_dir():
                continue
            if (entry / "self").is_dir():
                targets.append(agent_target(entry.name))
    gw_dir = TREES / "_gw"
    if gw_dir.is_dir():
        for entry in sorted(gw_dir.iterdir()):
            if entry.is_dir():
                targets.append(shared_target(entry.name))
    return targets


def find_plugin_target(name: str) -> Target:
    """Locate the single target whose ledger (or plugins/ dir) has the plugin."""
    matches = [
        t
        for t in discover_targets()
        if name in load_manifest(t)["plugins"] or (t.plugins_dir / name).is_dir()
    ]
    if not matches:
        print(f"Error: plugin '{name}' not found in any tree.", file=sys.stderr)
        sys.exit(1)
    if len(matches) > 1:
        labels = ", ".join(t.label for t in matches)
        print(
            f"Error: plugin '{name}' found in multiple trees ({labels}).\n"
            "Disambiguate with --agent or --shared.",
            file=sys.stderr,
        )
        sys.exit(1)
    return matches[0]


def git(target: Target, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    """Run git against the target's explicit git-dir + work-tree."""
    cmd = [
        "git",
        "-c",
        "safe.directory=*",
        f"--git-dir={target.gitdir}",
        f"--work-tree={target.tree}",
        *args,
    ]
    env = os.environ.copy()
    env.update(GIT_IDENTITY)
    # cwd inside the tree so pathspec args resolve against the work tree
    return subprocess.run(
        cmd, check=check, env=env, cwd=target.tree, capture_output=True, text=True
    )


def commit_and_push(target: Target, message: str) -> None:
    """Stage everything in the tree, commit as TriOnyx, and push to main."""
    if not target.gitdir.is_dir():
        print(
            f"Error: no git metadata for {target.label} at {target.gitdir} — "
            "cannot commit; is the workspace migrated?",
            file=sys.stderr,
        )
        sys.exit(1)
    git(target, "add", "-A")
    status = git(target, "status", "--porcelain")
    if not status.stdout.strip():
        print(f"  No changes to commit in {target.label}.")
        return
    git(target, "commit", "-m", message)
    result = git(target, "push", "origin", "main", check=False)
    if result.returncode != 0:
        print(f"  Warning: push failed for {target.label}:", file=sys.stderr)
        print(result.stderr or result.stdout, file=sys.stderr)
        sys.exit(1)
    print(f"  Committed and pushed to {target.label}: {message}")


def load_manifest(target: Target) -> dict:
    if target.manifest_path.exists():
        with open(target.manifest_path) as f:
            data = yaml.safe_load(f) or {}
    else:
        data = {}
    data.setdefault("plugins", {})
    return data


def save_manifest(target: Target, data: dict) -> None:
    target.manifest_path.parent.mkdir(parents=True, exist_ok=True)
    with open(target.manifest_path, "w") as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False)


def cmd_add(args: argparse.Namespace) -> None:
    target = resolve_target(args)
    if target is None:
        print("Error: 'add' requires --agent <name> or --shared <repo>.", file=sys.stderr)
        sys.exit(1)

    repo = args.repo
    name = args.name or repo.rstrip("/").rsplit("/", 1)[-1].removesuffix(".git")
    ref = args.ref or "main"
    dest = target.plugins_dir / name

    if dest.exists():
        print(f"Error: plugin '{name}' already exists at {dest}", file=sys.stderr)
        print("Use 'upgrade' to re-install from the repo.", file=sys.stderr)
        sys.exit(1)

    target.plugins_dir.mkdir(parents=True, exist_ok=True)

    print(f"Cloning {repo} (ref: {ref}) into {dest} ...")
    subprocess.run(
        ["git", "clone", "--depth=1", "--branch", ref, repo, str(dest)],
        check=True,
    )

    # Strip .git so the plugin becomes mutable repo content
    git_dir = dest / ".git"
    if git_dir.exists():
        shutil.rmtree(git_dir)

    # Auto-create plugin.json manifest if not present
    _ensure_plugin_json(dest, name)

    # Install Python dependencies if the plugin has a pyproject.toml
    _sync_python_deps(dest)

    manifest = load_manifest(target)
    manifest["plugins"][name] = {
        "repo": repo,
        "ref": ref,
        "installed": str(date.today()),
    }
    save_manifest(target, manifest)
    commit_and_push(target, f"chore(plugin): add {name}")
    print(f"Plugin '{name}' installed into {target.label}.")


def _ensure_plugin_json(dest: Path, name: str) -> None:
    """Create a default .claude-plugin/plugin.json if one doesn't exist."""
    plugin_dir = dest / ".claude-plugin"
    plugin_json = plugin_dir / "plugin.json"
    if not plugin_json.exists():
        plugin_dir.mkdir(parents=True, exist_ok=True)
        manifest = {
            "name": name,
            "description": f"TriOnyx workspace plugin: {name}",
            "version": "0.1.0",
        }
        plugin_json.write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"  Created {plugin_json}")


def _sync_python_deps(dest: Path) -> None:
    """Run `uv sync` if the plugin has a pyproject.toml."""
    pyproject = dest / "pyproject.toml"
    if not pyproject.exists():
        return
    print(f"  Syncing Python dependencies ...")
    result = subprocess.run(["uv", "sync"], cwd=dest)
    if result.returncode == 0:
        print(f"  Python dependencies installed.")
    else:
        print(f"  Warning: uv sync failed (exit {result.returncode}).", file=sys.stderr)


def cmd_upgrade(args: argparse.Namespace) -> None:
    name = args.name
    target = resolve_target(args) or find_plugin_target(name)
    manifest = load_manifest(target)
    entry = manifest["plugins"].get(name)

    if not entry or not entry.get("repo"):
        print(
            f"Error: no repo recorded for plugin '{name}' in {target.label}.",
            file=sys.stderr,
        )
        sys.exit(1)

    dest = target.plugins_dir / name
    if dest.exists():
        shutil.rmtree(dest)

    repo = entry["repo"]
    ref = entry.get("ref", "main")

    print(f"Re-cloning {repo} (ref: {ref}) into {dest} ...")
    subprocess.run(
        ["git", "clone", "--depth=1", "--branch", ref, repo, str(dest)],
        check=True,
    )

    git_dir = dest / ".git"
    if git_dir.exists():
        shutil.rmtree(git_dir)

    # Re-install Python dependencies if the plugin has a pyproject.toml
    _sync_python_deps(dest)

    entry["installed"] = str(date.today())
    save_manifest(target, manifest)
    commit_and_push(target, f"chore(plugin): upgrade {name}")
    print(f"Plugin '{name}' upgraded in {target.label}.")


def cmd_remove(args: argparse.Namespace) -> None:
    name = args.name
    target = resolve_target(args) or find_plugin_target(name)
    manifest = load_manifest(target)

    dest = target.plugins_dir / name
    if dest.exists():
        shutil.rmtree(dest)
        print(f"Removed {dest}")
    else:
        print(f"Directory {dest} not found.")

    if name in manifest["plugins"]:
        del manifest["plugins"][name]
        save_manifest(target, manifest)

    commit_and_push(target, f"chore(plugin): remove {name}")
    print(f"Plugin '{name}' removed from {target.label}.")


def cmd_list(args: argparse.Namespace) -> None:
    found = False
    for target in discover_targets():
        plugins = load_manifest(target)["plugins"]
        if not plugins:
            continue
        found = True
        print(f"{target.label}:")
        for name, info in plugins.items():
            repo = info.get("repo", "(local)")
            ref = info.get("ref", "")
            installed = info.get("installed", "")
            print(f"  {name:20s}  {repo}  ref={ref}  installed={installed}")

    if not found:
        print("No plugins installed.")


def _add_target_flags(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--agent", help="Agent whose repo the plugin lives in")
    parser.add_argument("--shared", help="Shared repo the plugin lives in (e.g. knowledge)")


def main() -> None:
    parser = argparse.ArgumentParser(description="TriOnyx plugin manager")
    sub = parser.add_subparsers(dest="command", required=True)

    p_add = sub.add_parser("add", help="Install a plugin from a git repo")
    p_add.add_argument("repo", help="Git repository URL")
    p_add.add_argument("--name", help="Plugin name (default: derived from URL)")
    p_add.add_argument("--ref", help="Git branch or tag (default: main)")
    _add_target_flags(p_add)
    p_add.set_defaults(func=cmd_add)

    p_upgrade = sub.add_parser("upgrade", help="Re-install a plugin from its repo")
    p_upgrade.add_argument("name", help="Plugin name")
    _add_target_flags(p_upgrade)
    p_upgrade.set_defaults(func=cmd_upgrade)

    p_remove = sub.add_parser("remove", help="Remove a plugin")
    p_remove.add_argument("name", help="Plugin name")
    _add_target_flags(p_remove)
    p_remove.set_defaults(func=cmd_remove)

    p_list = sub.add_parser("list", help="List installed plugins")
    p_list.set_defaults(func=cmd_list)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
