# Claude Desktop Account Switcher

Switch the **Claude Desktop** app between accounts on macOS without losing your local Code-tab sessions.

It includes a menu bar app and a small CLI. It works like [codex-account-switcher](https://github.com/liuzhao1225/codex-account-switcher) does for Codex Desktop: quit the app, swap the login, keep local state, then reopen the app.

> **Status: early.** Claude Desktop's on-disk layout is internal and can change between releases. Every sync takes a backup first; see [Recovery](#recovery).

## The problem

Claude Desktop stores the session list for its Code tab in a separate folder for each account and organization:

```
~/Library/Application Support/Claude/claude-code-sessions/<accountUuid>/<orgUuid>/local_*.json
```

When you sign in as a different account, Desktop reads a different folder, and your sidebar looks empty. The conversation transcripts live in `~/.claude/projects` and all accounts share them already. Only this per-account index of sessions is split.

CLI switchers such as [claude-account-switcher](https://github.com/Symbioose/claude-account-switcher) swap the Claude Code **CLI** credential in Keychain (`Claude Code-credentials`). They don't touch Desktop, which has its own login.

## What it does

On each switch:

1. **Quits Claude Desktop** normally and waits up to 30 s for it to exit. Nothing is force-killed.
2. **Saves the current login.** Desktop's `Cookies` database and the `oauth:*` keys in `config.json` are copied into the current profile, so rotated refresh tokens stay current.
3. **Syncs sessions** across every `<account>/<org>` folder:
   - When the same session exists in several folders, the newest copy (by `lastActivityAt`) wins.
   - Archived state follows that newest copy.
   - A session deleted in any account is never brought back in the others.
   - The whole `claude-code-sessions` folder is backed up first.
4. **Restores the target login** and reopens Desktop.

## Install

You need macOS 13 or later, on Apple Silicon or Intel, plus Python 3. The app uses Homebrew's `python3` if you have it, otherwise `/usr/bin/python3`. That one comes with the Command Line Tools, and macOS offers to install them the first time it runs.

### Download the app

1. Download `Claude-Desktop-Switcher-vX.Y.Z.zip` from the [latest release](https://github.com/bradleyzaia/claude-desktop-account-switcher/releases/latest).
2. Unzip it and drag **Claude Desktop Switcher.app** into `/Applications` or `~/Applications`.
3. Open it. A 👥 icon appears in the menu bar.

The app is **ad-hoc signed, not notarized**, so macOS blocks it the first time you open it. Either:
- open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**, or
- remove the download quarantine flag in Terminal:
  ```bash
  xattr -dr com.apple.quarantine "/Applications/Claude Desktop Switcher.app"
  ```

The app has the CLI built in, so you don't need anything else. To also use the CLI from Terminal, link it onto your PATH:

```bash
mkdir -p ~/.local/bin
ln -sf "/Applications/Claude Desktop Switcher.app/Contents/Resources/claude-desktop-switch.py" ~/.local/bin/claude-desktop-switch
```

To check the download, compare it with the `.sha256` file on the release:

```bash
shasum -a 256 -c Claude-Desktop-Switcher-vX.Y.Z.zip.sha256
```

### Build from source

This also needs Xcode or the Command Line Tools, to compile the app.

```bash
git clone https://github.com/bradleyzaia/claude-desktop-account-switcher.git
cd claude-desktop-account-switcher
./install.sh
```

This installs:

| What | Where |
| --- | --- |
| CLI | `~/.local/bin/claude-desktop-switch` |
| Menu bar app | `~/Applications/Claude Desktop Switcher.app` |

To install only the CLI, use `./install.sh --cli-only`.

To start the app when you log in, use System Settings → General → Login Items → **+**. Or run:

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"'"$HOME"'/Applications/Claude Desktop Switcher.app", hidden:true}'
```

## First-time setup

Save each account once, while Desktop is signed in to it:

1. Sign in to Desktop as account A. In the menu bar, choose **Save Current Login As…** and type a name, such as `work`.
2. In Desktop, **log out** and sign in as account B. Choose **Save Current Login As…** again and type a different name, such as `personal`.

Saving refuses if Desktop is still signed in to an account you've already saved under another name. That guards against saving the same login twice.

## Menu bar app

A 👥 icon in the menu bar, labeled with the name of the profile Desktop is signed in to.

| Item | What it does |
| --- | --- |
| *Profiles* (✓ = signed in now) | Click to switch: quits Desktop, syncs, restores the login, reopens Desktop |
| Save Current Login As… | Saves the account Desktop is signed in to under a name |
| Sync Sessions Now | Syncs sessions only, without changing accounts |
| Show Profiles Folder | Opens `~/.config/claude-desktop-switcher/profiles` |

The first time you switch, macOS asks whether *Claude Desktop Switcher* may control *Claude*. Allow it: that's how the app quits Desktop cleanly.

## CLI

```bash
claude-desktop-switch list               # saved profiles; * = current, (live) = signed in now
claude-desktop-switch save <name>        # save the current Desktop login
claude-desktop-switch use <name>         # switch Desktop to <name> (also syncs)
claude-desktop-switch sync [--dry-run]   # sync sessions only
claude-desktop-switch status --json      # machine-readable state (used by the app)
```

Run the CLI from **Terminal.app**, not from a terminal inside Claude Desktop. Quitting Desktop would kill the process mid-switch, so the CLI refuses to run there.

## Files

| Path | Contents |
| --- | --- |
| `~/.config/claude-desktop-switcher/profiles/<name>/` | `Cookies`, `config-auth.json`, `meta.json` (mode `0600`, folder `0700`) |
| `~/.config/claude-desktop-switcher/backups/` | The 10 most recent `claude-code-sessions` tarballs |
| `~/.config/claude-desktop-switcher/state.json` | Last-used profile name |

Saved profiles contain live login cookies and tokens. Desktop encrypts them with a key from your login Keychain (`Claude Safe Storage`), so they only work on this Mac and this user account. Still, treat the folder as secret, and don't commit it or put it in a synced folder.

## Limitations

- **macOS only.**
- **Connectors are per organization.** A session copied from another account opens with the current account's connectors and MCP servers.
- **Cowork / local-agent sessions** (`local-agent-mode-sessions/`) and scheduled tasks aren't synced; they stay with their account.
- **Desktop updates** may rename or reshape the files this tool touches. If a switch misbehaves after an update, use [Recovery](#recovery) and open an issue.

## Recovery

- **Sessions look wrong.** Quit Desktop, move the current folder aside, and extract a backup:
  ```bash
  cd ~/Library/Application\ Support/Claude
  mv claude-code-sessions claude-code-sessions.broken
  tar -xzf ~/.config/claude-desktop-switcher/backups/claude-code-sessions-<timestamp>.tar.gz
  ```
- **Login looks wrong.** Log out and back in from Desktop, then save that profile again.

## Uninstall

```bash
pkill -x ClaudeDesktopSwitcher
rm -rf "/Applications/Claude Desktop Switcher.app" "$HOME/Applications/Claude Desktop Switcher.app"
rm -f ~/.local/bin/claude-desktop-switch
# Optional: saved logins and backups
rm -rf ~/.config/claude-desktop-switcher
```

Also remove the app from Login Items if you added it.

## Releasing

```bash
echo 0.2.0 > VERSION
scripts/package-release.sh   # -> dist/Claude-Desktop-Switcher-v0.2.0.zip + .sha256
```

`scripts/build-app.sh` builds a universal (arm64 + x86_64), ad-hoc signed bundle with the CLI inside `Contents/Resources`.

## License

[MIT](LICENSE)

## Not affiliated

This is an independent tool. It isn't made or supported by Anthropic.
