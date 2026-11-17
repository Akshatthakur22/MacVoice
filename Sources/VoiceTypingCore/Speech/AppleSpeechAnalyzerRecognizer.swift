@preconcurrency import AVFAudio
import CoreMedia
import Foundation
import Speech

/// Native on-device recognizer available on macOS 26 and later. Speech model
/// assets are managed by macOS; call `installAssets()` explicitly while online
/// if they are not already installed. If no matching model is on disk,
/// `start()` asks macOS to install it before recognition begins.
@available(macOS 26.0, *)
public final class AppleSpeechAnalyzerRecognizer: SpeechRecognizer {
    // Callbacks and transcript state are touched by the result task, the
    // session's audio task, and stop(); a lock keeps those accesses serialized.
    private let stateLock = NSLock()
    private var updateHandler: ((SpeechRecognitionUpdate) -> Void)?
    private var errorHandler: ((Error) -> Void)?
    private var assembler: ProgressiveTranscriptAssembler

    public var onUpdate: ((SpeechRecognitionUpdate) -> Void)? {
        get { stateLock.withLock { updateHandler } }
        set { stateLock.withLock { updateHandler = newValue } }
    }
    public var onError: ((Error) -> Void)? {
        get { stateLock.withLock { errorHandler } }
        set { stateLock.withLock { errorHandler = newValue } }
    }

    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var outputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var cachedInputFormat: AVAudioFormat?
    private var cachedInputBuffer: AVAudioPCMBuffer?
    private var cachedConvertedBuffer: AVAudioPCMBuffer?
    private var outputSampleOffset: Int64 = 0
    private var running = false

    /// - Parameter streamsVolatileWords: Type completed words before the
    ///   recognizer finalizes a segment (live Verbatim typing). Pass false for
    ///   Polished mode to keep final punctuation exact.
    public init(locale: Locale, streamsVolatileWords: Bool = true) {
        self.locale = locale
        self.assembler = ProgressiveTranscriptAssembler(commitsVolatileWords: streamsVolatileWords)
    }

    /// Explicitly installs the system-managed speech assets. This may download
    /// model data from Apple; it is separate from `start()` and microphone use.
    public func installAssets() async throws {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechRecognizerError.modelUnavailable("SpeechTranscriber is unavailable on this Mac.")
        }
        let supported = try await supportedLocale()
        let targetNorm = Self.normalizedLocaleID(supported.identifier)
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { Self.normalizedLocaleID($0.identifier) == targetNorm }) {
            return
        }

        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        let modules: [any SpeechModule] = [transcriber]

        switch await AssetInventory.status(forModules: modules) {
        case .installed:
            return
        case .unsupported:
            throw SpeechRecognizerError.modelUnavailable("Apple does not support speech assets for locale \(locale.identifier) on this Mac.")
        case .supported, .downloading:
            break
        @unknown default:
            throw SpeechRecognizerError.modelUnavailable("macOS returned an unrecognized speech asset status for locale \(locale.identifier). Update macOS and try again.")
        }

        // macOS can return from the first request while the asset remains in
        // `.downloading`; Apple documents that this can mean a deferred retry,
        // rather than an active download. Re-request periodically so the
        // system gets another installation attempt instead of only polling a
        // stale status for two minutes.
        try await installAndConfirmAssets(modules: modules)
    }

    private func installAndConfirmAssets(modules: [any SpeechModule]) async throws {
        let retryIntervals: [UInt64] = [1, 2, 4, 8, 12, 15]
        var lastInstallationError: Error?

        for (attempt, retryInterval) in retryIntervals.enumerated() {
            try Task.checkCancellation()
            switch await AssetInventory.status(forModules: modules) {
            case .installed:
                return
            case .unsupported:
                throw SpeechRecognizerError.modelUnavailable("Apple does not support speech assets for locale \(locale.identifier) on this Mac.")
            case .supported, .downloading:
                guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
                    // A nil request means assets are already installed; allow
                    // the inventory a short time to reflect that state.
                    try await Task.sleep(nanoseconds: 500_000_000)
                    if await AssetInventory.status(forModules: modules) == .installed {
                        return
                    }
                    continue
                }
                do {
                    try await request.downloadAndInstall()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The system may keep the locale queued and allow a later
                    // request to succeed, so retain the error and retry.
                    lastInstallationError = error
                }
                try Task.checkCancellation()
                if await AssetInventory.status(forModules: modules) == .installed {
                    return
                }
                if attempt + 1 < retryIntervals.count {
                    try await Task.sleep(nanoseconds: retryInterval * 1_000_000_000)
                }
            @unknown default:
                throw SpeechRecognizerError.modelUnavailable("macOS returned an unrecognized speech asset status for locale \(locale.identifier). Update macOS and try again.")
            }
        }

        let detail = lastInstallationError.map { " Last error: \($0.localizedDescription)" } ?? ""
        throw SpeechRecognizerError.modelUnavailable("macOS has not installed speech assets for \(locale.identifier) after repeated download attempts. Check the internet connection and macOS Software Update, then press Try Again.\(detail)")
    }

    public func start() async throws {
        try Task.checkCancellation()
        guard !running else { throw SpeechRecognizerError.modelLoadFailed("Recognizer is already running.") }
        guard SpeechTranscriber.isAvailable else {
            throw SpeechRecognizerError.modelUnavailable("SpeechTranscriber is unavailable on this Mac.")
        }
        let supported = try await supportedLocale()
        try Task.checkCancellation()
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        let modules: [any SpeechModule] = [transcriber]

        // Fast path: if the assets for this locale are already installed on disk,
        // do not call installAssets() or hammer the XPC daemon with download requests!
        let targetNorm = Self.normalizedLocaleID(supported.identifier)
        let installed = await SpeechTranscriber.installedLocales
        let isAlreadyOnDisk = installed.contains(where: { Self.normalizedLocaleID($0.identifier) == targetNorm })

        if !isAlreadyOnDisk {
            var assetStatus = await AssetInventory.status(forModules: modules)
            if assetStatus != .installed {
                try await installAssets()
                assetStatus = await AssetInventory.status(forModules: modules)
            }
            guard assetStatus == .installed else {
                throw SpeechRecognizerError.modelUnavailable("Speech assets for \(locale.identifier) are not installed. Connect to the internet and press Try Again to restore them.")
            }
        }
        try Task.checkCancellation()
        guard let outputFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw SpeechRecognizerError.unsupportedAudioFormat
        }
        try Task.checkCancellation()

        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingOldest(256)
        )
        let analyzer = SpeechAnalyzer(modules: modules, options: nil)
        self.analyzer = analyzer
        self.outputFormat = outputFormat
        self.inputContinuation = continuation
        stateLock.withLock { assembler.reset() }
        outputSampleOffset = 0
        running = true

        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.receive(result)
                }
            } catch {
                self?.onError?(SpeechRecognizerError.inferenceFailed(error.localizedDescription))
            }
        }

        do {
            try await analyzer.start(inputSequence: inputStream)
            try Task.checkCancellation()
        } catch {
            running = false
            continuation.finish()
            resultTask?.cancel()
            await resultTask?.value
            resultTask = nil
            inputContinuation = nil
            self.analyzer = nil
            self.outputFormat = nil
            if error is CancellationError { throw error }

            // If macOS hibernated the speech daemon (NSCocoaErrorDomain Code=4099/4097),
            // wait briefly for the daemon to respawn and retry once.
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && (nsError.code == 4099 || nsError.code == 4097) {
                try await Task.sleep(nanoseconds: 300_000_000)
                try Task.checkCancellation()
                let retryTranscriber = SpeechTranscriber(locale: try await supportedLocale(), preset: .progressiveTranscription)
                let retryModules: [any SpeechModule] = [retryTranscriber]
                guard let retryOutputFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: retryModules) else {
                    throw SpeechRecognizerError.unsupportedAudioFormat
                }
                let (retryStream, retryContinuation) = AsyncStream<AnalyzerInput>.makeStream(
                    bufferingPolicy: .bufferingOldest(256)
                )
                let retryAnalyzer = SpeechAnalyzer(modules: retryModules, options: nil)
                self.analyzer = retryAnalyzer
                self.outputFormat = retryOutputFormat
                self.inputContinuation = retryContinuation
                stateLock.withLock { assembler.reset() }
                outputSampleOffset = 0
                running = true

                resultTask = Task { [weak self] in
                    do {
                        for try await result in retryTranscriber.results {
                            self?.receive(result)
                        }
                    } catch {
                        self?.onError?(SpeechRecognizerError.inferenceFailed(error.localizedDescription))
                    }
                }

                do {
                    try await retryAnalyzer.start(inputSequence: retryStream)
                    try Task.checkCancellation()
                    return
                } catch {
                    running = false
                    retryContinuation.finish()
                    resultTask?.cancel()
                    await resultTask?.value
                    resultTask = nil
                    inputContinuation = nil
                    self.analyzer = nil
                    self.outputFormat = nil
                    if error is CancellationError { throw error }
                    throw SpeechRecognizerError.modelLoadFailed(error.localizedDescription)
                }
            }

            throw SpeechRecognizerError.modelLoadFailed(error.localizedDescription)
        }
    }

    public func consume(_ frame: PCMFrame) async throws {
        try Task.checkCancellation()
        guard running, let continuation = inputContinuation, let outputFormat else {
            throw SpeechRecognizerError.stopped
        }

        let inputFormat: AVAudioFormat
        if let cached = cachedInputFormat,
           cached.sampleRate == frame.sampleRate,
           cached.channelCount == AVAudioChannelCount(frame.channelCount) {
            inputFormat = cached
        } else {
            guard let newFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: frame.sampleRate,
                channels: AVAudioChannelCount(frame.channelCount),
                interleaved: false
            ) else {
                throw SpeechRecognizerError.unsupportedAudioFormat
            }
            inputFormat = newFormat
            cachedInputFormat = newFormat
        }

        let inputBuffer: AVAudioPCMBuffer
        if let cachedBuf = cachedInputBuffer,
           cachedBuf.format == inputFormat,
           cachedBuf.frameCapacity >= AVAudioFrameCount(frame.frameCount) {
            inputBuffer = cachedBuf
        } else {
            guard let newBuf = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: max(AVAudioFrameCount(frame.frameCount), 2048)
            ) else {
                throw SpeechRecognizerError.unsupportedAudioFormat
            }
            inputBuffer = newBuf
            cachedInputBuffer = newBuf
        }
        inputBuffer.frameLength = AVAudioFrameCount(frame.frameCount)

        guard let channelData = inputBuffer.floatChannelData else {
            throw SpeechRecognizerError.unsupportedAudioFormat
        }
        if frame.channelCount == 1 {
            frame.samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    channelData[0].initialize(from: base, count: frame.frameCount)
                }
            }
        } else {
            for channel in 0..<frame.channelCount {
                for index in 0..<frame.frameCount {
                    channelData[channel][index] = frame.samples[index * frame.channelCount + channel]
                }
            }
        }

        if converter == nil || converterInputFormat != inputFormat {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw SpeechRecognizerError.unsupportedAudioFormat
            }
            converter = newConverter
            converterInputFormat = inputFormat
        }
        guard let converter else { throw SpeechRecognizerError.unsupportedAudioFormat }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(frame.frameCount) * ratio) + 32)
        let converted: AVAudioPCMBuffer
        if let cachedConv = cachedConvertedBuffer,
           cachedConv.format == outputFormat,
           cachedConv.frameCapacity >= capacity {
            converted = cachedConv
            converted.frameLength = 0
        } else {
            guard let newConv = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: max(capacity, 2048)) else {
                throw SpeechRecognizerError.unsupportedAudioFormat
            }
            converted = newConv
            cachedConvertedBuffer = newConv
        }

        var conversionError: NSError?
        var suppliedInput = false
        let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        if status == .error {
            throw SpeechRecognizerError.inferenceFailed(conversionError?.localizedDescription ?? "Audio conversion failed.")
        }
        guard converted.frameLength > 0 else { return }

        try Task.checkCancellation()
        let startTime = CMTime(value: outputSampleOffset, timescale: CMTimeScale(outputFormat.sampleRate))
        outputSampleOffset += Int64(converted.frameLength)
        guard case .dropped = continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: startTime)) else {
            return
        }
        throw SpeechRecognizerError.audioBufferOverrun
    }

    public func stop() async {
        guard running else { return }
        running = false
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                onError?(SpeechRecognizerError.inferenceFailed(error.localizedDescription))
            }
        }
        await resultTask?.value
        resultTask = nil
        let finalUpdate = stateLock.withLock { assembler.finalUpdate }
        onUpdate?(finalUpdate)
        analyzer = nil
        converter = nil
        converterInputFormat = nil
        cachedInputFormat = nil
        cachedInputBuffer = nil
        cachedConvertedBuffer = nil
        outputFormat = nil
    }

    private func receive(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
        let update = stateLock.withLock { assembler.receive(text: text, isFinal: result.isFinal) }
        onUpdate?(update)
    }

    public static func normalizedLocaleID(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "-", with: "_").lowercased()
    }

    private func supportedLocale() async throws -> Locale {
        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return supported
        }
        // In case the speech daemon was cold or waking from sleep, retry once
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechRecognizerError.modelUnavailable("The system speech model does not support locale \(locale.identifier).")
        }
        return supported
    }
}
