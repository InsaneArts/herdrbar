import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

@MainActor @Observable
final class SettingsModel {
    let hotkeys: Hotkeys
    let updater: Updater
    var openAtLogin = SMAppService.mainApp.status == .enabled
    var loginError: String?
    var automationDenied = false
    var recording: HotkeyAction?
    var cards = CardPreferences.load() {
        didSet { cards.save() }
    }
    var shortcutError: [HotkeyAction: String] = [:]
    private var monitor: Any?

    init(hotkeys: Hotkeys, updater: Updater) {
        self.hotkeys = hotkeys
        self.updater = updater
    }

    var notifyDone: Bool {
        get { UserDefaults.standard.object(forKey: "NotifyDone") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "NotifyDone") }
    }

    func refresh() {
        openAtLogin = SMAppService.mainApp.status == .enabled
        automationDenied = UserDefaults.standard.bool(forKey: "AutomationDenied")
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    func startRecording(_ action: HotkeyAction) {
        stopRecording()
        recording = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
            return nil
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    func clear(_ action: HotkeyAction) {
        hotkeys.set(nil, for: action)
        shortcutError[action] = nil
    }

    private func record(_ event: NSEvent) {
        guard let action = recording else { return }
        switch Int(event.keyCode) {
        case kVK_Escape:
            stopRecording()
        case kVK_Delete where event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty:
            clear(action)
            stopRecording()
        default:
            guard let shortcut = Shortcut(keyCode: event.keyCode, flags: event.modifierFlags,
                                          characters: event.charactersIgnoringModifiers) else {
                NSSound.beep()  // needs ⌘, ⌥ or ⌃
                return
            }
            shortcutError[action] = hotkeys.set(shortcut, for: action) ? nil : "\(shortcut.display) is used by another app."
            stopRecording()
        }
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                if let error = model.loginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Notifications") {
                Toggle("Show notifications", isOn: $model.cards.enabled)
                if model.cards.enabled {
                    Toggle("Also when an agent finishes", isOn: $model.notifyDone)
                    Picker("Position", selection: $model.cards.corner) {
                        ForEach(CardCorner.allCases, id: \.self) { Text($0.title) }
                    }
                    Picker("Display", selection: $model.cards.display) {
                        ForEach(CardDisplay.allCases, id: \.self) { Text($0.title) }
                    }
                    Picker("Layer", selection: $model.cards.layer) {
                        ForEach(CardLayer.allCases, id: \.self) { Text($0.title) }
                    }
                    Toggle("Show on every Space", isOn: $model.cards.everySpace)
                }
            }
            Section("Keyboard Shortcuts") {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) { recorder(for: action) }
                    if let error = model.shortcutError[action] {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            if model.automationDenied {
                Section {
                    fixIt("Allow Herdrbar to control your terminal to bring the exact herdr window forward.",
                          button: "Open Privacy Settings…",
                          url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
                }
            }
            Section("Updates") {
                @Bindable var updater = model.updater
                LabeledContent {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                } label: {
                    Text(["Herdrbar", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String]
                        .compactMap(\.self).joined(separator: " "))
                    Text(updater.availableVersion.map { "Version \($0) is available." }
                        ?? updater.lastCheckedAt.map { "Last checked \($0.formatted(.relative(presentation: .named)))." }
                        ?? "Not checked yet.")
                }
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                Toggle("Download updates automatically", isOn: $updater.automaticallyDownloadsUpdates)
                    .disabled(!updater.automaticallyChecksForUpdates)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { model.stopRecording() }
    }

    private func recorder(for action: HotkeyAction) -> some View {
        HStack(spacing: 6) {
            let recording = model.recording == action
            Button(recording ? "Type Shortcut…" : model.hotkeys.shortcut(for: action)?.display ?? "Record Shortcut") {
                recording ? model.stopRecording() : model.startRecording(action)
            }
            if !recording, model.hotkeys.shortcut(for: action) != nil {
                Button { model.clear(action) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("Remove shortcut")
            }
        }
    }

    private func fixIt(_ text: String, button: String, url: String) -> some View {
        HStack {
            Text(text)
            Spacer()
            Button(button) { if let url = URL(string: url) { NSWorkspace.shared.open(url) } }
        }
    }
}

@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    func show(_ model: SettingsModel) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "Herdrbar Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // Above other apps' windows, so it never opens hidden behind them.
            window.level = .floating
            window.center()
            self.window = window
        }
        model.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
