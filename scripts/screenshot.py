# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "playwright",
# ]
# ///
"""Render a local HTML page and save a screenshot using Playwright."""

import argparse
import subprocess
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright


def ensure_browsers_installed():
    """Install Chromium if not already present."""
    subprocess.run(
        [sys.executable, "-m", "playwright", "install", "chromium"],
        check=True,
        capture_output=True,
    )


def screenshot(url: str, output: str, width: int, height: int) -> Path:
    out = Path(output)
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": width, "height": height})
        page.goto(url, wait_until="networkidle")
        page.screenshot(path=str(out), full_page=True)
        browser.close()
    return out


def main():
    parser = argparse.ArgumentParser(description="Screenshot a local HTML page")
    parser.add_argument("url", help="URL or file path to render (e.g. http://localhost:8080 or ./page.html)")
    parser.add_argument("-o", "--output", default="screenshot.png", help="Output image path (default: screenshot.png)")
    parser.add_argument("-W", "--width", type=int, default=1280, help="Viewport width (default: 1280)")
    parser.add_argument("-H", "--height", type=int, default=720, help="Viewport height (default: 720)")
    args = parser.parse_args()

    url = args.url
    if not url.startswith(("http://", "https://", "file://")):
        path = Path(url).resolve()
        if not path.exists():
            print(f"Error: file not found: {path}", file=sys.stderr)
            sys.exit(1)
        url = f"file://{path}"

    ensure_browsers_installed()
    out = screenshot(url, args.output, args.width, args.height)
    print(f"Saved screenshot to {out.resolve()}")


if __name__ == "__main__":
    main()
