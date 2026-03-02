# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml"]
# ///
"""TriOnyx plugin manager — install, upgrade, and remove workspace plugins."""

import argparse
import shutil
import subprocess
import sys
from datetime import date
from pathlib import Path

import yaml

WORKSPACE = Path(__file__).resolve().parent.parent / "workspace"
PLUGINS_DIR = WORKSPACE / "plugins"
PLUGINS_YAML = WORKSPACE / "plugins.yaml"


def load_manifest() -> dict:
    if PLUGINS_YAML.exists():
        with open(PLUGINS_YAML) as f:
            data = yaml.safe_load(f) or {}
    else:
        data = {}
    data.setdefault("plugins", {})
    return data


def save_manifest(data: dict) -> None:
    PLUGINS_YAML.parent.mkdir(parents=True, exist_ok=True)
    with open(PLUGINS_YAML, "w") as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False)


def cmd_add(args: argparse.Namespace) -> None:
    repo = args.repo
    name = args.name or repo.rstrip("/").rsplit("/", 1)[-1].removesuffix(".git")
    ref = args.ref or "main"
    dest = PLUGINS_DIR / name

    if dest.exists():
        print(f"Error: plugin '{name}' already exists at {dest}", file=sys.stderr)
        print("Use 'upgrade' to re-install from the repo.", file=sys.stderr)
        sys.exit(1)

    PLUGINS_DIR.mkdir(parents=True, exist_ok=True)

    print(f"Cloning {repo} (ref: {ref}) into {dest} ...")
    subprocess.run(
        ["git", "clone", "--depth=1", "--branch", ref, repo, str(dest)],
        check=True,
    )

    # Strip .git so the plugin becomes mutable workspace files
    git_dir = dest / ".git"
    if git_dir.exists():
        shutil.rmtree(git_dir)

    manifest = load_manifest()
    manifest["plugins"][name] = {
        "repo": repo,
        "ref": ref,
        "installed": str(date.today()),
    }
    save_manifest(manifest)
    print(f"Plugin '{name}' installed.")


def cmd_upgrade(args: argparse.Namespace) -> None:
    name = args.name
    manifest = load_manifest()
    entry = manifest["plugins"].get(name)

    if not entry or not entry.get("repo"):
        print(f"Error: no repo recorded for plugin '{name}'.", file=sys.stderr)
        sys.exit(1)

    dest = PLUGINS_DIR / name
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

    entry["installed"] = str(date.today())
    save_manifest(manifest)
    print(f"Plugin '{name}' upgraded.")


def cmd_remove(args: argparse.Namespace) -> None:
    name = args.name
    manifest = load_manifest()

    dest = PLUGINS_DIR / name
    if dest.exists():
        shutil.rmtree(dest)
        print(f"Removed {dest}")
    else:
        print(f"Directory {dest} not found.")

    if name in manifest["plugins"]:
        del manifest["plugins"][name]
        save_manifest(manifest)

    print(f"Plugin '{name}' removed.")


def cmd_list(args: argparse.Namespace) -> None:
    manifest = load_manifest()
    plugins = manifest.get("plugins", {})

    if not plugins:
        print("No plugins installed.")
        return

    for name, info in plugins.items():
        repo = info.get("repo", "(local)")
        ref = info.get("ref", "")
        installed = info.get("installed", "")
        print(f"  {name:20s}  {repo}  ref={ref}  installed={installed}")


def main() -> None:
    parser = argparse.ArgumentParser(description="TriOnyx plugin manager")
    sub = parser.add_subparsers(dest="command", required=True)

    p_add = sub.add_parser("add", help="Install a plugin from a git repo")
    p_add.add_argument("repo", help="Git repository URL")
    p_add.add_argument("--name", help="Plugin name (default: derived from URL)")
    p_add.add_argument("--ref", help="Git branch or tag (default: main)")
    p_add.set_defaults(func=cmd_add)

    p_upgrade = sub.add_parser("upgrade", help="Re-install a plugin from its repo")
    p_upgrade.add_argument("name", help="Plugin name")
    p_upgrade.set_defaults(func=cmd_upgrade)

    p_remove = sub.add_parser("remove", help="Remove a plugin")
    p_remove.add_argument("name", help="Plugin name")
    p_remove.set_defaults(func=cmd_remove)

    p_list = sub.add_parser("list", help="List installed plugins")
    p_list.set_defaults(func=cmd_list)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
