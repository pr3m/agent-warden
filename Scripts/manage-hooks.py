#!/usr/bin/env python3
"""Install, remove or inspect the Agent Warden hook entries in a Claude Code settings file.

Design rules, in order of importance:

1. **Never lose an existing hook.** Entries that are not ours are copied through untouched, in
   their original order, and so are the groups that contain them — including groups we emptied,
   because a group we did not create is not ours to delete.
2. **Always back up before writing**, to a filename that cannot collide, preserving the original
   file's permissions, and refuse to write if the file changed underneath us since we read it.
3. **Only remove what we added.** Ownership comes from the manifest: an exact match against the
   command strings recorded there. There is no fallback that infers ownership from a binary's
   name — a hook of yours that runs a *different* executable also called `aa-emit`, with different
   arguments, is not ours and is never touched. Without a manifest we do not know what is ours, so
   we say so and change nothing.
4. **Scope ownership to one settings file.** The manifest is keyed by target path, so installing
   into a project settings file cannot make uninstall forget the user-level one.
5. **Be idempotent.** Installing twice leaves exactly one set of entries.

The installed entries carry the classification as an argument (`--signal` / `--kind`), decided by
Claude Code's own matcher. That keeps the app working even if payload field names change upstream.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import shlex
import shutil
import stat
import sys

# (event, matcher, arguments). A matcher of None means the event has only one meaning for us.
#
# PreToolUse is narrowed on purpose: unmatched it would fire on every single tool call, doubling
# the processes we spawn, while adding nothing PostToolUse does not already give us as a heartbeat.
#
# Notification is split by type rather than classified from the payload, so that the thing deciding
# what a notification means is Claude Code's own matcher.
HOOK_ENTRIES = [
    ("SessionStart", None, ["--signal", "sessionStart"]),
    ("SessionEnd", None, ["--signal", "sessionEnd"]),
    ("UserPromptSubmit", None, ["--signal", "activity"]),
    ("PostToolUse", None, ["--signal", "activity"]),
    ("PostToolUseFailure", None, ["--signal", "activity"]),
    ("SubagentStop", None, ["--signal", "activity"]),
    ("PreToolUse", "AskUserQuestion", ["--kind", "question"]),
    ("PreToolUse", "ExitPlanMode", ["--kind", "stageDecision"]),
    ("PermissionRequest", None, ["--kind", "approval"]),
    ("Notification", "permission_prompt", ["--kind", "approval"]),
    ("Notification", "idle_prompt", ["--kind", "idle"]),
    ("Notification", "agent_needs_input", ["--kind", "question"]),
    ("Notification", "elicitation_dialog|elicitation_url_dialog", ["--kind", "question"]),
    ("Notification", "agent_completed", ["--kind", "workComplete"]),
    ("Stop", None, ["--kind", "workComplete"]),
    ("StopFailure", None, ["--kind", "error"]),
]

EMITTER_NAME = "aa-emit"
HOOK_TIMEOUT = 5
MANIFEST_VERSION = 2


# --------------------------------------------------------------------------- paths


def default_manifest_path() -> str:
    home = os.environ.get("AGENT_ATTENTION_HOME")
    if home:
        return os.path.join(os.path.expanduser(home), "install-manifest.json")
    return os.path.expanduser("~/Library/Application Support/AgentAttention/install-manifest.json")


def command_string(emit_path: str, arguments: list[str]) -> str:
    """A single shell command string, with the path quoted the way `shlex.quote` does."""
    return " ".join([shlex.quote(emit_path)] + arguments)


# --------------------------------------------------------------------------- manifest


def load_manifest(path: str) -> tuple[dict, str]:
    """Returns (manifest, status) where status is "ok", "missing" or "corrupt".

    The distinction matters: "missing" and "corrupt" both mean we cannot know what is ours, and
    that has to be said out loud rather than papered over with a guess.
    """
    empty = {"version": MANIFEST_VERSION, "targets": {}}
    if not os.path.exists(path):
        return empty, "missing"
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (json.JSONDecodeError, OSError):
        return empty, "corrupt"
    if not isinstance(data, dict) or data.get("version") != MANIFEST_VERSION:
        # An older or unrecognised manifest tells us nothing reliable about ownership.
        return empty, "corrupt"
    data.setdefault("targets", {})
    return data, "ok"


def save_manifest(path: str, manifest: dict) -> None:
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, mode=0o700, exist_ok=True)
    temporary = f"{path}.tmp-{os.getpid()}"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def owned_commands(manifest: dict, settings_path: str) -> set[str]:
    target = manifest.get("targets", {}).get(os.path.abspath(settings_path))
    if not isinstance(target, dict):
        return set()
    return {entry["command"] for entry in target.get("entries", []) if isinstance(entry, dict) and "command" in entry}


# --------------------------------------------------------------------------- settings io


def read_raw(path: str) -> str | None:
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def parse_settings(raw: str | None) -> dict:
    if raw is None or not raw.strip():
        return {}
    return json.loads(raw)


def backup(path: str) -> str | None:
    """Timestamped, collision-proof, and with the original file's mode preserved."""
    if not os.path.exists(path):
        return None
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    candidate = f"{path}.agent-warden-backup-{stamp}"
    suffix = 1
    while os.path.exists(candidate):
        candidate = f"{path}.agent-warden-backup-{stamp}-{suffix}"
        suffix += 1
    shutil.copy2(path, candidate)
    os.chmod(candidate, stat.S_IMODE(os.stat(path).st_mode))
    return candidate


def write_settings(path: str, settings: dict, expected_raw: str | None) -> None:
    """Write, but only if nobody else changed the file while we were working."""
    current = read_raw(path)
    if current != expected_raw:
        raise SystemExit(
            f"error: {path} changed while this script was running. Nothing was written — "
            "re-run to pick up the new contents."
        )

    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    mode = stat.S_IMODE(os.stat(path).st_mode) if os.path.exists(path) else 0o600
    temporary = os.path.join(directory, f".agent-warden-write-{os.getpid()}.tmp")
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(settings, handle, indent=2)
        handle.write("\n")
    os.chmod(temporary, mode)
    os.replace(temporary, path)


# --------------------------------------------------------------------------- ownership


def entry_is_ours(entry: object, commands: set[str]) -> bool:
    """Exact command match only.

    A substring test would delete a hook of yours that merely mentions the emitter — a wrapper
    script living under a directory called `aa-emit`, or an `echo "aa-emit installed"`. Those are
    somebody else's hooks and they stay.
    """
    return isinstance(entry, dict) and isinstance(entry.get("command"), str) and entry["command"] in commands


def unowned_candidates(settings: dict, owned: set[str]) -> set[str]:
    """Commands that *look* like an emitter but are not recorded as ours.

    Reporting only. This is deliberately never used to decide what to delete: a basename is not
    ownership. `/tmp/unrelated-tool/aa-emit --custom` is somebody else's binary that happens to
    share a name, and removing it would be exactly the bug this exists to prevent.
    """
    found = set()
    for groups in (settings.get("hooks") or {}).values():
        if not isinstance(groups, list):
            continue
        for group in groups:
            if not isinstance(group, dict):
                continue
            for entry in group.get("hooks") or []:
                if not isinstance(entry, dict):
                    continue
                command = entry.get("command")
                if not isinstance(command, str):
                    continue
                try:
                    tokens = shlex.split(command)
                except ValueError:
                    continue
                if tokens and os.path.basename(tokens[0]) == EMITTER_NAME and command not in owned:
                    found.add(command)
    return found


def strip_ours(settings: dict, commands: set[str], created: dict | None = None) -> int:
    """Remove our entries.

    Structures we did not author stay exactly as they were — a group somebody else wrote keeps
    existing even once our entry is gone from it, and an `"Stop": []` or a `"hooks": {}` that was
    already in the file is left alone. Only keys recorded as created by *our* install are cleared
    away, which is what makes uninstall restore the file byte for byte.
    """
    created = created or {}
    created_events = set(created.get("events", []))
    created_hooks_key = bool(created.get("hooksKey"))

    hooks = settings.get("hooks")
    if not isinstance(hooks, dict) or not commands:
        return 0

    removed = 0
    for event in list(hooks.keys()):
        groups = hooks.get(event)
        if not isinstance(groups, list):
            continue
        kept_groups = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                kept_groups.append(group)
                continue
            entries = group["hooks"]
            kept = [entry for entry in entries if not entry_is_ours(entry, commands)]
            removed += len(entries) - len(kept)
            if len(kept) == len(entries):
                kept_groups.append(group)  # untouched
                continue
            if not kept and set(group.keys()) <= {"matcher", "hooks"} and len(entries) == 1:
                # A single-entry group in exactly the shape we write: ours, drop the whole thing.
                continue
            # Somebody else's group that happened to contain our entry: keep the group.
            group["hooks"] = kept
            kept_groups.append(group)
        hooks[event] = kept_groups
        if not kept_groups and event in created_events:
            del hooks[event]

    if not hooks and created_hooks_key:
        settings.pop("hooks", None)
    return removed


def add_ours(settings: dict, emit_path: str) -> tuple[list[dict], dict]:
    created_hooks_key = "hooks" not in settings
    hooks = settings.setdefault("hooks", {})
    created_events: list[str] = []
    recorded = []
    for event, matcher, arguments in HOOK_ENTRIES:
        if event not in hooks:
            created_events.append(event)
        groups = hooks.setdefault(event, [])
        if not isinstance(groups, list):
            raise SystemExit(
                f"error: hooks.{event} is a {type(groups).__name__}, not a list — refusing to touch "
                "it. Fix the settings file by hand and re-run."
            )
        command = command_string(emit_path, arguments)
        group: dict = {}
        if matcher:
            group["matcher"] = matcher
        group["hooks"] = [{"type": "command", "command": command, "timeout": HOOK_TIMEOUT}]
        groups.append(group)
        recorded.append({"event": event, "matcher": matcher, "command": command})
    return recorded, {"events": created_events, "hooksKey": created_hooks_key}


def count_ours(settings: dict, commands: set[str]) -> dict:
    found: dict[str, int] = {}
    for event, groups in (settings.get("hooks") or {}).items():
        if not isinstance(groups, list):
            continue
        total = sum(
            1
            for group in groups
            if isinstance(group, dict)
            for entry in (group.get("hooks") or [])
            if entry_is_ours(entry, commands)
        )
        if total:
            found[event] = total
    return found


# --------------------------------------------------------------------------- main


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=["install", "uninstall", "status"])
    parser.add_argument("--settings", default=os.path.expanduser("~/.claude/settings.json"))
    parser.add_argument("--emit-path", help="absolute path to the aa-emit binary (install only)")
    parser.add_argument("--manifest", default=None, help="ownership record (defaults under AGENT_ATTENTION_HOME)")
    parser.add_argument("--dry-run", action="store_true", help="print what would change and exit")
    args = parser.parse_args()

    settings_path = os.path.abspath(os.path.expanduser(args.settings))
    manifest_path = os.path.abspath(os.path.expanduser(args.manifest or default_manifest_path()))

    raw = read_raw(settings_path)
    try:
        settings = parse_settings(raw)
    except json.JSONDecodeError as error:
        print(f"error: {settings_path} is not valid JSON ({error}). Nothing was changed.", file=sys.stderr)
        return 1
    if not isinstance(settings, dict):
        print(f"error: {settings_path} does not contain a JSON object. Nothing was changed.", file=sys.stderr)
        return 1

    manifest, manifest_status = load_manifest(manifest_path)
    known = owned_commands(manifest, settings_path)
    candidates = unowned_candidates(settings, known)

    if args.action == "status":
        events = sorted((settings.get("hooks") or {}).keys())
        print(f"settings file : {settings_path}")
        print(f"manifest      : {manifest_path}  ({manifest_status})")
        print(f"hook events   : {', '.join(events) if events else '(none)'}")
        print(f"our entries   : {count_ours(settings, known) or '(none owned here)'}")
        print(f"owned commands: {len(known)} recorded for this settings file")
        if candidates:
            # Named, but explicitly not claimed. These will never be removed by this script.
            print(f"unowned lookalikes: {len(candidates)} command(s) run something called "
                  f"{EMITTER_NAME} but are not recorded as ours and will not be touched:")
            for command in sorted(candidates):
                print(f"  - {command}")
        return 0

    if args.action == "install":
        if not args.emit_path:
            print("error: --emit-path is required for install", file=sys.stderr)
            return 1
        emit_path = os.path.abspath(os.path.expanduser(args.emit_path))
        if not os.path.exists(emit_path):
            print(f"error: {emit_path} does not exist — run Scripts/build-app.sh first", file=sys.stderr)
            return 1
        if os.path.basename(emit_path) != EMITTER_NAME:
            print(
                f"error: refusing to install {emit_path}: the binary must be named {EMITTER_NAME} "
                "so uninstall can identify it without a manifest",
                file=sys.stderr,
            )
            return 1

        # What this install is about to write. An existing entry that is byte-identical to one of
        # these is not a guess about ownership — it is literally the command we are installing, so
        # replacing it is what keeps a second install idempotent.
        planned = {command_string(emit_path, arguments) for _, _, arguments in HOOK_ENTRIES}
        removable = known | (candidates & planned)
        surviving = candidates - planned

        previous = manifest.get("targets", {}).get(settings_path, {})
        removed = strip_ours(settings, removable, previous.get("created"))
        recorded, created = add_ours(settings, emit_path)

        if args.dry_run:
            print(json.dumps(settings.get("hooks", {}), indent=2))
            print(f"\n(dry run — {settings_path} unchanged; would replace {removed} existing entries)")
            return 0

        saved = backup(settings_path)
        write_settings(settings_path, settings, raw)

        manifest["targets"][settings_path] = {
            "installedAt": datetime.datetime.now().astimezone().isoformat(),
            "emitPath": emit_path,
            "backupPath": saved,
            "entries": recorded,
            "created": created,
        }
        save_manifest(manifest_path, manifest)

        print(f"backup        : {saved or '(no previous settings file)'}")
        print(f"settings      : {settings_path}")
        print(f"manifest      : {manifest_path}")
        print(f"hook command  : {command_string(emit_path, ['--signal', '…'])}")
        print(f"entries wired : {len(recorded)} across {len({e['event'] for e in recorded})} events")
        if removed:
            print(f"replaced      : {removed} previous Agent Warden entries")
        if surviving:
            print(f"left alone    : {len(surviving)} command(s) named {EMITTER_NAME} that are not ours:")
            for command in sorted(surviving):
                print(f"  - {command}")
        return 0

    # uninstall — manifest only. No inference, in either direction.
    if not known:
        if candidates:
            print(
                f"error: no ownership record for {settings_path} (manifest {manifest_status}), but "
                f"{len(candidates)} hook command(s) run something called {EMITTER_NAME}:",
                file=sys.stderr,
            )
            for command in sorted(candidates):
                print(f"  - {command}", file=sys.stderr)
            print(
                "Refusing to guess which of those are ours. Nothing was changed. Restore the "
                "manifest, or remove the entries by hand.",
                file=sys.stderr,
            )
            return 1
        print(f"nothing of ours recorded for {settings_path} (manifest {manifest_status})")
        return 0

    created = manifest.get("targets", {}).get(settings_path, {}).get("created")
    removed = strip_ours(settings, known, created)
    if args.dry_run:
        print(f"(dry run — would remove {removed} entries from {settings_path})")
        return 0

    if removed == 0:
        print(f"nothing to remove from {settings_path}")
    else:
        saved = backup(settings_path)
        write_settings(settings_path, settings, raw)
        print(f"backup        : {saved}")
        print(f"removed       : {removed} Agent Warden hook entries")
        print(f"settings      : {settings_path}")
    if candidates:
        print(f"left alone    : {len(candidates)} command(s) named {EMITTER_NAME} that are not ours")

    # Only forget ownership of *this* target; another settings file may still be installed.
    manifest.get("targets", {}).pop(settings_path, None)
    if manifest.get("targets"):
        save_manifest(manifest_path, manifest)
    elif os.path.exists(manifest_path):
        os.remove(manifest_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
