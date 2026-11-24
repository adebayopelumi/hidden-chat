import AppKit

// The look of Hidden Chat: a black and purple chat app (sidebar, question bubbles, formatted answers, a
// floating input with a purple send button), with the editorial serif from DESIGN.md for headlines.

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}

enum Theme {
    // Black, with a faint violet tint so the purple sits naturally. Darkest to lightest.
    static let sidebar = NSColor(hex: 0x09080c)
    static let main = NSColor(hex: 0x0e0d12)
    static let raised = NSColor(hex: 0x16141c)       // the input box
    static let bubble = NSColor(hex: 0x1e1b27)       // the user's messages
    static let selected = NSColor(hex: 0x221e2e)     // a highlighted sidebar row
    static let hover = NSColor(hex: 0x17151e)
    static let well = NSColor(hex: 0x050407)         // segmented control track, code blocks
    static let divider = NSColor(hex: 0x1d1a25)
    static let border = NSColor(hex: 0x2a2635)
    static let borderStrong = NSColor(hex: 0x3a3449)
    // Text
    static let text = NSColor(hex: 0xefecf6)
    static let body = NSColor(hex: 0xcdc8d9)         // answers
    static let muted = NSColor(hex: 0x958fa6)
    static let faint = NSColor(hex: 0x5f596e)
    // Purple accent
    static let accent = NSColor(hex: 0x8b5cf6)
    static let accentLight = NSColor(hex: 0xa78bfa)
    static let accentDeep = NSColor(hex: 0x6d28d9)
    static let link = NSColor(hex: 0xb79cff)
    static let error = NSColor(hex: 0xff6b8b)
    static let selection = NSColor(hex: 0x3b2d63)

    // Fonts. DESIGN.md's PP Editorial Old / Inter / JetBrains Mono are used when installed,
    // otherwise New York, San Francisco and SF Mono.
    private static let families = Set(NSFontManager.shared.availableFontFamilies)

    static func display(_ size: CGFloat) -> NSFont {
        if families.contains("PP Editorial Old"), let f = NSFont(name: "PPEditorialOld-Regular", size: size) { return f }
        let system = NSFont.systemFont(ofSize: size)
        if let serif = system.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: serif, size: size) { return f }
        return NSFont(name: "Georgia", size: size) ?? system
    }

    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        if families.contains("Inter") {
            let d = NSFontDescriptor(fontAttributes: [.family: "Inter", .traits: [NSFontDescriptor.TraitKey.weight: weight]])
            if let f = NSFont(descriptor: d, size: size) { return f }
        }
        return .systemFont(ofSize: size, weight: weight)
    }

    static func mono(_ size: CGFloat) -> NSFont {
        if families.contains("JetBrains Mono"), let f = NSFont(name: "JetBrainsMono-Regular", size: size) { return f }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func symbol(_ name: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    static func label(_ text: String, _ font: NSFont, _ color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = font
        l.textColor = color
        return l
    }

    static func icon(_ name: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSImageView {
        let v = NSImageView()
        v.image = symbol(name, size: size, color: color, weight: weight)
        v.setContentHuggingPriority(.required, for: .horizontal)
        return v
    }
}

// MARK: Surfaces

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A flat rectangle or rounded box: fill, optional 1 pt border, optional rule on one edge.
class SurfaceView: FlippedView {
    var fill: NSColor? { didSet { needsDisplay = true } }
    var border: NSColor? { didSet { needsDisplay = true } }
    var radius: CGFloat
    var topRule: NSColor?
    var rightRule: NSColor?

    init(fill: NSColor?, border: NSColor? = nil, radius: CGFloat = 0) {
        self.fill = fill
        self.border = border
        self.radius = radius
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        if let fill { fill.setFill(); radius > 0 ? path.fill() : bounds.fill() }
        if let border { border.setStroke(); path.lineWidth = 1; path.stroke() }
        if let topRule { topRule.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill() }
        if let rightRule { rightRule.setFill(); NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill() }
    }
}

/// An input's box. Its border turns purple while the field inside has focus (and the window is active).
final class FieldBox: SurfaceView {
    private var observation: NSKeyValueObservation?
    private var tokens: [NSObjectProtocol] = []
    private var focused = false { didSet { if focused != oldValue { border = focused ? Theme.accent.withAlphaComponent(0.7) : Theme.border } } }

    init(radius: CGFloat) { super.init(fill: Theme.raised, border: Theme.border, radius: radius) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        observation = nil
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
        guard let window else { return }
        observation = window.observe(\.firstResponder) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    private func refresh() {
        guard let window, window.isKeyWindow, let responder = window.firstResponder as? NSView else { focused = false; return }
        let view = (responder as? NSText)?.delegate as? NSView ?? responder  // a text field edits through a field editor
        focused = view.isDescendant(of: self) || responder.isDescendant(of: self)
    }
}

/// Fades the bottom of the conversation into the background above the input box.
final class FadeView: NSView {
    var color = Theme.main
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: color.withAlphaComponent(0), ending: color)?.draw(in: bounds, angle: -90)
    }
}

/// The app's mark: an orange rounded square with a symbol.
final class AppMark: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 24) }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        NSGradient(starting: Theme.accentLight, ending: Theme.accentDeep)?.draw(in: path, angle: -60)
        if let image = Theme.symbol("eye.slash.fill", size: 11, color: .white, weight: .semibold) {
            let s = image.size
            image.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
        }
    }
}

// MARK: Controls

/// A clickable view: runs `onClick` on mouse-up inside, responds to the first click in an inactive window,
/// and tracks hover.
class ClickableView: FlippedView {
    var onClick: () -> Void = {}
    var isEnabled = true { didSet { needsDisplay = true } }
    private(set) var hovered = false
    private(set) var pressed = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { guard isEnabled else { return }; pressed = true; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }
}

/// A row in the sidebar: icon and title, plus an "on" dot for modes or a switch for toggles.
final class SidebarItem: ClickableView {
    enum Kind { case action, mode, toggle }
    let kind: Kind
    var title: String { didSet { needsDisplay = true } }
    var symbol: String
    var isOn = false { didSet { needsDisplay = true } }
    var filled = false  // always highlighted (New chat)

    init(_ title: String, symbol: String, kind: Kind = .action) {
        self.title = title
        self.symbol = symbol
        self.kind = kind
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 34).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityLabel() -> String? { title }
    override func accessibilityValue() -> Any? { kind == .action ? nil : (isOn ? "on" : "off") }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = filled || (kind == .mode && isOn)
        if highlighted || hovered || pressed {
            (pressed ? Theme.borderStrong : highlighted ? Theme.selected : Theme.hover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        let color = isEnabled ? Theme.text : Theme.faint
        if let image = Theme.symbol(kind == .mode && isOn ? "stop.fill" : symbol, size: 13, color: kind == .mode && isOn ? Theme.accent : color) {
            let s = image.size
            image.draw(in: NSRect(x: 10 + (18 - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.ui(13.5), .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: 38, y: (bounds.height - size.height) / 2), withAttributes: attrs)

        switch kind {
        case .action: break
        case .mode where isOn:
            // A live dot; on hover it says what clicking does.
            if hovered {
                let stop: [NSAttributedString.Key: Any] = [.font: Theme.ui(11.5, .medium), .foregroundColor: Theme.muted]
                let s = ("Stop" as NSString).size(withAttributes: stop)
                ("Stop" as NSString).draw(at: NSPoint(x: bounds.width - 12 - s.width, y: (bounds.height - s.height) / 2), withAttributes: stop)
            } else {
                let dot = NSRect(x: bounds.width - 18, y: bounds.midY - 3.5, width: 7, height: 7)
                Theme.accent.withAlphaComponent(0.25).setFill()
                NSBezierPath(ovalIn: dot.insetBy(dx: -3, dy: -3)).fill()
                Theme.accent.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
        case .mode: break
        case .toggle:
            let track = NSRect(x: bounds.width - 40, y: bounds.midY - 8, width: 28, height: 16)
            (isOn ? Theme.accent : Theme.borderStrong).setFill()
            NSBezierPath(roundedRect: track, xRadius: 8, yRadius: 8).fill()
            let knob = NSRect(x: isOn ? track.maxX - 14 : track.minX + 2, y: track.minY + 2, width: 12, height: 12)
            (isOn ? NSColor.white : Theme.muted).setFill()
            NSBezierPath(ovalIn: knob).fill()
        }
    }
}

/// Two or more segments in a dark track; the selected one is raised.
final class SegmentedControl: ClickableView {
    let titles: [String]
    var selectedIndex = 0 { didSet { needsDisplay = true } }
    var onChange: (Int) -> Void = { _ in }

    init(_ titles: [String]) {
        self.titles = titles
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 34).isActive = true
        onClick = {}
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        super.mouseUp(with: event)
        guard bounds.contains(point), !titles.isEmpty else { return }
        let index = min(titles.count - 1, Int(point.x / (bounds.width / CGFloat(titles.count))))
        if index != selectedIndex { selectedIndex = index; onChange(index) }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.well.setFill()
        let track = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        track.fill()
        Theme.divider.setStroke()
        track.lineWidth = 1
        track.stroke()
        let width = bounds.width / CGFloat(titles.count)
        for (i, title) in titles.enumerated() {
            let cell = NSRect(x: CGFloat(i) * width, y: 0, width: width, height: bounds.height)
            if i == selectedIndex {
                let pill = NSBezierPath(roundedRect: cell.insetBy(dx: 3, dy: 3), xRadius: 7, yRadius: 7)
                Theme.bubble.setFill(); pill.fill()
                Theme.borderStrong.setStroke(); pill.lineWidth = 1; pill.stroke()
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.ui(13.5, i == selectedIndex ? .medium : .regular),
                                                        .foregroundColor: i == selectedIndex ? Theme.text : Theme.muted]
            let s = (title as NSString).size(withAttributes: attrs)
            (title as NSString).draw(at: NSPoint(x: cell.midX - s.width / 2, y: cell.midY - s.height / 2), withAttributes: attrs)
        }
    }
}

/// A square icon button: purple with a white symbol (Send), or dark.
final class IconButton: ClickableView {
    var symbol: String { didSet { needsDisplay = true } }
    var light: Bool
    let side: CGFloat

    init(symbol: String, light: Bool = true, side: CGFloat = 30) {
        self.symbol = symbol
        self.light = light
        self.side = side
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor = !isEnabled ? Theme.bubble : light ? (pressed ? Theme.accentDeep : hovered ? Theme.accentLight : Theme.accent)
            : (hovered ? Theme.selected : Theme.bubble)
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let color: NSColor = !isEnabled ? Theme.faint : light ? .white : Theme.text
        if let image = Theme.symbol(symbol, size: 13, color: color, weight: .bold) {
            let s = image.size
            image.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
        }
    }
}

/// A text button: purple (primary) or dark with a border (secondary). 8 pt corners.
final class ThemedButton: NSButton {
    enum Style { case primary, secondary }

    var style: Style { didSet { needsDisplay = true } }
    var symbol: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var compact = false { didSet { invalidateIntrinsicContentSize() } }
    var onClick: (() -> Void)?

    override var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { false }

    init(_ title: String, symbol: String? = nil, style: Style, target: AnyObject? = nil, action: Selector? = nil) {
        self.style = style
        self.symbol = symbol
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        if let target, let action {
            self.target = target
            self.action = action
        } else {
            self.target = self
            self.action = #selector(clicked)
        }
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func clicked() { onClick?() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    private var labelFont: NSFont { Theme.ui(compact ? 12.5 : 13, .medium) }
    private var hPad: CGFloat { title.isEmpty ? (compact ? 7 : 9) : (compact ? 10 : 16) }
    private var iconSize: CGFloat { compact ? 11 : 12 }
    private var colors: (fill: NSColor, border: NSColor?, text: NSColor) {
        if !isEnabled { return (Theme.bubble, nil, Theme.faint) }
        switch style {
        case .primary: return (isHighlighted ? Theme.accentDeep : Theme.accent, nil, .white)
        case .secondary: return (isHighlighted ? Theme.selected : Theme.bubble, Theme.borderStrong, Theme.text)
        }
    }
    private var titleAttributes: [NSAttributedString.Key: Any] { [.font: labelFont, .foregroundColor: colors.text] }

    override var intrinsicContentSize: NSSize {
        var width = hPad * 2
        if !title.isEmpty { width += ceil((title as NSString).size(withAttributes: titleAttributes).width) }
        if symbol != nil { width += iconSize + 2 + (title.isEmpty ? 0 : 6) }
        return NSSize(width: width, height: compact ? 26 : 32)
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = colors
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        c.fill.setFill(); path.fill()
        if let border = c.border { border.setStroke(); path.lineWidth = 1; path.stroke() }
        let text = title as NSString
        let textSize = title.isEmpty ? .zero : text.size(withAttributes: titleAttributes)
        let icon = symbol.flatMap { Theme.symbol($0, size: iconSize, color: c.text, weight: .semibold) }
        let iconWidth = icon == nil ? 0 : iconSize + 2
        let gap: CGFloat = icon != nil && !title.isEmpty ? 6 : 0
        var x = (bounds.width - (iconWidth + gap + textSize.width)) / 2
        if let icon {
            let s = icon.size
            icon.draw(in: NSRect(x: x + (iconWidth - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
            x += iconWidth + gap
        }
        if !title.isEmpty { text.draw(at: NSPoint(x: x, y: (bounds.height - textSize.height) / 2), withAttributes: titleAttributes) }
    }
}

/// A borderless, background-less scroll view around a text view.
func scrolling(_ textView: NSTextView) -> NSScrollView {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.scrollerStyle = .overlay
    scroll.borderType = .noBorder
    scroll.drawsBackground = false
    textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
    textView.minSize = .zero
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
    textView.drawsBackground = false
    textView.selectedTextAttributes = [.backgroundColor: Theme.selection]
    textView.insertionPointColor = Theme.text
    scroll.documentView = textView
    return scroll
}
