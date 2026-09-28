import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var fleet = Fleet()
    private let menu = StatusMenu()
    private var install = HerdrInstall.locate()
    private var source: LocalSource?
    private let jump = Jump()
    private var tasks: [Task<Void, Never>] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
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
    }

    private func apply(_ result: Result<Snapshot, any Error>, machine: String) {
        _ = fleet.apply(result, machine: machine, now: .now)
        render()
    }

    private func render() {
        let localMachine = fleet.machines[Fleet.local]
        if localMachine?.firstFailure != nil { install = HerdrInstall.locate() }
        let local = MenuRows.localState(machine: localMachine, herdrInstalled: install.isInstalled, now: .now)
        menu.update(MenuRows.model(fleet: fleet, local: local, now: .now))
    }

    private func jump(to key: AgentKey) {
        guard let agent = fleet.agent(key) else { return }
        Task {
            await jump.to(agent, install: install)
            source?.refresh()
        }
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
