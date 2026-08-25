# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8.0"]
# ///
"""Tests for the shutdown/control-read race in the agent runner's main loop.

``main()`` races ``dispatcher.read_control()`` against the SIGTERM event with
``asyncio.wait(FIRST_COMPLETED)``, which may report *both* waiters as done.
The message cannot be serviced (the loop is exiting), but it must not vanish
silently — ``log_dropped_control`` names it in the log.
"""

from __future__ import annotations

import asyncio
import logging
import sys
from pathlib import Path

# Ensure runtime/ is importable
sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "runtime"))

import agent_runner


def _done_task(loop: asyncio.AbstractEventLoop, result=None, exc=None) -> asyncio.Future:
    """A completed future standing in for the read_control task."""
    fut = loop.create_future()
    if exc is not None:
        fut.set_exception(exc)
    else:
        fut.set_result(result)
    return fut


def test_dropped_message_is_logged_with_its_type(caplog) -> None:
    loop = asyncio.new_event_loop()
    try:
        task = _done_task(loop, {"type": "prompt", "content": "hi"})
        with caplog.at_level(logging.WARNING):
            assert agent_runner.log_dropped_control(task) == "prompt"
        assert "prompt" in caplog.text
    finally:
        loop.close()


def test_unknown_shape_still_reports_something(caplog) -> None:
    loop = asyncio.new_event_loop()
    try:
        task = _done_task(loop, ["not", "a", "dict"])
        with caplog.at_level(logging.WARNING):
            assert agent_runner.log_dropped_control(task) == "list"
    finally:
        loop.close()


def test_dict_without_type_reports_unknown(caplog) -> None:
    loop = asyncio.new_event_loop()
    try:
        task = _done_task(loop, {"content": "hi"})
        with caplog.at_level(logging.WARNING):
            assert agent_runner.log_dropped_control(task) == "unknown"
    finally:
        loop.close()


def test_eof_is_not_a_dropped_message(caplog) -> None:
    """``read_control`` returns None on EOF — nothing was lost."""
    loop = asyncio.new_event_loop()
    try:
        task = _done_task(loop, None)
        with caplog.at_level(logging.WARNING):
            assert agent_runner.log_dropped_control(task) is None
        assert caplog.text == ""
    finally:
        loop.close()


def test_pending_read_is_not_a_dropped_message() -> None:
    """The common case: only the shutdown waiter fired."""
    loop = asyncio.new_event_loop()
    try:
        assert agent_runner.log_dropped_control(loop.create_future()) is None
    finally:
        loop.close()


def test_cancelled_read_is_not_a_dropped_message() -> None:
    loop = asyncio.new_event_loop()
    try:
        fut = loop.create_future()
        fut.cancel()
        assert agent_runner.log_dropped_control(fut) is None
    finally:
        loop.close()


def test_failed_read_is_not_a_dropped_message() -> None:
    loop = asyncio.new_event_loop()
    try:
        task = _done_task(loop, exc=RuntimeError("boom"))
        assert agent_runner.log_dropped_control(task) is None
    finally:
        loop.close()
