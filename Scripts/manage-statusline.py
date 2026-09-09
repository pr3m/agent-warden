#!/usr/bin/env python3
"""Install, remove or inspect Agent Warden's statusLine wrapper in a Claude Code settings file.

Why this script exists and is not a one-liner in install.sh: the live machine this was written
against has `statusLine.command` pointing at a wrapper the `claude-code-roam` plugin generated —
`roam-wrapped-statusline.sh` — which itself chains the user's own status line *and* carries a
hand-added "redmy heavy-run lock" segment with a comment warning it is lost if the wrapper is ever
regenerated. Uninstalling that plugin deletes the wrapper (and both chained segments) outright.
This script's entire job is to take over that wrapper without regenerating it: read whatever is
there now, swap out only the one line that invoked the plugin's indicator, and copy every other
line through unchanged — including segments this script has never heard of and cannot describe.

Design rules, in order of importance (mirrors Scripts/manage-hooks.py's list; read that file's
docstring too, since this one intentionally does not repeat every rationale it already covers):

1. **Never regenerate from a template when there is something to carry over.** A hand-added
   segment (the heavy-run lock is the concrete example, but the rule is general) has no other copy
   anywhere — it lives only in the wrapper file. Rebuilding the wrapper from a template would
   silently delete it. So: splice one line, copy the rest byte-for-byte.
2. **The replace step touches only lines that identifiably invoke the old roam-plugin indicator.**
   Matching is content-based (a regex over the file the current command points at), not filename or
   path based, so a wrapper the user has since renamed is still recognised and everything else in
   it — however unfamiliar — still survives.
3. **Ownership of statusLine.command is a fixed identity, not a manifest lookup.** Unlike the hook
   emitter, whose install path varies with wherever this repo happens to be checked out, the wrapper
   this script writes always lives at one conventional path (`--wrapper-path`, defaulting to
   `~/.claude/bin/agent-warden-statusline.sh`). "Ours" therefore means "statusLine.command equals
   that path" — a direct, unambiguous comparison that needs no manifest to answer.
4. **The manifest records what to restore, never what to delete.** install-manifest.json is a
   plain file this user's own account can edit. If `uninstall` trusted a path read back out of it
   as the argument to `os.remove`, a tampered or merely stale manifest could nominate an arbitrary
   file the user has permission to delete — a classic confused-deputy bug, and exactly the failure
   requirement 5 of this task calls out. So the manifest's job is restricted to supplying the JSON
   *value* to put back into `statusLine` (a value is not a filesystem operation); the deletion
   target is always the wrapper path this invocation itself computed (its `--wrapper-path` default
   or override), never a string that came back out of a JSON file.
5. **Default to preview.** Unlike manage-hooks.py — which writes unless told `--dry-run` — this
   script defaults to `--dry-run` and requires the explicit `--write` flag to touch anything. The
   file this script edits is executed on every status-line refresh and carries a segment the user
   cannot regenerate if it is lost, so a transformation bug here is far more consequential and far
   easier to miss than a wrong hook entry. `--dry-run`, if given, always wins over `--write` — so a
   caller that always appends `--dry-run` for safety can never be overridden by a stray `--write`
   earlier on the command line.
6. **Always back up settings.json before writing, exactly as manage-hooks.py does** (timestamped,
   collision-proof, original file mode preserved) — copied verbatim rather than imported, since
   these Scripts are each meant to run standalone with only the standard library.

Invoked as `/usr/bin/python3` (project convention; see manage-hooks.py), not `python3` off PATH.
"""

from __future__ import annotations

import argparse
import copy
import datetime
import json
import os
import re
import shlex
import shutil
import stat
import sys

MANIFEST_VERSION = 2  # Must match Scripts/manage-hooks.py's MANIFEST_VERSION: both scripts read
# and write the *same* install-manifest.json, this one adding a "statusLine" section alongside
# hooks' "targets" section. A mismatch would make load_manifest() below treat a perfectly good
# hooks manifest as corrupt and discard it (see load_manifest's docstring) the moment a statusline
# install ran after it — so if manage-hooks.py's version ever changes, this constant must move
# with it in the same commit.

DEFAULT_WRAPPER_PATH = os.path.expanduser("~/.claude/bin/agent-warden-statusline.sh")

# The literal regex requirement from this task's brief, matched per-line against whatever file
# statusLine.command currently points at. Deliberately narrow: it must match the plugin's own
# indicator invocation and nothing else, because every line that does *not* match is copied
# through untouched — that is what preserves a hand-added segment (the heavy-run lock) that this
# script has no other way to know about.
ROAM_INVOCATION_RE = re.compile(r"roam-cli[\"'\s]+indicator|roam-indicator\.sh")

# Known limitation, deliberate: this pattern does not also match our *own* previously-installed
# `aa-roam indicator` line. A re-install therefore carries the aa-roam invocation through
# unchanged rather than refreshing it to a new --roam-bin value (e.g. after the repo moved). That
# trade-off is intentional — the brief specifies this exact regex, twice, as the replace rule, and
# widening it on our own initiative would mean this script no longer does what it was asked to do.
# In ordinary use --roam-bin resolves to the same absolute path on every install anyway (the app
# bundle path from a fixed checkout), so the case this limitation bites is a moved repo checkout,
# not routine reinstall.

WRAPPER_HEADER_ABSENT = """#!/bin/bash
# agent-warden-statusline
# Prints the {badge} indicator for the Claude Code status line. No previous statusLine command
# was configured, so there is nothing else to chain in -- Agent Warden owns this file outright.
# To revert: /usr/bin/python3 Scripts/manage-statusline.py uninstall --settings {settings_path}
"""

WRAPPER_TEMPLATE_ABSENT = WRAPPER_HEADER_ABSENT + """
{indicator_line}
printf '%s' "$INDICATOR"
"""

WRAPPER_TEMPLATE_OTHER = """#!/bin/bash
# agent-warden-statusline
# Composite Claude Code statusLine: calls your original command, then appends the {badge}
# indicator when roam is active. Managed by Agent Warden.
# To revert: /usr/bin/python3 Scripts/manage-statusline.py uninstall --settings {settings_path}

# --- original user statusLine begins ---
ORIG_OUT="$({original_command})"
# --- original user statusLine ends ---

{indicator_line}
if [ -n "$INDICATOR" ]; then
  ORIG_OUT="$ORIG_OUT $INDICATOR"
fi

printf '%s' "$ORIG_OUT"
"""

BADGE = "\U0001F392 roam on"  # 🎒 roam on — matches RoamIndicator.badge (Task 14); used only in
# comments here, never compared against at runtime, so a badge-text change there cannot break
# this script's parsing.


# --------------------------------------------------------------------------- paths


def default_manifest_path() -> str:
    """Identical to manage-hooks.py's function of the same name — this is deliberately the same
    file, not a lookalike, since both scripts record into one shared install-manifest.json."""
    home = os.environ.get("AGENT_ATTENTION_HOME")
    if home:
        return os.path.join(os.path.expanduser(home), "install-manifest.json")
    return os.path.expanduser("~/Library/Application Support/AgentAttention/install-manifest.json")


def build_indicator_line(roam_bin: str) -> str:
    """The replacement for a matched line. Keeps the `INDICATOR=` variable name the plugin used,
    because untouched lines further down the file (`if [ -n "$INDICATOR" ]; then ...`) reference
    it by that name — renaming it would silently break code this script never even looks at."""
    return 'INDICATOR="$(%s indicator 2>/dev/null)"' % shlex.quote(roam_bin)


# --------------------------------------------------------------------------- manifest
# (backup/read_raw/parse_settings/write_settings/load_manifest/save_manifest below are copied
# from manage-hooks.py's implementations, not imported, so this script stays runnable standalone
# exactly like its model — see that file's docstring for the reasoning behind each one.)


def load_manifest(path: str) -> tuple[dict, str]:
    """Returns (manifest, status) where status is "ok", "missing" or "corrupt".

    A "corrupt" or version-mismatched manifest is treated as empty rather than partially trusted:
    if we cannot verify its shape we cannot safely tell ours from anyone else's, in either the
    hooks section or ours, so we say so (via the returned status) and the caller decides whether
    that is fatal for what it is about to do.
    """
    empty = {"version": MANIFEST_VERSION, "targets": {}, "statusLine": {}}
    if not os.path.exists(path):
        return empty, "missing"
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (json.JSONDecodeError, OSError):
        return empty, "corrupt"
    if not isinstance(data, dict) or data.get("version") != MANIFEST_VERSION:
        return empty, "corrupt"
    data.setdefault("targets", {})
    data.setdefault("statusLine", {})
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


def manifest_is_empty(manifest: dict) -> bool:
    """True once every section but "version" is empty.

    Used only to decide whether this script may delete install-manifest.json outright on
    uninstall. Known residual risk, not fixed here because it lives in a file this task does not
    touch: manage-hooks.py's own uninstall path deletes the file whenever ITS "targets" section
    empties out, without checking this script's "statusLine" section first — so a hooks uninstall
    run after a statusline install can still delete this section's record out from under it. This
    script itself never makes that mistake (it checks every section), but it cannot fix the other
    script's blind spot without editing a file outside this task's scope. Recorded in the task
    report as a follow-up.
    """
    return not any(bool(value) for key, value in manifest.items() if key != "version")


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


def write_wrapper(path: str, content: str) -> None:
    """Atomic write of the generated wrapper, then made executable.

    Executable because Claude Code runs `statusLine.command` directly; a wrapper written without
    the exec bit would fail silently on every status-line refresh — worse than the check it
    replaces, since a broken status line is not necessarily what the user is looking at, but not
    having "🎒 roam on" fail-safe (blank rather than error) is small consolation for the *rest* of
    the line — the directory/branch/model/ctx% segments — also going blank.
    """
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    temporary = os.path.join(directory, f".agent-warden-statusline-{os.getpid()}.tmp")
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write(content)
    os.chmod(temporary, 0o755)
    os.replace(temporary, path)


# --------------------------------------------------------------------------- classification


def resolve_command_path(command: str) -> str | None:
    """The on-disk file `command`'s first token points at, if any.

    statusLine.command is a shell command string, not necessarily a bare path — but every wrapper
    this project or the roam plugin has ever generated is a plain absolute path with no
    arguments, so taking the first shell token is enough to find it without a full shell parse.
    Returns None (rather than raising) for anything that is not a plain, existing, readable file:
    an inline one-liner, a missing path, or a malformed command string are all "nothing to splice
    on top of" as far as this script is concerned, and installing over them falls back to wrapping
    the whole command instead (see build_wrapper).
    """
    try:
        tokens = shlex.split(command)
    except ValueError:
        return None
    if not tokens:
        return None
    candidate = os.path.abspath(os.path.expanduser(os.path.expandvars(tokens[0])))
    return candidate if os.path.isfile(candidate) else None


def read_text(path: str) -> str | None:
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError:
        return None


def classify(settings: dict, wrapper_path: str) -> tuple[str, str | None, str | None]:
    """Returns (label, command, resolved_script_path).

    label is one of "absent", "ours", "roam-plugin", "other" — see the module docstring, rule 3,
    for why "ours" is a direct path comparison rather than a manifest lookup. `resolved_script_path`
    is set only when `command` points at a file we could actually read, since that is the one case
    install() can splice on top of rather than wrap from a template.
    """
    status_line = settings.get("statusLine")
    command = None
    if isinstance(status_line, dict):
        raw_command = status_line.get("command")
        if isinstance(raw_command, str) and raw_command.strip():
            command = raw_command

    if command is None:
        return "absent", None, None

    resolved = resolve_command_path(command)
    direct_path = os.path.abspath(os.path.expanduser(os.path.expandvars(command)))
    if direct_path == wrapper_path or resolved == wrapper_path:
        return "ours", command, resolved

    if resolved is not None:
        content = read_text(resolved)
        if content is not None and ROAM_INVOCATION_RE.search(content):
            return "roam-plugin", command, resolved

    return "other", command, resolved


def splice_indicator(original_text: str, roam_bin: str) -> tuple[str, int]:
    """Copy every line verbatim except the ones matching ROAM_INVOCATION_RE, which are replaced
    with the aa-roam equivalent. This is the whole mechanism that preserves an unfamiliar
    hand-added segment: it is never parsed, classified, or reasoned about — only left alone."""
    replacement = build_indicator_line(roam_bin)
    lines = original_text.splitlines(keepends=True)
    replaced = 0
    output: list[str] = []
    for line in lines:
        if ROAM_INVOCATION_RE.search(line):
            newline = "\n" if line.endswith("\n") else ""
            output.append(replacement + newline)
            replaced += 1
        else:
            output.append(line)
    return "".join(output), replaced


def build_wrapper(label: str, resolved_script_path: str | None, original_command: str | None,
                   roam_bin: str, settings_path: str) -> str:
    """Never regenerates from a template when there is a file to carry over (rule 1). Splicing is
    used only for "roam-plugin" and "ours" — the two labels classify() only assigns once it has
    already found a line matching ROAM_INVOCATION_RE (or, for "ours", the file at our own fixed
    wrapper_path) in that file, so there is guaranteed to be at least one line to replace. A
    generic "other" script is not guaranteed to contain any such line — splicing it would silently
    copy the file through with no indicator ever added, which is a worse failure than a bug in the
    fixture-testing sense: it would look like a successful install while doing nothing. So "other"
    (and "absent") always go through a template that explicitly appends the indicator, whether or
    not the current command happens to resolve to a real, readable file."""
    if label in ("roam-plugin", "ours") and resolved_script_path is not None:
        original_text = read_text(resolved_script_path)
        if original_text is not None:
            new_text, _replaced = splice_indicator(original_text, roam_bin)
            return new_text

    if label == "absent":
        return WRAPPER_TEMPLATE_ABSENT.format(
            badge=BADGE, settings_path=settings_path, indicator_line=build_indicator_line(roam_bin)
        )

    return WRAPPER_TEMPLATE_OTHER.format(
        badge=BADGE,
        settings_path=settings_path,
        original_command=original_command or "",
        indicator_line=build_indicator_line(roam_bin),
    )


# --------------------------------------------------------------------------- main


def do_check(settings: dict, wrapper_path: str) -> int:
    label, _command, _resolved = classify(settings, wrapper_path)
    print(label)
    return 0


def do_install(args: argparse.Namespace, settings_path: str, manifest_path: str,
                wrapper_path: str, raw: str | None, settings: dict) -> int:
    if not args.roam_bin:
        print("error: --roam-bin is required for install", file=sys.stderr)
        return 1
    roam_bin = os.path.abspath(os.path.expanduser(args.roam_bin))
    if not os.path.exists(roam_bin):
        print(f"error: {roam_bin} does not exist — build the app first (Scripts/build-app.sh)",
              file=sys.stderr)
        return 1

    label, command, resolved = classify(settings, wrapper_path)
    wrapper_text = build_wrapper(label, resolved, command, roam_bin, settings_path)

    do_write = args.write and not args.dry_run
    if not do_write:
        sys.stdout.write(wrapper_text)
        print(f"\n(dry run — {settings_path} and {wrapper_path} unchanged; "
              f"current statusLine classified as '{label}')", file=sys.stderr)
        return 0

    # Load the manifest *before* touching settings, so a reinstall over our own previous install
    # ("ours") can carry the true pre-Warden value forward instead of clobbering it. Without this,
    # reinstalling would read the CURRENT statusLine — which by definition is already our own
    # wrapper when label is "ours" — and record that as "previousStatusLine", so a later uninstall
    # would restore Warden's wrapper right back rather than reverting to what the user had before
    # Warden ever touched the file. This mirrors how manage-hooks.py threads its own `created`
    # bookkeeping through `previous.get("created")` across repeated installs (see add_ours there).
    manifest, manifest_status = load_manifest(manifest_path)
    existing_entry = manifest.get("statusLine", {}).get(settings_path)
    if label == "ours" and isinstance(existing_entry, dict) and "previousStatusLine" in existing_entry:
        previous_status_line = copy.deepcopy(existing_entry["previousStatusLine"])
    else:
        previous_status_line = copy.deepcopy(settings.get("statusLine"))

    new_status_line = dict(settings.get("statusLine")) if isinstance(settings.get("statusLine"), dict) else {}
    new_status_line.setdefault("type", "command")
    new_status_line["command"] = wrapper_path
    settings["statusLine"] = new_status_line

    saved = backup(settings_path)
    write_settings(settings_path, settings, raw)
    write_wrapper(wrapper_path, wrapper_text)

    manifest["statusLine"][settings_path] = {
        "installedAt": datetime.datetime.now().astimezone().isoformat(),
        "roamBin": roam_bin,
        "backupPath": saved,
        # Informational only — never read back as a deletion or restoration TARGET. See rule 4
        # in the module docstring. Restoration uses previousStatusLine below; deletion always uses
        # this invocation's own --wrapper-path, never a value out of this file.
        "wrapperPath": wrapper_path,
        "previousStatusLine": previous_status_line,
    }
    save_manifest(manifest_path, manifest)

    print(f"backup        : {saved or '(no previous settings file)'}")
    print(f"settings      : {settings_path}")
    print(f"manifest      : {manifest_path}  ({manifest_status})")
    print(f"wrapper       : {wrapper_path}")
    print(f"roam binary   : {roam_bin}")
    print(f"previous state: {label}")
    return 0


def do_uninstall(args: argparse.Namespace, settings_path: str, manifest_path: str,
                  wrapper_path: str, raw: str | None, settings: dict) -> int:
    manifest, manifest_status = load_manifest(manifest_path)
    entry = manifest.get("statusLine", {}).get(settings_path)
    if not isinstance(entry, dict):
        print(f"nothing of ours recorded for {settings_path} (manifest {manifest_status})")
        return 0

    status_line = settings.get("statusLine")
    current_command = status_line.get("command") if isinstance(status_line, dict) else None
    if current_command != wrapper_path:
        print(
            f"error: current statusLine.command is not ours (expected {wrapper_path!r}, found "
            f"{current_command!r}). Refusing to restore blindly. Nothing changed.",
            file=sys.stderr,
        )
        return 1

    previous_status_line = entry.get("previousStatusLine")

    do_write = args.write and not args.dry_run
    if not do_write:
        print(f"(dry run — would restore statusLine to: {json.dumps(previous_status_line)})")
        print(f"(dry run — would remove wrapper at {wrapper_path})")
        return 0

    if previous_status_line is None:
        settings.pop("statusLine", None)
    else:
        settings["statusLine"] = previous_status_line

    saved = backup(settings_path)
    write_settings(settings_path, settings, raw)

    # The deletion target is this invocation's own computed wrapper_path — never anything read
    # back out of `entry` — per rule 4 in the module docstring.
    removed_wrapper = False
    if os.path.isfile(wrapper_path):
        os.remove(wrapper_path)
        removed_wrapper = True

    manifest["statusLine"].pop(settings_path, None)
    if manifest_is_empty(manifest):
        if os.path.exists(manifest_path):
            os.remove(manifest_path)
    else:
        save_manifest(manifest_path, manifest)

    print(f"backup        : {saved}")
    print(f"settings      : {settings_path}")
    print(f"restored      : statusLine {'removed (was absent before install)' if previous_status_line is None else 'restored'}")
    print(f"wrapper       : {'removed ' + wrapper_path if removed_wrapper else '(already absent) ' + wrapper_path}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=["check", "install", "uninstall"])
    parser.add_argument("--settings", default=os.path.expanduser("~/.claude/settings.json"))
    parser.add_argument(
        "--wrapper-path",
        default=DEFAULT_WRAPPER_PATH,
        help="where the generated wrapper is written/removed (override only to test against a "
             "scratch settings file without touching the real ~/.claude/bin)",
    )
    parser.add_argument("--roam-bin", default=None, help="absolute path to the aa-roam binary (install only)")
    parser.add_argument("--manifest", default=None, help="ownership record (defaults under AGENT_ATTENTION_HOME)")
    parser.add_argument("--write", action="store_true", help="actually write changes (default: preview only)")
    parser.add_argument("--dry-run", action="store_true",
                         help="preview only, no changes — the default even without this flag; "
                              "always wins over --write when both are given")
    args = parser.parse_args()

    settings_path = os.path.abspath(os.path.expanduser(args.settings))
    manifest_path = os.path.abspath(os.path.expanduser(args.manifest or default_manifest_path()))
    wrapper_path = os.path.abspath(os.path.expanduser(args.wrapper_path))

    raw = read_raw(settings_path)
    try:
        settings = parse_settings(raw)
    except json.JSONDecodeError as error:
        print(f"error: {settings_path} is not valid JSON ({error}). Nothing was changed.", file=sys.stderr)
        return 1
    if not isinstance(settings, dict):
        print(f"error: {settings_path} does not contain a JSON object. Nothing was changed.", file=sys.stderr)
        return 1

    if args.action == "check":
        return do_check(settings, wrapper_path)
    if args.action == "install":
        return do_install(args, settings_path, manifest_path, wrapper_path, raw, settings)
    return do_uninstall(args, settings_path, manifest_path, wrapper_path, raw, settings)


if __name__ == "__main__":
    raise SystemExit(main())
