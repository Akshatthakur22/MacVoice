import AVFAudio
import Foundation

/// A copied, interleaved Float32 PCM block from the current microphone input.
/// The frame callback runs on AVAudioEngine's audio delivery thread.
public struct PCMFrame: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public let channelCount: Int
    public let frameCount: Int
    /// Callback-time uptime, not the microphone's hardware capture timestamp.
    public let deliveryUptimeNanoseconds: UInt64

    public init(
        samples: [Float],
        sampleRate: Double,
        channelCount: Int,
        frameCount: Int,
        deliveryUptimeNanoseconds: UInt64
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
        self.deliveryUptimeNanoseconds = deliveryUptimeNanoseconds
    }
}

public enum AudioCaptureError: Error, LocalizedError {
    case permissionDenied
    case noInputDevice
    case unsupportedAudioFormat
    case alreadyRunning
    case engineStartFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access is not authorized. The host app must request access and include NSMicrophoneUsageDescription."
        case .noInputDevice:
            return "No usable microphone input is available."
        case .unsupportedAudioFormat:
            return "The microphone supplied an audio format without Float32 channel data."
        case .alreadyRunning:
            return "Audio capture is already running."
        case .engineStartFailed(let message):
            return "Could not start microphone capture: \(message)"
        }
    }
}

/// Captures microphone PCM in memory without recording it to disk.
///
/// The host should call `requestPermission()` from its permission flow and set
/// `onFrame` before calling `start()`. `onFrame` is invoked on the audio delivery
/// thread; it must return quickly and must not perform model inference inline.
public final class AudioCapture {
    public var onFrame: ((PCMFrame) -> Void)?
    public var onError: ((AudioCaptureError) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let framesPerBuffer: AVAudioFrameCount
    private var running = false

    public init(framesPerBuffer: AVAudioFrameCount = 512) {
        self.framesPerBuffer = max(1, framesPerBuffer)
    }

    /// Requests microphone permission. The host remains responsible for its
    /// user-facing explanation and for declaring NSMicrophoneUsageDescription.
    public static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { throw AudioCaptureError.alreadyRunning }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw AudioCaptureError.permissionDenied
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        let frameHandler = onFrame
        let errorHandler = onError
        input.installTap(onBus: 0, bufferSize: framesPerBuffer, format: format) { buffer, _ in
            guard let channels = buffer.floatChannelData else {
                errorHandler?(.unsupportedAudioFormat)
                return
            }

            let channelCount = Int(buffer.format.channelCount)
            let frameCount = Int(buffer.frameLength)
            var samples = [Float](repeating: 0, count: frameCount * channelCount)
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    samples[frame * channelCount + channel] = channels[channel][frame]
                }
            }
            frameHandler?(PCMFrame(
                samples: samples,
                sampleRate: buffer.format.sampleRate,
                channelCount: channelCount,
                frameCount: frameCount,
                deliveryUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            ))
        }

        engine.prepare()
        do {
            try engine.start()
            running = true
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.engineStartFailed(error.localizedDescription)
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    deinit {
        stop()
    }
}
