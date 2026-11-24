import AppKit

// The conversation: a scrolling column of messages. Questions are bubbles on the right; answers are
// formatted text with a line for each step taken (searching files, reading one) above them.

/// Turns the Markdown that models reply in into styled text: headings, bold/italic, inline code,
/// links, bulleted and numbered lists, quotes and code blocks. Unfinished syntax (mid-stream) shows as typed.
enum Markdown {
    static let codeBlock = NSAttributedString.Key("hiddenchat.codeBlock")

    static func render(_ source: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var code: [String]? = nil  // lines of an open ``` block
        var gap: CGFloat = 0       // space owed for blank lines

        func paragraph(_ configure: (NSMutableParagraphStyle) -> Void = { _ in }) -> NSMutableParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 4
            p.paragraphSpacingBefore = out.length == 0 ? 0 : max(gap, 4)
            configure(p)
            gap = 0
            return p
        }
        func flushCode() {
            guard let lines = code else { return }
            let text = lines.isEmpty ? " " : lines.joined(separator: "\n")
            let rows = text.components(separatedBy: "\n")
            for (i, line) in rows.enumerated() {
                let style = NSMutableParagraphStyle()
                style.firstLineHeadIndent = 14; style.headIndent = 14; style.tailIndent = -14
                style.lineSpacing = 2
                // 10 pt of padding inside the box, plus 10 pt of gap above it unless it opens the answer.
                if i == 0 { style.paragraphSpacingBefore = out.length == 0 ? 10 : 20 }
                if i == rows.count - 1 { style.paragraphSpacing = 10 }
                out.append(NSAttributedString(string: line + "\n", attributes: [
                    .font: Theme.mono(12.5), .foregroundColor: Theme.text, .paragraphStyle: style, codeBlock: true]))
            }
            gap = 12
            code = nil
        }

        for raw in source.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if code != nil { flushCode() } else { code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if trimmed.isEmpty { gap = 12; continue }
            if trimmed.allSatisfy({ "-*_".contains($0) }) && trimmed.count >= 3 { gap = 14; continue }  // rule

            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let level = CGFloat(min(indent / 2, 4))

            if let match = trimmed.firstMatch(of: #/^(#{1,6})\s+(.*)$/#) {
                let size: CGFloat = match.1.count <= 1 ? 18 : match.1.count == 2 ? 16.5 : 15
                let p = paragraph { $0.paragraphSpacingBefore = out.length == 0 ? 0 : 14; $0.paragraphSpacing = 2 }
                out.append(inline(String(match.2), size: size, weight: .semibold, color: Theme.text, paragraph: p))
            } else if let match = trimmed.firstMatch(of: #/^([-*+•])\s+(.*)$/#) {
                out.append(listItem(marker: "•", text: String(match.2), level: level, paragraph: paragraph()))
            } else if let match = trimmed.firstMatch(of: #/^(\d+)[.)]\s+(.*)$/#) {
                out.append(listItem(marker: "\(match.1).", text: String(match.2), level: level, paragraph: paragraph()))
            } else if let match = trimmed.firstMatch(of: #/^>\s?(.*)$/#) {
                let p = paragraph { $0.firstLineHeadIndent = 14; $0.headIndent = 14 }
                out.append(inline(String(match.1), color: Theme.muted, paragraph: p))
            } else {
                out.append(inline(trimmed, paragraph: paragraph()))
            }
            out.append(NSAttributedString(string: "\n", attributes: [.font: Theme.ui(14.5)]))
        }
        if code != nil { flushCode() }  // still streaming
        while out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }

    private static func listItem(marker: String, text: String, level: CGFloat, paragraph p: NSMutableParagraphStyle) -> NSAttributedString {
        let start = 4 + level * 20
        p.firstLineHeadIndent = start
        p.headIndent = start + 22
        p.tabStops = [NSTextTab(textAlignment: .left, location: start + 22)]
        let out = NSMutableAttributedString(string: marker + "\t", attributes: [
            .font: Theme.ui(14.5), .foregroundColor: Theme.muted, .paragraphStyle: p])
        out.append(inline(text, paragraph: p))
        return out
    }

    /// Bold, italic, `code`, ~~strike~~ and [links](…) within one line.
    static func inline(_ text: String, size: CGFloat = 14.5, weight: NSFont.Weight = .regular,
                       color: NSColor = Theme.body, paragraph: NSParagraphStyle) -> NSAttributedString {
        let base = Theme.ui(size, weight)
        let plain: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: color, .paragraphStyle: paragraph]
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: plain)
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            var attrs = plain
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                attrs[.font] = Theme.mono(size - 1.5)
                attrs[.foregroundColor] = Theme.text
                attrs[.backgroundColor] = Theme.bubble
            } else {
                var font = base
                if intent.contains(.stronglyEmphasized) {
                    font = Theme.ui(size, .semibold)
                    attrs[.foregroundColor] = Theme.text
                }
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                attrs[.font] = font
                if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link { attrs[.link] = link }
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attrs))
        }
        return out
    }
}

/// Draws the dark rounded box behind code blocks.
final class CodeBlockLayoutManager: NSLayoutManager {
    static let endPadding: CGFloat = 10
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0 else { return }
        let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let everything = NSRange(location: 0, length: storage.length)
        var location = visible.location
        while location < NSMaxRange(visible), location < storage.length {
            var range = NSRange()
            if storage.attribute(Markdown.codeBlock, at: location, longestEffectiveRange: &range, in: everything) != nil {
                var rect = NSRect.null
                enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { line, _, _, _, _ in
                    rect = rect.union(line)
                }
                if !rect.isNull {
                    rect = rect.offsetBy(dx: origin.x, dy: origin.y)
                    let gap: CGFloat = range.location == 0 ? 0 : 10  // the gap above the block sits outside it
                    rect.origin.y += gap
                    rect.size.height -= gap
                    if NSMaxRange(range) == storage.length { rect.size.height += Self.endPadding }  // no spacing after the last line
                    let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
                    Theme.well.setFill(); path.fill()
                    Theme.border.setStroke(); path.lineWidth = 1; path.stroke()
                }
            }
            location = max(NSMaxRange(range), location + 1)
        }
    }
}

/// Selectable, non-editable text that is exactly as tall as its contents at the width it's given.
final class MessageTextView: NSTextView {
    convenience init() {
        let storage = NSTextStorage()
        let layout = CodeBlockLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        self.init(frame: NSRect(x: 0, y: 0, width: 200, height: 20), textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainerInset = .zero
        translatesAutoresizingMaskIntoConstraints = false
        selectedTextAttributes = [.backgroundColor: Theme.selection]
        linkTextAttributes = [.foregroundColor: Theme.link, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        setContentHuggingPriority(.defaultHigh, for: .vertical)
    }

    func set(_ text: NSAttributedString) {
        textStorage?.setAttributedString(text)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        guard let layout = layoutManager, let container = textContainer else { return super.intrinsicContentSize }
        layout.ensureLayout(for: container)
        var height = ceil(layout.usedRect(for: container).height) + textContainerInset.height * 2
        if let storage = textStorage, storage.length > 0, storage.attribute(Markdown.codeBlock, at: storage.length - 1, effectiveRange: nil) != nil {
            height += CodeBlockLayoutManager.endPadding  // room for a code block's bottom padding
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }
}

/// The user's question: an optional caption ("They asked", "From screen") and a bubble on the right.
final class QuestionView: FlippedView {
    init(_ text: String, caption: String?, symbol: String?) {
        super.init(frame: .zero)
        let bubble = SurfaceView(fill: Theme.bubble, radius: 16)
        let body = MessageTextView()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3.5
        let attributed = NSAttributedString(string: text, attributes: [.font: Theme.ui(14.5), .foregroundColor: Theme.text, .paragraphStyle: paragraph])
        body.set(attributed)
        let natural = ceil(attributed.boundingRect(with: NSSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin]).width) + 2

        var views: [NSView] = [bubble]
        var captionRow: NSStackView?
        if let caption {
            var parts: [NSView] = []
            if let symbol { parts.append(Theme.icon(symbol, size: 10.5, color: Theme.accentLight, weight: .semibold)) }
            parts.append(Theme.label(caption, Theme.ui(12, .medium), Theme.muted))
            let row = NSStackView(views: parts)
            row.spacing = 6
            captionRow = row
            views.insert(row, at: 0)
        }
        for v in views + [body] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        views.forEach(addSubview)
        bubble.addSubview(body)

        let wantsNatural = body.widthAnchor.constraint(equalToConstant: natural)
        wantsNatural.priority = .defaultHigh
        var constraints = [
            body.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 12),
            body.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -12),
            body.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -16),
            body.widthAnchor.constraint(lessThanOrEqualToConstant: natural),
            wantsNatural,
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.82),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        if let captionRow {
            constraints += [captionRow.topAnchor.constraint(equalTo: topAnchor),
                            captionRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                            bubble.topAnchor.constraint(equalTo: captionRow.bottomAnchor, constant: 7)]
        } else {
            constraints.append(bubble.topAnchor.constraint(equalTo: topAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The assistant's reply: what it did (one line per step), "Thinking…" until words arrive, the answer,
/// and how long the first word took.
final class AnswerView: FlippedView {
    private let stack = NSStackView()
    private let steps = NSStackView()
    private let thinking = Theme.label("Thinking…", Theme.ui(13), Theme.muted)
    private let answer = MessageTextView()
    private let footer = NSStackView()

    init() {
        super.init(frame: .zero)
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 6
        footer.spacing = 5
        footer.isHidden = true
        answer.isHidden = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setViews([steps, thinking, answer, footer], in: .top)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            answer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        steps.isHidden = true
        // "Thinking…" breathes while waiting.
        thinking.wantsLayer = true
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1; pulse.toValue = 0.35; pulse.duration = 0.8
        pulse.autoreverses = true; pulse.repeatCount = .infinity
        thinking.layer?.add(pulse, forKey: "pulse")
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A step the assistant took, like "Reading ~/Notes/plan.md".
    func addStep(_ text: String) {
        let row = NSStackView(views: [Theme.icon(Self.symbol(for: text), size: 11, color: Theme.muted),
                                      Theme.label(text, Theme.ui(13), Theme.muted)])
        row.spacing = 7
        (row.views.last as? NSTextField)?.lineBreakMode = .byTruncatingMiddle
        (row.views.last as? NSTextField)?.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        steps.addArrangedSubview(row)
        row.widthAnchor.constraint(lessThanOrEqualTo: steps.widthAnchor).isActive = true
        steps.isHidden = false
    }

    private static func symbol(for step: String) -> String {
        if step.hasPrefix("Searching") { return "magnifyingglass" }
        if step.hasPrefix("Looking") { return "folder" }
        if step.hasPrefix("Reading") { return "doc.text" }
        if step.hasPrefix("Asking to write") { return "square.and.pencil" }
        if step.hasPrefix("Asking to run") { return "terminal" }
        return "wrench.and.screwdriver"
    }

    /// The answer so far, as Markdown.
    func setAnswer(_ markdown: String) {
        thinking.isHidden = true
        answer.isHidden = false
        answer.set(Markdown.render(markdown))
    }

    func addError(_ text: String) {
        thinking.isHidden = true
        let row = NSStackView(views: [Theme.icon("exclamationmark.triangle.fill", size: 11, color: Theme.error),
                                      wrapping(text, Theme.ui(13), Theme.error)])
        row.alignment = .top
        row.spacing = 7
        stack.insertArrangedSubview(row, at: stack.arrangedSubviews.firstIndex(of: footer) ?? stack.arrangedSubviews.count)
        row.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
    }

    /// Done: shows how long the first word took, or that it was stopped.
    func finish(firstWordAfter seconds: Double?, stopped: Bool) {
        thinking.isHidden = true
        var parts: [NSView] = []
        if let seconds {
            parts += [Theme.icon("clock", size: 10, color: Theme.faint), Theme.label(String(format: "%.1fs", seconds), Theme.ui(11.5), Theme.faint)]
        }
        if stopped { parts.append(Theme.label(seconds == nil ? "Stopped" : "· Stopped", Theme.ui(11.5), Theme.faint)) }
        footer.setViews(parts, in: .leading)
        footer.isHidden = parts.isEmpty
    }
}

/// A wrapping label that follows the width it's given.
func wrapping(_ text: String, _ font: NSFont, _ color: NSColor) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: text)
    l.font = font
    l.textColor = color
    l.isSelectable = true
    l.preferredMaxLayoutWidth = 0
    return l
}

/// The scrolling column. Keeps to the bottom while new text arrives, unless you've scrolled up to read.
final class ChatList: NSView {
    let scroll = NSScrollView()
    private let document = FlippedView()
    private let stack = NSStackView()
    private var pinned = true
    private var hasMessages = false

    init() {
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 40, right: 0)  // room under the fade
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 26
        for v in [scroll, document, stack] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(scroll)
        scroll.documentView = document
        document.addSubview(stack)
        let column = stack.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -64)
        column.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
            stack.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            column,
        ])
        scroll.contentView.postsBoundsChangedNotifications = true
        document.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { self.pinned = self.nearBottom } }
        }
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, self.pinned { self.scrollToBottom() } }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private var nearBottom: Bool {
        let clip = scroll.contentView
        return clip.bounds.maxY >= document.frame.height + scroll.contentInsets.bottom - 40
    }

    func scrollToBottom() {
        let clip = scroll.contentView
        let y = max(-scroll.contentInsets.top, document.frame.height + scroll.contentInsets.bottom - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    /// Empties the conversation and shows `welcome` in its place.
    func reset(welcome: NSView) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        hasMessages = false
        add(welcome, isMessage: false)
        pinned = true
    }

    func add(_ view: NSView, isMessage: Bool = true) {
        if isMessage && !hasMessages {
            hasMessages = true
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }  // the welcome makes way
        }
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        pinned = true
        layoutSubtreeIfNeeded()
        scrollToBottom()
    }

    func remove(_ views: [NSView]) {
        views.forEach { $0.removeFromSuperview() }
    }

    /// A one-line note from the app ("Watching the left half…"), or a problem.
    func addNote(_ text: String, error: Bool = false) {
        let row = NSStackView(views: [Theme.icon(error ? "exclamationmark.triangle.fill" : "info.circle", size: 11,
                                                 color: error ? Theme.error : Theme.accentLight),
                                      wrapping(text, Theme.ui(12.5), error ? Theme.error : Theme.muted)])
        row.alignment = .top
        row.spacing = 8
        add(row)
    }
}
