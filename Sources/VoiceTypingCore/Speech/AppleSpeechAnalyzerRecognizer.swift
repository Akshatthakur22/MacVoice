@preconcurrency import AVFAudio
import CoreMedia
import Foundation
import Speech

/// Native on-device recognizer available on macOS 26 and later. Speech model
/// assets are managed by macOS; call `installAssets()` explicitly while online
/// if they are not already installed. `start()` never initiates a download.
@available(macOS 26.0, *)
public final class AppleSpeechAnalyzerRecognizer: SpeechRecognizer {
    public var onUpdate: ((SpeechRecognitionUpdate) -> Void)?
    public var onError: ((Error) -> Void)?

    private let locale: Locale
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var confirmedText = ""
    private var outputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var cachedInputFormat: AVAudioFormat?
    private var cachedInputBuffer: AVAudioPCMBuffer?
    private var cachedConvertedBuffer: AVAudioPCMBuffer?
    private var outputSampleOffset: Int64 = 0
    private var running = false

    public init(locale: Locale) {
        self.locale = locale
    }

    /// Explicitly installs the system-managed speech assets. This may download
    /// model data from Apple; it is separate from `start()` and microphone use.
    public func installAssets() async throws {
        guard SpeechTranscriber.isAvailable else {
            throw SpeechRecognizerError.modelUnavailable("SpeechTranscriber is unavailable on this Mac.")
        }
        let transcriber = SpeechTranscriber(locale: try await supportedLocale(), preset: .progressiveTranscription)
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
        let retryInterval: UInt64 = 20
        let maximumAttempts = 6
        var lastInstallationError: Error?

        for attempt in 0..<maximumAttempts {
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
                    try await Task.sleep(nanoseconds: 1_000_000_000)
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
                if attempt + 1 < maximumAttempts {
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
        let transcriber = SpeechTranscriber(locale: try await supportedLocale(), preset: .progressiveTranscription)
        try Task.checkCancellation()
        let modules: [any SpeechModule] = [transcriber]
        guard await AssetInventory.status(forModules: modules) == .installed else {
            throw SpeechRecognizerError.modelUnavailable("Speech assets for \(locale.identifier) are not installed. Connect to the internet and press Try Again to restore them.")
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
        confirmedText = ""
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
        onUpdate?(SpeechRecognitionUpdate(
            hypothesis: confirmedText,
            confirmedTranscript: confirmedText,
            isFinal: true
        ))
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
        if result.isFinal {
            confirmedText += text
            onUpdate?(SpeechRecognitionUpdate(
                hypothesis: confirmedText,
                confirmedTranscript: confirmedText
            ))
        } else {
            onUpdate?(SpeechRecognitionUpdate(
                hypothesis: confirmedText + text,
                confirmedTranscript: confirmedText
            ))
        }
    }

    private func supportedLocale() async throws -> Locale {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechRecognizerError.modelUnavailable("The system speech model does not support locale \(locale.identifier).")
        }
        return supported
    }
}
