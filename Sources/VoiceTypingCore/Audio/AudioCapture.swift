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
public protocol AudioCapturing: AnyObject {
    var onFrame: ((PCMFrame) -> Void)? { get set }
    var onError: ((AudioCaptureError) -> Void)? { get set }
    func start() throws
    func stop()
}

public final class AudioCapture: AudioCapturing {
    public var onFrame: ((PCMFrame) -> Void)?
    public var onError: ((AudioCaptureError) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let framesPerBuffer: AVAudioFrameCount
    private var running = false
    /// Bumped on every start/stop so a delayed restart from an old
    /// configuration change cannot revive a stopped capture.
    private var runGeneration: UInt64 = 0
    private var configurationObserver: (any NSObjectProtocol)?
    private let restartQueue = DispatchQueue(label: "MacVoice.AudioCapture.restart")
    /// Delays between attempts to restart after the input device changes.
    /// Bluetooth headsets can report no input for a moment while they switch
    /// to their microphone profile.
    private static let restartDelays: [Double] = [0, 0.1, 0.25, 0.5, 1.0]

    public init(framesPerBuffer: AVAudioFrameCount = 512) {
        self.framesPerBuffer = max(1, framesPerBuffer)
        self.configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
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

        installTap(on: input)
        engine.prepare()
        do {
            try engine.start()
            running = true
            runGeneration &+= 1
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
        runGeneration &+= 1
    }

    /// The input device or its format changed (headset connected, Bluetooth
    /// profile switch, sample-rate change). Restart capture on the new
    /// device, retrying briefly before reporting an error.
    private func handleConfigurationChange() {
        lock.lock()
        guard running else { lock.unlock(); return }
        let generation = runGeneration
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.unlock()
        restart(generation: generation, attempt: 0)
    }

    private func restart(generation: UInt64, attempt: Int) {
        let delays = Self.restartDelays
        restartQueue.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            // Stopped, or restarted by a newer change, in the meantime.
            guard self.running, self.runGeneration == generation else { self.lock.unlock(); return }
            let input = self.engine.inputNode
            let format = input.outputFormat(forBus: 0)
            var failure: AudioCaptureError?
            if format.sampleRate > 0, format.channelCount > 0 {
                self.installTap(on: input)
                self.engine.prepare()
                do {
                    try self.engine.start()
                    self.lock.unlock()
                    return
                } catch {
                    input.removeTap(onBus: 0)
                    failure = .engineStartFailed(error.localizedDescription)
                }
            } else {
                failure = .noInputDevice
            }
            if attempt + 1 < delays.count {
                self.lock.unlock()
                self.restart(generation: generation, attempt: attempt + 1)
                return
            }
            self.running = false
            self.runGeneration &+= 1
            let handler = self.onError
            self.lock.unlock()
            if let failure { handler?(failure) }
        }
    }

    /// Taps the input in its current hardware format (`format: nil`). Passing
    /// a format read earlier can raise an Objective-C exception that crashes
    /// the app if the device changed in between.
    private func installTap(on input: AVAudioInputNode) {
        let frameHandler = onFrame
        let errorHandler = onError
        input.removeTap(onBus: 0) // installing a second tap on a bus also raises
        input.installTap(onBus: 0, bufferSize: framesPerBuffer, format: nil) { buffer, _ in
            guard let channels = buffer.floatChannelData else {
                errorHandler?(.unsupportedAudioFormat)
                return
            }

            let channelCount = Int(buffer.format.channelCount)
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }

            let totalSamples = frameCount * channelCount
            let samples = [Float](unsafeUninitializedCapacity: totalSamples) { dst, initializedCount in
                if channelCount == 1 {
                    if let base = dst.baseAddress {
                        base.initialize(from: channels[0], count: frameCount)
                    }
                } else {
                    for frame in 0..<frameCount {
                        for channel in 0..<channelCount {
                            dst[frame * channelCount + channel] = channels[channel][frame]
                        }
                    }
                }
                initializedCount = totalSamples
            }

            frameHandler?(PCMFrame(
                samples: samples,
                sampleRate: buffer.format.sampleRate,
                channelCount: channelCount,
                frameCount: frameCount,
                deliveryUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            ))
        }
    }

    deinit {
        stop()
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
