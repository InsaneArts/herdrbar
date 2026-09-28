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

    /// Raises the exact window when the terminal supports it, otherwise the app.
    static func raise(_ client: HerdrClient, socket: String) async {
        guard let pid = client.hostPID, let app = NSRunningApplication(processIdentifier: pid) else { return }
        NSApp.yieldActivation(to: app)
        let exact: Bool = switch client.hostBundleID {
        case ghostty: await focusGhostty(pid: pid, socket: socket)
        default: false
        }
        if !exact {
            let activated = app.activate(from: .current, options: [])
            jumpLog.notice("app activation of \(client.hostBundleID ?? "?", privacy: .public) pid \(pid): \(activated)")
        }
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
        if found {
            let activated = NSRunningApplication(processIdentifier: pid)?.activate(from: .current, options: []) ?? false
            jumpLog.notice("ghostty activation: \(activated)")
        }
        return found
    }

    /// Opens a terminal running herdr, which attaches to the running session. Launch Services needs no
    /// Automation permission.
    static func openHerdr(herdr: String, preferred: String?) {
        let candidates = [preferred, ghostty, terminal].compactMap(\.self)
        for bundleID in candidates {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            switch bundleID {
            case ghostty:
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.arguments = ["-e", herdr]
                configuration.createsNewApplicationInstance = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                return
            case terminal:
                guard let script = commandFile(running: herdr) else { continue }
                NSWorkspace.shared.open([script], withApplicationAt: url, configuration: NSWorkspace.OpenConfiguration())
                return
            default:
                continue
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
