import AppKit

/// The menu bar item and its native menu. While the menu is open, rows only update in place:
/// nothing is added, removed, or reordered under the pointer.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    var onSelect: ((AgentKey) -> Void)?
    var onWillOpen: (() -> Void)?

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var model = MenuModel()
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
        rebuild()
    }

    // MARK: Menu bar button

    private func updateButton() {
        guard let button = item.button else { return }
        // Placeholder glyphs until the custom template image exists.
        let symbol = model.herdrDown ? "circle.slash" : model.anyBlocked ? "circle.hexagongrid.fill" : "circle.hexagongrid"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image?.isTemplate = true
        button.image = image
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
        menu.addItem(NSMenuItem(title: "Quit Herdrbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
