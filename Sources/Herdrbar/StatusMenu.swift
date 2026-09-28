import AppKit

/// The menu bar item and its native menu. While the menu is open, rows only update in place:
/// nothing is added, removed, or reordered under the pointer.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    var onSelect: ((AgentKey) -> Void)?
    var onOpenHerdr: (() -> Void)?
    var onSettings: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onWillOpen: (() -> Void)?
    var onDidClose: (() -> Void)?
    /// The agent row under the pointer or the keyboard highlight, or nil when there is none.
    var onHighlight: ((AgentRow?) -> Void)?

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private(set) var model = MenuModel()
    private var isOpen = false
    private var rowItems: [AgentKey: NSMenuItem] = [:]

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.imagePosition = .imageLeading
        item.button?.setAccessibilityLabel("Herdrbar")
        update(MenuModel(notice: .connecting, tooltip: "Connecting to Herdr"))
    }

    func update(_ model: MenuModel) {
        self.model = model
        updateButton()
        if isOpen { updateRowsInPlace() } else { rebuild() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
        onWillOpen?()
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        onHighlight?(nil)
        rebuild()
        onDidClose?()
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        let key = item?.representedObject as? AgentKey
        onHighlight?((model.needsYou + model.working + model.idle).first { $0.key == key })
    }

    /// Where the open menu sits on screen. The menu drops down from the icon, so its frame follows from
    /// the icon's window and the menu's size.
    var openMenuFrame: (frame: NSRect, screen: NSScreen)? {
        guard let window = item.button?.window, let screen = window.screen else { return nil }
        let size = menu.size
        let x = min(window.frame.minX, screen.visibleFrame.maxX - size.width)
        return (NSRect(x: x, y: window.frame.minY - size.height, width: size.width, height: size.height), screen)
    }

    /// Opens the menu as if its icon was clicked (the hotkey, and first launch).
    func open() {
        item.button?.performClick(nil)
    }

    // MARK: Menu bar button

    private func updateButton() {
        guard let button = item.button else { return }
        button.image = MenuBarGlyph.image(attention: model.anyBlocked, down: model.herdrDown)
        if model.attention > 0 {
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
            button.attributedTitle = NSAttributedString(string: " \(model.attention)", attributes: [.font: font])
        } else {
            button.title = ""
        }
        button.toolTip = model.tooltip
        button.setAccessibilityValue(model.tooltip)
    }

    // MARK: Menu

    private func rebuild() {
        menu.removeAllItems()
        rowItems = [:]
        if let notice = model.notice { menu.addItem(disabledItem(notice.text)) }
        addSection("Needs You", model.needsYou)
        addSection("Working", model.working)
        if !model.idle.isEmpty {
            menu.addItem(.separator())
            let idle = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
            idle.badge = NSMenuItemBadge(count: model.idle.count)
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for row in model.idle { submenu.addItem(rowItem(row)) }
            idle.submenu = submenu
            menu.addItem(idle)
        }
        if case .tooOld = model.notice {
            menu.addItem(disabledItem("Run brew upgrade herdr"))
        }
        menu.addItem(.separator())
        switch model.notice {
        case .notInstalled?: menu.addItem(actionItem("Get Herdr", #selector(getHerdr)))
        case .notRunning?: menu.addItem(actionItem("Start Herdr", #selector(openHerdr), key: "o"))
        default: menu.addItem(actionItem("Open Herdr", #selector(openHerdr), key: "o"))
        }
        if let until = model.pausedUntil {
            let resume = actionItem("Resume Notifications", #selector(togglePause))
            resume.subtitle = "Paused until \(until.formatted(date: .omitted, time: .shortened))"
            menu.addItem(resume)
        } else {
            menu.addItem(actionItem("Pause Notifications for 1 Hour", #selector(togglePause)))
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Settings…", #selector(openSettings), key: ","))
        menu.addItem(NSMenuItem(title: "Quit Herdrbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func openSettings() { onSettings?() }

    @objc private func togglePause() { onTogglePause?() }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openHerdr() { onOpenHerdr?() }

    @objc private func getHerdr() {
        if let url = URL(string: "https://herdr.dev") { NSWorkspace.shared.open(url) }
    }

    private func addSection(_ title: String, _ rows: [AgentRow]) {
        guard !rows.isEmpty else { return }
        menu.addItem(.sectionHeader(title: title))
        for row in rows { menu.addItem(rowItem(row)) }
    }

    private func rowItem(_ row: AgentRow) -> NSMenuItem {
        let item = NSMenuItem(title: row.title, action: #selector(selectRow(_:)), keyEquivalent: "")
        item.target = self
        item.subtitle = row.subtitle
        item.image = Self.image(for: row.status)
        item.representedObject = row.key
        rowItems[row.key] = item
        return item
    }

    private func updateRowsInPlace() {
        let rows = model.needsYou + model.working + model.idle
        let current = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, item) in rowItems {
            guard let row = current[key] else {
                item.isEnabled = false  // gone; the row leaves when the menu opens again
                continue
            }
            if item.title != row.title { item.title = row.title }
            if item.subtitle != row.subtitle { item.subtitle = row.subtitle }
            item.image = Self.image(for: row.status)
            item.isEnabled = true
        }
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func selectRow(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? AgentKey else { return }
        onSelect?(key)
    }

    private static let images: [AgentStatus: NSImage] = {
        var images: [AgentStatus: NSImage] = [:]
        for status in AgentStatus.allCases {
            let (symbol, color, label): (String, NSColor?, String) = switch status {
            case .blocked: ("exclamationmark.circle.fill", .systemOrange, "Needs your answer")
            case .done: ("checkmark.circle.fill", .systemGreen, "Finished")
            case .working: ("circle.dotted", nil, "Working")
            case .idle: ("circle", nil, "Idle")
            case .unknown: ("questionmark.circle", nil, "State unknown")
            }
            guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: label) else { continue }
            if let color {
                images[status] = base.withSymbolConfiguration(.init(paletteColors: [.white, color])) ?? base
            } else {
                base.isTemplate = true
                images[status] = base
            }
        }
        return images
    }()

    private static func image(for status: AgentStatus) -> NSImage? { images[status] }
}

/// herdr's ram, cropped from its logo (Scripts/make_menubar_icon.py), drawn as a template image.
/// A blocked agent adds a badge dot; an unavailable herdr dims the ram and slashes it.
@MainActor
enum MenuBarGlyph {
    static let ram: NSImage? = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf").flatMap(NSImage.init(contentsOf:))

    private static var cache: [Int: NSImage] = [:]

    static func image(attention: Bool, down: Bool, ram: NSImage? = MenuBarGlyph.ram) -> NSImage? {
        guard let ram else {
            // `swift run` has no app bundle, so no PDF.
            let image = NSImage(systemSymbolName: down ? "circle.slash" : attention ? "circle.hexagongrid.fill" : "circle.hexagongrid",
                                accessibilityDescription: nil)
            image?.isTemplate = true
            return image
        }
        let key = (attention ? 1 : 0) + (down ? 2 : 0)
        if ram === MenuBarGlyph.ram, let cached = cache[key] { return cached }
        let image = NSImage(size: ram.size, flipped: false) { rect in
            ram.draw(in: rect, from: .zero, operation: .sourceOver, fraction: down ? 0.45 : 1)
            let context = NSGraphicsContext.current
            if attention && !down {
                // Bottom right sits on the ram's chest; the horn at the top stays readable.
                let dot = NSRect(x: rect.maxX - 5.5, y: rect.minY, width: 5.5, height: 5.5)
                context?.compositingOperation = .clear
                NSBezierPath(ovalIn: dot.insetBy(dx: -1.3, dy: -1.3)).fill()
                context?.compositingOperation = .sourceOver
                NSColor.black.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            if down {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: rect.minX + 1.5, y: rect.maxY - 1.5))
                slash.line(to: NSPoint(x: rect.maxX - 1.5, y: rect.minY + 1.5))
                slash.lineCapStyle = .round
                context?.compositingOperation = .clear
                slash.lineWidth = 4.5
                slash.stroke()
                context?.compositingOperation = .sourceOver
                NSColor.black.setStroke()
                slash.lineWidth = 1.5
                slash.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Herdrbar"
        if ram === MenuBarGlyph.ram { cache[key] = image }
        return image
    }
}
