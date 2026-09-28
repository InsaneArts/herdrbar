import AppKit
import CoreServices
import OSLog
import ScriptingBridge

let jumpLog = Logger(subsystem: "com.tornikegomareli.Herdrbar", category: "jump")

/// Brings the terminal window that hosts a herdr client to the front, or opens one.
/// Terminals are always addressed by process id: one terminal app can run several instances.
@MainActor
enum Terminals {
    static let ghostty = "com.mitchellh.ghostty"
    static let iTerm = "com.googlecode.iterm2"
    static let terminal = "com.apple.Terminal"
    static let kitty = "net.kovidgoyal.kitty"
    static let alacritty = "org.alacritty"

    /// Raises the exact window when the terminal supports it, otherwise the app.
    static func raise(_ client: HerdrClient, socket: String) async {
        guard let pid = client.hostPID, let app = NSRunningApplication(processIdentifier: pid) else { return }
        NSApp.yieldActivation(to: app)
        // Alacritty and other terminals have no way to focus one window: activating the exact process that
        // hosts herdr is precise when each window is its own process.
        let exact: Bool = switch client.hostBundleID {
        case ghostty: await focusGhostty(pid: pid, socket: socket)
        case iTerm: await focusITerm(pid: pid, tty: client.tty)
        case terminal: await focusTerminal(pid: pid, tty: client.tty)
        case kitty: await focusKitty(client, app: app)
        default: false
        }
        // Selecting a window inside a terminal does not bring the terminal forward; activating its process does.
        let activated = app.activate(from: .current, options: [])
        jumpLog.notice("\(client.hostBundleID ?? "?", privacy: .public) pid \(pid): exact \(exact), activated \(activated)")
    }

    /// Ghostty exposes no tty or pid per terminal, so herdr briefly titles its window with a nonce and
    /// Ghostty's scripting finds the terminal by that name.
    static func focusGhostty(pid: pid_t, socket: String) async -> Bool {
        guard await Automation.allowed(bundleID: ghostty) else { return false }
        let nonce = "herdrbar-\(UInt64.random(in: 1...UInt64.max))"
        let started = ContinuousClock.now
        let line = try? await Herdr.call("client.window_title.set", ["title": nonce], socket: socket)
        let reply = line.flatMap { try? decodeReply($0, as: TitleReply.self) }
        jumpLog.notice("window_title.set: \(reply.map { "\($0.reason) changed=\($0.changed)" } ?? "failed", privacy: .public)")
        guard reply?.reason == "set" else { return false }

        var found = false
        if let app = SBApplication(processIdentifier: pid) {
            app.timeout = 120  // ticks: 2 s, instead of the default 2 minutes
            for _ in 0..<12 {
                if let terminals = app.value(forKey: "terminals") as? SBElementArray,
                   let match = terminals.filtered(using: NSPredicate(format: "name CONTAINS %@", nonce)).first as? SBObject {
                    match.perform(Selector(("focus")))
                    found = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        _ = try? await Herdr.call("client.window_title.clear", socket: socket)
        jumpLog.notice("ghostty terminal found: \(found) after \(ContinuousClock.now - started, privacy: .public)")
        return found
    }

    /// iTerm2 and Terminal.app expose each session's tty, which matches the herdr client's exactly.
    static func focusITerm(pid: pid_t, tty: String?) async -> Bool {
        guard let tty, isSafeTTY(tty), await Automation.allowed(bundleID: iTerm),
              let app = SBApplication(processIdentifier: pid) else { return false }
        app.timeout = 120
        for window in elements(app, "windows") {
            for tab in elements(window, "tabs") {
                for session in elements(tab, "sessions") where session.value(forKey: "tty") as? String == tty {
                    for object in [window, tab, session] { object.perform(Selector(("select"))) }
                    jumpLog.notice("iterm session found for \(tty, privacy: .public)")
                    return true
                }
            }
        }
        return false
    }

    static func focusTerminal(pid: pid_t, tty: String?) async -> Bool {
        guard let tty, isSafeTTY(tty), await Automation.allowed(bundleID: terminal),
              let app = SBApplication(processIdentifier: pid) else { return false }
        app.timeout = 120
        for window in elements(app, "windows") {
            for tab in elements(window, "tabs") where tab.value(forKey: "tty") as? String == tty {
                if window.value(forKey: "miniaturized") as? Bool == true { window.setValue(false, forKey: "miniaturized") }
                tab.setValue(true, forKey: "selected")
                window.setValue(1, forKey: "index")
                jumpLog.notice("terminal tab found for \(tty, privacy: .public)")
                return true
            }
        }
        return false
    }

    /// kitty focuses one window through its remote control, when the user turned it on (`listen_on`).
    static func focusKitty(_ client: HerdrClient, app: NSRunningApplication) async -> Bool {
        guard let bundle = app.bundleURL, let command = kittyCommand(environment: client.environment, kittyApp: bundle) else {
            return false
        }
        do {
            _ = try await CLI.run(command, timeout: .seconds(3))
            return true
        } catch {
            jumpLog.notice("kitty remote control failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// `kitten @ focus-window`, built from the client's own environment. nil without remote control.
    static func kittyCommand(environment: [String: String], kittyApp: URL) -> [String]? {
        guard let address = environment["KITTY_LISTEN_ON"], address.hasPrefix("unix:") || address.hasPrefix("tcp:"),
              let window = environment["KITTY_WINDOW_ID"], let id = Int(window), id > 0 else { return nil }
        return [kittyApp.appending(path: "Contents/MacOS/kitten").path, "@", "--to", address,
                "focus-window", "--match", "id:\(id)"]
    }

    static func isSafeTTY(_ tty: String) -> Bool {
        tty.wholeMatch(of: /\/dev\/tty[a-z0-9]+/) != nil
    }

    private static func elements(_ object: SBObject, _ key: String) -> [SBObject] {
        (object.value(forKey: key) as? SBElementArray)?.compactMap { $0 as? SBObject } ?? []
    }

    /// How to start a terminal running herdr.
    enum OpenPlan: Equatable {
        /// A new instance of the app with these arguments, through Launch Services: no Automation needed.
        case newInstance(arguments: [String])
        /// A `.command` file that the app runs: no Automation needed.
        case commandFile
        /// iTerm2's `create window with default profile command`.
        case iTermScript
    }

    static func openPlan(for bundleID: String, herdr: String) -> OpenPlan? {
        switch bundleID {
        case ghostty, alacritty: .newInstance(arguments: ["-e", herdr])
        case kitty: .newInstance(arguments: [herdr])
        case terminal: .commandFile
        case iTerm: .iTermScript
        default: nil
        }
    }

    /// Opens a terminal running herdr, which attaches to the running session: the terminal herdr last ran
    /// in, else the first installed of Ghostty, iTerm2, and Terminal.
    static func openHerdr(herdr: String, preferred: String?) async {
        for bundleID in [preferred, ghostty, iTerm, terminal].compactMap(\.self) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                  let plan = openPlan(for: bundleID, herdr: herdr) else { continue }
            switch plan {
            case .newInstance(let arguments):
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.arguments = arguments
                configuration.createsNewApplicationInstance = true
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                return
            case .commandFile:
                guard let script = commandFile(running: herdr) else { continue }
                _ = try? await NSWorkspace.shared.open([script], withApplicationAt: url, configuration: NSWorkspace.OpenConfiguration())
                return
            case .iTermScript:
                guard await Automation.allowed(bundleID: iTerm),
                      let running = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()),
                      let app = SBApplication(processIdentifier: running.processIdentifier) else { continue }
                app.timeout = 120
                app.perform(Selector(("createWindowWithDefaultProfileCommand:")), with: herdr)
                return
            }
        }
    }

    /// A `.command` file makes Terminal run herdr without Apple Events.
    private static func commandFile(running herdr: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appending(path: "herdrbar-open-herdr.command")
        let quoted = "'" + herdr.replacingOccurrences(of: "'", with: "'\\''") + "'"
        guard (try? Data("#!/bin/sh\nexec \(quoted)\n".utf8).write(to: url)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

enum Automation {
    /// Asks macOS whether Herdrbar may send Apple Events to an app, prompting the user the first time.
    /// macOS stores the answer per app, so the bundle id is the target. The prompt blocks until
    /// answered, so this runs off the main thread.
    static func allowed(bundleID: String) async -> Bool {
        let status = await Task.detached {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            guard let descriptor = target.aeDesc else { return OSStatus(paramErr) }
            return AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, true)
        }.value
        jumpLog.notice("automation permission for \(bundleID, privacy: .public): \(status)")
        UserDefaults.standard.set(status == OSStatus(errAEEventNotPermitted), forKey: "AutomationDenied")
        return status == noErr
    }
}
