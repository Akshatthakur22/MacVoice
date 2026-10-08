import Foundation
import Darwin
import TypingCore

// Usage: swift run TypingCoreDemo [sample] [--newline=newline|enter|shift-enter|omit] [--delay=0|1|5|10]
// Focus a plain text field before the countdown finishes.
let samples: [String: String] = [
    "basic": "lowercase UPPERCASE MiXeD 0123456789 multiple  spaces",
    "punctuation": ". , ; : ! ? ' \" ` () [] {} / \\ - _ + = * & % $ # @ < > | ~ ^",
    "typography": "— – - … ‘curly’ “quotes” • ° ™ © ₹ € $ £ ¥",
    "whitespace": "  leading  multiple   spaces trailing  \tTAB\nline 2\n\nblank\rCR\r\nCRLF",
    "unicode": "á é ñ Ελληνικά Кириллица العربية עברית नमस्ते বাংলা தமிழ் తెలుగు ગુજરાતી ਪੰਜਾਬੀ 中文 日本語 한국어",
    "combining": "é e\u{301} a\u{0301}\u{0323}",
    "emoji": "😀 ☺️ 👍🏽 👩‍🎤 🇮🇳 👨‍👩‍👧‍👦 👩‍❤️‍💋‍👩 x😀y",
    "speech": "Hello, how are you?\nCan you please send me the report by tomorrow?\nHey, I'll call you at 5:30 PM.\nUse the API endpoint /users/{id}.\n₹10,000 — approximately €110.\nनमस्ते, आप कैसे हैं?",
    "newline": "hello\nworld",
    "list": "hey this is the list :\n1) apple\n2) banana\n3) orange\n\nend of list",
    "stream": "unused",
    "cancel": String(repeating: "cancel me ", count: 1000),
    "cancel-now": String(repeating: "cancel me ", count: 1000),
    "long": String(repeating: "A longer paragraph tests sustained event delivery. ", count: 100)
]
let arguments = Array(CommandLine.arguments.dropFirst())
let name = arguments.first(where: { !$0.hasPrefix("--") }) ?? "basic"
let text = samples[name] ?? samples["basic"]!
let newlineArgument = arguments.first(where: { $0.hasPrefix("--newline=") })?
    .components(separatedBy: "=").last ?? "newline"
let newlineBehavior: NewlineBehavior
switch newlineArgument {
case "enter": newlineBehavior = .enter
case "shift-enter": newlineBehavior = .shiftEnter
case "omit": newlineBehavior = .omit
default: newlineBehavior = .newline
}
let delayArgument = arguments.first(where: { $0.hasPrefix("--delay=") })?
    .components(separatedBy: "=").last.flatMap(Double.init) ?? 5

print("Focus a plain text field. Typing begins in 5 seconds; sample: \(name); newline: \(newlineArgument); delay: \(delayArgument)ms")
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
let engine = TypingEngine(interCharacterDelay: delayArgument / 1000, newlineBehavior: newlineBehavior)
let chunks = name == "stream" ? ["hello ", "how ", "are ", "you?", "na", "m", "ste", "👩‍", "🎤"] : [text]
let chunkCount = chunks.count
var completedChunks = 0
var eventPairsPosted = 0
var firstEventLatency: TimeInterval?

func handleCompletion(_ result: Result<TypingReport, TypingError>) {
    switch result {
    case .success(let report):
        completedChunks += 1
        eventPairsPosted += report.eventPairsPosted
        if firstEventLatency == nil { firstEventLatency = report.timeToFirstEvent }
        guard completedChunks == chunkCount else { return }
    case .failure(let error):
        fputs("Typing failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
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
    print(String(format: "Submitted %d event pairs in %.3fs (%.1f pairs/s); first post %.2fms",
                 eventPairsPosted, elapsed, Double(eventPairsPosted) / max(elapsed, 0.001),
                 (firstEventLatency ?? 0) * 1000))
    print(String(format: "Process CPU used: %.3fs; RSS before/after: %.1f / %.1f MiB",
                 cpuAfter - cpuBefore,
                 Double(rssBefore) / 1_048_576,
                 Double(finalStatus == KERN_SUCCESS ? finalTaskInfo.resident_size : 0) / 1_048_576))
    print("Destination insertion was not verified by CGEvent.")
    exit(0)
}

for chunk in chunks {
    engine.append(chunk, completion: handleCompletion)
}
if name == "cancel" || name == "cancel-now" {
    if name == "cancel-now" { engine.stop() }
    else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { engine.stop() } }
}
dispatchMain()
