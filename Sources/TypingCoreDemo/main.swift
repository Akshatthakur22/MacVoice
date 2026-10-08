import Foundation
import Darwin
#if canImport(TypingCore)
import TypingCore
#else
import CoreGraphics

private final class TypingEngine {
    private let interCharacterDelay: TimeInterval

    init(interCharacterDelay: TimeInterval) {
        self.interCharacterDelay = interCharacterDelay
    }

    func type(_ text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [interCharacterDelay] in
            for character in text {
                let eventSource = CGEventSource(stateID: .hidSystemState)
                guard let keyDown = CGEvent(keyboardEventSource: eventSource,
                                            virtualKey: 0,
                                            keyDown: true),
                      let keyUp = CGEvent(keyboardEventSource: eventSource,
                                          virtualKey: 0,
                                          keyDown: false) else {
                    completion(.failure(TypingEngineError.eventCreationFailed))
                    return
                }

                let units = Array(String(character).utf16)
                units.withUnsafeBufferPointer { buffer in
                    CGEventKeyboardSetUnicodeString(keyDown,
                                                    UInt32(buffer.count),
                                                    buffer.baseAddress)
                    CGEventKeyboardSetUnicodeString(keyUp,
                                                    UInt32(buffer.count),
                                                    buffer.baseAddress)
                }
                keyDown.post(tap: .cghidEventTap)
                keyUp.post(tap: .cghidEventTap)
                if interCharacterDelay > 0 {
                    Thread.sleep(forTimeInterval: interCharacterDelay)
                }
            }
            completion(.success(()))
        }
    }
}

private enum TypingEngineError: LocalizedError {
    case eventCreationFailed

    var errorDescription: String? {
        "Unable to create a keyboard event"
    }
}
#endif

// Usage: swift run TypingCoreDemo [basic|unicode|long|newline] [--newline=newline|enter|omit]
// Focus a plain text field before the countdown finishes.
let samples: [String: String] = [
    "basic": "Hello, world!\nHow are you?\n1234567890\n@#$%^&*()_+-={}[]",
    "unicode": "á é ñ ₹ € © — … \" ' () [] {} 😀 नमस्ते हिन्दी",
    "long": String(repeating: "A longer paragraph tests sustained event delivery. ", count: 100),
    "newline": "hello\nworld"
]
let arguments = Array(CommandLine.arguments.dropFirst())
let name = arguments.first(where: { !$0.hasPrefix("--") }) ?? "basic"
let text = samples[name] ?? samples["basic"]!
let newlineArgument = arguments.first(where: { $0.hasPrefix("--newline=") })?
    .components(separatedBy: "=").last ?? "newline"
let newlineBehavior: NewlineBehavior
switch newlineArgument {
case "enter": newlineBehavior = .enter
case "omit": newlineBehavior = .omit
default: newlineBehavior = .newline
}

print("Focus a plain text field. Typing begins in 5 seconds; sample: \(name)")
for seconds in stride(from: 5, through: 1, by: -1) {
    print("\(seconds)…")
    Thread.sleep(forTimeInterval: 1)
}

let start = ProcessInfo.processInfo.systemUptime
var usageBefore = rusage()
getrusage(RUSAGE_SELF, &usageBefore)
var taskInfo = mach_task_basic_info()
var taskInfoCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
let taskInfoStatus = withUnsafeMutablePointer(to: &taskInfo) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(taskInfoCount)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &taskInfoCount)
    }
}
let rssBefore = taskInfoStatus == KERN_SUCCESS ? taskInfo.resident_size : 0
let engine = TypingEngine(interCharacterDelay: 0.005, newlineBehavior: newlineBehavior)
engine.type(text) { result in
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    var usageAfter = rusage()
    getrusage(RUSAGE_SELF, &usageAfter)
    let cpuBefore = Double(usageBefore.ru_utime.tv_sec) + Double(usageBefore.ru_utime.tv_usec) / 1_000_000
        + Double(usageBefore.ru_stime.tv_sec) + Double(usageBefore.ru_stime.tv_usec) / 1_000_000
    let cpuAfter = Double(usageAfter.ru_utime.tv_sec) + Double(usageAfter.ru_utime.tv_usec) / 1_000_000
        + Double(usageAfter.ru_stime.tv_sec) + Double(usageAfter.ru_stime.tv_usec) / 1_000_000
    var finalTaskInfo = mach_task_basic_info()
    var finalCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let finalStatus = withUnsafeMutablePointer(to: &finalTaskInfo) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(finalCount)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &finalCount)
        }
    }
    switch result {
    case .success:
        let count = text.count
        print(String(format: "Posted %d graphemes in %.3fs (%.1f graphemes/s)", count, elapsed, Double(count) / max(elapsed, 0.001)))
        print(String(format: "Process CPU used: %.3fs; RSS before/after: %.1f / %.1f MiB",
                     cpuAfter - cpuBefore,
                     Double(rssBefore) / 1_048_576,
                     Double(finalStatus == KERN_SUCCESS ? finalTaskInfo.resident_size : 0) / 1_048_576))
    case .failure(let error):
        fputs("Typing failed: \(error.localizedDescription)\n", stderr)
    }
    exit(result.isSuccess ? 0 : 1)
}
dispatchMain()

private extension Result where Success == Void {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
