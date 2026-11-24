import AppKit

/// Boxes drawn around questions spotted on screen, each with ✓ (solve it) and ✕ (dismiss) buttons.
/// Like the rest of Hidden Chat they're hidden from screen capture, and clicking them doesn't take
/// focus away from the app you're using.
@MainActor
final class Highlighter {
    final class Item {
        let key: String
        var block: TextBlock
        var outline: NSWindow!
        var buttons: NSPanel!
        init(key: String, block: TextBlock) {
            self.key = key
            self.block = block
        }
    }

    static let maxShown = 3          // boxes on screen at once
    static let maxChecksPerMinute = 12

    /// The watched display, in global screen coordinates.
    var screenFrame = NSRect.zero
    /// ✓ was clicked.
    var onSolve: (TextBlock) -> Void = { _ in }
    /// The quick AI check: is this text a question or task worth solving?
    var classify: (String) async -> Bool = { _ in false }

    private(set) var items: [Item] = []
    private var dismissed: Set<String> = []  // answered or ✕'d, so they aren't flagged again
    private var checking: Set<String> = []
    private var recentChecks: [Date] = []
    private var currentLines: [TextLine] = []

    /// Identity of a block's text, ignoring spacing and punctuation the text reader may vary.
    static func key(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// Called each time the screen's text settles.
    func update(lines: [TextLine], newBlocks: [TextBlock], rulesOnly: Bool) {
        currentLines = lines
        track()
        var checksNow = 0
        for block in newBlocks.map(Self.trimmed) {
            let key = Self.key(block.text)
            let words = block.text.split(whereSeparator: \.isWhitespace).count
            guard block.lines.count <= 15, words >= 3, !key.isEmpty, !dismissed.contains(key), !checking.contains(key),
                  !items.contains(where: { $0.key == key }) else { continue }

            // Clear questions are flagged straight away…
            if block.lines.contains(where: { QuestionDetector.looksLikeQuestion($0.text) }) {
                show(block, key: key)
                continue
            }
            // …anything else that might be a task ("Solve for x…", "Write a function…") gets a quick AI check,
            // except on a first look or a whole new scene, where only clear questions are flagged.
            guard !rulesOnly, words >= 4, words <= 150, checksNow < 3, allowCheck() else { continue }
            checksNow += 1
            checking.insert(key)
            Task {
                let isTask = await classify(block.text)
                checking.remove(key)
                guard isTask, !dismissed.contains(key), !items.contains(where: { $0.key == key }),
                      currentLines.contains(where: { $0.text == block.lines[0].text }) else { return }  // still on screen
                show(block, key: key)
            }
        }
    }

    /// Leaves out finished sentences above the question, like an earlier chat message ("Sam: morning!").
    static func trimmed(_ block: TextBlock) -> TextBlock {
        let lines = Array(block.lines.drop { line in
            let t = line.text.trimmingCharacters(in: .whitespaces)
            return (t.hasSuffix(".") || t.hasSuffix("!")) && !QuestionDetector.looksLikeQuestion(t)
        })
        return lines.isEmpty ? block : TextBlock(lines: lines)
    }

    /// Removes every box (when watching stops). `forget` also forgets what was dismissed.
    func clear(forget: Bool = false) {
        items.forEach(remove)
        checking.removeAll()
        if forget { dismissed.removeAll() }
    }

    private func allowCheck() -> Bool {
        let now = Date()
        recentChecks.removeAll { now.timeIntervalSince($0) > 60 }
        guard recentChecks.count < Self.maxChecksPerMinute else { return false }
        recentChecks.append(now)
        return true
    }

    /// Keeps boxes on their text as it moves, and removes boxes whose text is gone.
    private func track() {
        for item in items {
            let texts = Set(item.block.lines.map(\.text))
            let matches = currentLines.filter { texts.contains($0.text) }
            // The same words can appear twice on screen; follow the biggest group.
            guard let moved = ScreenWatcher.group(matches).max(by: { $0.lines.count < $1.lines.count }) else {
                remove(item)
                continue
            }
            if !moved.box.equalTo(item.block.box) {
                item.block = moved
                place(item)
            }
        }
    }

    private func show(_ block: TextBlock, key: String) {
        if items.count >= Self.maxShown { remove(items[0]) }  // make room: drop the oldest
        let item = Item(key: key, block: block)
        item.outline = makeOutline()
        item.buttons = makeButtons(solve: { [weak self, weak item] in
            guard let self, let item else { return }
            self.dismissed.insert(item.key)
            self.remove(item)
            self.onSolve(item.block)
        }, dismiss: { [weak self, weak item] in
            guard let self, let item else { return }
            self.dismissed.insert(item.key)
            self.remove(item)
        })
        items.append(item)
        place(item)
        item.outline.orderFrontRegardless()
        item.buttons.orderFrontRegardless()
    }

    private func remove(_ item: Item) {
        item.outline?.orderOut(nil)
        item.buttons?.orderOut(nil)
        items.removeAll { $0 === item }
    }

    /// Screen rectangle (global coordinates) for a normalized box, with a little margin.
    func rect(for box: CGRect) -> NSRect {
        let f = screenFrame
        return NSRect(x: f.minX + box.minX * f.width, y: f.minY + box.minY * f.height,
                      width: box.width * f.width, height: box.height * f.height).insetBy(dx: -6, dy: -5)
    }

    private func place(_ item: Item) {
        let r = rect(for: item.block.box)
        item.outline.setFrame(r, display: true)
        let size = item.buttons.frame.size
        var origin = NSPoint(x: r.maxX - size.width, y: r.maxY + 3)          // just above the box, at its right end
        if origin.y + size.height > screenFrame.maxY { origin.y = r.maxY - size.height - 3 }  // no room: inside the top
        origin.x = max(screenFrame.minX, min(origin.x, screenFrame.maxX - size.width))
        item.buttons.setFrameOrigin(origin)
    }

    private func makeOutline() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true  // clicks go through to the app underneath
        w.level = .floating
        w.sharingType = .none
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = HighlightView()
        return w
    }

    func makeButtons(solve: @escaping () -> Void, dismiss: @escaping () -> Void) -> NSPanel {
        // A non-activating panel: clicking it doesn't pull focus from the app you're typing in.
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 110, height: 34),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = SurfaceView(fill: Theme.raised, border: Theme.borderStrong, radius: 10)
        let ok = ThemedButton("Solve", symbol: "checkmark", style: .primary)
        ok.compact = true
        ok.toolTip = "Solve this"
        ok.onClick = solve
        let no = ThemedButton("", symbol: "xmark", style: .secondary)
        no.compact = true
        no.toolTip = "Dismiss"
        no.onClick = dismiss
        let stack = NSStackView(views: [ok, no])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        panel.setContentSize(background.fittingSize)
        return panel
    }

    /// A sample box with its buttons, for checking the look (HIDDENCHAT_SNAPSHOT).
    func demoView() -> NSView {
        let view = SurfaceView(fill: Theme.main)
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 120)
        let text = NSTextField(labelWithString: "What is the capital of Australia?")
        text.font = .systemFont(ofSize: 15)
        text.textColor = Theme.text
        text.frame = NSRect(x: 40, y: 64, width: 300, height: 22)
        let outline = HighlightView(frame: NSRect(x: 30, y: 58, width: 250, height: 34))
        let buttons = makeButtons(solve: {}, dismiss: {}).contentView!
        buttons.removeFromSuperview()
        buttons.frame.origin = NSPoint(x: 280 - buttons.frame.width, y: 58 - buttons.frame.height - 4)
        [text, outline, buttons].forEach(view.addSubview)
        return view
    }
}

/// The highlight around a question: a coloured, rounded border with a faint fill.
private final class HighlightView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        Theme.accent.withAlphaComponent(0.10).setFill()
        path.fill()
        Theme.accent.setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}
