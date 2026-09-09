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
   it — however unfamiliar — still survives. A line that merely *mentions* the invocation in a
   comment is not touched either (see splice_indicator) — only a line that would actually run it.
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
7. **Warden's own wrapper path is never a valid original command and never a valid restore
   target.** It is the file this script writes, so chaining it produces a wrapper that invokes
   itself on every status-line refresh, and restoring to it points statusLine.command at a file
   the same uninstall then deletes. Both were real, both were silent, and both are now refused —
   see `points_at_wrapper`, which is the single test all three enforcement points share.

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

# The third case, and the only one that exists because of a failure rather than a starting state:
# statusLine.command already points at OUR wrapper path, but that file is gone. There is nothing
# to splice and — this is the whole point — nothing to chain, because the only thing the command
# names is the file about to be written. Chaining it would make the wrapper call itself.
WRAPPER_TEMPLATE_RECOVERED = """#!/bin/bash
# agent-warden-statusline
# Prints the {badge} indicator for the Claude Code status line.
#
# REBUILT, NOT MIGRATED. statusLine.command already pointed here when this ran, but this file
# was missing, so there was nothing to carry over -- any command this wrapper used to chain is
# not recoverable from it. If your status line is now shorter than it was, the previous
# statusLine value is in install-manifest.json and the previous settings.json is in one of the
# timestamped .agent-warden-backup-* files beside {settings_path}.
# To revert: /usr/bin/python3 Scripts/manage-statusline.py uninstall --settings {settings_path}

{indicator_line}
printf '%s' "$INDICATOR"
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


def points_at_wrapper(command, wrapper_path: str) -> bool:
    """Does this statusLine command name OUR OWN wrapper?

    **This is the one safety invariant of this script**, and the reason it is a named function
    used from three places rather than an inline comparison written three ways: Warden's wrapper
    path is never a valid "original command" to chain, and never a valid target to restore
    statusLine.command to. Both mistakes were real and both are silent:

    - Chaining it generates `ORIG_OUT="$(.../agent-warden-statusline.sh)"` *inside*
      `.../agent-warden-statusline.sh` — a wrapper that invokes itself, unbounded, on every
      status-line refresh.
    - Restoring it puts the user's statusLine back to a path this same uninstall is about to
      delete, and prints "restored" while doing it.

    Deliberately answered WITHOUT touching the filesystem. `resolve_command_path` returns None for
    a path that does not exist, and "our wrapper is missing" is exactly the case both bugs need,
    so a check that depends on the file being there would miss both.

    Three spellings, widest to narrowest, because a false positive here is harmless and a false
    negative is the bug:

    1. The whole command string as a path — a bare path, which is what every wrapper this project
       and the roam plugin generate.
    2. **Every** shell token expanded as a path, not just the first. `bash <wrapper_path>` and
       `/usr/bin/env sh ~/.claude/bin/agent-warden-statusline.sh` both invoke us with our path in
       argument position, and a first-token check calls them somebody else's command.
    3. The raw wrapper path as a substring, for anything hidden inside a quoted `sh -c '...'`.

    Being wrong in the "yes, that is us" direction costs nothing: the command is not chained (a
    wrapper that says so is generated instead) and it is not recorded as a restore target. Being
    wrong the other way is a wrapper that calls itself forever.
    """
    if isinstance(command, dict):
        command = command.get("command")
    if not isinstance(command, str) or not command.strip():
        return False

    def as_path(text: str) -> str:
        return os.path.abspath(os.path.expanduser(os.path.expandvars(text)))

    if as_path(command) == wrapper_path:
        return True
    if wrapper_path in command:
        return True
    try:
        tokens = shlex.split(command)
    except ValueError:
        return False
    return any(as_path(token) == wrapper_path for token in tokens)


def classify(settings: dict, wrapper_path: str) -> tuple[str, str | None, str | None]:
    """Returns (label, command, resolved_script_path).

    label is one of "absent", "ours", "roam-plugin", "other" — see the module docstring, rule 3,
    for why "ours" is a direct path comparison rather than a manifest lookup. `resolved_script_path`
    is set only when `command` points at a file we could actually read, since that is the one case
    install() can splice on top of rather than wrap from a template.

    A `statusLine` that is present but not the documented `{"type": ..., "command": ...}` shape —
    a bare string is the case actually seen — must NOT collapse to "absent". "absent" tells
    build_wrapper() there was truly nothing before, so it writes WRAPPER_TEMPLATE_ABSENT, whose
    comment says outright "no previous statusLine command was configured" — discarding whatever
    value the user's live footer was actually built from and lying about it in the file that
    replaces it. A truthy non-dict value is something, not nothing, so its own string form is
    used as `command` and flows through the exact same ours/roam-plugin/other checks below —
    if it happens to equal our wrapper path or a roam-plugin file it is classified accordingly,
    otherwise it lands on "other" and build_wrapper() wraps it as ORIG_OUT like any other command.
    """
    status_line = settings.get("statusLine")
    command = None
    if isinstance(status_line, dict):
        raw_command = status_line.get("command")
        if isinstance(raw_command, str) and raw_command.strip():
            command = raw_command
    elif isinstance(status_line, str) and status_line.strip():
        command = status_line

    if command is None:
        return "absent", None, None

    resolved = resolve_command_path(command)
    # `points_at_wrapper` rather than the two comparisons that used to be written out here: it is
    # the same test, but it also catches `<wrapper_path> --some-flag`, which used to fall through
    # to "other" and be wrapped as ORIG_OUT — generating a wrapper that calls itself. `resolved`
    # is still passed through and is still None when our wrapper is missing; that is what
    # build_wrapper reads to tell "splice on top of it" from "it is not there".
    if points_at_wrapper(command, wrapper_path):
        return "ours", command, resolved

    if resolved is not None:
        content = read_text(resolved)
        if content is not None and ROAM_INVOCATION_RE.search(content):
            return "roam-plugin", command, resolved

    return "other", command, resolved


def splice_indicator(original_text: str, roam_bin: str) -> tuple[str, int]:
    """Copy every line verbatim except the ones matching ROAM_INVOCATION_RE, which are replaced
    with the aa-roam equivalent. This is the whole mechanism that preserves an unfamiliar
    hand-added segment: it is never parsed, classified, or reasoned about — only left alone.

    A commented-out line is skipped even if it matches: `# see $HOME/.claude/roam/bin/roam-cli
    indicator for how this used to work` is a line that *mentions* the old invocation, not one
    that runs it, and rewriting it into live shell code would contradict this script's own claim
    (module docstring, rule 2) that only the plugin's actual indicator invocation is touched.
    A line counts as a comment when its first non-whitespace character is `#` — matching shell's
    own rule for what a comment is, so this cannot disagree with how bash itself would read the
    same line.
    """
    replacement = build_indicator_line(roam_bin)
    lines = original_text.splitlines(keepends=True)
    replaced = 0
    output: list[str] = []
    for line in lines:
        is_comment = line.lstrip().startswith("#")
        if not is_comment and ROAM_INVOCATION_RE.search(line):
            newline = "\n" if line.endswith("\n") else ""
            output.append(replacement + newline)
            replaced += 1
        else:
            output.append(line)
    return "".join(output), replaced


def build_wrapper(label: str, resolved_script_path: str | None, original_command: str | None,
                   roam_bin: str, settings_path: str, wrapper_path: str) -> str:
    """Never regenerates from a template when there is a file to carry over (rule 1). Splicing is
    used only for "roam-plugin" and "ours" — the two labels classify() only assigns once it has
    already found a line matching ROAM_INVOCATION_RE (or, for "ours", the file at our own fixed
    wrapper_path) in that file, so there is guaranteed to be at least one line to replace. A
    generic "other" script is not guaranteed to contain any such line — splicing it would silently
    copy the file through with no indicator ever added, which is a worse failure than a bug in the
    fixture-testing sense: it would look like a successful install while doing nothing. So "other"
    (and "absent") always go through a template that explicitly appends the indicator, whether or
    not the current command happens to resolve to a real, readable file.

    **The generated wrapper must never invoke itself** (see `points_at_wrapper`). The case that
    broke this: label "ours" with the wrapper file missing. classify() answers ("ours", <our own
    path>, None) — correctly, because statusLine.command really does point at us — the splice
    branch is skipped because there is no file to read, the "absent" branch is skipped because the
    label is not "absent", and the fall-through wrapped OUR OWN PATH as ORIG_OUT. Every status-line
    refresh would then have re-entered this wrapper, forever. The guard is on the *command*, not
    on the label, so it also covers a hand-edited `<wrapper_path> --flag` and any future label
    that reaches the fall-through."""
    if label in ("roam-plugin", "ours") and resolved_script_path is not None:
        original_text = read_text(resolved_script_path)
        if original_text is not None:
            new_text, _replaced = splice_indicator(original_text, roam_bin)
            return new_text

    if label == "absent":
        return WRAPPER_TEMPLATE_ABSENT.format(
            badge=BADGE, settings_path=settings_path, indicator_line=build_indicator_line(roam_bin)
        )

    if points_at_wrapper(original_command, wrapper_path):
        # Our own wrapper, gone. Nothing to chain, and saying so in the file is the honest answer:
        # the ABSENT template's "no previous statusLine command was configured" would be a lie,
        # since there was one — it was us, and whatever we used to chain went with the file.
        return WRAPPER_TEMPLATE_RECOVERED.format(
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
    wrapper_text = build_wrapper(label, resolved, command, roam_bin, settings_path, wrapper_path)

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

    # THE INVARIANT, enforced on the way in (`do_uninstall` enforces it again on the way out).
    #
    # The branch above only recovers the true pre-Warden value while the manifest still HAS one.
    # The manifest is a single shared file and there are at least four ordinary ways to lose it:
    # a direct `manage-hooks.py uninstall` (which its own --help presents as a standalone tool)
    # deletes it once "targets" empties; a MANIFEST_VERSION bump makes load_manifest() read it as
    # corrupt and hand back an empty one; a truncated or hand-edited file does the same; and a
    # changed AGENT_ATTENTION_HOME simply looks elsewhere. Any of those, followed by a reinstall,
    # lands in the `else` branch with settings.statusLine.command already equal to wrapper_path —
    # and recorded OUR OWN WRAPPER as the thing to restore. The next uninstall then "restored" the
    # user's statusLine to a path it deletes in the same breath, printing "restored" while doing
    # it. The user's hand-tuned command and their hand-added segments survived only in the
    # timestamped backups, and nothing told them to look there.
    #
    # We cannot invent what we no longer know, so this records that we do not know it, loudly and
    # in a form uninstall can act on, rather than recording something false.
    previous_unrecoverable = points_at_wrapper(previous_status_line, wrapper_path)
    if previous_unrecoverable:
        previous_status_line = None

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
        # Read by do_uninstall. A plain `previousStatusLine: null` means "there was no statusLine
        # before Warden", and uninstall removes the key entirely on that basis — which would be
        # the wrong thing here, where there certainly WAS one and we simply cannot name it. The
        # two cases have to be distinguishable in the manifest or the restore guesses.
        "previousStatusLineUnrecoverable": previous_unrecoverable,
    }
    save_manifest(manifest_path, manifest)

    print(f"backup        : {saved or '(no previous settings file)'}")
    print(f"settings      : {settings_path}")
    print(f"manifest      : {manifest_path}  ({manifest_status})")
    print(f"wrapper       : {wrapper_path}")
    print(f"roam binary   : {roam_bin}")
    print(f"previous state: {label}")
    if previous_unrecoverable:
        print()
        print("WARNING: statusLine.command already pointed at Warden's own wrapper, and the "
              "manifest", file=sys.stderr)
        print(f"         had no record of what it replaced (manifest {manifest_status}). Your "
              "pre-Warden", file=sys.stderr)
        print("         status line could not be carried forward and is NOT recorded for "
              "restoration —", file=sys.stderr)
        print("         recording Warden's own wrapper as the thing to restore would be worse "
              "than", file=sys.stderr)
        print("         admitting this. Uninstall will say so rather than guess. It is in the "
              "backups:", file=sys.stderr)
        print(f"             {saved or '(no previous settings file to back up)'}", file=sys.stderr)
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

    # THE INVARIANT, enforced on the way out (`do_install` enforces it on the way in).
    #
    # Two ways to get here with a restore target that is our own wrapper: install recorded the
    # "we do not know" flag because the manifest had been lost, or the manifest was hand-edited
    # or written by an older version of this script that had the bug. Both are refused the same
    # way, because "restoring" either one means pointing statusLine.command at a file this
    # function deletes four lines later — leaving the user with a status line that runs nothing,
    # a "restored : statusLine restored" line saying it went fine, and their real command
    # surviving only in a timestamped backup nobody told them about.
    #
    # Refusing means changing NOTHING: the wrapper file stays (it may be the last copy of a
    # chained hand-added segment), settings.json stays, and the manifest entry stays so a repaired
    # manifest can still be used later. uninstall.sh treats a non-zero exit here as a warning and
    # carries on with the rest of the teardown, which is what should happen — a status line that
    # was not restored is a nuisance; a root daemon left holding a sleep block is not.
    if entry.get("previousStatusLineUnrecoverable") or points_at_wrapper(previous_status_line,
                                                                        wrapper_path):
        directory = os.path.dirname(settings_path) or "."
        try:
            backups = sorted(
                name for name in os.listdir(directory)
                if name.startswith(os.path.basename(settings_path) + ".agent-warden-backup-")
            )
        except OSError:
            # This is the error path. It must not raise its own error on the way out.
            backups = []
        print(
            "error: the recorded previous statusLine is Warden's own wrapper "
            f"({wrapper_path!r}), which is not something to restore to — it is the file this "
            "uninstall removes. This happens when install-manifest.json was lost between "
            "installs (a standalone manage-hooks.py uninstall, a manifest version bump, or a "
            "changed AGENT_ATTENTION_HOME will each do it), so the real previous value is not "
            "known.\n"
            "Nothing was changed: your statusLine, the wrapper and the manifest entry are all "
            "as they were.\n"
            "Your original statusLine is in a settings backup beside the settings file:",
            file=sys.stderr,
        )
        for name in backups[-5:]:
            print(f"    {os.path.join(directory, name)}", file=sys.stderr)
        if not backups:
            print("    (none found — look for *.agent-warden-backup-* beside "
                  f"{settings_path})", file=sys.stderr)
        recorded = entry.get("backupPath")
        if recorded:
            print(f"The backup taken by the install that recorded this: {recorded}",
                  file=sys.stderr)
        print("Put the command you want back into statusLine.command by hand, then delete "
              f"{wrapper_path} and this entry from {manifest_path}.", file=sys.stderr)
        return 1

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
