import AVFAudio
import Darwin
import Foundation
import VoiceTypingCore

private final class UpdateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var firstHypothesis: TimeInterval?
    private var firstConfirmed: TimeInterval?
    private var latestText = ""

    func record(_ update: SpeechRecognitionUpdate, elapsed: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        if firstHypothesis == nil, !update.hypothesis.isEmpty { firstHypothesis = elapsed }
        if firstConfirmed == nil, !update.confirmedTranscript.isEmpty { firstConfirmed = elapsed }
        latestText = update.confirmedTranscript
    }

    var timings: (hypothesis: TimeInterval?, confirmed: TimeInterval?, text: String) {
        lock.lock()
        defer { lock.unlock() }
        return (firstHypothesis, firstConfirmed, latestText)
    }
}

@main
enum VoiceTypingBenchmark {
    static func main() async {
        do {
            guard #available(macOS 26.0, *) else {
                throw BenchmarkError.unsupportedOS
            }
            try await run()
        } catch {
            fputs("Benchmark failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @available(macOS 26.0, *)
    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let audioPath = arguments.first(where: { !$0.hasPrefix("--") }) else {
            throw BenchmarkError.usage
        }
        let referencePath = option("--reference-file", in: arguments)
        let localeID = option("--locale", in: arguments) ?? "en-US"
        let locale = Locale(identifier: localeID)
        let audioURL = URL(fileURLWithPath: audioPath)
        let audioFile = try AVAudioFile(forReading: audioURL)
        let audioFormat = audioFile.processingFormat
        guard audioFormat.sampleRate > 0, audioFormat.channelCount > 0 else {
            throw SpeechRecognizerError.unsupportedAudioFormat
        }

        let reference = try referencePath.map {
            try String(contentsOf: URL(fileURLWithPath: $0), encoding: .utf8)
        }
        let recognizer = AppleSpeechAnalyzerRecognizer(locale: locale)
        let updates = UpdateRecorder()
        var audioStartUptime: UInt64?
        recognizer.onUpdate = { update in
            let start = audioStartUptime ?? DispatchTime.now().uptimeNanoseconds
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000_000
            updates.record(update, elapsed: elapsed)
        }

        var usageBefore = rusage()
        getrusage(RUSAGE_SELF, &usageBefore)
        let rssBefore = residentBytes()
        let modelStart = DispatchTime.now().uptimeNanoseconds
        try await recognizer.start()
        let modelSetupDuration = seconds(since: modelStart)

        audioStartUptime = DispatchTime.now().uptimeNanoseconds
        let frameCount = 512
        let channelCount = Int(audioFormat.channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw SpeechRecognizerError.unsupportedAudioFormat
        }
        while audioFile.framePosition < audioFile.length {
            try audioFile.read(into: buffer, frameCount: AVAudioFrameCount(frameCount))
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { break }
            guard let channels = buffer.floatChannelData else {
                throw SpeechRecognizerError.unsupportedAudioFormat
            }
            var interleaved = [Float](repeating: 0, count: frames * channelCount)
            for frame in 0..<frames {
                for channel in 0..<channelCount {
                    interleaved[frame * channelCount + channel] = channels[channel][frame]
                }
            }
            let frame = PCMFrame(
                samples: interleaved,
                sampleRate: audioFormat.sampleRate,
                channelCount: channelCount,
                frameCount: frames,
                deliveryUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
            try await recognizer.consume(frame)
            let interval = Double(frames) / audioFormat.sampleRate
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }

        let audioDuration = Double(audioFile.length) / audioFormat.sampleRate
        let audioEndUptime = DispatchTime.now().uptimeNanoseconds
        await recognizer.stop()
        let finalizationLatency = Double(DispatchTime.now().uptimeNanoseconds &- audioEndUptime) / 1_000_000_000

        var usageAfter = rusage()
        getrusage(RUSAGE_SELF, &usageAfter)
        let cpuSeconds = cpuTime(usageAfter) - cpuTime(usageBefore)
        let rssAfter = residentBytes()
        let result = updates.timings

        print("Provider: Apple SpeechAnalyzer")
        print("Locale: \(localeID)")
        print(String(format: "Asset/model setup: %.3fs", modelSetupDuration))
        print(String(format: "Audio duration / replay wall time: %.3f / %.3fs", audioDuration, seconds(since: audioStartUptime ?? audioEndUptime)))
        print(String(format: "First hypothesis / first confirmed: %@ / %@", formatted(result.hypothesis), formatted(result.confirmed)))
        print(String(format: "Stop-to-finalization: %.3fs", finalizationLatency))
        print(String(format: "Process CPU / RSS before-after: %.3fs / %.1f → %.1f MiB", cpuSeconds, mib(rssBefore), mib(rssAfter)))
        if let reference {
            print(String(format: "Reference WER (whitespace tokens, punctuation retained): %.2f%%", wordErrorRate(reference, result.text) * 100))
            print(String(format: "Reference CER (Unicode scalars): %.2f%%", characterErrorRate(reference, result.text) * 100))
        }
        print("\nTranscript:\n\(result.text)")
        print("\nModel assets must already be installed; this tool does not download them or access the microphone.")
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        arguments.first(where: { $0.hasPrefix(name + "=") })?.dropFirst(name.count + 1).description
    }

    private static func seconds(since start: UInt64) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000_000
    }

    private static func formatted(_ value: TimeInterval?) -> String {
        guard let value else { return "not observed" }
        return String(format: "%.3fs", value)
    }

    private static func cpuTime(_ usage: rusage) -> Double {
        Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.resident_size : 0
    }

    private static func mib(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }

    private static func wordErrorRate(_ reference: String, _ hypothesis: String) -> Double {
        let left = reference.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let right = hypothesis.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return Double(editDistance(left, right)) / Double(max(left.count, 1))
    }

    private static func characterErrorRate(_ reference: String, _ hypothesis: String) -> Double {
        let left = reference.unicodeScalars.map(String.init)
        let right = hypothesis.unicodeScalars.map(String.init)
        return Double(editDistance(left, right)) / Double(max(left.count, 1))
    }

    private static func editDistance<T: Equatable>(_ lhs: [T], _ rhs: [T]) -> Int {
        var previous = Array(0...rhs.count)
        for (leftIndex, leftValue) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, rightValue) in rhs.enumerated() {
                current[rightIndex + 1] = min(
                    previous[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    previous[rightIndex] + (leftValue == rightValue ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[rhs.count]
    }
}

private enum BenchmarkError: Error, LocalizedError {
    case usage
    case unsupportedOS
    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: swift run VoiceTypingBenchmark audio.wav [--locale=en-US] [--reference-file=transcript.txt]"
        case .unsupportedOS:
            return "VoiceTypingBenchmark requires macOS 26 or newer."
        }
    }
}
