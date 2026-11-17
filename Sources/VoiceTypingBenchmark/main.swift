import AVFAudio
import Darwin
import Foundation
import TypingCore
import VoiceTypingCore

// End-to-end dictation benchmark. Plays pre-rendered sentence audio through the
// app's real VoiceTypingSession (recognizer → assembler → reconciler → phrase
// buffer → polisher) in real time, with a fake microphone and a fake keyboard
// that timestamps every append. No keystrokes are posted and nothing is
// downloaded; Apple speech assets must already be installed.
//
// Usage:
//   VoiceTypingBenchmark --audio-dir=DIR --sentences=FILE [--mode=polished|verbatim]
//       [--engine=speech|speechFast|dictation] [--locale=en-US] [--words=FILE]
//       [--gap=0.8] [--speed=1] [--label=NAME]
//
// Prints one machine-readable "RESULT" line plus a human summary.

@main
enum VoiceTypingBenchmark {
    static func main() async {
        do {
            guard #available(macOS 26.0, *) else { throw BenchmarkError.unsupportedOS }
            try await run()
        } catch {
            fputs("Benchmark failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @available(macOS 26.0, *)
    private static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let audioDir = option("--audio-dir", args), let sentencesPath = option("--sentences", args) else {
            throw BenchmarkError.usage
        }
        let mode = PolishingMode(rawValue: option("--mode", args) ?? "polished") ?? .polished
        let engine = AppleSpeechAnalyzerRecognizer.Engine(rawValue: option("--engine", args) ?? "speech") ?? .speech
        let locale = Locale(identifier: option("--locale", args) ?? "en-US")
        let gap = Double(option("--gap", args) ?? "0.8") ?? 0.8
        let speed = max(0.25, Double(option("--speed", args) ?? "1") ?? 1)
        let label = option("--label", args) ?? URL(fileURLWithPath: audioDir).lastPathComponent
        let words = try option("--words", args).map {
            try String(contentsOfFile: $0, encoding: .utf8).split(whereSeparator: \.isNewline).map(String.init)
        } ?? []

        let sentences = try String(contentsOfFile: sentencesPath, encoding: .utf8)
            .split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        let files = try FileManager.default.contentsOfDirectory(atPath: audioDir)
            .filter { $0.hasSuffix(".wav") }.sorted()
        guard files.count == sentences.count else { throw BenchmarkError.mismatch(files.count, sentences.count) }

        // Build one stream: lead-in, then each sentence followed by a pause.
        let sampleRate = 16_000.0
        var samples = [Float](repeating: 0, count: Int(0.3 * sampleRate))
        var spans: [(start: Double, end: Double)] = []
        for file in files {
            let clip = try readMono(URL(fileURLWithPath: audioDir).appendingPathComponent(file), sampleRate: sampleRate)
            let start = Double(samples.count) / sampleRate
            samples += clip
            spans.append((start, Double(samples.count) / sampleRate))
            samples += [Float](repeating: 0, count: Int(gap * sampleRate))
        }

        let recognizer = AppleSpeechAnalyzerRecognizer(
            locale: locale, engine: engine, streamsVolatileWords: mode == .verbatim, contextualStrings: words)
        let capture = FakeMicrophone()
        let keyboard = TimestampingKeyboard()
        let session = VoiceTypingSession(
            audioCapture: capture, recognizer: recognizer, typingEngine: keyboard,
            polisher: NativeSwiftTranscriptPolisher(locale: locale), polishingMode: mode)

        let startBegan = now()
        try await session.start()
        let startDuration = now() - startBegan

        // Real-time playback on an absolute schedule (no drift).
        let streamStart = now()
        keyboard.origin = streamStart
        let chunk = 512
        var sent = 0
        while sent < samples.count {
            let count = min(chunk, samples.count - sent)
            capture.emit(PCMFrame(samples: Array(samples[sent..<(sent + count)]), sampleRate: sampleRate,
                                  channelCount: 1, frameCount: count,
                                  deliveryUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds))
            sent += count
            let due = streamStart + Double(sent) / sampleRate / speed
            let wait = due - now()
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        let stopBegan = now()
        await session.stop()
        let stopDuration = now() - stopBegan
        let state = await session.state

        // MARK: Metrics
        let appends = keyboard.appends
        let typed = appends.map(\.text).joined()
        let reference = sentences.joined(separator: " ")
        let refWords = normalizedWords(reference)
        let hypWords = normalizedWords(typed)
        let wer = Double(editDistance(refWords, hypWords)) / Double(max(refWords.count, 1))
        let formattedRef = reference.split(whereSeparator: \.isWhitespace).map(String.init)
        let formattedHyp = typed.replacingOccurrences(of: "’", with: "'").split(whereSeparator: \.isWhitespace).map(String.init)
        let formattedWER = Double(editDistance(formattedRef, formattedHyp)) / Double(max(formattedRef.count, 1))

        // When each hypothesis word became complete on screen, per typing model.
        let models: [(String, TypingModel)] = [("current", .perCharacter(0.005)), ("chunked", .perEvent(0.005, unitsPerEvent: 20))]
        var timelines: [String: [Double]] = [:]
        var recognizedTimes: [Double] = []
        for (name, model) in models {
            var free = 0.0
            var cumulative = ""
            var times: [Double] = []
            var recognized: [Double] = []
            for (index, append) in appends.enumerated() {
                let begin = max(append.time / speed * speed, free)
                free = begin + model.cost(of: append.text)
                cumulative += append.text
                let isLast = index == appends.count - 1
                var complete = normalizedWords(cumulative).count
                if !isLast, let last = cumulative.last, last.isLetter || last.isNumber { complete -= 1 }
                while times.count < complete { times.append(free); recognized.append(append.time) }
            }
            timelines[name] = times
            recognizedTimes = recognized
        }

        let alignment = align(refWords, hypWords)
        var refIndex = 0
        var endLatency: [String: [Double]] = ["recognized": [], "current": [], "chunked": []]
        var firstLatency: [String: [Double]] = ["recognized": [], "current": [], "chunked": []]
        for (sentenceIndex, sentence) in sentences.enumerated() {
            let count = normalizedWords(sentence).count
            let indices = Array(refIndex..<(refIndex + count))
            refIndex += count
            let span = spans[sentenceIndex]
            let realEnd = span.end / speed, realStart = span.start / speed
            if let firstHyp = indices.lazy.compactMap({ alignment[$0] }).first {
                firstLatency["recognized"]!.append(recognizedTimes[firstHyp] - realStart)
                for (name, _) in models { firstLatency[name]!.append(timelines[name]![firstHyp] - realStart) }
            }
            if let lastHyp = indices.reversed().lazy.compactMap({ alignment[$0] }).first {
                endLatency["recognized"]!.append(recognizedTimes[lastHyp] - realEnd)
                for (name, _) in models { endLatency[name]!.append(timelines[name]![lastHyp] - realEnd) }
            }
        }

        let exactSentences = zip(sentences, splitSentences(typed)).filter { $0 == $1 }.count
        print(String(format: "RESULT label=%@ engine=%@ mode=%@ words=%d wer=%.4f fwer=%.4f exact=%d/%d start=%.3f stop=%.3f end_rec_med=%.3f end_rec_p90=%.3f end_cur_med=%.3f end_chk_med=%.3f first_rec_med=%.3f first_cur_med=%.3f first_chk_med=%.3f state=%@",
                     label, engine.rawValue, mode.rawValue, refWords.count, wer, formattedWER, exactSentences, sentences.count,
                     startDuration, stopDuration,
                     median(endLatency["recognized"]!), percentile(endLatency["recognized"]!, 0.9),
                     median(endLatency["current"]!), median(endLatency["chunked"]!),
                     median(firstLatency["recognized"]!), median(firstLatency["current"]!), median(firstLatency["chunked"]!),
                     "\(state)"))
        print("Typed:\n\(typed)\n")
    }

    // MARK: Helpers

    private static func option(_ name: String, _ args: [String]) -> String? {
        args.first(where: { $0.hasPrefix(name + "=") }).map { String($0.dropFirst(name.count + 1)) }
    }

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

    private static func readMono(_ url: URL, sampleRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw BenchmarkError.audio
        }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(file.length) * sampleRate / file.processingFormat.sampleRate + 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw BenchmarkError.audio }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    static func normalizedWords(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    private static func splitSentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".?!".contains(character) {
                result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    private static func editDistance<T: Equatable>(_ lhs: [T], _ rhs: [T]) -> Int {
        var previous = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: rhs.count)
            for (j, right) in rhs.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (left == right ? 0 : 1))
            }
            previous = current
        }
        return previous[rhs.count]
    }

    /// Maps each reference word to the hypothesis word it aligns with (match or substitution).
    private static func align(_ ref: [String], _ hyp: [String]) -> [Int?] {
        let n = ref.count, m = hyp.count
        var cost = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        for j in 0...m { cost[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    cost[i][j] = min(cost[i - 1][j] + 1, cost[i][j - 1] + 1,
                                     cost[i - 1][j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1))
                }
            }
        }
        var mapping = [Int?](repeating: nil, count: n)
        var i = n, j = m
        while i > 0 && j > 0 {
            if cost[i][j] == cost[i - 1][j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1) {
                mapping[i - 1] = j - 1; i -= 1; j -= 1
            } else if cost[i][j] == cost[i - 1][j] + 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        return mapping
    }

    private static func median(_ values: [Double]) -> Double { percentile(values, 0.5) }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }
}

private enum TypingModel {
    case perCharacter(Double)
    case perEvent(Double, unitsPerEvent: Int)

    func cost(of text: String) -> Double {
        switch self {
        case .perCharacter(let delay):
            return Double(text.count) * delay
        case .perEvent(let delay, let units):
            // Line breaks are their own key events; other text is grouped.
            let breaks = text.filter { $0 == "\n" || $0 == "\u{2028}" }.count
            let other = text.filter { $0 != "\n" && $0 != "\u{2028}" }.utf16.count
            return Double(breaks + (other + units - 1) / units) * delay
        }
    }
}

private final class FakeMicrophone: AudioCapturing, @unchecked Sendable {
    var onFrame: ((PCMFrame) -> Void)?
    var onError: ((AudioCaptureError) -> Void)?
    func start() throws {}
    func stop() {}
    func emit(_ frame: PCMFrame) { onFrame?(frame) }
}

/// Records each append with its time relative to `origin`; posts nothing.
private final class TimestampingKeyboard: TypingOutput, @unchecked Sendable {
    struct Append { let time: Double; let text: String }
    var origin = 0.0
    private let lock = NSLock()
    private var recorded: [Append] = []
    var appends: [Append] { lock.withLock { recorded } }

    func append(_ text: String, completion: ((Result<TypingReport, TypingError>) -> Void)?) {
        let time = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 - origin
        lock.withLock { recorded.append(Append(time: time, text: text)) }
        _ = completion // success is implied; TypingReport has no public initializer
    }
    func stop() {}
    func drain() async {}
}

private enum BenchmarkError: Error, LocalizedError {
    case usage, unsupportedOS, audio
    case mismatch(Int, Int)
    var errorDescription: String? {
        switch self {
        case .usage: "Usage: VoiceTypingBenchmark --audio-dir=DIR --sentences=FILE [--mode=polished|verbatim] [--locale=en-US] [--words=FILE] [--gap=0.8] [--speed=1]"
        case .unsupportedOS: "VoiceTypingBenchmark requires macOS 26 or newer."
        case .audio: "Could not read or convert benchmark audio."
        case .mismatch(let files, let sentences): "Found \(files) WAV files for \(sentences) sentences."
        }
    }
}
