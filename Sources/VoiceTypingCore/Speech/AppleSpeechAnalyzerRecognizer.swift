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
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
            return
        }
        try await request.downloadAndInstall()
    }

    public func start() async throws {
        guard !running else { throw SpeechRecognizerError.modelLoadFailed("Recognizer is already running.") }
        guard SpeechTranscriber.isAvailable else {
            throw SpeechRecognizerError.modelUnavailable("SpeechTranscriber is unavailable on this Mac.")
        }
        let transcriber = SpeechTranscriber(locale: try await supportedLocale(), preset: .progressiveTranscription)
        let modules: [any SpeechModule] = [transcriber]
        guard await AssetInventory.status(forModules: modules) == .installed else {
            throw SpeechRecognizerError.modelUnavailable("Speech assets for \(locale.identifier) are not installed. Install them explicitly before going offline.")
        }
        guard let outputFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw SpeechRecognizerError.unsupportedAudioFormat
        }

        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingOldest(32)
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
        } catch {
            running = false
            continuation.finish()
            resultTask?.cancel()
            resultTask = nil
            self.analyzer = nil
            throw SpeechRecognizerError.modelLoadFailed(error.localizedDescription)
        }
    }

    public func consume(_ frame: PCMFrame) async throws {
        guard running, let continuation = inputContinuation, let outputFormat else {
            throw SpeechRecognizerError.stopped
        }
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: frame.sampleRate,
            channels: AVAudioChannelCount(frame.channelCount),
            interleaved: false
        )
        guard let inputFormat,
              let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(frame.frameCount)
              ),
              let channelData = inputBuffer.floatChannelData else {
            throw SpeechRecognizerError.unsupportedAudioFormat
        }
        inputBuffer.frameLength = AVAudioFrameCount(frame.frameCount)
        for channel in 0..<frame.channelCount {
            for index in 0..<frame.frameCount {
                channelData[channel][index] = frame.samples[index * frame.channelCount + channel]
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
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw SpeechRecognizerError.unsupportedAudioFormat
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
