@testable import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import Foundation
import MLXLMCommon
@testable import ripple
import Testing

/// Word-wise cursor motion in the ``ChatScreen`` input box: Option/Alt + Left/Right (and the
/// Alt-b / Alt-f and modified-CSI byte sequences terminals send for them) jump a whole word.
@MainActor
struct ChatInputCursorTests {
    private func makeScreen() -> ChatScreen {
        let agent = RippleDeepAgent.make(
            textModel: FakeChatModel(answer: "x"),
            visionModel: FakeChatModel(answer: "y", supportsVision: true)
        )
        return ChatScreen(variant: DeepAgentVariant.all[0], agent: agent, build: { _, _ in nil }, gate: ApprovalGate())
    }

    @Test("Word left / right move across whitespace-delimited words")
    func wordMotion() {
        let screen = makeScreen()
        screen.setInput("hello world foo") // cursor at the end (15)
        screen.cursorWordLeft(); #expect(screen.cursor == 12) // start of "foo"
        screen.cursorWordLeft(); #expect(screen.cursor == 6) // start of "world"
        screen.cursorWordRight(); #expect(screen.cursor == 11) // end of "world"
        screen.cursorWordRight(); #expect(screen.cursor == 15) // end of "foo"
    }

    @Test("Modified-arrow CSI (Option/Alt + Left/Right) maps to word motion")
    func modifiedArrowCSI() {
        let screen = makeScreen()
        screen.setInput("hello world")
        screen.csi = Array("1;3D".utf8); screen.dispatchCSI() // Alt + Left
        #expect(screen.cursor == 6) // start of "world"
        screen.csi = Array("1;3C".utf8); screen.dispatchCSI() // Alt + Right
        #expect(screen.cursor == 11) // end of "world"
    }

    @Test("ESC b / ESC f (Alt-b / Alt-f) maps to word motion")
    func altLetterWordMotion() {
        let screen = makeScreen()
        screen.setInput("hello world")
        _ = screen.consumeEscapeByte(0x1B); _ = screen.consumeEscapeByte(0x62) // ESC b -> previous word
        #expect(screen.cursor == 6)
        _ = screen.consumeEscapeByte(0x1B); _ = screen.consumeEscapeByte(0x66) // ESC f -> next word
        #expect(screen.cursor == 11)
    }

    @Test("Input wraps whole words to the next line instead of splitting mid-word")
    func wordWrapKeepsWordsWhole() {
        let screen = makeScreen()
        let text = Array("write a long text about dead fox society which is fictional gathering of big")
        let layout = screen.layoutInput(text, width: 24, cursor: text.count)
        #expect(layout.rows.count > 1) // it actually wrapped
        #expect(layout.rows.joined() == String(text)) // every character is placed exactly once, in order
        // No row ends partway through a word (its last char is a letter and the next row continues it),
        // and the word from the screenshot lives wholly in one row.
        #expect(layout.rows.contains { $0.contains("gathering") })
        for index in layout.rows.indices.dropLast() {
            let endsMidWord = layout.rows[index].last.map { $0 != " " } ?? false
            let nextStartsMidWord = layout.rows[index + 1].first.map { $0 != " " } ?? false
            #expect(!(endsMidWord && nextStartsMidWord), "row \(index) splits a word")
        }
    }

    /// The visual row the caret currently sits on, laid out at the live input width.
    private func caretRow(_ screen: ChatScreen) -> Int {
        screen.layoutInput(screen.input, width: screen.inputTextWidth, cursor: screen.cursor).line
    }

    @Test("Up / Down move the caret between the lines of a multi-line input")
    func verticalLineMotion() {
        let screen = makeScreen()
        screen.cols = 80 // inputTextWidth 70: wide enough that only the hard newlines wrap
        screen.history = ["recalled"]
        screen.setInput("alpha\nbeta\ngamma") // cursor at the end, on the last line ("gamma")
        #expect(caretRow(screen) == 2)
        screen.onUp(); #expect(caretRow(screen) == 1) // -> "beta"
        screen.onUp(); #expect(caretRow(screen) == 0) // -> "alpha"
        // On the first line, another Up recalls the previous prompt instead of moving the caret.
        screen.onUp(); #expect(screen.inputText == "recalled")
        // Down off the single-line recalled entry restores the saved multi-line draft.
        screen.onDown(); #expect(screen.inputText == "alpha\nbeta\ngamma")
    }

    @Test("Down moves the caret down through the visual lines from the top")
    func downLineMotion() {
        let screen = makeScreen()
        screen.cols = 80
        screen.setInput("alpha\nbeta\ngamma")
        screen.cursor = 0 // start on the first line
        #expect(caretRow(screen) == 0)
        screen.onDown(); #expect(caretRow(screen) == 1)
        screen.onDown(); #expect(caretRow(screen) == 2)
    }

    @Test("Up / Down move between the soft-wrapped rows of one long logical line")
    func verticalMotionAcrossWrap() {
        let screen = makeScreen()
        screen.cols = 24 // inputTextWidth 14, so the line wraps across several rows
        screen.setInput("aaaa bbbb cccc dddd eeee")
        let last = caretRow(screen)
        #expect(last >= 1) // it actually wrapped
        screen.onUp(); #expect(caretRow(screen) == last - 1) // up a wrapped row, no newline involved
    }

    @Test("A word longer than the line still hard-breaks, and the caret maps onto it")
    func longWordHardBreaksWithExactCaret() {
        let screen = makeScreen()
        let text = Array("supercalifragilisticexpialidocious") // 34 chars, no spaces
        let width = 10
        let layout = screen.layoutInput(text, width: width, cursor: 12) // caret inside the word
        #expect(layout.rows.count == 4) // 34 / 10 -> 4 rows
        #expect(layout.rows.joined() == String(text))
        #expect(layout.line == 12 / width) // row 1
        #expect(layout.col == 12 % width) // col 2
    }
}
