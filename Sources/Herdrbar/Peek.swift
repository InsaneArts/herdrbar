import AppKit

/// The bottom of an agent's screen, trimmed for a small preview beside the menu.
enum Peek {
    static let lineLimit = 16
    static let widthLimit = 90

    static func lines(from text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            // Status bars pad with long runs of spaces; keep the words, drop the gap.
            var line = String(raw).replacing(/\ {3,}/, with: "   ")
            while line.last?.isWhitespace == true { line.removeLast() }
            return line.count > widthLimit ? String(line.prefix(widthLimit - 1)) + "…" : line
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        var tail = Array(lines.suffix(lineLimit))
        while tail.first?.isEmpty == true { tail.removeFirst() }
        return tail
    }
}

struct AgentReadResult: Decodable, Sendable {
    struct Read: Decodable, Sendable { var text: String }
    var read: Read
}

/// A floating preview next to the open menu. It ignores the mouse, so hovering and clicking still
/// belong to the menu, and it never takes focus.
@MainActor
final class PeekPanel {
    private let panel: NSPanel
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let screen = NSTextField(wrappingLabelWithString: "")
    private let stack: NSStackView
    /// 90 columns of 11 pt monospaced text (6.6 pt each) plus padding, so lines never wrap.
    static let width: CGFloat = 624

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        screen.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        screen.textColor = .labelColor
        screen.lineBreakMode = .byCharWrapping
        screen.preferredMaxLayoutWidth = Self.width - 28
        let divider = NSBox()
        divider.boxType = .separator

        stack = NSStackView(views: [title, subtitle, divider, screen])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.setCustomSpacing(10, after: subtitle)
        divider.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        background.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            background.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        panel.contentView = background
    }

    /// Shows the agent beside `menuFrame`: on its left, or on its right when the left has no room.
    /// nil `lines` means the screen is still being read.
    func show(_ row: AgentRow, lines: [String]?, beside menuFrame: NSRect, on display: NSScreen) {
        title.stringValue = row.title
        subtitle.stringValue = row.subtitle
        screen.stringValue = lines.map { $0.isEmpty ? "(empty screen)" : $0.joined(separator: "\n") } ?? "Reading…"
        stack.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: min(stack.fittingSize.height, display.visibleFrame.height - 40))
        var x = menuFrame.minX - size.width - 6
        if x < display.visibleFrame.minX { x = menuFrame.maxX + 6 }
        let y = max(display.visibleFrame.minY, menuFrame.maxY - size.height)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
