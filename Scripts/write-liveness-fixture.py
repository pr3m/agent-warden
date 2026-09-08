#!/usr/bin/env python3
"""Write a state.json with three sessions whose process states are known in advance.

Used by the smoke test so tri-state liveness is covered deterministically. The collector's own
liveness legitimately depends on who invoked it — a hook fired outside Claude Code has no Claude
ancestor to identify, so its `process` is "unidentified" — which makes it useless as an assertion.
This fixture pins all three answers instead:

  live  — a pid that certainly exists (passed in)   -> alive
  gone  — a pid that certainly does not             -> dead
  anon  — no pid recorded at all                    -> unidentified

Deliberately omits `claudePIDStartedAt`, so existence alone decides and no clock reading is needed.

  write-liveness-fixture.py <state.json path> <live pid>
"""

from __future__ import annotations

import datetime
import json
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    path, live_pid = sys.argv[1], int(sys.argv[2])
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000+00:00")

    def identity(name: str, pid: int | None) -> dict:
        record = {"sessionID": f"fixture-{name}", "cwd": f"/tmp/fixture/{name}"}
        if pid is not None:
            record["claudePID"] = pid
        return record

    cases = [("live", live_pid), ("gone", 999999), ("anon", None)]

    json.dump(
        {
            "version": 2,
            "items": [
                {
                    "id": f"item-{name}",
                    "sessionID": f"fixture-{name}",
                    "episodeID": f"ep-{name}",
                    "kind": "approval",
                    "source": "explicit",
                    "detail": "fixture",
                    "firstSeenAt": now,
                    "lastSeenAt": now,
                    "occurrences": 1,
                    "identity": identity(name, pid),
                }
                for name, pid in cases
            ],
            "sessions": {
                f"fixture-{name}": {
                    "identity": identity(name, pid),
                    "activity": "awaitingUser",
                    "lastEventAt": now,
                    "lastActivityAt": now,
                    "episodeID": f"ep-{name}",
                    "episodeDismissed": False,
                }
                for name, pid in cases
            },
            "recentEventIDs": [],
            "savedAt": now,
        },
        open(path, "w"),
    )
    print(f"fixture written: live pid {live_pid}, dead pid 999999, one with no pid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
