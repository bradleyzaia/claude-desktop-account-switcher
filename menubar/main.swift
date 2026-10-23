// Menu bar front end for claude-desktop-switch.
// All switching logic lives in that script; this app only shows profiles and runs it.
// Prefers the copy bundled in Resources (version-matched), else the installed CLI.

import AppKit

let scriptPath = Bundle.main.path(forResource: "claude-desktop-switch", ofType: "py")
    ?? NSString(string: "~/.local/bin/claude-desktop-switch").expandingTildeInPath
let profilesPath = NSString(string: "~/.config/claude-desktop-switcher/profiles").expandingTildeInPath
let pythonPath = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
    .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
let logPath = NSString(string: "~/.config/claude-desktop-switcher/app.log").expandingTildeInPath

func appLog(_ msg: String) {
    let data = Data("\(ISO8601DateFormatter().string(from: Date())) \(msg)\n".utf8)
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    } else {
        try? FileManager.default.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logPath, contents: data, attributes: [.posixPermissions: 0o600])
    }
}

struct Profile: Decodable { let name: String; let accountUuid: String? }
struct Status: Decodable { let current: String?; let liveAccountUuid: String?; let profiles: [Profile] }

func runScript(_ args: [String]) -> (ok: Bool, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: pythonPath)
    p.arguments = ["-I", scriptPath] + args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (false, "Couldn't run \(scriptPath): \(error.localizedDescription)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
}

func loadStatus() -> Status? {
    let r = runScript(["status", "--json"])
    guard r.ok else { return nil }
    return try? JSONDecoder().decode(Status.self, from: Data(r.output.utf8))
}

let statusItemName = "ClaudeDesktopSwitcher"
let positionKey = "NSStatusItem Preferred Position \(statusItemName)"

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    var busy = false

    func applicationDidFinishLaunching(_ note: Notification) {
        // New items land at the far left, which a full menu bar hides behind the notch.
        // macOS stores Cmd-drag positions (points from the right edge) under this key;
        // seed one near the clock the first time, and respect the user's choice after.
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(260.0, forKey: positionKey)
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = statusItemName
        item.button?.image = NSImage(systemSymbolName: "person.2.circle", accessibilityDescription: "Claude account")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refreshTitle()
        appLog("launched \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") script=\(scriptPath) python=\(pythonPath)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if self.logPlacement("startup") == false { self.warnHidden() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in self.logPlacement("screen change") }
    }

    func warnHidden() {
        let alert = NSAlert()
        alert.messageText = "Claude Desktop Switcher is running, but its icon is hidden"
        alert.informativeText = "Your menu bar is full, so macOS hides the 👥 icon behind the notch. Hold ⌘ and drag some other menu bar icons off the bar (or quit apps you don't need there), then reopen Claude Desktop Switcher."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // Records where the icon landed: a crowded menu bar hides items behind the notch.
    @discardableResult
    func logPlacement(_ why: String) -> Bool? {
        guard let win = item.button?.window else { appLog("\(why): status item has no window"); return nil }
        let f = win.frame
        var notch = "none"
        if let s = win.screen, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            notch = "\(Int(l.maxX))-\(Int(r.minX))"
        }
        let visible = win.occlusionState.contains(.visible)
        appLog("\(why): icon x=\(Int(f.minX))-\(Int(f.maxX)) y=\(Int(f.minY)) visible=\(visible) notch=\(notch) screenWidth=\(Int(win.screen?.frame.width ?? 0))")
        return visible
    }

    func liveProfile(_ s: Status?) -> Profile? {
        guard let s, let live = s.liveAccountUuid else { return nil }
        return s.profiles.first { $0.accountUuid == live }
    }

    // Icon only (narrow, so it fits on a crowded menu bar); the account name is in the tooltip and menu.
    func refreshTitle() {
        let symbol = busy ? "arrow.triangle.2.circlepath" : "person.2.circle"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Claude account")
        item.button?.toolTip = busy ? "Switching…" : "Claude Desktop: \(liveProfile(loadStatus())?.name ?? "unsaved login")"
    }

    func menuNeedsUpdate(_ menu: NSMenu) { build(menu) }

    func build(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = loadStatus()
        let live = liveProfile(status)

        menu.addItem(NSMenuItem(title: busy ? "Switching…" : "Claude Desktop account", action: nil, keyEquivalent: ""))
        if let status {
            for p in status.profiles {
                let mi = NSMenuItem(title: p.name, action: busy ? nil : #selector(switchTo(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = p.name
                mi.state = p.name == live?.name ? .on : .off
                mi.toolTip = p.accountUuid
                menu.addItem(mi)
            }
            if live == nil {
                menu.addItem(NSMenuItem(title: "Current login isn't saved", action: nil, keyEquivalent: ""))
            }
            if status.profiles.count < 2 {
                menu.addItem(NSMenuItem(title: "To add an account: log in to it in Claude Desktop,", action: nil, keyEquivalent: ""))
                menu.addItem(NSMenuItem(title: "then choose Save Current Login As…", action: nil, keyEquivalent: ""))
            }
        } else {
            menu.addItem(NSMenuItem(title: "Can't read \(scriptPath)", action: nil, keyEquivalent: ""))
        }

        menu.addItem(.separator())
        addAction(menu, "Save Current Login As…", #selector(saveCurrent))
        addAction(menu, "Sync Sessions Now", #selector(syncNow))
        addAction(menu, "Show Profiles Folder", #selector(showProfiles), alwaysEnabled: true)
        menu.addItem(.separator())
        addAction(menu, "Quit Switcher", #selector(NSApplication.terminate(_:)), alwaysEnabled: true, target: NSApp)
    }

    func addAction(_ menu: NSMenu, _ title: String, _ sel: Selector, alwaysEnabled: Bool = false, target: AnyObject? = nil) {
        let mi = NSMenuItem(title: title, action: (busy && !alwaysEnabled) ? nil : sel, keyEquivalent: "")
        mi.target = target ?? self
        menu.addItem(mi)
    }

    @objc func switchTo(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, sender.state != .on else { return }
        guard confirm("Switch Claude Desktop to “\(name)”?",
                      "Claude Desktop will quit, sessions will be synced across accounts, and Desktop reopens signed in as \(name). Anything running in Desktop stops.",
                      "Switch") else { return }
        run(["use", name])
    }

    @objc func saveCurrent() {
        let alert = NSAlert()
        alert.messageText = "Save the current Desktop login"
        alert.informativeText = "Name this account (e.g. stable, dev). Desktop will quit and reopen."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { run(["save", name]) }
    }

    @objc func syncNow() {
        guard confirm("Sync sessions across accounts?",
                      "Claude Desktop will quit, copy sessions between accounts, then reopen.",
                      "Sync") else { return }
        run(["sync"])
    }

    @objc func showProfiles() {
        NSWorkspace.shared.open(URL(fileURLWithPath: profilesPath))
    }

    func confirm(_ title: String, _ info: String, _ ok: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: ok)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func run(_ args: [String]) {
        busy = true
        refreshTitle()
        appLog("run \(args.joined(separator: " "))")
        DispatchQueue.global(qos: .userInitiated).async {
            let r = runScript(args)
            appLog("  -> \(r.ok ? "ok" : "FAILED"): \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            DispatchQueue.main.async {
                self.busy = false
                self.refreshTitle()
                if !r.ok {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "claude-desktop-switch \(args.joined(separator: " ")) failed"
                    alert.informativeText = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()

if CommandLine.arguments.contains("--dump-menu") {
    // Print the menu for testing without clicking.
    let menu = NSMenu()
    delegate.build(menu)
    for mi in menu.items {
        print(mi.isSeparatorItem ? "---" : "\(mi.state == .on ? "✓" : " ") \(mi.title)\(mi.action == nil ? "  (disabled)" : "")")
    }
    exit(0)
}

app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
