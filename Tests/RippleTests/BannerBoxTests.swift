@testable import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
@testable import ripple
import Testing

/// The `ripple chat` launch banner is a bordered two-pane box. Its borders only line up if every
/// rendered row is exactly the same display width - which holds at any color depth, since ANSI
/// escapes carry no width and the box math pads by `TextWidth`. Long model ids / cwds must be
/// clipped, not overflow a pane. Pure, model-free checks of `ChatScreen.bannerBox`. (These run at
/// the ambient `Theme.depth` on purpose: mutating that process-global would race other suites.)
@MainActor
struct BannerBoxTests {
    @Test(arguments: [58, 60, 76, 100, 110])
    func everyBoxRowIsTheSameWidth(width: Int) {
        let lines = ChatScreen.bannerBox(
            width: width, planner: "8B-A1B", vision: "VL 1.6B",
            cwd: "~/GitHub/mispher/some/deeply/nested/working/directory/that/is/too/long",
            introFrame: 3
        )
        let rows = lines.filter { !$0.text.isEmpty } // drop the leading/trailing spacer lines
        #expect(rows.count >= 8) // top + 6 content rows + bottom, at least
        for row in rows {
            let measured = TextWidth.of(row.text)
            #expect(
                measured == width + 2, // the box is `width` columns after a 2-space indent
                "width \(width): row measured \(measured), expected \(width + 2): <\(row.text)>"
            )
        }
    }

    @Test func listsTheFirstThreeMcpServersThenAnEllipsis() {
        let width = 100
        let lines = ChatScreen.bannerBox(
            width: width, planner: "8B-A1B", vision: "VL 1.6B", cwd: "~/x",
            mcp: ["filesystem", "github", "slack", "notion"], introFrame: 0
        )
        let text = lines.map(\.text).joined(separator: "\n")
        #expect(text.contains("models")) // the section header above the model rows
        #expect(text.contains("available mcps: "))
        #expect(text.contains("filesystem"))
        #expect(text.contains("github"))
        #expect(text.contains("slack"))
        #expect(!text.contains("notion")) // only the first three are listed, then `…`
        #expect(text.contains("…"))
        for row in lines.filter({ !$0.text.isEmpty }) { // the extra row keeps the box aligned
            #expect(TextWidth.of(row.text) == width + 2)
        }
    }

    @Test func listsLoadedInstructionFilesAndKeepsTheBoxAligned() {
        let width = 100
        let lines = ChatScreen.bannerBox(
            width: width, planner: "8B-A1B", vision: "VL 1.6B", cwd: "~/x",
            instructions: ["AGENTS.md", "CLAUDE.md", "src/RIPPLE.md", "extra/AGENTS.md"], introFrame: 0
        )
        let text = lines.map(\.text).joined(separator: "\n")
        #expect(text.contains("instructions: "))
        #expect(text.contains("AGENTS.md"))
        #expect(text.contains("CLAUDE.md"))
        #expect(text.contains("src/RIPPLE.md"))
        #expect(!text.contains("extra/AGENTS.md")) // only the first three are listed, then `…`
        #expect(text.contains("…"))
        for row in lines.filter({ !$0.text.isEmpty }) { // the extra row keeps the box aligned
            #expect(TextWidth.of(row.text) == width + 2)
        }
    }

    @Test func showsAYellowNudgeForServersNeedingAuth() {
        let width = 100
        let lines = ChatScreen.bannerBox(
            width: width, planner: "8B-A1B", vision: "VL 1.6B", cwd: "~/x",
            mcp: ["parallel-task-mcp", "deepwiki"], needsAuth: ["parallel-task-mcp"], introFrame: 0
        )
        let text = lines.map(\.text).joined(separator: "\n")
        #expect(text.contains("available mcps: "))
        #expect(text.contains("needs sign-in")) // the yellow nudge under the list
        for row in lines.filter({ !$0.text.isEmpty }) { // the extra row keeps the box aligned
            #expect(TextWidth.of(row.text) == width + 2)
        }
    }

    @Test func wordmarkKeepsItsWidthWhileAnimating() {
        for frame in 0 ... 18 {
            #expect(TextWidth.of(ChatScreen.rippleWordmark("ripple", frame: frame)) == 6)
        }
    }

    /// The ASCII-art wordmark is three rows that must stay column-aligned (so the vertical gradient and
    /// the box borders line up): each row is exactly 18 display columns at every animation frame, with
    /// escapes carrying no width.
    @Test func asciiArtWordmarkRowsShareWidthWhileAnimating() {
        for frame in 0 ... 18 {
            let rows = ChatScreen.rippleArt(frame: frame)
            #expect(rows.count == 3)
            for row in rows {
                #expect(TextWidth.of(row) == 18, "frame \(frame): row measured \(TextWidth.of(row)): <\(row)>")
            }
        }
    }
}
