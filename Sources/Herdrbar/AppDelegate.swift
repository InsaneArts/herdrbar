import AppKit
import ServiceManagement
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var fleet = Fleet()
    private let menu = StatusMenu()
    private var install = HerdrInstall.locate()
    private var source: LocalSource?
    private let jump = Jump()
    private let hotkeys = Hotkeys()
    private lazy var settings = SettingsModel(hotkeys: hotkeys)
    private let settingsWindow = SettingsWindow()
    private lazy var notifier = Notifier(.init(
        post: { notice in
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            content.sound = notice.playsSound ? .default : nil
            content.userInfo = ["machine": notice.key.machine, "terminal": notice.key.terminalID]
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil), withCompletionHandler: nil)
        },
        remove: { identifiers in
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
        },
        currentAgent: { [weak self] key in self?.fleet.agent(key) },
        herdrIsFrontmost: { Self.herdrIsFrontmost() },
        notifyDone: { [weak self] in self?.settings.notifyDone ?? true }))
    private var lastHotkeyJump: AgentKey?
    private let peek = PeekPanel()
    private var screens: [AgentKey: (lines: [String], at: Date)] = [:]
    private var highlighted: AgentKey?
    private var tasks: [Task<Void, Never>] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        let source = LocalSource(socketPath: install.socketPath)
        self.source = source
        menu.onWillOpen = { [weak self] in
            self?.source?.refresh()
            self?.render()
        }
        menu.onSelect = { [weak self] key in self?.jump(to: key) }
        menu.onOpenHerdr = { [weak self] in
            guard let self else { return }
            Task { await self.jump.raiseHerdr(install: self.install) }
        }
        menu.onSettings = { [weak self] in self?.showSettings() }
        menu.onHighlight = { [weak self] row in self?.highlight(row) }
        hotkeys.onPress = { [weak self] action in self?.hotkeyPressed(action) }
        let publish: @Sendable (Result<Snapshot, any Error>) async -> Void = { [weak self] result in
            await self?.apply(result, machine: Fleet.local)
        }
        tasks.append(Task { await source.run(publish: publish) })
        // Keeps "4m" labels moving. Task.sleep, unlike a default-mode Timer, also fires while the menu is open.
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.render()
            }
        })
        render()
        welcome()
    }

    /// Opening the app again from Finder or Spotlight shows Settings: the way back when the notch hides the icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    private func apply(_ result: Result<Snapshot, any Error>, machine: String) {
        let transitions = fleet.apply(result, machine: machine, now: .now)
        render()
        notifier.handle(transitions)
    }

    private func render() {
        let localMachine = fleet.machines[Fleet.local]
        if localMachine?.firstFailure != nil { install = HerdrInstall.locate() }
        let local = MenuRows.localState(machine: localMachine, herdrInstalled: install.isInstalled, now: .now)
        menu.update(MenuRows.model(fleet: fleet, local: local, now: .now))
    }

    private func jump(to key: AgentKey) {
        notifier.withdraw(key)
        guard let agent = fleet.agent(key) else { return }
        Task {
            await jump.to(agent, install: install)
            source?.refresh()
        }
    }

    private func hotkeyPressed(_ action: HotkeyAction) {
        switch action {
        case .openMenu:
            menu.open()
        case .nextWaiting:
            // With herdr unavailable, the menu says why.
            if menu.model.herdrDown { return menu.open() }
            guard let key = MenuRows.nextWaiting(in: menu.model, after: lastHotkeyJump) else { return NSSound.beep() }
            lastHotkeyJump = key
            jump(to: key)
        }
    }

    /// Peek: shows the highlighted agent's last screen lines beside the menu. Read on demand and kept
    /// for a few seconds; never written to notifications, because agent output can contain secrets.
    private func highlight(_ row: AgentRow?) {
        highlighted = row?.key
        guard let row, row.key.machine == Fleet.local, let agent = fleet.agent(row.key),
              let place = menu.openMenuFrame else { return peek.hide() }
        let cached = screens[row.key].flatMap { Date.now.timeIntervalSince($0.at) < 3 ? $0.lines : nil }
        peek.show(row, lines: cached, beside: place.frame, on: place.screen)
        guard cached == nil else { return }
        let socket = install.socketPath, pane = agent.paneID
        Task {
            let lines = await Self.readScreen(pane: pane, socket: socket)
            screens[row.key] = (lines, .now)
            guard highlighted == row.key, let place = menu.openMenuFrame else { return }
            peek.show(row, lines: lines, beside: place.frame, on: place.screen)
        }
    }

    private static func readScreen(pane: String, socket: String) async -> [String] {
        struct Params: Encodable, Sendable {
            var target: String
            var source = "detection"
        }
        guard isSafeID(pane), let line = try? await Herdr.call("agent.read", Params(target: pane), socket: socket),
              let result = try? decodeReply(line, as: AgentReadResult.self) else { return ["Can't read this agent's screen."] }
        return Peek.lines(from: result.read.text)
    }

    private func showSettings() {
        settingsWindow.show(settings)
    }

    /// First launch: the menu opens once so you see where Herdrbar lives; macOS asks about notifications
    /// after it closes. An installed copy also turns on Open at Login; a development build does not.
    private func welcome() {
        let center = UNUserNotificationCenter.current()
        guard !UserDefaults.standard.bool(forKey: "LaunchedBefore") else {
            Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
            return
        }
        UserDefaults.standard.set(true, forKey: "LaunchedBefore")
        if Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent == "Applications" {
            try? SMAppService.mainApp.register()
        }
        menu.onDidClose = { [weak self] in
            self?.menu.onDidClose = nil
            Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            menu.open()
        }
    }

    /// herdr's own UI already shows a change while the terminal hosting it is in front. Compared by pid,
    /// so a second instance of the same terminal app doesn't count.
    static func herdrIsFrontmost() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        return ClientLocator.localClients().contains { $0.hostPID == front }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let machine = info["machine"] as? String, let terminal = info["terminal"] as? String else { return }
        await MainActor.run { jump(to: AgentKey(machine: machine, terminalID: terminal)) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

/// Where herdr lives. GUI apps don't see the shell's PATH, so the usual install locations are checked.
struct HerdrInstall {
    var binary: String?
    var socketPath: String

    var isInstalled: Bool { binary != nil || FileManager.default.fileExists(atPath: socketPath) }

    static func locate(defaults: UserDefaults = .standard) -> HerdrInstall {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [defaults.string(forKey: "HerdrPath"), "\(home)/.local/bin/herdr",
                          "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"].compactMap(\.self)
        return HerdrInstall(
            binary: candidates.first { FileManager.default.isExecutableFile(atPath: $0) },
            socketPath: defaults.string(forKey: "HerdrSocketPath") ?? "\(home)/.config/herdr/herdr.sock")
    }
}
