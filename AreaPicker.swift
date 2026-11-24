import AppKit

/// Dims every screen and lets the user drag out a rectangle. Esc cancels.
/// Reports the rectangle in global screen coordinates, plus the screen it's on.
@MainActor
final class AreaPicker {
    private var windows: [NSWindow] = []
    private var completion: ((NSRect, NSScreen)?) -> Void = { _ in }

    func pick(completion: @escaping ((NSRect, NSScreen)?) -> Void) {
        self.completion = completion
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let window = KeyableWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.sharingType = .none
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onDone = { [weak self] rect in
                self?.finish(rect.map { (NSRect(x: $0.minX + screen.frame.minX, y: $0.minY + screen.frame.minY,
                                                width: $0.width, height: $0.height), screen) })
            }
            window.contentView = view
            window.orderFrontRegardless()
            if screen.frame.contains(mouse) {
                window.makeKey()
                window.makeFirstResponder(view)
            }
            windows.append(window)
        }
        NSApp.activate()
    }

    private func finish(_ result: (NSRect, NSScreen)?) {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        completion(result)
    }
}

/// Borderless windows don't take key events (for Esc) unless they say so.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class PickerView: NSView {
    var onDone: (NSRect?) -> Void = { _ in }
    private var start: NSPoint?
    private var current: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: NSRect? {
        guard let s = start, let c = current else { return nil }
        return NSRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(s.x - c.x), height: abs(s.y - c.y))
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect = selection, rect.width >= 10, rect.height >= 10 else {
            start = nil
            needsDisplay = true
            return
        }
        onDone(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDone(nil) }  // Esc
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        if let rect = selection {
            NSColor.clear.setFill()
            rect.fill(using: .copy)  // the selected area shows through undimmed
            Theme.accent.setStroke()
            let border = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
            border.lineWidth = 2
            border.stroke()
        }
        let hint = "Drag around the area to answer from  ·  Esc to cancel" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.ui(14, .medium), .foregroundColor: NSColor.white]
        let size = hint.size(withAttributes: attrs)
        let box = NSRect(x: bounds.midX - size.width / 2 - 14, y: bounds.maxY - 90, width: size.width + 28, height: size.height + 14)
        Theme.raised.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        hint.draw(at: NSPoint(x: box.minX + 14, y: box.minY + 7), withAttributes: attrs)
    }
}

/// A thin outline around the area being watched. It ignores the mouse and is hidden from screen capture.
@MainActor
final class AreaOutline {
    private let window: NSWindow

    init(rect: NSRect) {
        window = NSWindow(contentRect: rect.insetBy(dx: -3, dy: -3), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.level = .floating
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = OutlineView()
        window.orderFrontRegardless()
    }

    func close() { window.orderOut(nil) }
}

private final class OutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.accent.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8)
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        path.stroke()
    }
}
