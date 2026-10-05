import AppKit
import Aurora
import SwiftUI

enum CardCorner: String, CaseIterable, Sendable {
    case topRight, topCenter, topLeft, bottomRight, bottomLeft

    var isTop: Bool { self == .topRight || self == .topCenter || self == .topLeft }

    var title: String {
        switch self {
        case .topRight: "Top right"
        case .topCenter: "Top center"
        case .topLeft: "Top left"
        case .bottomRight: "Bottom right"
        case .bottomLeft: "Bottom left"
        }
    }
}

enum CardDisplay: String, CaseIterable, Sendable {
    case main, pointer

    var title: String { self == .main ? "Main display" : "Display with the pointer" }
}

enum CardLayer: String, CaseIterable, Sendable {
    case aboveWindows, desktop

    var title: String { self == .aboveWindows ? "Above windows" : "On the desktop" }
}

struct CardPreferences: Equatable, Sendable {
    /// Off, Herdrbar shows no notifications; the menu still counts what needs you.
    var enabled = true
    var corner = CardCorner.topRight
    var display = CardDisplay.main
    var layer = CardLayer.aboveWindows
    /// On, a card follows you to every Space. Off, it stays on the Space where it appeared.
    var everySpace = true

    static func load(_ defaults: UserDefaults = .standard) -> CardPreferences {
        func value<T: RawRepresentable<String>>(_ key: String) -> T? { defaults.string(forKey: key).flatMap(T.init) }
        var preferences = CardPreferences()
        preferences.enabled = defaults.object(forKey: "NotificationsEnabled") as? Bool ?? preferences.enabled
        preferences.corner = value("CardCorner") ?? preferences.corner
        preferences.display = value("CardDisplay") ?? preferences.display
        preferences.layer = value("CardLayer") ?? preferences.layer
        preferences.everySpace = defaults.object(forKey: "CardEverySpace") as? Bool ?? preferences.everySpace
        return preferences
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: "NotificationsEnabled")
        defaults.set(corner.rawValue, forKey: "CardCorner")
        defaults.set(display.rawValue, forKey: "CardDisplay")
        defaults.set(layer.rawValue, forKey: "CardLayer")
        defaults.set(everySpace, forKey: "CardEverySpace")
    }
}

/// Where cards go: the newest in the corner, older ones stacked away from it.
enum CardLayout {
    static let card = CGSize(width: 340, height: 74)
    /// Room around the card for its shadow and its squash.
    static let padding: CGFloat = 24
    static let edge: CGFloat = 12
    static let gap: CGFloat = 10
    static let limit = 3

    static func cardFrame(index: Int, corner: CardCorner, in area: CGRect) -> CGRect {
        let x = switch corner {
        case .topLeft, .bottomLeft: area.minX + edge
        case .topCenter: area.midX - card.width / 2
        case .topRight, .bottomRight: area.maxX - edge - card.width
        }
        let step = CGFloat(index) * (card.height + gap)
        let y = corner.isTop ? area.maxY - edge - card.height - step : area.minY + edge + step
        return CGRect(origin: CGPoint(x: x, y: y), size: card)
    }

    static func panelFrame(index: Int, corner: CardCorner, in area: CGRect) -> CGRect {
        cardFrame(index: index, corner: corner, in: area).insetBy(dx: -padding, dy: -padding)
    }

    /// How far a card has slid to its new slot at `k` (0…1) of the move: fast out, a little past the slot, back.
    static func slide(_ k: Double) -> Double {
        let c1 = 1.2, c3 = c1 + 1, x = k - 1
        return k <= 0 ? 0 : k >= 1 ? 1 : 1 + c3 * x * x * x + c1 * x * x
    }

    static func mix(_ a: CGRect, _ b: CGRect, _ k: Double) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * k, y: a.minY + (b.minY - a.minY) * k, width: a.width, height: a.height)
    }
}

/// A card's headline. The first line of each kind says plainly what happened; the others have fun with it.
enum CardCopy {
    static func headline(name: String, blocked: Bool, reminder: Bool, variant: Int) -> String {
        let lines = reminder ? ["\(name) is still waiting", "\(name) misses you", "\(name) is still tapping its foot"]
            : blocked ? ["\(name) needs you", "\(name) has a question", "\(name) is tapping its foot", "\(name) raised a hand"]
            : ["\(name) is done", "Ta-da! \(name) is done", "\(name) finished. High five?", "\(name) wrapped it up"]
        return lines[(variant % lines.count + lines.count) % lines.count]
    }
}

struct CardContent: Equatable, Sendable {
    var blocked: Bool
    var headline: String
    var detail: String
    var place: String
}

extension CardContent {
    init(_ notice: AgentNotice, variant: Int = .random(in: 0..<100)) {
        self.init(blocked: notice.blocked,
                  headline: CardCopy.headline(name: notice.agentName, blocked: notice.blocked, reminder: notice.reminder, variant: variant),
                  detail: notice.task ?? (notice.blocked ? "Waiting for your answer." : "Ready for the next task."),
                  place: notice.place)
    }
}

/// Herdrbar's own notifications: glass cards that drop in, squash, and settle. A click jumps to the agent.
/// A finished agent's card goes after a few seconds; a blocked agent's card stays until you answer or close it.
@MainActor
final class CardStack {
    var onClick: (AgentKey) -> Void = { _ in }

    private struct Card {
        let id: String
        let key: AgentKey?
        let panel: NSPanel
        let model: CardModel
    }

    static let doneLifetime: Duration = .seconds(8)
    /// Newest first: index 0 sits in the corner.
    private var cards: [Card] = []
    private var timers: [String: Task<Void, Never>] = [:]
    /// The cards moving to new slots. A new slide replaces a card's old one, from wherever it is.
    private var slides: [String: Slide] = [:]
    /// Fixed while any card is up, so the stack never jumps to another display or corner.
    private var anchor: (corner: CardCorner, area: CGRect)?

    func show(_ notice: AgentNotice) {
        show(CardContent(notice), id: notice.identifier, key: notice.key)
    }

    func remove(_ ids: [String]) {
        for id in ids { dismiss(id) }
    }

    private func show(_ content: CardContent, id: String, key: AgentKey?) {
        if let card = cards.first(where: { $0.id == id }) {
            card.model.content = content
            card.model.arrivals += 1
            schedule(card)
            return
        }
        let preferences = CardPreferences.load()
        if anchor == nil, let screen = screen(for: preferences.display) {
            anchor = (preferences.corner, screen.visibleFrame)
        }
        guard let anchor else { return }
        let model = CardModel(content)
        let panel = Self.panel(preferences)
        panel.contentView = CardHostingView(rootView: CardView(
            model: model, fromTop: anchor.corner.isTop,
            onClick: { [weak self] in self?.clicked(id) },
            onClose: { [weak self] in self?.dismiss(id) }))
        let card = Card(id: id, key: key, panel: panel, model: model)
        cards.insert(card, at: 0)
        if cards.count > CardLayout.limit, let oldest = cards.last { dismiss(oldest.id) }
        panel.setFrame(CardLayout.panelFrame(index: 0, corner: anchor.corner, in: anchor.area), display: false)
        layout(animated: true)
        panel.orderFrontRegardless()
        schedule(card)
    }

    private func clicked(_ id: String) {
        guard let key = cards.first(where: { $0.id == id })?.key else { return dismiss(id) }
        onClick(key)  // the jump withdraws the notice, which dismisses the card
    }

    private func dismiss(_ id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        let card = cards.remove(at: index)
        timers.removeValue(forKey: id)?.cancel()
        slides[id] = nil
        card.model.leaving = true
        Task {
            try? await Task.sleep(for: .milliseconds(260))
            card.panel.orderOut(nil)
        }
        if cards.isEmpty { anchor = nil } else { layout(animated: true) }
    }

    private func schedule(_ card: Card) {
        timers.removeValue(forKey: card.id)?.cancel()
        guard !card.model.content.blocked else { return }
        timers[card.id] = Task { [weak self] in
            try? await Task.sleep(for: Self.doneLifetime)
            while card.model.hovering, !Task.isCancelled { try? await Task.sleep(for: .seconds(1)) }
            guard !Task.isCancelled else { return }
            self?.dismiss(card.id)
        }
    }

    private func layout(animated: Bool) {
        guard let anchor else { return }
        for (index, card) in cards.enumerated() {
            let target = CardLayout.panelFrame(index: index, corner: anchor.corner, in: anchor.area)
            if animated, card.panel.frame != target {
                slides[card.id] = Slide(card.panel, to: target)
            } else {
                slides[card.id] = nil
                card.panel.setFrame(target, display: true)
            }
        }
    }

    private func screen(for display: CardDisplay) -> NSScreen? {
        switch display {
        case .main: NSScreen.screens.first
        case .pointer: NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.screens.first
        }
    }

    private static func panel(_ preferences: CardPreferences) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // the card draws its own, inside the panel's padding
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [preferences.everySpace ? .canJoinAllSpaces : .moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        switch preferences.layer {
        case .aboveWindows:
            panel.level = .statusBar
        case .desktop:
            // Just above the desktop icons, under every window.
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            panel.collectionBehavior.insert(.stationary)
        }
        return panel
    }
}

/// Moves a card's window to its new slot over 0.4 s, a step every display frame. NSWindow's animator moves a
/// borderless panel at once, so the stack jumped instead of sliding.
@MainActor
private final class Slide: NSObject {
    private let panel: NSPanel
    private let from: CGRect
    private let to: CGRect
    private let start = CACurrentMediaTime()
    private var link: CADisplayLink?
    static let duration = 0.4

    init(_ panel: NSPanel, to: CGRect) {
        self.panel = panel
        from = panel.frame
        self.to = to
        super.init()
        link = panel.displayLink(target: self, selector: #selector(step))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func step(_ link: CADisplayLink) {
        let k = min(1, (CACurrentMediaTime() - start) / Self.duration)
        panel.setFrame(CardLayout.mix(from, to, CardLayout.slide(k)), display: true)
        if k >= 1 { link.invalidate() }
    }

    isolated deinit {
        link?.invalidate()
    }
}

/// A card answers the first click, though Herdrbar is never the active app.
private final class CardHostingView: NSHostingView<CardView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor @Observable
final class CardModel {
    var content: CardContent
    /// 0 drops the card in; each later update makes it hop.
    var arrivals = 0
    var leaving = false
    var hovering = false
    var glowing = true
    /// Flares the glow again when the card hops.
    let burster = AuroraGlow.Burster()

    init(_ content: CardContent) {
        self.content = content
    }
}

struct CardView: View {
    let model: CardModel
    let fromTop: Bool
    let onClick: () -> Void
    let onClose: () -> Void

    @State private var y: CGFloat
    @State private var stretch = CGSize(width: 0.94, height: 1.1)
    @State private var opacity = 0.0

    init(model: CardModel, fromTop: Bool, onClick: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.model = model
        self.fromTop = fromTop
        self.onClick = onClick
        self.onClose = onClose
        _y = State(initialValue: fromTop ? -90 : 90)
    }

    /// The way back to the screen edge the card came from.
    private var away: CGFloat { fromTop ? -1 : 1 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        HStack(spacing: 12) {
            Logo(blocked: model.content.blocked)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.content.headline).font(.system(size: 13, weight: .semibold))
                Text(model.content.detail).font(.system(size: 12))
                Text(model.content.place).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: CardLayout.card.width, height: CardLayout.card.height)
        .background { Glass(shape: shape) }
        .overlay {
            // Aurora flares on arrival, on each hop and under the pointer, then rests as a still border:
            // its glow redraws every frame, and a blocked card can stay up for a long time.
            if model.glowing || model.hovering {
                AuroraGlow(.standard)
                    .palette(model.content.blocked ? .sunset : .forest)
                    .cornerRadius(20)
                    .borderWidth(3)
                    .glowSize(16)
                    .burster(model.burster)
                    .clipShape(shape)
                    .transition(.opacity)
            } else {
                shape.strokeBorder(LinearGradient(colors: model.content.blocked ? [.orange, .pink] : [.green, .mint],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing).opacity(0.8),
                                   lineWidth: 1.5)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            if model.hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(.regularMaterial, in: Circle())
                        .overlay { Circle().strokeBorder(.white.opacity(0.15)) }
                }
                .buttonStyle(.plain)
                .offset(x: -6, y: -6)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Close")
            }
        }
        .contentShape(shape)
        .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        .scaleEffect(model.hovering ? 1.025 : 1)
        .onHover { hovering in withAnimation(.spring(duration: 0.3, bounce: 0.4)) { model.hovering = hovering } }
        .onTapGesture(perform: onClick)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .scaleEffect(x: stretch.width, y: stretch.height, anchor: fromTop ? .bottom : .top)
        .offset(y: y)
        .opacity(opacity)
        .padding(CardLayout.padding)
        .task(id: model.arrivals) { await arrive() }
        .onChange(of: model.leaving) { if model.leaving { leave() } }
    }

    /// Drops in from the screen edge, stretched by the fall; squashes on landing; settles with a wobble.
    /// A card already on screen hops instead.
    private func arrive() async {
        if model.arrivals == 0 {
            withAnimation(.easeIn(duration: 0.26)) {
                y = 0
                opacity = 1
            }
            try? await Task.sleep(for: .milliseconds(260))
        } else {
            model.glowing = true
            model.burster.fire()
            withAnimation(.easeOut(duration: 0.14)) { y = away * 16 }
            try? await Task.sleep(for: .milliseconds(140))
            withAnimation(.easeIn(duration: 0.14)) { y = 0 }
            try? await Task.sleep(for: .milliseconds(140))
        }
        withAnimation(.spring(duration: 0.12, bounce: 0)) { stretch = CGSize(width: 1.07, height: 0.86) }
        try? await Task.sleep(for: .milliseconds(110))
        withAnimation(.spring(duration: 0.55, bounce: 0.6)) { stretch = CGSize(width: 1, height: 1) }
        try? await Task.sleep(for: .seconds(3.5))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.8)) { model.glowing = false }
    }

    /// Springs back up into the edge it came from.
    private func leave() {
        withAnimation(.spring(duration: 0.12, bounce: 0)) { stretch = CGSize(width: 1.04, height: 0.94) }
        withAnimation(.easeIn(duration: 0.22).delay(0.06)) {
            y = away * 50
            opacity = 0
            stretch = CGSize(width: 0.9, height: 1.06)
        }
    }
}

/// herdr's ram (the app icon), with what happened on its corner: orange for blocked, green for finished.
private struct Logo: View {
    let blocked: Bool
    @State private var popped = false

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 44, height: 44)
            .overlay(alignment: .bottomTrailing) {
                ZStack {
                    Circle().fill(blocked ? Color.orange : Color.green)
                        .overlay { Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5) }
                    Image(systemName: blocked ? "exclamationmark" : "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                }
                .frame(width: 18, height: 18)
                .scaleEffect(popped ? 1 : 0.1)
                .rotationEffect(.degrees(popped ? 0 : blocked ? -40 : 40))
                .offset(x: 3, y: 2)
            }
            .onAppear {
                withAnimation(.spring(duration: 0.5, bounce: 0.65).delay(0.3)) { popped = true }
            }
    }
}

/// Liquid Glass on macOS 26; a blurred material before it.
private struct Glass: View {
    let shape: RoundedRectangle

    var body: some View {
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            BehindWindowBlur().clipShape(shape)
        }
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

