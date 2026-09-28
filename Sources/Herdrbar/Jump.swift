import AppKit

/// Takes you to an agent: herdr focuses it, then the terminal window running herdr comes forward.
@MainActor
final class Jump {
    var lastActive: [pid_t: Date] = [:]
    private var observer: NSObjectProtocol?

    init() {
        if let front = NSWorkspace.shared.frontmostApplication { lastActive[front.processIdentifier] = .now }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.lastActive[pid] = .now }
        }
    }

    func to(_ agent: Agent, install: HerdrInstall) async {
        if agent.key.machine == Fleet.local, isSafeID(agent.paneID) {
            // `agent.focus` moves herdr's focus but not the attached client's view in herdr 0.9.0
            // (herdr#3760). `pane.focus` moves both, and also marks a done agent as seen.
            _ = try? await Herdr.call("pane.focus", ["pane_id": agent.paneID], socket: install.socketPath)
        }
        await raiseHerdr(install: install)
    }

    /// Brings the herdr window forward without changing what herdr shows, or opens one.
    func raiseHerdr(install: HerdrInstall) async {
        let clients = ClientLocator.localClients()
        jumpLog.notice("herdr clients: \(clients.map { "\($0.pid)@\($0.hostBundleID ?? "-")" }.joined(separator: ", "), privacy: .public)")
        guard !clients.isEmpty else {
            if let herdr = install.binary {
                Terminals.openHerdr(herdr: herdr, preferred: UserDefaults.standard.string(forKey: "LastHerdrTerminal"))
            }
            return
        }
        // A client inside tmux or ssh has no terminal app of its own: herdr's focus is all we can do.
        guard let client = mostRecentlyUsed(clients) else { return }
        if let bundleID = client.hostBundleID { UserDefaults.standard.set(bundleID, forKey: "LastHerdrTerminal") }
        await Terminals.raise(client, socket: install.socketPath)
    }

    /// With several herdr clients, the one whose terminal you used last wins; then the newest.
    func mostRecentlyUsed(_ clients: [HerdrClient]) -> HerdrClient? {
        clients.filter { $0.hostPID != nil }.max { a, b in
            let lastA = lastActive[a.hostPID!] ?? .distantPast, lastB = lastActive[b.hostPID!] ?? .distantPast
            return lastA != lastB ? lastA < lastB : a.pid < b.pid
        }
    }
}

/// Ids from herdr reach other programs only when they have a plain shape.
func isSafeID(_ id: String) -> Bool {
    id.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._:@-]{0,127}/) != nil
}
