# /// script
# requires-python = ">=3.11"
# dependencies = ["youtube-transcript-api", "httpx"]
# ///
"""Fetch transcript from a YouTube video.

Usage:
    uv run scripts/youtube-transcript.py <url> [url2 ...] [--save [DIR]] [--lang LANG]

Without --save, prints transcript to stdout (single URL only).
With --save, fetches the video title and saves each transcript as
    <dir>/<slugified-title>.txt
"""

import argparse
import re
import sys
import textwrap
from pathlib import Path

import httpx
from youtube_transcript_api import YouTubeTranscriptApi
from youtube_transcript_api.formatters import TextFormatter


def extract_video_id(url_or_id: str) -> str:
    """Extract video ID from a URL or return as-is if already an ID."""
    if "youtube.com" in url_or_id:
        for param in url_or_id.split("?")[-1].split("&"):
            if param.startswith("v="):
                return param[2:]
    if "youtu.be/" in url_or_id:
        return url_or_id.split("youtu.be/")[-1].split("?")[0]
    return url_or_id


def fetch_video_title(video_id: str) -> str:
    """Fetch the video title from YouTube's oembed endpoint."""
    url = f"https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v={video_id}&format=json"
    resp = httpx.get(url, follow_redirects=True, timeout=15)
    resp.raise_for_status()
    return resp.json()["title"]


def slugify(text: str) -> str:
    """Turn a title into a filesystem-friendly slug."""
    text = text.lower()
    text = re.sub(r"[^\w\s-]", "", text)
    text = re.sub(r"[\s_-]+", "-", text).strip("-")
    return text[:80]


def fetch_transcript(video_id: str, languages: list[str]) -> str:
    api = YouTubeTranscriptApi()
    transcript = api.fetch(video_id, languages=languages)
    # Join caption segments into flowing text, then re-wrap into paragraphs.
    # Segments often break mid-sentence; joining and splitting on double
    # newlines (or long pauses) produces readable output.
    raw = " ".join(snippet.text.replace("\n", " ") for snippet in transcript)
    # Collapse multiple spaces
    raw = re.sub(r" {2,}", " ", raw)
    # Wrap into paragraphs (~80 chars) for readability
    return textwrap.fill(raw, width=80)


def main():
    parser = argparse.ArgumentParser(description="Fetch YouTube transcripts")
    parser.add_argument("urls", nargs="+", help="YouTube video URLs or IDs")
    parser.add_argument("--save", nargs="?", const=".", metavar="DIR",
                        help="Save transcripts to DIR (default: current directory)")
    parser.add_argument("--lang", default="en", help="Transcript language (default: en)")
    args = parser.parse_args()

    languages = [args.lang]

    for url in args.urls:
        video_id = extract_video_id(url)
        text = fetch_transcript(video_id, languages)

        if args.save is not None:
            title = fetch_video_title(video_id)
            slug = slugify(title)
            out_dir = Path(args.save)
            out_dir.mkdir(parents=True, exist_ok=True)
            out_path = out_dir / f"{slug}.txt"
            out_path.write_text(text)
            print(f"Saved: {out_path}  ({title})")
        else:
            if len(args.urls) > 1:
                print(f"=== {video_id} ===")
            print(text)


if __name__ == "__main__":
    main()
