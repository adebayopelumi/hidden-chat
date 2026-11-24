import AVFoundation
import ScreenCaptureKit
import Speech

/// Live speech-to-text for one audio source, using Apple's on-device SpeechAnalyzer (audio never leaves the Mac).
final class LiveTranscriber: @unchecked Sendable {
    typealias Handler = @MainActor (_ text: String, _ isFinal: Bool) -> Void

    private let handler: Handler
    private let lock = NSLock()
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?

    // Silence detection: the recognizer holds back the end of a sentence until it's sure the
    // speaker is done, which can take seconds. We finish it ourselves after a pause. Too short a pause
    // cuts sentences at every breath, and each cut piece is recognized without the words around it.
    static let pauseToFinish = 0.8  // seconds of quiet after speech
    static let cutAfterSpeech = 0.25  // where in that pause the sentence is cut
    private var framesFed: Int64 = 0
    private var lastLoudFrame: Int64 = 0
    private var speaking = false
    private var noiseFloor: Float = 0.002

    init(handler: @escaping Handler) { self.handler = handler }

    /// Every language the recognizer can transcribe, as identifiers like "en_GB".
    static func supportedLocaleIDs() async -> [String] {
        await SpeechTranscriber.supportedLocales.map(\.identifier)
    }

    /// The recognizer language for a Settings choice ("" = automatic).
    static func locale(for setting: String) async -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        if !setting.isEmpty, let chosen = supported.first(where: { $0.identifier == setting }) { return chosen }
        let current = Locale.current
        if let exact = supported.first(where: { $0.language.languageCode == current.language.languageCode && $0.region == current.region }) {
            return exact
        }
        // English regions without a model of their own (Nigeria, Ghana, Kenya…) get an arbitrary near one
        // from Apple (Singapore English for Nigeria). British English is the closer fit.
        if current.language.languageCode == .english, let british = supported.first(where: { $0.identifier == "en_GB" }) {
            return british
        }
        return await SpeechTranscriber.supportedLocale(equivalentTo: current) ?? Locale(identifier: "en-US")
    }

    func start(localeID: String = "") async throws {
        let locale = await Self.locale(for: localeID)
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [])

        // One-time download of the speech model for this language.
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppError(message: "Speech recognition isn't available for \(locale.identifier).")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        try await analyzer.prepareToAnalyze(in: format)  // load the model now, not on the first word
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        let handler = self.handler
        resultsTask = Task {
            do {
                var live: (text: String, range: CMTimeRange)?  // latest in-progress result
                for try await result in transcriber.results {
                    let raw = String(result.text.characters)
                    guard result.isFinal else {
                        live = (raw, result.range)
                        await handler(raw, false)
                        continue
                    }
                    var text = Self.cleaned(raw)
                    // A forced finish occasionally garbles a short phrase into bare punctuation (",.");
                    // fall back to the words that were showing live for the same stretch of audio.
                    if !text.contains(where: \.isLetter), let l = live,
                       CMTimeRangeGetIntersection(l.range, otherRange: result.range).duration.seconds > 0 {
                        text = Self.cleaned(l.text)
                    }
                    live = nil
                    await handler(text, true)
                }
            } catch {
                await handler("⚠️ Transcription stopped: \(error.localizedDescription)", true)
            }
        }
        try await analyzer.start(inputSequence: stream)

        lock.withLock {
            self.format = format
            self.input = continuation
            self.analyzer = analyzer
        }
    }

    /// Accepts audio in any format, from any thread.
    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let input, let format, let converted = convert(buffer, to: format) else { return }
        input.yield(AnalyzerInput(buffer: converted))
        framesFed += Int64(converted.frameLength)

        // Simple voice activity detection against a slowly adapting noise floor.
        let level = Self.rms(converted)
        if level > max(0.004, noiseFloor * 4) {
            speaking = true
            lastLoudFrame = framesFed
            return
        }
        noiseFloor = noiseFloor * 0.98 + level * 0.02
        // Finish the sentence as soon as the speaker pauses.
        if speaking, Double(framesFed - lastLoudFrame) / format.sampleRate >= Self.pauseToFinish {
            speaking = false
            // Cut inside the pause (shortly after the last word), not at the edge of the audio received so far.
            let cut = lastLoudFrame + Int64(Self.cutAfterSpeech * format.sampleRate)
            let through = CMTime(value: cut, timescale: CMTimeScale(format.sampleRate))
            let analyzer = self.analyzer
            Task { try? await analyzer?.finalize(through: through) }
        }
    }

    /// Removes fragments the recognizer sometimes invents from silence, like "the.." or ",....".
    static func cleaned(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // a leading short word trailed by dots: "the.. How would you…" → "How would you…"
        if let r = t.range(of: #"^[\p{P}\s]*\p{L}{1,4}\.{2,}\s*"#, options: .regularExpression) { t.removeSubrange(r) }
        // leading punctuation: ". what is…" → "what is…"
        if let r = t.range(of: #"^[\p{P}\s]+"#, options: .regularExpression) { t.removeSubrange(r) }
        // nothing but punctuation left
        if !t.contains(where: \.isLetter) && !t.contains(where: \.isNumber) { return "" }
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        if let f = buffer.floatChannelData?[0] {
            for i in 0..<n { sum += f[i] * f[i] }
        } else if let s = buffer.int16ChannelData?[0] {
            for i in 0..<n { let v = Float(s[i]) / 32768; sum += v * v }
        } else {
            return 0
        }
        return (sum / Float(n)).squareRoot()
    }

    func stop() {
        let analyzer: SpeechAnalyzer? = lock.withLock {
            input?.finish()
            input = nil
            return self.analyzer
        }
        Task { try? await analyzer?.finalizeAndFinishThroughEndOfInput() }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return (status == .error || out.frameLength == 0) ? nil : out
    }
}

/// The microphone ("Me").
final class MicCapture {
    private let engine = AVAudioEngine()
    private var running = false

    func start(feed: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AppError(message: "No microphone found.") }
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in feed(buffer) }
        engine.prepare()
        do { try engine.start() } catch { node.removeTap(onBus: 0); throw error }
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }
}

/// Everything the Mac is playing, such as the other people on a call ("Them").
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var feed: ((AVAudioPCMBuffer) -> Void)?
    private let queue = DispatchQueue(label: "hiddenchat.system-audio")

    func start(feed: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        self.feed = feed
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw AppError(message: "No display found.") }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // Audio is all we want; keep the required video part as small and slow as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        feed = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        feed?(buffer)
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
