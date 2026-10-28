#!/usr/bin/env python3
"""Switch Claude Desktop accounts while keeping local Code-tab sessions.

Claude Desktop keeps Code-tab sessions under
  ~/Library/Application Support/Claude/claude-code-sessions/<accountUuid>/<orgUuid>/
so a different login shows a different (often empty) sidebar. Transcripts live
in ~/.claude/projects and are shared already; only this per-account index is split.

This tool, Codex-switcher style:
  1. quits Claude Desktop (gracefully, waits for it to exit)
  2. snapshots the live Desktop login (Cookies + oauth keys in config.json)
  3. merges session metadata across every <account>/<org> folder
  4. restores the target login and reopens Desktop

Usage:
  claude-desktop-switch.py save <name>     snapshot current Desktop login as <name>
  claude-desktop-switch.py use <name>      switch Desktop to <name> (syncs sessions)
  claude-desktop-switch.py add             sign Desktop out on this Mac to add an account
  claude-desktop-switch.py sync [--dry-run]  only merge sessions across accounts
  claude-desktop-switch.py list
  claude-desktop-switch.py status --json   (used by the menu bar app)

CLI account switchers (e.g. Symbioose/claude-account-switcher) only swap the
Claude Code *CLI* credential ("Claude Code-credentials" in Keychain). They never
touch Desktop, which has its own login. This tool is the Desktop counterpart.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import time
from pathlib import Path

APP_NAME = "Claude"
APP_BIN = "/Applications/Claude.app/Contents/MacOS/Claude"
DATA = Path.home() / "Library/Application Support/Claude"
SESSIONS = DATA / "claude-code-sessions"
CONFIG = DATA / "config.json"
AUTH_FILES = ["Cookies", "Cookies-journal"]
# config.json keys that belong to the signed-in identity
AUTH_KEY_PREFIXES = ("oauth:",)
AUTH_KEYS = ("lastKnownAccountUuid", "bootSideSessions")

HOME = Path.home() / ".config/claude-desktop-switcher"
PROFILES = HOME / "profiles"
BACKUPS = HOME / "backups"
STATE = HOME / "state.json"


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def ensure_dirs():
    for d in (HOME, PROFILES, BACKUPS):
        d.mkdir(parents=True, exist_ok=True)
        os.chmod(d, 0o700)


def load_state():
    try:
        return json.loads(STATE.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_state(state):
    STATE.write_text(json.dumps(state, indent=2))
    os.chmod(STATE, 0o600)


def read_config():
    return json.loads(CONFIG.read_text())


def write_config(cfg):
    tmp = CONFIG.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(cfg, indent=2))
    os.chmod(tmp, 0o600)
    tmp.replace(CONFIG)


# --- Desktop process control ------------------------------------------------

def running_inside_desktop():
    """True if an ancestor process is Claude Desktop (quitting it would kill us)."""
    pid = os.getppid()
    while pid > 1:
        out = subprocess.run(["ps", "-o", "ppid=,comm=", "-p", str(pid)],
                             capture_output=True, text=True).stdout.strip()
        if not out:
            return False
        ppid, comm = out.split(None, 1)
        if "/Claude.app/" in comm:
            return True
        pid = int(ppid)
    return False


def desktop_running():
    out = subprocess.run(["osascript", "-e", f'application "{APP_NAME}" is running'],
                         capture_output=True, text=True).stdout.strip()
    return out == "true"


def quit_desktop(timeout=30):
    if not desktop_running():
        return
    if running_inside_desktop():
        die("Run this from Terminal.app, not inside Claude Desktop (quitting Desktop would kill it).")
    print("Quitting Claude Desktop...")
    r = subprocess.run(["osascript", "-e", f'quit app "{APP_NAME}"'], capture_output=True, text=True)
    if "-1743" in r.stderr:  # errAEEventNotPermitted
        die("macOS blocked quitting Claude. Allow it in System Settings > Privacy & Security > "
            "Automation (turn on 'Claude' under this app or Terminal), then retry.")
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not desktop_running():
            time.sleep(1)  # let it finish flushing files
            return
        time.sleep(0.5)
    die("Claude Desktop did not quit (finish or stop running sessions, quit it, and retry).")


def open_desktop():
    subprocess.run(["open", "-a", APP_NAME])


# --- auth snapshots ---------------------------------------------------------

def live_account_uuid():
    return read_config().get("lastKnownAccountUuid")


def snapshot(name):
    """Copy the live Desktop login into profiles/<name>. Desktop must be quit."""
    dest = PROFILES / name
    dest.mkdir(exist_ok=True)
    os.chmod(dest, 0o700)
    for f in AUTH_FILES:
        src = DATA / f
        if src.exists():
            shutil.copy2(src, dest / f)
            os.chmod(dest / f, 0o600)
        elif (dest / f).exists():
            (dest / f).unlink()
    cfg = read_config()
    keys = {k: v for k, v in cfg.items() if k.startswith(AUTH_KEY_PREFIXES) or k in AUTH_KEYS}
    (dest / "config-auth.json").write_text(json.dumps(keys, indent=2))
    os.chmod(dest / "config-auth.json", 0o600)
    meta = {"accountUuid": cfg.get("lastKnownAccountUuid"), "savedAt": int(time.time())}
    (dest / "meta.json").write_text(json.dumps(meta, indent=2))
    return meta


def restore(name):
    src = PROFILES / name
    for f in AUTH_FILES:
        live = DATA / f
        if (src / f).exists():
            shutil.copy2(src / f, live)
        elif live.exists():
            live.unlink()
    keys = json.loads((src / "config-auth.json").read_text())
    cfg = read_config()
    for k in [k for k in cfg if k.startswith(AUTH_KEY_PREFIXES) or k in AUTH_KEYS]:
        del cfg[k]
    cfg.update(keys)
    write_config(cfg)


def clear_login():
    """Sign Desktop out on this Mac only. Desktop's own Log out also ends the
    session server-side, which would kill the saved copy of that login."""
    for f in AUTH_FILES:
        (DATA / f).unlink(missing_ok=True)
    cfg = read_config()
    for k in [k for k in cfg if k.startswith(AUTH_KEY_PREFIXES) or k in AUTH_KEYS]:
        del cfg[k]
    write_config(cfg)


def profiles_for(uuid):
    """Profile names saved for an account, real names before auto-* ones."""
    if not uuid or not PROFILES.exists():
        return []
    names = [p.name for p in PROFILES.iterdir() if (profile_meta(p.name) or {}).get("accountUuid") == uuid]
    return sorted(names, key=lambda n: (n.startswith("auto-"), n))


def save_live_login(state):
    """Refresh the profile for whichever account Desktop is signed in to (refresh
    tokens rotate, so an old snapshot goes stale). Desktop must be quit."""
    live = live_account_uuid()
    if not live:
        return None
    names = profiles_for(live)
    name = state.get("current") if state.get("current") in names else (names[0] if names else None)
    if name is None:
        name = f"auto-{live[:8]}"
        print(f"The current login ({live}) isn't saved yet; saving it as '{name}'.")
    snapshot(name)
    return name


def retire_profile(name):
    """Move a superseded profile into backups rather than deleting it."""
    dest = BACKUPS / f"{name}-retired-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.move(str(PROFILES / name), dest)
    return dest


def profile_meta(name):
    try:
        return json.loads((PROFILES / name / "meta.json").read_text())
    except FileNotFoundError:
        return None


# --- session merge ----------------------------------------------------------

def scope_dirs():
    """Every <accountUuid>/<orgUuid> folder under claude-code-sessions."""
    if not SESSIONS.exists():
        return []
    return sorted(d for a in SESSIONS.iterdir() if a.is_dir() for d in a.iterdir() if d.is_dir())


def session_stamp(path):
    try:
        d = json.loads(path.read_text())
        return d.get("lastActivityAt") or d.get("createdAt") or 0, d
    except (json.JSONDecodeError, OSError):
        return 0, {}


def backup_sessions():
    ts = time.strftime("%Y%m%d-%H%M%S")
    out = BACKUPS / f"claude-code-sessions-{ts}.tar.gz"
    with tarfile.open(out, "w:gz") as tar:
        tar.add(SESSIONS, arcname="claude-code-sessions")
    os.chmod(out, 0o600)
    # keep the 10 newest backups
    for old in sorted(BACKUPS.glob("claude-code-sessions-*.tar.gz"))[:-10]:
        old.unlink()
    return out


def sync_sessions(dry_run=False):
    dirs = scope_dirs()
    if len(dirs) < 2:
        print("Nothing to sync (fewer than two account/org folders).")
        return

    newest = {}      # filename -> (stamp, path, data)
    tombstones = {}  # session uuid -> path of deleted_<uuid>
    archived = set()
    for d in dirs:
        for p in d.iterdir():
            if p.name.startswith("local_") and p.suffix == ".json":
                stamp, data = session_stamp(p)
                if p.name not in newest or stamp > newest[p.name][0]:
                    newest[p.name] = (stamp, p, data)
            elif p.name.startswith("deleted_"):
                tombstones.setdefault(p.name[len("deleted_"):], p)
            elif p.name == "archived-sessions.idx":
                try:
                    archived |= set(json.loads(p.read_text()).get("archived", []))
                except (json.JSONDecodeError, OSError):
                    pass

    # newest copy of each session decides its archived state
    for name, (_, _, data) in newest.items():
        sid = name[:-len(".json")]
        if data.get("isArchived") is True:
            archived.add(sid)
        elif data.get("isArchived") is False:
            archived.discard(sid)

    if not dry_run:
        print(f"Backup: {backup_sessions()}")

    copied = 0
    for d in dirs:
        for name, (stamp, src, _) in newest.items():
            sid = name[len("local_"):-len(".json")]
            if sid in tombstones:
                continue  # deleted somewhere: don't resurrect it elsewhere
            dst = d / name
            if dst.exists() and session_stamp(dst)[0] >= stamp:
                continue
            copied += 1
            print(f"  {'would copy' if dry_run else 'copy'} {name} -> {d.parent.name[:8]}/{d.name[:8]}")
            if not dry_run:
                shutil.copy2(src, dst)
        for sid, src in tombstones.items():
            if not (d / src.name).exists():
                if not dry_run:
                    shutil.copy2(src, d / src.name)
        idx = d / "archived-sessions.idx"
        known = {n[:-len(".json")] for n in newest}
        if not dry_run:
            idx.write_text(json.dumps({"v": 1, "archived": sorted(archived & known)}))
            os.chmod(idx, 0o600)

    print(f"{'Would copy' if dry_run else 'Copied'} {copied} session file(s) across {len(dirs)} account/org folders.")


# --- commands ---------------------------------------------------------------

def cmd_save(name):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,39}", name):
        die("Profile names use letters, digits, '.', '_' or '-' (max 40 chars).")
    ensure_dirs()
    live = live_account_uuid()
    if not live:
        die("Claude Desktop isn't signed in. Sign in first, then save.")
    existing = profile_meta(name)
    if existing and existing.get("accountUuid") != live:
        die(f"'{name}' is already saved for a different account. Pick another name.")
    others = [n for n in profiles_for(live) if n != name]
    taken = [n for n in others if not n.startswith("auto-")]
    if taken:
        die(f"Desktop is signed in to the account already saved as '{taken[0]}'. "
            f"To add another account, use Add Account (CLI: add), sign in, then save.")
    was_running = desktop_running()
    quit_desktop()
    meta = snapshot(name)
    for n in others:  # auto-saved copies of this account are superseded by the named one
        print(f"Replaced '{n}' (moved to {retire_profile(n)}).")
    state = load_state()
    state["current"] = name
    save_state(state)
    print(f"Saved Desktop login as '{name}' (account {meta['accountUuid']}).")
    if was_running:
        open_desktop()


def cmd_use(name):
    ensure_dirs()
    target = profile_meta(name)
    if not target:
        die(f"No profile '{name}'. Run: save {name}  (while signed in to that account)")
    state = load_state()

    quit_desktop()
    save_live_login(state)
    sync_sessions()
    restore(name)
    state["current"] = name
    save_state(state)
    print(f"Switched Desktop to '{name}' (account {target['accountUuid']}).")
    open_desktop()


def cmd_add():
    """Sign Desktop out on this Mac so another account can sign in."""
    ensure_dirs()
    state = load_state()
    quit_desktop()
    saved = save_live_login(state)
    if saved:
        print(f"Saved the current login as '{saved}'.")
    clear_login()
    state.pop("current", None)
    save_state(state)
    print("Desktop is signed out on this Mac. Sign in to the new account, then save it "
          "(menu: Save Current Login As…, CLI: save <name>).")
    open_desktop()


def cmd_list():
    state = load_state()
    if not PROFILES.exists():
        print("No profiles yet.")
        return
    live = live_account_uuid()
    for p in sorted(PROFILES.iterdir()):
        meta = profile_meta(p.name) or {}
        mark = "*" if p.name == state.get("current") else " "
        tag = " (live)" if meta.get("accountUuid") == live else ""
        print(f"{mark} {p.name:20} {meta.get('accountUuid')}{tag}")


def cmd_status():
    """JSON snapshot for the menu bar app."""
    profiles = []
    if PROFILES.exists():
        for p in sorted(PROFILES.iterdir()):
            meta = profile_meta(p.name)
            if meta:
                profiles.append({"name": p.name, "accountUuid": meta.get("accountUuid")})
    print(json.dumps({
        "current": load_state().get("current"),
        "liveAccountUuid": live_account_uuid(),
        "profiles": profiles,
    }))


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return
    cmd, args = argv[1], argv[2:]
    if cmd == "save" and len(args) == 1:
        cmd_save(args[0])
    elif cmd == "use" and len(args) == 1:
        cmd_use(args[0])
    elif cmd == "add" and not args:
        cmd_add()
    elif cmd == "sync":
        ensure_dirs()
        dry_run = "--dry-run" in args
        was_running = not dry_run and desktop_running()
        if not dry_run:
            quit_desktop()
        sync_sessions(dry_run=dry_run)
        if was_running:
            open_desktop()
    elif cmd == "list":
        cmd_list()
    elif cmd == "status" and args == ["--json"]:
        cmd_status()
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv)
