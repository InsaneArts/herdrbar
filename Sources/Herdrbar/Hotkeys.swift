import AppKit
import Carbon.HIToolbox

/// A key combination for a global hotkey, stored with the text Settings shows for it.
struct Shortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    /// Carbon modifier mask: cmdKey, optionKey, controlKey, shiftKey.
    var modifiers: UInt32
    var display: String

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    /// nil unless ⌘, ⌥ or ⌃ is held: a shortcut with shift alone would swallow typing everywhere.
    init?(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) {
        let flags = flags.intersection([.command, .option, .control, .shift])
        guard !flags.isDisjoint(with: [.command, .option, .control]) else { return nil }
        var carbon: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
        self.init(keyCode: UInt32(keyCode), modifiers: carbon, display: symbols + Self.keyName(keyCode, characters))
    }

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func keyName(_ keyCode: UInt16, _ characters: String?) -> String {
        namedKeys[Int(keyCode)] ?? characters?.uppercased() ?? "#\(keyCode)"
    }
}

enum HotkeyAction: UInt32, CaseIterable, Sendable {
    case openMenu = 1
    case nextWaiting = 2

    var title: String {
        switch self {
        case .openMenu: "Open Herdrbar menu"
        case .nextWaiting: "Go to next agent that needs you"
        }
    }

    var defaultsKey: String { "Shortcut.\(rawValue)" }
}

/// System-wide hotkeys through Carbon's RegisterEventHotKey, which needs no permission.
/// (A global NSEvent monitor would need Input Monitoring.)
@MainActor
final class Hotkeys {
    var onPress: ((HotkeyAction) -> Void)?
    private var registered: [HotkeyAction: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?

    init() {
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard let userData, let action = HotkeyAction(rawValue: id.id) else { return noErr }
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers application events on the main thread.
            MainActor.assumeIsolated { hotkeys.onPress?(action) }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
        for action in HotkeyAction.allCases { _ = register(shortcut(for: action), for: action) }
    }

    func shortcut(for action: HotkeyAction) -> Shortcut? {
        UserDefaults.standard.data(forKey: action.defaultsKey).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
    }

    /// Returns false when another app already owns the combination; the old shortcut then stays.
    @discardableResult
    func set(_ shortcut: Shortcut?, for action: HotkeyAction) -> Bool {
        let previous = self.shortcut(for: action)
        guard register(shortcut, for: action) else {
            _ = register(previous, for: action)
            return false
        }
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: action.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: action.defaultsKey)
        }
        return true
    }

    private func register(_ shortcut: Shortcut?, for action: HotkeyAction) -> Bool {
        if let old = registered.removeValue(forKey: action) { UnregisterEventHotKey(old) }
        guard let shortcut else { return true }
        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4852_4442), id: action.rawValue)  // 'HRDB'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return false }
        registered[action] = reference
        return true
    }
}
