import XCTest
@testable import TypingCore

final class TextEncoderTests: XCTestCase {
    private func actions(_ text: String, _ behavior: NewlineBehavior = .newline) -> [InputAction] {
        var output: [InputAction] = []
        TextEncoder.forEachAction(in: text, newlineBehavior: behavior) { output.append($0) }
        return output
    }

    private func unicodeText(_ actions: [InputAction]) -> String {
        actions.compactMap { action in
            if case .unicode(let text) = action { return text }
            return nil
        }.joined()
    }

    private func scalars(_ text: String) -> [UInt32] {
        text.unicodeScalars.map(\.value)
    }

    func testBasicAndPunctuationMatrixPreservesScalarSequence() {
        let matrix = [
            "lowercase UPPERCASE MiXeD 0123456789 words  with  multiple   spaces",
            ".,;:!? '\" ` () [] {} / \\ - _ + = * & % $ # @ < > | ~ ^",
            "— – - … ‘curly’ “quotes” apostrophe’s • ° ™ © ₹ € $ £ ¥",
            "  leading and trailing  "
        ].joined(separator: "\n")
        let emitted = unicodeText(actions(matrix))
        let expected = matrix.replacingOccurrences(of: "\n", with: "\n")
        XCTAssertEqual(scalars(emitted), scalars(expected))
    }

    func testUnicodeScriptsCombiningSequencesAndEmojiPreserveScalars() {
        let matrix = "á e\u{301} a\u{0301}\u{0323} Ελληνικά Кириллица العربية עברית नमस्ते বাংলা தமிழ் తెలుగు ગુજરાતી ਪੰਜਾਬੀ 中文 日本語 한국어 " +
            "😀 ☺️ 👍🏽 👩‍🎤 🇮🇳 👨‍👩‍👧‍👦 👩‍❤️‍💋‍👩 x😀y"
        XCTAssertEqual(scalars(unicodeText(actions(matrix))), scalars(matrix))
    }

    func testLineEndingPoliciesAndWhitespace() {
        XCTAssertEqual(actions("a\nb\n\nc"), [.unicode("a"), .unicode("\n"), .unicode("b"), .unicode("\n"), .unicode("\n"), .unicode("c")])
        XCTAssertEqual(actions("a\rb\r\nc"), [.unicode("a"), .unicode("\n"), .unicode("b"), .unicode("\n"), .unicode("c")])
        XCTAssertEqual(actions("a\nb", .enter), [.unicode("a"), .keyCode(36), .unicode("b")])
        XCTAssertEqual(actions("a\nb", .omit), [.unicode("a"), .unicode("b")])
        XCTAssertEqual(actions(" \t  "), [.unicode(" "), .keyCode(48), .unicode(" "), .unicode(" ")])
    }

    func testEmptyTextAndAppendChunks() {
        XCTAssertTrue(actions("").isEmpty)
        let chunks = ["hello ", "how ", "are ", "you?", "na", "m", "ste", "👩‍", "🎤"]
        let emitted = chunks.flatMap { actions($0) }
        XCTAssertEqual(scalars(unicodeText(emitted)), scalars(chunks.joined()))
    }
}
