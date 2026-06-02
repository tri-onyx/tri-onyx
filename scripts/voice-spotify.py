#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["pynput"]
# ///
"""Pause Spotify while Space is held (≥1s) for voice dictation."""

import subprocess
import threading
import time

from pynput import keyboard

kb = keyboard.Controller()
space_down_at = None
timer = None
paused = False


def spotify_ctl(action):
    subprocess.run(
        [
            "dbus-send", "--print-reply",
            "--dest=org.mpris.MediaPlayer2.spotify",
            "/org/mpris/MediaPlayer2",
            f"org.mpris.MediaPlayer2.Player.{action}",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def pause():
    global paused
    paused = True
    spotify_ctl("Pause")


def resume():
    global paused
    if paused:
        paused = False
        kb.press(keyboard.Key.enter)
        kb.release(keyboard.Key.enter)
        spotify_ctl("Play")


def on_press(key):
    global space_down_at, timer
    if key == keyboard.Key.space and space_down_at is None:
        space_down_at = time.monotonic()
        timer = threading.Timer(1.0, pause)
        timer.start()


def on_release(key):
    global space_down_at, timer
    if key == keyboard.Key.space:
        if timer:
            timer.cancel()
            timer = None
        space_down_at = None
        if paused:
            threading.Timer(0.5, resume).start()


print("Listening for Space hold (≥1s) to pause Spotify. Ctrl+C to stop.")

with keyboard.Listener(on_press=on_press, on_release=on_release) as listener:
    listener.join()
