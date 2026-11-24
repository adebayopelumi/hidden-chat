import AppKit
import CoreImage
import ScreenCaptureKit
import Vision

/// JPEG (base64) of an image, shrunk so its long side is at most `maxSide` pixels.
func jpegBase64(_ image: CGImage, maxSide: CGFloat = 2048) -> String? {
    var cg = image
    let longSide = CGFloat(max(image.width, image.height))
    if longSide > maxSide {
        let s = maxSide / longSide
        let w = Int(CGFloat(image.width) * s), h = Int(CGFloat(image.height) * s)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        cg = scaled
    }
    return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.75])?.base64EncodedString()
}

/// The main display, leaving out Hidden Chat's own windows.
private func captureFilter(from content: SCShareableContent) throws -> (SCContentFilter, CGDirectDisplayID) {
    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
        throw AppError(message: "No display found to capture.")
    }
    let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
    return (SCContentFilter(display: display, excludingApplications: me, exceptingWindows: []), display.displayID)
}

enum ScreenGrabber {
    /// A single screenshot of the main display (used until the watcher has its first frame).
    static func capture() async throws -> CGImage {
        let (filter, _) = try captureFilter(from: try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

/// A line of text read from the screen, and where it is: 0…1 of the screen, origin bottom-left (as Vision reports it).
struct TextLine {
    let text: String
    let box: CGRect
}

/// Neighbouring lines that belong together: a question and its wrapped lines, a quiz question and its options.
struct TextBlock {
    let lines: [TextLine]
    var text: String { lines.map(\.text).joined(separator: "\n") }
    var box: CGRect { lines.dropFirst().reduce(lines[0].box) { $0.union($1.box) } }
}

/// Continuously records the screen at a low frame rate and reads its text on this Mac. Keeps the latest
/// frame and a timeline of text as it appears, and reports new blocks of text once the screen settles.
final class ScreenWatcher: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Change { let time: Date; let newLines: [String] }

    /// Called on the main thread each time the screen's text settles: every line on screen (to keep highlights
    /// in place), the blocks of new text, and whether this is the first look or a whole new scene (switching
    /// apps, scrolling a page), when only clear questions are worth flagging.
    var onSettled: (@MainActor (_ lines: [TextLine], _ newBlocks: [TextBlock], _ firstLookOrNewScene: Bool) -> Void)?
    /// The display being watched.
    private(set) var displayID: CGDirectDisplayID?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "hiddenchat.screen-watch")
    private let lock = NSLock()
    private let ciContext = CIContext()
    private var previousLines: Set<String> = []
    private var frame: CGImage?
    private var frameJPEG: String?
    private var timeline: [Change] = []
    private var lastSeen = ""
    private var reported: Set<String> = []
    private var baselineSet = false
    private var generation = 0

    /// Frames are pre-shrunk and pre-encoded as they arrive, so asking a question doesn't wait on it.
    static let jpegMaxSide: CGFloat = 1600
    var latestFrame: CGImage? { lock.withLock { frame } }
    var latestJPEG: String? { lock.withLock { frameJPEG } }
    var changes: [Change] { lock.withLock { timeline } }

    /// `interval` is the shortest gap between frames; frames only arrive when the screen changes.
    func start(interval: Double = 1) async throws {
        let (filter, display) = try captureFilter(from: try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))
        displayID = display
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.minimumFrameInterval = CMTime(seconds: interval, preferredTimescale: 600)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.showsCursor = false

        lock.withLock {
            previousLines = []; timeline = []; frame = nil; frameJPEG = nil
            lastSeen = ""; reported = []; baselineSet = false; generation += 1
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        lock.withLock { generation += 1 }
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isNewFrame(sampleBuffer),
              let pixels = sampleBuffer.imageBuffer else { return }
        let ci = CIImage(cvPixelBuffer: pixels)
        guard let image = ciContext.createCGImage(ci, from: ci.extent) else { return }
        handle(image)
    }

    /// Reads one new frame: updates the timeline, and reports new text once the screen stops changing.
    func handle(_ image: CGImage) {
        let found = Self.recognize(in: image)
        let lines = found.map(\.text)
        let jpeg = jpegBase64(image, maxSide: Self.jpegMaxSide)
        let text = lines.joined(separator: "\n")
        let g: Int? = lock.withLock {
            frame = image
            frameJPEG = jpeg
            let fresh = lines.filter { !previousLines.contains($0) }
            previousLines = Set(lines)
            if !fresh.isEmpty {
                timeline.append(Change(time: Date(), newLines: fresh))
                if timeline.count > 400 { timeline.removeFirst(timeline.count - 400) }
            }
            guard text != lastSeen else { return nil }
            lastSeen = text
            generation += 1
            return generation
        }
        guard let g else { return }
        // Wait for the text to stop changing (someone still typing, scrolling) before reporting it.
        queue.asyncAfter(deadline: .now() + AreaWatcher.settle) { [weak self] in self?.commit(g, found: found) }
    }

    private func commit(_ g: Int, found: [TextLine]) {
        let result: (blocks: [TextBlock], broad: Bool)? = lock.withLock {
            guard g == generation else { return nil }  // changed again since; a later commit will handle it
            let fresh = found.filter { !reported.contains($0.text) }
            let broad = !baselineSet || fresh.count > 20
            baselineSet = true
            reported = Set(found.map(\.text))
            return (Self.group(fresh), broad)
        }
        guard let result, let onSettled else { return }
        Task { @MainActor in onSettled(found, result.blocks, result.broad) }
    }

    /// Groups lines into blocks: a line joins the block whose last line sits right above it and overlaps it
    /// sideways. Works column by column, so a chat beside a document doesn't get mixed together.
    static func group(_ lines: [TextLine]) -> [TextBlock] {
        var groups: [[TextLine]] = []
        for line in lines.sorted(by: { $0.box.maxY > $1.box.maxY }) {  // top to bottom
            let b = line.box
            if let i = groups.lastIndex(where: { group in
                let last = group[group.count - 1].box
                let gap = last.minY - b.maxY  // vertical space between the two lines
                let overlap = min(last.maxX, b.maxX) - max(last.minX, b.minX)
                return gap > -last.height * 0.5 && gap < max(last.height, b.height) * 1.3 && overlap > 0
            }) {
                groups[i].append(line)
            } else {
                groups.append([line])
            }
        }
        return groups.map { TextBlock(lines: $0) }
    }

    /// Part of a frame, by a normalized box (as in TextLine), with some margin around it for context.
    static func crop(_ image: CGImage, to box: CGRect) -> CGImage? {
        let padded = box.insetBy(dx: -0.03, dy: -0.025).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let rect = CGRect(x: padded.minX * w, y: (1 - padded.maxY) * h, width: padded.width * w, height: padded.height * h).integral
        return image.cropping(to: rect)
    }

    /// Skips the "nothing changed" frames ScreenCaptureKit sends while the screen is idle.
    static func isNewFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    /// Loads the text-recognition model in the background. The first load after a new build can take
    /// most of a minute, so do it at launch rather than when the user first needs it.
    static func warmUp() {
        Task.detached(priority: .utility) {
            let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
            if let image = ctx?.makeImage() { _ = recognize(in: image) }
        }
    }

    /// On-device text recognition (Apple Vision); nothing is uploaded. Lines come top to bottom, left to right.
    static func recognize(in image: CGImage) -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .sorted { a, b in
                abs(a.boundingBox.midY - b.boundingBox.midY) > 0.005 ? a.boundingBox.midY > b.boundingBox.midY
                                                                     : a.boundingBox.minX < b.boundingBox.minX
            }
            .compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces),
                      text.count > 1 else { return nil }
                return TextLine(text: text, box: observation.boundingBox)
            }
    }

    static func recognizeLines(in image: CGImage) -> [String] { recognize(in: image).map(\.text) }
}

/// Watches one area of the screen the user selected: reads its text whenever it changes and, once the
/// text has settled, reports what's new so it can be answered right away.
final class AreaWatcher: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Called on the main thread with the new text, the whole area's text, and the area as JPEG.
    var onNewText: (@MainActor (_ new: String, _ full: String, _ jpeg: String?) -> Void)?

    static let settle = 0.7  // seconds the text must stay unchanged before it's reported
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "hiddenchat.area-watch")
    private let ciContext = CIContext()
    private let lock = NSLock()
    private var image: CGImage?
    private var lastSeen = ""
    private var reported: Set<String> = []
    private var generation = 0

    /// The latest picture of the area, as JPEG (for questions typed while the area is watched).
    var latestJPEG: String? { lock.withLock { image }.flatMap { jpegBase64($0, maxSide: 1600) } }

    /// `rect` is in global screen coordinates (bottom-left origin), on `screen`.
    func start(rect: NSRect, on screen: NSScreen) async throws {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw AppError(message: "Couldn't identify that screen.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw AppError(message: "Couldn't find that screen to record.")
        }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        // ScreenCaptureKit measures from the display's top-left corner, in points.
        let local = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        let scale = max(screen.backingScaleFactor, 2)  // at least 2x, so small text reads well
        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = Int(local.width * scale)
        config.height = Int(local.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)  // up to two looks per second, only when it changes
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.showsCursor = false

        lock.withLock { image = nil; lastSeen = ""; reported = []; generation += 1 }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        lock.withLock { generation += 1 }
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, ScreenWatcher.isNewFrame(sampleBuffer),
              let pixels = sampleBuffer.imageBuffer else { return }
        let ci = CIImage(cvPixelBuffer: pixels)
        guard let frame = ciContext.createCGImage(ci, from: ci.extent) else { return }
        handle(frame)
    }

    /// Reads one new frame of the area; reports its new text once it stops changing.
    func handle(_ frame: CGImage) {
        let lines = ScreenWatcher.recognizeLines(in: frame)
        let text = lines.joined(separator: "\n")
        let g: Int? = lock.withLock {
            image = frame
            guard text != lastSeen else { return nil }
            lastSeen = text
            generation += 1
            return generation
        }
        guard let g else { return }
        // Wait for the text to stop changing (typing, scrolling, animations) before reporting it.
        queue.asyncAfter(deadline: .now() + Self.settle) { [weak self] in self?.commit(g, lines: lines, frame: frame) }
    }

    private func commit(_ g: Int, lines: [String], frame: CGImage) {
        let new: String? = lock.withLock {
            guard g == generation else { return nil }  // changed again since; a later commit will handle it
            let fresh = Self.newText(previous: reported, current: lines)
            reported = Set(lines)
            return fresh
        }
        guard let new, let onNewText else { return }
        let full = lines.joined(separator: "\n")
        let jpeg = jpegBase64(frame, maxSide: 1600)
        Task { @MainActor in onNewText(new, full, jpeg) }
    }

    /// The lines that weren't in the area last time, if there's enough of them to be worth answering.
    static func newText(previous: Set<String>, current: [String]) -> String? {
        let fresh = current.filter { !previous.contains($0) }
        let words = fresh.joined(separator: " ").split(whereSeparator: \.isWhitespace).count
        return words >= 2 ? fresh.joined(separator: "\n") : nil
    }
}
