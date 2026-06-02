# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "playwright",
# ]
# ///
"""Browser automation tool using accessibility-based locators.

Replaces screenshot.py. Supports navigation, clicking, filling forms,
reading text, screenshots, and listing accessible elements — all driven
by Playwright's get_by_role/get_by_label locators.

Browser state (cookies, localStorage) persists across invocations via
a persistent user data directory.
"""

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright, TimeoutError as PwTimeout

PROFILE_DIR = Path("./tmp/.browser-profile")
LAST_URL_FILE = Path("./tmp/.browser-last-url")
DEFAULT_WIDTH = 1280
DEFAULT_HEIGHT = 720

ROLE_MAP = {
    "button": "button",
    "link": "link",
    "textbox": "textbox",
    "checkbox": "checkbox",
    "radio": "radio",
    "combobox": "combobox",
    "heading": "heading",
    "tab": "tab",
    "menuitem": "menuitem",
    "img": "img",
    "list": "list",
    "listitem": "listitem",
    "navigation": "navigation",
    "region": "region",
    "status": "status",
    "log": "log",
    "menu": "menu",
}


def ensure_browsers_installed():
    subprocess.run(
        [sys.executable, "-m", "playwright", "install", "chromium"],
        check=True,
        capture_output=True,
    )


def _save_last_url(url: str):
    LAST_URL_FILE.parent.mkdir(parents=True, exist_ok=True)
    LAST_URL_FILE.write_text(url)


def _load_last_url() -> str | None:
    if LAST_URL_FILE.exists():
        return LAST_URL_FILE.read_text().strip()
    return None


def _resolve_url(url: str) -> str:
    if not url.startswith(("http://", "https://", "file://")):
        path = Path(url).resolve()
        if not path.exists():
            print(f"Error: file not found: {path}", file=sys.stderr)
            sys.exit(1)
        return f"file://{path}"
    return url


def _wait_for_htmx(page, timeout_ms: int = 3000):
    try:
        page.wait_for_function(
            """() => {
                if (typeof htmx === 'undefined') return true;
                return document.querySelectorAll('.htmx-request').length === 0;
            }""",
            timeout=timeout_ms,
        )
        page.wait_for_timeout(100)
    except PwTimeout:
        pass


def _get_locator(page, role: str, name: str):
    key = role.lower()
    if key == "text":
        return page.get_by_text(name)
    if key == "label":
        return page.get_by_label(name)
    aria_role = ROLE_MAP.get(key)
    if not aria_role:
        print(f"Error: unknown role '{role}'. Valid: {', '.join(sorted(ROLE_MAP))}, text, label", file=sys.stderr)
        sys.exit(1)
    return page.get_by_role(aria_role, name=name)


def _get_ax_tree(page) -> list[dict]:
    """Get accessibility tree via CDP."""
    cdp = page.context.new_cdp_session(page)
    tree = cdp.send("Accessibility.getFullAXTree")
    cdp.detach()

    skip_roles = {"none", "generic", "StaticText", "InlineTextBox",
                  "LineBreak", "paragraph", "Group"}
    results = []
    for node in tree.get("nodes", []):
        role = node.get("role", {}).get("value", "")
        name = node.get("name", {}).get("value", "")
        if not role or role in skip_roles:
            continue

        props = {p["name"]: p.get("value", {}).get("value")
                 for p in node.get("properties", [])}
        state_parts = []
        if props.get("expanded") is True:
            state_parts.append("expanded")
        elif props.get("expanded") is False:
            state_parts.append("collapsed")
        if props.get("pressed") is True:
            state_parts.append("pressed")
        elif props.get("pressed") == "mixed":
            state_parts.append("mixed")
        if props.get("checked") is True:
            state_parts.append("checked")
        if props.get("disabled") is True:
            state_parts.append("disabled")

        results.append({
            "role": role,
            "name": name,
            "state": ", ".join(state_parts),
        })
    return results


def cmd_navigate(args):
    url = _resolve_url(args.url)
    width = args.width or DEFAULT_WIDTH
    height = args.height or DEFAULT_HEIGHT
    wait = args.wait or "load"

    ensure_browsers_installed()
    PROFILE_DIR.mkdir(parents=True, exist_ok=True)

    with sync_playwright() as p:
        context = p.chromium.launch_persistent_context(
            str(PROFILE_DIR),
            headless=True,
            viewport={"width": width, "height": height},
            ignore_https_errors=True,
        )
        page = context.pages[0] if context.pages else context.new_page()
        page.goto(url, wait_until=wait)
        _wait_for_htmx(page)
        _save_last_url(url)

        title = page.title()
        print(f"Navigated to: {url}")
        print(f"Title: {title}")

        if args.screenshot:
            out = Path(args.screenshot)
            out.parent.mkdir(parents=True, exist_ok=True)
            page.screenshot(path=str(out), full_page=True)
            print(f"Screenshot: {out.resolve()}")

        context.close()


def cmd_click(args):
    ensure_browsers_installed()
    last_url = _load_last_url()
    if not last_url:
        print("Error: no page loaded. Run 'navigate' first.", file=sys.stderr)
        sys.exit(2)

    with sync_playwright() as p:
        context = p.chromium.launch_persistent_context(
            str(PROFILE_DIR),
            headless=True,
            viewport={"width": DEFAULT_WIDTH, "height": DEFAULT_HEIGHT},
            ignore_https_errors=True,
        )
        page = context.pages[0] if context.pages else context.new_page()
        page.goto(last_url, wait_until="load")
        _wait_for_htmx(page)

        locator = _get_locator(page, args.role, args.name)
        try:
            locator.click(timeout=5000)
        except PwTimeout:
            print(f"Error: could not find {args.role} '{args.name}'", file=sys.stderr)
            context.close()
            sys.exit(1)

        _wait_for_htmx(page)

        new_url = page.url
        _save_last_url(new_url)
        print(f"Clicked {args.role} '{args.name}'")
        if new_url != last_url:
            print(f"Navigated to: {new_url}")

        if args.screenshot:
            out = Path(args.screenshot)
            out.parent.mkdir(parents=True, exist_ok=True)
            page.screenshot(path=str(out), full_page=True)
            print(f"Screenshot: {out.resolve()}")

        context.close()


def cmd_fill(args):
    ensure_browsers_installed()
    last_url = _load_last_url()
    if not last_url:
        print("Error: no page loaded. Run 'navigate' first.", file=sys.stderr)
        sys.exit(2)

    with sync_playwright() as p:
        context = p.chromium.launch_persistent_context(
            str(PROFILE_DIR),
            headless=True,
            viewport={"width": DEFAULT_WIDTH, "height": DEFAULT_HEIGHT},
            ignore_https_errors=True,
        )
        page = context.pages[0] if context.pages else context.new_page()
        page.goto(last_url, wait_until="load")
        _wait_for_htmx(page)

        locator = _get_locator(page, args.role, args.name)
        try:
            locator.fill(args.value, timeout=5000)
        except PwTimeout:
            print(f"Error: could not find {args.role} '{args.name}'", file=sys.stderr)
            context.close()
            sys.exit(1)

        _wait_for_htmx(page)
        print(f"Filled {args.role} '{args.name}' with: {args.value}")
        context.close()


def cmd_read(args):
    ensure_browsers_installed()
    last_url = _load_last_url()
    if not last_url:
        print("Error: no page loaded. Run 'navigate' first.", file=sys.stderr)
        sys.exit(2)

    with sync_playwright() as p:
        context = p.chromium.launch_persistent_context(
            str(PROFILE_DIR),
            headless=True,
            viewport={"width": DEFAULT_WIDTH, "height": DEFAULT_HEIGHT},
            ignore_https_errors=True,
        )
        page = context.pages[0] if context.pages else context.new_page()
        page.goto(last_url, wait_until="load")
        _wait_for_htmx(page)

        if args.role and args.name:
            locator = _get_locator(page, args.role, args.name)
            try:
                text = locator.inner_text(timeout=5000)
            except PwTimeout:
                print(f"Error: could not find {args.role} '{args.name}'", file=sys.stderr)
                context.close()
                sys.exit(1)
        else:
            text = page.inner_text("body")

        print(text)
        context.close()


def cmd_screenshot(args):
    ensure_browsers_installed()
    last_url = _load_last_url()
    if not last_url:
        print("Error: no page loaded. Run 'navigate' first.", file=sys.stderr)
        sys.exit(2)

    width = args.width or DEFAULT_WIDTH
    height = args.height or DEFAULT_HEIGHT
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)

    with sync_playwright() as p:
        context = p.chromium.launch_persistent_context(
            str(PROFILE_DIR),
            headless=True,
            viewport={"width": width, "height": height},
            ignore_https_errors=True,
        )
        page = context.pages[0] if context.pages else context.new_page()
        page.goto(last_url, wait_until="load")
        _wait_for_htmx(page)
        page.screenshot(path=str(out), full_page=True)
        print(f"Saved screenshot to {out.resolve()}")
        context.close()


def cmd_list(args):
    ensure_browsers_installed()
    last_url = _load_last_url()
    if not last_url:
        print("Error: no page loaded. Run 'navigate' first.", file=sys.stderr)
        sys.exit(2)

    with sync_playwright() as p:
        context = p.chromium.launch_persistent_context(
            str(PROFILE_DIR),
            headless=True,
            viewport={"width": DEFAULT_WIDTH, "height": DEFAULT_HEIGHT},
            ignore_https_errors=True,
        )
        page = context.pages[0] if context.pages else context.new_page()
        page.goto(last_url, wait_until="load")
        _wait_for_htmx(page)

        results = _get_ax_tree(page)

        role_filter = args.role.lower() if args.role else None
        for item in results:
            if role_filter and item["role"].lower() != role_filter:
                continue
            name_display = f'  name="{item["name"]}"' if item["name"] else ""
            state_display = f"  state={item['state']}" if item["state"] else ""
            print(f"role={item['role']}{name_display}{state_display}")

        context.close()


def cmd_wait(args):
    ensure_browsers_installed()
    last_url = _load_last_url()
    if not last_url:
        print("Error: no page loaded. Run 'navigate' first.", file=sys.stderr)
        sys.exit(2)

    timeout = args.timeout or 10000

    with sync_playwright() as p:
        context = p.chromium.launch_persistent_context(
            str(PROFILE_DIR),
            headless=True,
            viewport={"width": DEFAULT_WIDTH, "height": DEFAULT_HEIGHT},
            ignore_https_errors=True,
        )
        page = context.pages[0] if context.pages else context.new_page()
        page.goto(last_url, wait_until="load")
        _wait_for_htmx(page)

        try:
            page.get_by_text(args.text).first.wait_for(state="visible", timeout=timeout)
            print(f"Found: '{args.text}'")
        except PwTimeout:
            print(f"Timeout: '{args.text}' not found after {timeout}ms", file=sys.stderr)
            context.close()
            sys.exit(1)

        context.close()


def cmd_close(args):
    if PROFILE_DIR.exists():
        shutil.rmtree(PROFILE_DIR)
        print("Browser profile cleaned up.")
    if LAST_URL_FILE.exists():
        LAST_URL_FILE.unlink()
    print("Session closed.")


def main():
    parser = argparse.ArgumentParser(
        description="Browser automation using accessibility-based locators",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # navigate
    p_nav = sub.add_parser("navigate", help="Navigate to a URL")
    p_nav.add_argument("url", help="URL or file path to open")
    p_nav.add_argument("--screenshot", "-s", metavar="PATH", help="Save screenshot after navigation")
    p_nav.add_argument("-W", "--width", type=int, help=f"Viewport width (default: {DEFAULT_WIDTH})")
    p_nav.add_argument("-H", "--height", type=int, help=f"Viewport height (default: {DEFAULT_HEIGHT})")
    p_nav.add_argument("--wait", choices=["load", "domcontentloaded", "networkidle", "commit"], help="Wait strategy (default: load)")
    p_nav.set_defaults(func=cmd_navigate)

    # click
    p_click = sub.add_parser("click", help="Click an element by role and name")
    p_click.add_argument("role", help="ARIA role (button, link, checkbox, etc.)")
    p_click.add_argument("name", help="Accessible name of the element")
    p_click.add_argument("--screenshot", "-s", metavar="PATH", help="Save screenshot after click")
    p_click.set_defaults(func=cmd_click)

    # fill
    p_fill = sub.add_parser("fill", help="Fill an input by role and name")
    p_fill.add_argument("role", help="ARIA role (textbox, combobox, etc.)")
    p_fill.add_argument("name", help="Accessible name of the element")
    p_fill.add_argument("value", help="Value to fill")
    p_fill.set_defaults(func=cmd_fill)

    # read
    p_read = sub.add_parser("read", help="Read text content from an element or the page")
    p_read.add_argument("role", nargs="?", help="ARIA role (optional)")
    p_read.add_argument("name", nargs="?", help="Accessible name (optional)")
    p_read.set_defaults(func=cmd_read)

    # screenshot
    p_ss = sub.add_parser("screenshot", help="Screenshot the current page")
    p_ss.add_argument("-o", "--output", default="screenshot.png", help="Output path (default: screenshot.png)")
    p_ss.add_argument("-W", "--width", type=int, help=f"Viewport width (default: {DEFAULT_WIDTH})")
    p_ss.add_argument("-H", "--height", type=int, help=f"Viewport height (default: {DEFAULT_HEIGHT})")
    p_ss.set_defaults(func=cmd_screenshot)

    # list
    p_list = sub.add_parser("list", help="List accessible elements on the page")
    p_list.add_argument("--role", help="Filter by role")
    p_list.set_defaults(func=cmd_list)

    # wait
    p_wait = sub.add_parser("wait", help="Wait for text to appear on the page")
    p_wait.add_argument("text", help="Text to wait for")
    p_wait.add_argument("--timeout", type=int, help="Timeout in ms (default: 10000)")
    p_wait.set_defaults(func=cmd_wait)

    # close
    p_close = sub.add_parser("close", help="Clean up browser session")
    p_close.set_defaults(func=cmd_close)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
