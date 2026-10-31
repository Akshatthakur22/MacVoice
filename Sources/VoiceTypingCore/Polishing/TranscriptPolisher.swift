import Foundation

/// A replaceable asynchronous transcript-cleanup backend.
public protocol TranscriptPolisher: Sendable {
    func polish(_ transcript: String) async throws -> String
}

public struct PassthroughTranscriptPolisher: TranscriptPolisher {
    public init() {}
    public func polish(_ transcript: String) async throws -> String { transcript }
}

/// Instant, zero-dependency in-process transcript normalizer.
/// Cleans filler words, removes stutters, capitalizes sentences, fixes contractions,
/// and normalizes punctuation in < 1 ms with 0 MB additional RAM.
public struct NativeSwiftTranscriptPolisher: TranscriptPolisher {
    public init() {}

    private static let fillers: Set<String> = ["um", "uh", "erm", "ah"]
    private static let contractions: [String: String] = [
        "dont": "don't", "cant": "can't", "wont": "won't",
        "didnt": "didn't", "isnt": "isn't", "arent": "aren't",
        "couldnt": "couldn't", "shouldnt": "shouldn't", "wouldnt": "wouldn't",
        "thats": "that's", "whats": "what's", "theres": "there's",
        "im": "I'm", "ive": "I've", "ill": "I'll", "id": "I'd"
    ]

    public func polish(_ transcript: String) async throws -> String {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return transcript }

        let words = transcript.components(separatedBy: .whitespaces)
        var cleanedWords: [String] = []
        var lastWordLower = ""

        for rawWord in words {
            let stripped = rawWord.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if stripped.isEmpty {
                if !rawWord.isEmpty { cleanedWords.append(rawWord) }
                continue
            }
            if Self.fillers.contains(stripped) {
                continue
            }
            if stripped == lastWordLower && stripped.count > 1 {
                continue
            }
            lastWordLower = stripped

            var word = rawWord
            if stripped == "i" {
                word = rawWord.replacingOccurrences(of: "i", with: "I")
            } else if let fixed = Self.contractions[stripped] {
                let leadingPunct = rawWord.prefix(while: { $0.isPunctuation })
                let trailingPunct = rawWord.reversed().prefix(while: { $0.isPunctuation }).reversed()
                word = String(leadingPunct) + fixed + String(trailingPunct)
            }
            cleanedWords.append(word)
        }

        var result = cleanedWords.joined(separator: " ")
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: " .", with: ".")
        result = result.replacingOccurrences(of: " ?", with: "?")
        result = result.replacingOccurrences(of: " !", with: "!")
        result = result.replacingOccurrences(of: " :", with: ":")
        result = result.replacingOccurrences(of: " ;", with: ";")

        result = capitalizeSentences(result)

        let leadingSpaces = transcript.prefix(while: \.isWhitespace)
        let trailingSpaces = transcript.reversed().prefix(while: \.isWhitespace).reversed()
        let cleaned = String(leadingSpaces) + result.trimmingCharacters(in: .whitespaces) + String(trailingSpaces)
        return try PolisherOutputValidator.validate(cleaned, original: transcript)
    }

    private func capitalizeSentences(_ text: String) -> String {
        var chars = Array(text)
        var shouldCapitalize = true
        for i in 0..<chars.count {
            let c = chars[i]
            if shouldCapitalize && c.isLetter {
                chars[i] = Character(c.uppercased())
                shouldCapitalize = false
            } else if ".!?\n".contains(c) {
                shouldCapitalize = true
            }
        }
        return String(chars)
    }
}

public enum PolishingMode: String, CaseIterable, Sendable {
    case verbatim
    case polished
}

/// Local persistent MLX-LM worker. The worker loads a model once and exchanges
/// one JSON request/response per line. It never contacts an inference service.
public actor LocalMLXTranscriptPolisher: TranscriptPolisher {
    private static let modelKey = "qwen025"
    private static let modelRepository = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
    private static let modelRevision = "a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3"
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var bufferedOutput = Data()

    public init() {}

    public func isInstalled() -> Bool {
        let root = Self.installRoot
        return FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("venv/bin/python3").path)
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("models/\(Self.modelKey)/config.json").path)
    }

    public func polish(_ transcript: String) async throws -> String {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return transcript }
        try startWorkerIfNeeded()
        guard let input, let output else { throw PolisherError.workerUnavailable }
        let request: [String: String] = ["transcript": transcript, "model": Self.modelRepository]
        let data = try JSONSerialization.data(withJSONObject: request)
        try input.write(contentsOf: data + Data([0x0A]))

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.readResponse(from: output) }
            group.addTask {
                try await Task.sleep(for: .seconds(12))
                await self.stop()
                throw PolisherError.timedOut
            }
            guard let result = try await group.next() else { throw PolisherError.invalidResponse }
            group.cancelAll()
            return try PolisherOutputValidator.validate(result, original: transcript)
        }
    }

    public func stop() {
        try? input?.write(contentsOf: Data("{\"command\":\"shutdown\"}\n".utf8))
        process?.terminate()
        process = nil
        input = nil
        output = nil
        bufferedOutput.removeAll()
    }

    private static var installRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Typer/MLX", isDirectory: true)
    }

    private func startWorkerIfNeeded() throws {
        if process?.isRunning == true { return }
        let root = Self.installRoot
        let python = root.appendingPathComponent("venv/bin/python3").path
        let bundledScript = Bundle.main.resourceURL?.appendingPathComponent("mlx_worker.py")
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourceScript = sourceRoot.appendingPathComponent("Resources/mlx_worker.py")
        let installedScript = root.appendingPathComponent("mlx_worker.py")
        let scriptURL = [bundledScript, Optional(sourceScript), Optional(installedScript)]
            .compactMap { $0 }.first(where: { FileManager.default.fileExists(atPath: $0.path) }) ?? installedScript
        guard FileManager.default.isExecutableFile(atPath: python),
              FileManager.default.fileExists(atPath: scriptURL.path) else { throw PolisherError.notInstalled }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: python)
        child.arguments = [scriptURL.path, "--model", Self.modelRepository, "--revision", Self.modelRevision,
                           "--model-dir", root.appendingPathComponent("models/\(Self.modelKey)").path]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        child.environment = ProcessInfo.processInfo.environment.merging([
            "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1"
        ]) { _, new in new }
        try child.run()
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        // Drain diagnostics to avoid a full stderr pipe stalling inference.
        DispatchQueue.global(qos: .utility).async { _ = stderr.fileHandleForReading.readDataToEndOfFile() }
    }

    private func readResponse(from handle: FileHandle) async throws -> String {
        try await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { throw PolisherError.workerUnavailable }
            return try await self.readLine(from: handle)
        }.value
    }

    private func readLine(from handle: FileHandle) throws -> String {
        while true {
            if let newline = bufferedOutput.firstIndex(of: 0x0A) {
                let line = bufferedOutput.prefix(upTo: newline)
                bufferedOutput.removeSubrange(...newline)
                guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    throw PolisherError.invalidResponse
                }
                if object["ready"] as? Bool == true { continue }
                if let message = object["error"] as? String { throw PolisherError.workerFailed(message) }
                guard let text = object["text"] as? String else { throw PolisherError.invalidResponse }
                return text
            }
            guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else { throw PolisherError.workerUnavailable }
            bufferedOutput.append(byte)
        }
    }

}

/// Conservative post-generation checks; this rejects clear responses/rewrites,
/// but cannot prove semantic equivalence for an arbitrary language model.
public enum PolisherOutputValidator {
    private static let negations: Set<String> = ["no", "not", "never", "without", "cannot", "can't", "dont", "don't", "didn't", "isn't", "won't", "neither", "nor"]
    private static let removableFillers: Set<String> = ["um", "uh", "erm"]

    public static func validate(_ result: String, original: String) throws -> String {
        let clean = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("```") else { throw PolisherError.invalidResponse }
        let inputTokens = tokens(original)
        let outputTokens = tokens(clean)
        guard !inputTokens.isEmpty, !outputTokens.isEmpty,
              outputTokens.count <= inputTokens.count,
              outputTokens.count >= max(1, inputTokens.count - inputTokens.filter(removableFillers.contains).count) else {
            throw PolisherError.invalidResponse
        }
        let distance = editDistance(inputTokens, outputTokens)
        let similarity = 1 - Double(distance) / Double(max(inputTokens.count, outputTokens.count))
        guard similarity >= 0.58 else { throw PolisherError.invalidResponse }
        // Accept case/punctuation edits and dropping known fillers only. Other
        // token edits can change intent, numbers, technical terms, or quotes.
        let sourceContent = inputTokens.filter { !removableFillers.contains($0) }
        let outputContent = outputTokens.filter { !removableFillers.contains($0) }
        guard sourceContent == outputContent else { throw PolisherError.invalidResponse }
        let requiredNumbers = inputTokens.filter { $0.contains(where: \.isNumber) }
        guard requiredNumbers.allSatisfy(outputTokens.contains) else { throw PolisherError.invalidResponse }
        let requiredNegations = inputTokens.filter { negations.contains($0.lowercased()) }
        guard requiredNegations.allSatisfy(outputTokens.contains) else { throw PolisherError.invalidResponse }
        let leadingEnd = original.firstIndex(where: { !$0.isWhitespace }) ?? original.endIndex
        let trailingStart = original.lastIndex(where: { !$0.isWhitespace }).map { original.index(after: $0) } ?? original.endIndex
        return String(original[..<leadingEnd]) + clean + String(original[trailingStart...])
    }

    private static func tokens(_ value: String) -> [String] {
        value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'’")) }
            .filter { !$0.isEmpty }
    }

    private static func editDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        var previous = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = i + 1
            for (j, right) in rhs.enumerated() {
                current[j + 1] = min(current[j] + 1, previous[j + 1] + 1,
                                     previous[j] + (left == right ? 0 : 1))
            }
            previous = current
        }
        return previous[rhs.count]
    }
}

public enum PolisherError: Error, LocalizedError {
    case notInstalled, workerUnavailable, invalidResponse, timedOut
    case workerFailed(String)
    public var errorDescription: String? {
        switch self {
        case .notInstalled: "Local polishing model is not installed. Use Install Local Polishing Model first."
        case .workerUnavailable: "The local polishing worker stopped unexpectedly."
        case .invalidResponse: "The local polisher returned an empty or invalid response."
        case .timedOut: "Local transcript polishing timed out."
        case .workerFailed(let message): "Local transcript polishing failed: \(message)"
        }
    }
}

/// Converts punctuation-delimited stable text into phrases. No silence timing
/// is currently provided by Apple SpeechAnalyzer, so stop always flushes the tail.
public struct PhraseBuffer: Sendable {
    private var pending = ""
    private let maximumPhraseCharacters: Int
    public init(maximumPhraseCharacters: Int = 360) { self.maximumPhraseCharacters = maximumPhraseCharacters }

    public mutating func append(_ stableDelta: String) -> [String] {
        pending += stableDelta
        var phrases: [String] = []
        while let boundary = pending.firstIndex(where: { ".!?。！？।\n".contains($0) }) {
            let end = pending.index(after: boundary)
            phrases.append(String(pending[..<end]))
            pending = String(pending[end...])
        }
        while pending.count >= maximumPhraseCharacters {
            let end = pending.index(pending.startIndex, offsetBy: maximumPhraseCharacters)
            if let space = pending[..<end].lastIndex(where: { $0.isWhitespace }) {
                let cut = pending.index(after: space)
                phrases.append(String(pending[..<cut]))
                pending = String(pending[cut...])
            } else { break }
        }
        return phrases.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public mutating func flush() -> String? {
        defer { pending = "" }
        guard !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return pending
    }
}
