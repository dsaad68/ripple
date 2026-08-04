@testable import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
@testable import ripple
import Testing

struct ChatMarkdownTests {
    @Test func inlineStylesAreAppliedAndMarkersConsumed() {
        Theme.depth = .ansi256 // assertions below check 256-color codes
        let out = ChatMarkdown.render("The **fast** path uses the `cache` and is *cheap*.", width: 80)
            .joined(separator: "\n")
        #expect(out.contains("38;5;215")) // inline `code` foreground
        #expect(out.contains("\u{1B}[1;")) // a bold run
        #expect(out.contains("\u{1B}[3;")) // an italic run
        #expect(!out.contains("**")) // bold markers consumed
        #expect(!out.contains("`")) // code markers consumed
    }

    @Test func headerAndListRender() {
        Theme.depth = .ansi256 // assertions below check 256-color codes
        let out = ChatMarkdown.render("## Plan\n- first\n- second", width: 40)
        #expect(out.count == 3)
        #expect(out[0].contains("Plan"))
        #expect(out[1].contains("•")) // bullet glyph
        #expect(!out[1].contains("- ")) // raw list marker replaced
    }

    @Test func fencedCodeBlockKeepsContentLiteral() {
        Theme.depth = .ansi256 // assertions below check 256-color codes
        let out = ChatMarkdown.render("```\nlet x = `y`\n```", width: 40).joined(separator: "\n")
        #expect(out.contains("let x = `y`")) // backticks inside a fence stay literal
        #expect(out.contains("38;5;109")) // code-block color
    }

    @Test func wrapsLongParagraphsToWidth() {
        Theme.depth = .ansi256 // assertions below check 256-color codes
        let out = ChatMarkdown.render(String(repeating: "word ", count: 30), width: 24)
        #expect(out.count > 1) // wrapped across lines
    }

    @Test func linkRendersTextUnderlinedWithTrailingURL() {
        Theme.depth = .ansi256 // assertions below check 256-color codes
        let out = ChatMarkdown.render("See [Swift](https://swift.org) docs.", width: 80)
            .joined(separator: "\n")
        #expect(out.contains("Swift"))
        #expect(out.contains("38;5;75")) // link foreground
        #expect(out.contains("\u{1B}[4;")) // underline
        #expect(out.contains("swift.org")) // url kept (dimmed)
        #expect(!out.contains("](")) // link markers consumed
    }

    @Test func nestedListUsesIndentAndADistinctBullet() {
        Theme.depth = .ansi256 // assertions below check 256-color codes
        let out = ChatMarkdown.render("- top\n  - nested", width: 40)
        #expect(out.count == 2)
        #expect(out[0].contains("•")) // level 0 bullet
        #expect(out[1].contains("◦")) // level 1 bullet
        #expect(out[1].hasPrefix("  ")) // indented under its parent
    }

    @Test func pipeTableAlignsIntoColumns() {
        Theme.depth = .ansi256 // assertions below check 256-color codes
        let table = "| Name | Age |\n|------|-----|\n| Ann | 30 |\n| Bob | 7 |"
        let out = ChatMarkdown.render(table, width: 40)
        #expect(out.count == 4) // header + rule + 2 body rows
        #expect(out[0].contains("Name") && out[0].contains("Age"))
        #expect(out[1].contains("┼")) // column rule joiner
        #expect(out[3].contains("Bob") && out[3].contains("7"))
        #expect(!out.joined().contains("|---")) // raw separator consumed
    }
}
