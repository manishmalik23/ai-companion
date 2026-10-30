#!/usr/bin/env python3
"""Print a reviewable hook configuration without changing agent settings."""

import argparse
import json
from pathlib import Path
import shlex
import sys


PROJECT_DIR = Path(__file__).resolve().parent
SOURCES = ("claude", "codex", "chatgpt-work")
LIFECYCLE_EVENTS = (
    "SessionStart",
    "UserPromptSubmit",
    "PostToolUse",
    "Stop",
    "SessionEnd",
)


def build_config(source, runtime, bridge_path=None, command_prefix=None):
    """Use absolute, shell-quoted paths so hooks work from other projects."""
    base_command = list(command_prefix) if command_prefix is not None else [
        str(Path(sys.executable).resolve()),
        str(bridge_path or PROJECT_DIR / "bridge.py"),
    ]
    base_command += [
        "hook",
        "--source",
        source,
        "--runtime",
        str(Path(runtime).expanduser().resolve()),
    ]
    permission_command = shlex.join(base_command + ["--wait", "120"])
    lifecycle_command = shlex.join(base_command)
    hooks = {
        "PermissionRequest": [
            {
                "matcher": "*",
                "hooks": [
                    {
                        "type": "command",
                        "command": permission_command,
                        "timeout": 130,
                    }
                ],
            }
        ]
    }
    for event in LIFECYCLE_EVENTS:
        hooks[event] = [
            {
                "hooks": [
                    {
                        "type": "command",
                        "command": lifecycle_command,
                        "timeout": 2,
                    }
                ]
            }
        ]
    if source == "claude":
        for event in ("PostToolUseFailure", "PostToolBatch", "StopFailure"):
            hooks[event] = [{
                "hooks": [{"type": "command", "command": lifecycle_command, "timeout": 2}],
            }]
        hooks["Notification"] = [{
            "matcher": "permission_prompt",
            "hooks": [{"type": "command", "command": lifecycle_command, "timeout": 2}],
        }]
        hooks["PreToolUse"] = [{
            "matcher": "^AskUserQuestion$",
            "hooks": [{"type": "command", "command": permission_command, "timeout": 130}],
        }, {
            "matcher": "*",
            "hooks": [{"type": "command", "command": shlex.join(base_command + ["--track-tools"]), "timeout": 2}],
        }]
    else:
        hooks["Interrupt"] = [{
            "hooks": [{"type": "command", "command": lifecycle_command, "timeout": 2}],
        }]
        hooks["PreToolUse"] = [{
            "matcher": "(^|[.])(request_user_input|request_user_input_async)$",
            "hooks": [{"type": "command", "command": lifecycle_command, "timeout": 2}],
        }, {
            "matcher": "*",
            "hooks": [{"type": "command", "command": shlex.join(base_command + ["--track-activity"]), "timeout": 2}],
        }]
    return {"hooks": hooks}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", choices=SOURCES, required=True)
    parser.add_argument(
        "--runtime",
        type=Path,
        default=PROJECT_DIR / ".runtime",
        help="IPC directory used by the running companion (default: project .runtime)",
    )
    args = parser.parse_args()
    json.dump(build_config(args.source, args.runtime), sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
