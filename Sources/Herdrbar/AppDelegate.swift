import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var fleet = Fleet()
    private let menu = StatusMenu()
    private var install = HerdrInstall.locate()
    private var source: LocalSource?
    private let jump = Jump()
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
        notifyDone: { UserDefaults.standard.object(forKey: "NotifyDone") as? Bool ?? true }))
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
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
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
