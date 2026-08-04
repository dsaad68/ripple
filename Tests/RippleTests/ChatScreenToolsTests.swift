@testable import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import MLXLMCommon
@testable import ripple
import Testing

/// The `/tools` browser: toolset-name mapping, parameter-type labels, text wrapping, and the
/// two-level navigation model. (The live `makeToolsBrowser` needs a real agent, so it is exercised
/// by hand in `ripple chat`.)
struct ChatScreenToolsTests {
    @Test func toolsetTitleMapsKnownNamesAndTitleCasesTheRest() {
        #expect(ChatScreen.toolsetTitle("apple_notes") == "Apple Notes")
        #expect(ChatScreen.toolsetTitle("clipboard") == "Clipboard")
        #expect(ChatScreen.toolsetTitle("todo_list") == "Planning")
        #expect(ChatScreen.toolsetTitle("screenshot") == "Screen Capture")
        #expect(ChatScreen.toolsetTitle("some_new_thing") == "Some New Thing") // fallback
    }

    @Test func typeLabelNamesEachParameterType() {
        #expect(ChatScreen.typeLabel(.string) == "string")
        #expect(ChatScreen.typeLabel(.int) == "int")
        #expect(ChatScreen.typeLabel(.double) == "number")
        #expect(ChatScreen.typeLabel(.bool) == "bool")
        #expect(ChatScreen.typeLabel(.array(elementType: .string)) == "array")
        #expect(ChatScreen.typeLabel(.object(properties: [])) == "object")
    }

    @Test func wrapPlainWrapsOnWordsAndHardSplitsLongWords() {
        let wrapped = ChatScreen.wrapPlain("the quick brown fox", width: 9)
        #expect(wrapped == ["the quick", "brown fox"])
        #expect(wrapped.allSatisfy { $0.count <= 9 })

        // A single token longer than the line is hard-split rather than overflowing.
        let split = ChatScreen.wrapPlain("supercalifragilistic", width: 6)
        #expect(split.allSatisfy { $0.count <= 6 })
        #expect(split.joined() == "supercalifragilistic")

        #expect(ChatScreen.wrapPlain("", width: 10).isEmpty) // empty text -> no lines
    }

    @Test func browserMoveWrapsAroundAndCurrentTracksTheOpenGroup() {
        let groups = [
            ToolsBrowser.Group(title: "Apple Notes", tools: []),
            ToolsBrowser.Group(title: "Clipboard", tools: [])
        ]
        var browser = ToolsBrowser(groups: groups)
        #expect(browser.groupIndex == 0)
        #expect(browser.current == nil) // nothing opened yet -> level 1 (the list)

        browser.move(-1) // wraps to the last group
        #expect(browser.groupIndex == 1)
        browser.move(1) // wraps back to the first
        #expect(browser.groupIndex == 0)

        browser.openGroup = 1
        #expect(browser.current?.title == "Clipboard")

        browser.openGroup = 99 // out of range is ignored rather than crashing
        #expect(browser.current == nil)
    }

    @Test func styledParamLabelBrightensTheNameOverItsType() {
        #expect(ChatScreen.styledParamLabel("path (optional, string)")
            == Paint.fg(252, "path ") + Paint.fg(240, "(optional, string)"))
        #expect(ChatScreen.styledParamLabel("bare") == Paint.fg(252, "bare")) // no parenthetical -> one run
    }

    @Test func toolsSlashCommandIsRegistered() async {
        await #expect(MainActor.run { ChatScreen.commands.contains { $0.name == "/tools" } })
    }

    @Test func freshSlashCommandIsRegistered() async {
        await #expect(MainActor.run { ChatScreen.commands.contains { $0.name == "/fresh" } })
    }
}
