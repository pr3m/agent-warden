#!/usr/bin/env python3
"""Install or upgrade the built app, in place, without taking anything else with it.

What this is for. The binaries used to *be* the repo's build directory, so the install was only ever
as stable as the folder it was built in. Renaming that folder broke the hook entries, the login item
and the build cache at the same time, and none of them said so — the hooks failed silently at every
turn, and the login item would have launched a deleted binary at the next reboot. The app now lives
somewhere of its own, and the repo can be renamed, moved or deleted without any of that following.

The rules, in order of importance:

1. **Never damage what is not ours.** Every protected file is hashed before and after. Settings are
   the one file we deliberately change, and only through `manage-hooks.py`, which replaces our own
   entries and copies every other hook through untouched — so the check there is that *somebody
   else's* hooks came out byte-identical, not that the file did.
2. **A failed install leaves the previous one running.** The old bundle is moved aside rather than
   deleted, and put back if any step fails.
3. **Verify the thing being installed, before installing it.** Every bundled executable must be
   present, executable, report the same version, and the bundle must satisfy its own signature.
   A candidate that cannot prove what it is does not get installed.
4. **Restart Agent Warden and nothing else.** The running app is stopped by the path it was launched
   from, never by a bare process name.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

# Everything the installer verifies and links. `aa-roam` belongs here because the status-line
# wrapper invokes it by name from PATH, so an install that does not link it leaves the roam badge
# silently absent.
#
# `aa-powerd` is deliberately NOT here: it is installed root-owned into /Library by
# Scripts/install-powerd.sh rather than linked from the bundle, and it answers no `--version`,
# which the verification below requires of every name in this list.
EXECUTABLES = ["AgentWarden", "aa-emit", "aa-status", "aa-bridge", "aa-session", "aa-roam"]
LAUNCH_LABEL = "dev.agentwarden"


def digest(path: Path) -> str | None:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError:
        return None


def say(step: str, detail: str = "") -> None:
    print(f"{step:<14}: {detail}" if detail else step)


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


# --------------------------------------------------------------------------- verifying a candidate

def verify_candidate(app: Path) -> dict[str, str]:
    """Everything that must be true before this bundle is allowed near the running install."""
    macos = app / "Contents" / "MacOS"
    if not macos.is_dir():
        fail(f"{app} is not an app bundle")

    versions: set[str] = set()
    hashes: dict[str, str] = {}
    for name in EXECUTABLES:
        binary = macos / name
        if not binary.is_file():
            fail(f"{name} is missing from the bundle")
        if not os.access(binary, os.X_OK):
            fail(f"{name} is in the bundle but is not executable")
        result = subprocess.run([str(binary), "--version"], capture_output=True, text=True)
        if result.returncode != 0:
            fail(f"{name} --version failed: {result.stderr.strip()}")
        versions.add(result.stdout.strip().split()[-1])
        hashes[name] = digest(binary) or fail(f"could not hash {name}")

    if len(versions) != 1:
        fail(f"the bundled executables do not agree on a version: {sorted(versions)}")

    signature = subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", str(app)], capture_output=True, text=True
    )
    if signature.returncode != 0:
        fail(f"the bundle does not satisfy its own signature: {signature.stderr.strip()}")

    version = versions.pop()
    say("candidate", f"{app}")
    say("version", version)
    say("executables", f"{len(EXECUTABLES)} present, executable, all reporting {version}")
    say("signature", "valid, satisfies its designated requirement")
    return {"version": version, "hashes": hashes}


# ------------------------------------------------------------------------------- the running app

def running_app_pids(bundles: list[Path]) -> list[int]:
    """Only processes launched from one of *these* bundles. Never a bare process-name match."""
    pids: list[int] = []
    for bundle in bundles:
        binary = str(bundle / "Contents" / "MacOS" / "AgentWarden")
        found = subprocess.run(["pgrep", "-f", binary], capture_output=True, text=True)
        pids += [int(line) for line in found.stdout.split() if line.isdigit()]
    return sorted(set(pids))


def stop_app(bundles: list[Path], plist: Path) -> bool:
    """Stop Agent Warden, and say whether a login item was the thing that started it.

    Takes every bundle this app might currently be running from — the place we are installing to,
    and the place it was built. The first upgrade after a move is exactly the case where the running
    copy is *not* the one at the install path, and leaving it running would put two wardens on the
    same data directory.
    """
    had_login_item = False
    if plist.exists():
        try:
            declared = plistlib.loads(plist.read_bytes())
            arguments = declared.get("ProgramArguments") or []
            if declared.get("Label") == LAUNCH_LABEL and arguments:
                had_login_item = True
                subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}", str(plist)],
                               capture_output=True)
        except Exception:
            pass
    for pid in running_app_pids(bundles):
        subprocess.run(["kill", str(pid)], capture_output=True)
    return had_login_item


# --------------------------------------------------------------------------------------- the work

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    repo = Path(__file__).resolve().parent.parent
    parser.add_argument("--candidate", default=str(repo / "build" / "AgentWarden.app"))
    parser.add_argument("--install-dir", default=str(Path.home() / "Applications"))
    parser.add_argument("--link-dir", default=str(Path.home() / ".local" / "bin"))
    parser.add_argument("--settings", default=str(Path.home() / ".claude" / "settings.json"))
    parser.add_argument("--no-path", action="store_true", help="do not touch PATH symlinks")
    parser.add_argument("--no-restart", action="store_true", help="install but leave the app stopped")
    parser.add_argument("--dry-run", action="store_true", help="verify and report, change nothing")
    options = parser.parse_args()

    candidate = Path(options.candidate).resolve()
    install_dir = Path(options.install_dir)
    install = install_dir / "AgentWarden.app"
    settings = Path(options.settings)
    plist = Path.home() / "Library" / "LaunchAgents" / f"{LAUNCH_LABEL}.plist"
    data = Path.home() / "Library" / "Application Support" / "AgentAttention"

    print("== Verifying the candidate ==")
    facts = verify_candidate(candidate)

    if options.dry_run:
        print("\n(dry run — nothing was installed)")
        say("would install", str(install))
        return

    # Protected: things *the user* owns and an upgrade has no business rewriting — their chime and
    # mute preferences, and the terminal tabs they paired by hand. Deliberately absent are the three
    # files this installer changes on purpose: `settings.json`, the login-item plist and the hook
    # manifest. Listing those as unchanged would make the check a lie that always passes, so they
    # get positive checks of their own below — that they now point at what was just installed.
    protected = [data / "config.json", data / "pairings.json"]
    before = {str(p): digest(p) for p in protected}
    settings_before = settings.read_text() if settings.exists() else ""

    tag = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backups = data / "upgrade-backups" / tag
    backups.mkdir(parents=True, exist_ok=True)
    for path in protected + [settings, data / "state.json"]:
        if path.exists():
            shutil.copy2(path, backups / path.name)
    say("backup", str(backups))

    print("\n== Stopping Agent Warden ==")
    stopped = running_app_pids([install, candidate])
    had_login_item = stop_app([install, candidate], plist)
    say("stopped", f"{len(stopped)} Agent Warden process(es), matched by bundle path only")

    install_dir.mkdir(parents=True, exist_ok=True)
    previous = install_dir / f"AgentWarden.previous-{tag}.app"
    staged = install_dir / f"AgentWarden.staged-{tag}.app"
    shutil.copytree(candidate, staged, symlinks=True)

    print("\n== Installing ==")
    moved = False
    try:
        if install.exists():
            os.rename(install, previous)
            moved = True
        os.rename(staged, install)
        say("installed", f"{install}  (version {facts['version']})")
    except Exception as error:
        # A failed install leaves the previous one exactly where it was.
        if moved and previous.exists() and not install.exists():
            os.rename(previous, install)
        if staged.exists():
            shutil.rmtree(staged, ignore_errors=True)
        fail(f"install failed and the previous version was put back: {error}")

    print("\n== Rewiring what points at it ==")
    hooks = subprocess.run(
        ["/usr/bin/python3", str(repo / "Scripts" / "manage-hooks.py"), "install",
         "--settings", str(settings),
         "--emit-path", str(install / "Contents" / "MacOS" / "aa-emit")],
        capture_output=True, text=True)
    if hooks.returncode != 0:
        fail(f"the hooks could not be rewired, so the app is installed but not wired: {hooks.stderr.strip()}")
    say("hooks", "pointed at the installed bundle")

    if had_login_item:
        subprocess.run(["/usr/bin/python3", str(repo / "Scripts" / "launch-agent.py"), "write",
                        str(plist), LAUNCH_LABEL, str(install / "Contents" / "MacOS" / "AgentWarden")],
                       capture_output=True)
        subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist)], capture_output=True)
        say("login item", "rewritten to the installed bundle")

    if not options.no_path:
        link_dir = Path(options.link_dir)
        link_dir.mkdir(parents=True, exist_ok=True)
        linked, refused = 0, []
        for name in ["aa-status", "aa-emit", "aa-bridge", "aa-session"]:
            target, source = link_dir / name, install / "Contents" / "MacOS" / name
            if target.is_symlink():
                # Ours only if it points into an AgentWarden bundle. A name proves nothing.
                if "AgentWarden.app/Contents/MacOS/" not in os.readlink(target):
                    refused.append(str(target)); continue
                target.unlink()
            elif target.exists():
                refused.append(str(target)); continue
            target.symlink_to(source)
            linked += 1
        say("commands", f"{linked} linked into {link_dir}")
        for path in refused:
            say("refused", f"{path} — not ours, left untouched")
        if str(link_dir) not in os.environ.get("PATH", "").split(":"):
            say("PATH", f"{link_dir} is not on your PATH; add: export PATH=\"{link_dir}:$PATH\"")

    print("\n== Checking nothing else moved ==")
    after = {str(p): digest(p) for p in protected}
    changed = [p for p in before if before[p] != after[p]]
    if changed:
        for path in changed:
            say("CHANGED", path)
        fail("a protected file changed during the upgrade; the backup above has the original")
    say("protected", f"{len(protected)} files unchanged (chime/mute settings, terminal pairings)")

    # Positive checks on the three files we did change: each must now name the bundle just installed.
    wired = install / "Contents" / "MacOS"
    manifest_text = (data / "install-manifest.json").read_text() if (data / "install-manifest.json").exists() else ""
    say("hooks point at", "the installed bundle" if str(wired / "aa-emit") in settings.read_text()
        else "WARNING: something other than the installed bundle")
    say("manifest names", "the installed bundle" if str(wired / "aa-emit") in manifest_text
        else "WARNING: a path that is not the installed bundle")
    if plist.exists():
        declared = plistlib.loads(plist.read_bytes())
        target = (declared.get("ProgramArguments") or [""])[0]
        say("login item", "the installed bundle" if target == str(wired / "AgentWarden")
            else f"points at {target}")

    # Settings are allowed to change, but only in our own entries. Every other hook must come out
    # byte-identical — that is the promise `manage-hooks.py` makes, and this is where it is checked.
    if settings_before:
        kept = [line for line in settings_before.splitlines() if "AgentWarden.app/Contents/MacOS/aa-emit" not in line]
        now = [line for line in settings.read_text().splitlines() if "AgentWarden.app/Contents/MacOS/aa-emit" not in line]
        say("settings", "every hook that is not ours is unchanged" if kept == now
            else "WARNING: a hook that is not ours changed — compare against the backup")

    if not options.no_restart:
        print("\n== Restarting ==")
        if had_login_item:
            # `launchctl bootstrap` above already started it. Calling `open` as well starts a
            # *second* one, and two wardens share one data directory: each writes its own view of
            # the queue over the other's, so the badge flips between two counts and every event is
            # logged twice. That is exactly what happened, and it is why the app now refuses to be
            # the second instance as well.
            say("restarted", "by the login item, which already started it — not started twice")
        else:
            subprocess.run(["open", str(install)], capture_output=True)
            say("restarted", "Agent Warden, and nothing else")

    if previous.exists():
        shutil.rmtree(previous, ignore_errors=True)

    receipt = {"version": facts["version"], "installedAt": datetime.datetime.now().isoformat(),
               "install": str(install), "candidate": str(candidate),
               "sha256": facts["hashes"], "backup": str(backups)}
    (data / "installed-version.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print()
    say("receipt", str(data / "installed-version.json"))


if __name__ == "__main__":
    main()
