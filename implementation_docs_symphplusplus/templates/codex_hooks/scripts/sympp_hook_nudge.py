#!/usr/bin/env python3
"""Emit deterministic Symphony++ Codex hook nudges."""

from __future__ import annotations

import json
import re
import sys


MAX_EVENT_SCAN_BYTES = 65536
EVENT_PATTERN = re.compile(rb'"hook_event_name"\s*:\s*"([^"\\]+)"')

MESSAGES = {
    "SessionStart": "Symphony++ reminder: load the assigned WorkPackage context before editing; hooks are nudges, server-side MCP checks remain authoritative.",
    "UserPromptSubmit": "Symphony++ reminder: stay inside the assigned WorkPackage; update progress/findings after meaningful work.",
    "PreToolUse": "Symphony++ reminder: keep this tool use within the assigned WorkPackage and avoid raw secrets in commands, logs, or files.",
    "PostToolUse": "Symphony++ reminder: record durable findings/progress when this tool changed package evidence.",
    "Stop": "Symphony++ reminder: final response is complete; verify handoff evidence before closing the package.",
}


def hook_event_name() -> str | None:
    match = EVENT_PATTERN.search(sys.stdin.buffer.read(MAX_EVENT_SCAN_BYTES))
    if not match:
        return None

    try:
        return match.group(1).decode("ascii")
    except UnicodeDecodeError:
        return None


def main() -> int:
    event = hook_event_name()
    message = MESSAGES.get(event)
    if not message:
        return 0

    output: dict[str, object]
    if event in {"SessionStart", "UserPromptSubmit"}:
        output = {
            "continue": True,
            "hookSpecificOutput": {
                "hookEventName": event,
                "additionalContext": message,
            },
        }
    elif event == "PostToolUse":
        output = {
            "hookSpecificOutput": {
                "hookEventName": event,
                "additionalContext": message,
            },
        }
    elif event == "Stop":
        output = {"systemMessage": message}
    else:
        output = {"systemMessage": message}

    print(json.dumps(output, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
