@testable import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
@testable import ripple
import Testing

struct TextWidthTests {
    @Test func asciiIsOnePerCharacter() {
        #expect(TextWidth.of("hello") == 5)
        #expect(TextWidth.of("") == 0)
    }

    @Test func wideCjkCountsAsTwo() {
        #expect(TextWidth.of("你好") == 4) // two wide ideographs
        #expect(TextWidth.of("a你b") == 4) // 1 + 2 + 1
    }

    @Test func emojiCountsAsTwo() {
        #expect(TextWidth.of("🎉") == 2)
    }

    @Test func ansiEscapesHaveNoWidth() {
        #expect(TextWidth.of("\u{1B}[38;5;1mhi\u{1B}[0m") == 2)
        #expect(TextWidth.of("\u{1B}[1;38;2;10;20;30mok\u{1B}[0m") == 2)
    }
}
