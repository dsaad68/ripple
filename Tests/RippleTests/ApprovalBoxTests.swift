@testable import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
@testable import ripple
import Testing

/// The `ripple` tool-approval prompt is a bordered box: the tool name rides the top border, then the
/// call's arguments, then three choices - Approve / Reject / Always allow this tool. Its borders only
/// line up if every rendered row is exactly the same display width, which `ChatScreen.approvalBox`
/// guarantees by padding on `TextWidth` (ANSI escapes carry no width, the ⚠ glyph is one column).
/// Pure, model-free checks of the box framing. (These run at the ambient `Theme.depth` on purpose:
/// mutating that process-global would race other suites.)
@MainActor
struct ApprovalBoxTests {
    @Test(arguments: [44, 60, 80, 120])
    func everyBoxRowIsTheSameWidth(width: Int) {
        let title = Paint.fg(179, "⚠") + " " + Paint.fg(252, "Approve ")
            + Paint.fg(215, "write_file") + Paint.fg(244, " ?")
        let rows: [(String, ClickAction?)] = [
            (Paint.fg(244, "file_path: ") + Paint.fg(252, "/tmp/notes.txt"), nil),
            ("", nil),
            (Paint.fg(114, "Approve"), .resolveApproval(true)),
            (Paint.fg(174, "Reject"), .resolveApproval(false)),
            (Paint.fg(111, "Always allow"), .alwaysAllowTool),
            ("", nil),
            (Paint.fg(240, "↑↓ choose · enter confirm · esc deny"), nil)
        ]
        let lines = ChatScreen.approvalBox(width: width, title: title, rows: rows)
        #expect(lines.count == rows.count + 2) // top border + body rows + bottom border
        for line in lines {
            let measured = TextWidth.of(line.text)
            #expect(
                measured == width + 2, // the box is `width` columns after a 2-space indent
                "width \(width): row measured \(measured), expected \(width + 2): <\(line.text)>"
            )
        }
    }

    /// The transcript/menu card frame (`approvalBox` is this with no trailing / title action): every
    /// rendered row - the top border carrying the title and a right-side `trailing`, the body rows, and
    /// the bottom border - is exactly the same display width at any size, so the box never skews.
    @Test(arguments: [44, 60, 80, 120])
    func cardFramesEveryRowToTheSameWidth(width: Int) {
        let title = Paint.fg(179, "⚙") + " " + Paint.fg(252, "write_todos")
        let rows = [
            Line(Paint.fg(244, "todos: [{content: inspect the working directory}]")),
            Line(Paint.fg(114, "✓") + " Updated todo list")
        ]
        let lines = ChatScreen.card(width: width, title: title, trailing: Paint.fg(240, "0.0s ▸"), rows: rows)
        #expect(lines.count == rows.count + 2) // top border + body rows + bottom border
        for line in lines {
            let measured = TextWidth.of(line.text)
            #expect(
                measured == width + 2,
                "width \(width): row measured \(measured), expected \(width + 2): <\(line.text)>"
            )
        }
    }

    /// The card's `trailing` (a duration / disclosure) and `title` ride the top border, and the
    /// `titleAction` lands on that border line so a click on the header toggles the card.
    @Test func cardTrailingAndTitleActionRideTheTopBorder() {
        let lines = ChatScreen.card(width: 60, title: Paint.fg(252, "plan"), trailing: Paint.fg(240, "1/3"),
                                    rows: [Line("an item")], titleAction: .togglePlan)
        #expect(lines.first?.text.contains("plan") == true)
        #expect(lines.first?.text.contains("1/3") == true)
        guard case .togglePlan? = lines.first?.action else {
            Issue.record("expected the title action on the top border line")
            return
        }
    }

    /// The choices keep their order and each carries the click action that resolves the prompt, so a
    /// mouse click lands on the right decision - Approve, Reject, or Always allow.
    @Test func choiceRowsKeepTheirOrderAndClickActions() {
        let rows: [(String, ClickAction?)] = [
            ("Approve", .resolveApproval(true)),
            ("Reject", .resolveApproval(false)),
            ("Always allow", .alwaysAllowTool)
        ]
        let lines = ChatScreen.approvalBox(width: 60, title: "Approve ls ?", rows: rows)
        // lines[0] is the top border; the three choices follow in order, then the bottom border.
        guard case .resolveApproval(true)? = lines[1].action,
              case .resolveApproval(false)? = lines[2].action,
              case .alwaysAllowTool? = lines[3].action
        else {
            Issue.record("expected Approve / Reject / Always allow rows, in order, with their click actions")
            return
        }
    }
}
