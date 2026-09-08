#!/usr/bin/env python3
"""Write or remove Agent Warden's login item, with ownership decided by parsing the plist.

A `grep` for the label is not ownership: it matches a comment, a different key, or somebody else's
agent that merely mentions ours. This parses the file and requires an exact match on both `Label`
and `ProgramArguments` before it will overwrite or delete anything.

  launch-agent.py write  <plist> <label> <program>
  launch-agent.py remove <plist> <label> <program>
  launch-agent.py check  <plist> <label> <program>

Exit codes: 0 done (or nothing to do), 1 refused — the file exists and is not ours.
Adds no permissions and no new prompts; a launch agent plist is an ordinary file in the user's
own LaunchAgents directory.
"""

from __future__ import annotations

import os
import plistlib
import sys


def ownership(path: str, label: str, program: str) -> str:
    """"absent", "ours" or "foreign"."""
    if not os.path.exists(path):
        return "absent"
    try:
        with open(path, "rb") as handle:
            data = plistlib.load(handle)
    except Exception:
        # Unparseable is not ours to delete.
        return "foreign"
    if not isinstance(data, dict):
        return "foreign"
    if data.get("Label") != label:
        return "foreign"
    if data.get("ProgramArguments") != [program]:
        return "foreign"
    return "ours"


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    action, path, label, program = sys.argv[1:5]
    state = ownership(path, label, program)

    if action == "check":
        print(state)
        return 0

    if state == "foreign":
        print(
            f"error: {path} exists and is not ours (expected Label {label!r} and "
            f"ProgramArguments [{program!r}]). Refusing to touch it.",
            file=sys.stderr,
        )
        return 1

    if action == "write":
        os.makedirs(os.path.dirname(path), exist_ok=True)
        temporary = f"{path}.tmp-{os.getpid()}"
        with open(temporary, "wb") as handle:
            plistlib.dump(
                {
                    "Label": label,
                    "ProgramArguments": [program],
                    "RunAtLoad": True,
                    "KeepAlive": False,
                    "ProcessType": "Interactive",
                },
                handle,
            )
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
        print(f"wrote {path}")
        return 0

    if action == "remove":
        if state == "absent":
            print("no login item to remove")
            return 0
        os.remove(path)
        print(f"removed {path}")
        return 0

    print(f"unknown action {action!r}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
