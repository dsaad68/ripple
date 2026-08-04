import DeepAgents
import Foundation

// The human-in-the-loop approval cards for `ripple chat`: the normal bordered card, the louder
// shell-command card, and the box/argument/diff helpers that fill them. Split out of the render
// layer to keep that file within budget; the model types live in ChatScreenModel.
extension ChatScreen {
    /// The approval card shown above the input box while a gated tool call waits: a bordered box whose
    /// top border names the tool, then its arguments (a short multi-line preview for big values like
    /// file content, or a colored diff for file writes), then the three choices - Approve, Reject, and
    /// Always allow this tool for the rest of the session - with the highlighted one confirmed by
    /// Enter. The `a` / `r` / `A` keys still jump straight to a choice.
    func approvalLines(_ request: ToolApprovalRequest, width: Int) -> [Line] {
        if request.toolName == "shell" { return shellApprovalLines(request, width: width) }
        let inner = width - 4 // visible columns between "│ " and " │"
        let sel = approvalSelection
        var rows: [(String, ClickAction?)] = approvalArgRows(request, inner: inner).map { ($0, nil) }
        rows.append(("", nil)) // a spacer between the arguments and the choices
        rows.append((choice("Approve", "a", on: sel == 0, color: 114), .resolveApproval(true)))
        rows.append((choice("Reject", "r", on: sel == 1, color: 174), .resolveApproval(false)))
        rows.append((choice("Always allow", "A", on: sel == 2, color: 111), .alwaysAllowTool))
        rows.append(("", nil)) // a spacer between the choices and the hint
        rows.append((Paint.fg(240, "↑↓ choose · enter confirm · esc deny"), nil))

        // The tool name rides the top border: "╭─ ⚠ Approve <tool> ? ─...─╮".
        let title = Paint.fg(179, "⚠") + " " + Paint.fg(252, "Approve ")
            + Paint.fg(215, request.toolName) + Paint.fg(244, " ?")
        return Self.approvalBox(width: width, title: title, rows: rows)
    }

    /// The shell-command approval card - deliberately louder than the normal one: a red frame, a
    /// red banner riding the top border, the command in bold behind a red gutter, ``ShellGuard``
    /// risk markers, and only Approve / Reject (no "always allow" - turning the gate off for shell
    /// must be a deliberate Settings change). The selection defaults to Reject, set in
    /// ``ChatScreen`` when the request arrives, so a stray Enter denies.
    private func shellApprovalLines(_ request: ToolApprovalRequest, width: Int) -> [Line] {
        let inner = width - 4
        let sel = approvalSelection
        let command = shellArg(request, "command") ?? ""
        var rows: [(String, ClickAction?)] = [
            (Paint.fg(174, "Runs on your real machine and can modify or delete files."), nil),
            ("", nil)
        ]
        let commandLines = command.components(separatedBy: "\n")
        for line in commandLines.prefix(8) {
            rows.append((Paint.fg(174, "▌ ") + Paint.bold(Paint.fg(255, clip(line, inner - 2))), nil))
        }
        if commandLines.count > 8 {
            rows.append((Paint.fg(174, "▌ ") + Paint.fg(240, "… \(commandLines.count - 8) more lines"), nil))
        }
        let markers = ShellGuard.riskMarkers(command)
        if !markers.isEmpty {
            rows.append(("", nil))
            for marker in markers { rows.append((Paint.fg(179, "⚠ " + clip(marker, inner - 2)), nil)) }
        }
        if let stdin = shellArg(request, "stdin") {
            rows.append((Paint.fg(244, "stdin: ") + Paint.fg(240, "\(stdin.count) chars"), nil))
        }
        rows.append(("", nil))
        rows.append((choice("Approve", "a", on: sel == 0, color: 114), .resolveApproval(true)))
        rows.append((choice("Reject", "r", on: sel == 1, color: 174), .resolveApproval(false)))
        rows.append((choice("Edit", "e", on: sel == 2, color: 111), .editApproval))
        rows.append(("", nil))
        rows.append((Paint.fg(240, "↑↓ choose · enter confirm · esc deny"), nil))

        let title = Paint.bgFg(Theme.danger.xterm, 232, " ⚠ SHELL COMMAND - REVIEW CAREFULLY ")
        return Self.approvalBox(width: width, title: title, rows: rows, edge: Theme.danger.xterm)
    }

    /// The raw string value of a shell approval argument (`command` / `stdin`), or nil.
    private func shellArg(_ request: ToolApprovalRequest, _ key: String) -> String? {
        if case .string(let value)? = request.arguments[key] { return value }
        return nil
    }

    /// Frame a titled box exactly `width` display columns wide (after the 2-space indent): `title`
    /// rides the top border on the left, each `rows` entry becomes a "│ content … │" body row (padded
    /// to align the right border, carrying its optional click action), and the bottom border is plain.
    /// The shared transcript/menu frame is ``card(width:title:trailing:rows:edge:titleAction:)``; this
    /// is that with no trailing segment and no clickable title. Pure, so border alignment can be
    /// unit-tested at any width - the styled content's visible width (escape sequences skipped) drives
    /// the padding.
    static func approvalBox(
        width: Int, title: String, rows: [(String, ClickAction?)], edge: Int = Theme.border.xterm
    ) -> [Line] {
        card(width: width, title: title, rows: rows.map { Line($0.0, $0.1) }, edge: edge)
    }

    /// Frame a card (a transcript tool/plan card or a menu panel) exactly `width` columns wide (after
    /// the 2-space indent): `title` rides the top border on the left, an optional `trailing` (e.g. a
    /// duration + ▸/▾ disclosure) rides the right end, each `rows` entry becomes a "│ content … │" body
    /// row padded to align the right border (carrying its click action), and the bottom border is
    /// plain. `titleAction`, when set, makes the whole top border clickable so a click toggles the
    /// card's disclosure. Pure, so the framing is unit-testable at any width; callers keep `title` +
    /// `trailing` within `width` (tool names / durations are short). The default `edge` is the light
    /// border grey; a failing card passes ``Theme/danger`` for a louder frame.
    static func card(
        width: Int, title: String, trailing: String = "", rows: [Line],
        edge: Int = Theme.border.xterm, titleAction: ClickAction? = nil
    ) -> [Line] {
        let inner = width - 4 // visible columns between "│ " and " │"
        let top: String
        if trailing.isEmpty {
            let fill = max(0, width - TextWidth.of(title) - 5) // "╭─ " + title + " " + fill + "╮"
            top = "  " + Paint.fg(edge, "╭─ ") + title
                + Paint.fg(edge, " " + String(repeating: "─", count: fill) + "╮")
        } else {
            // "╭─ " + title + " " + fill + " " + trailing + " ╮"
            let fill = max(0, width - TextWidth.of(title) - TextWidth.of(trailing) - 7)
            top = "  " + Paint.fg(edge, "╭─ ") + title
                + Paint.fg(edge, " " + String(repeating: "─", count: fill) + " ") + trailing
                + Paint.fg(edge, " ╮")
        }
        var out: [Line] = [Line(top, titleAction)]
        for row in rows {
            let text = TextWidth.truncate(row.text, to: inner) // a no-op when the caller pre-fit it
            let pad = String(repeating: " ", count: max(0, inner - TextWidth.of(text)))
            out.append(Line("  " + Paint.fg(edge, "│") + " " + text + pad + " " + Paint.fg(edge, "│"), row.action))
        }
        out.append(Line("  " + Paint.fg(edge, "╰" + String(repeating: "─", count: width - 2) + "╯")))
        return out
    }

    /// One choice row inside the approval box: a ❯ marker when selected, the label tinted (bright when
    /// selected), and its single-key shortcut aligned into a column.
    private func choice(_ label: String, _ key: String, on selected: Bool, color: Int) -> String {
        let marker = selected ? Paint.arrow("❯") + " " : "  "
        let gap = String(repeating: " ", count: max(2, 14 - label.count))
        return marker + Paint.fg(selected ? color : 244, label) + Paint.fg(238, gap + "(\(key))")
    }

    /// The argument rows inside the approval box: a colored diff for file writes, else key/value rows
    /// with a short multi-line preview for big values. Each string is inner box content (no frame).
    private func approvalArgRows(_ request: ToolApprovalRequest, inner: Int) -> [String] {
        if let diff = fileDiffRows(request, inner: inner) { return diff }
        var out: [String] = []
        for arg in request.argumentRows {
            if arg.value.contains("\n") || arg.value.count > max(8, inner - 4) {
                let valueLines = arg.value.components(separatedBy: "\n")
                out.append(Paint.fg(244, arg.key)
                    + Paint.fg(240, "  (\(valueLines.count) lines, \(arg.value.count) chars)"))
                for preview in valueLines.prefix(3) { out.append("  " + Paint.fg(240, clip(preview, inner - 2))) }
                if valueLines.count > 3 { out.append("  " + Paint.fg(238, "…")) }
            } else {
                out.append(Paint.fg(244, arg.key + ": ")
                    + Paint.fg(252, clip(arg.value, max(8, inner - 2 - arg.key.count))))
            }
        }
        return out
    }

    /// For a write_file / edit_file approval, render the change as a colored diff instead of opaque
    /// argument blobs (returns nil for other tools, which fall back to plain argument rows).
    private func fileDiffRows(_ request: ToolApprovalRequest, inner: Int) -> [String]? {
        func string(_ key: String) -> String? {
            if case .string(let value)? = request.arguments[key] { return value }
            return nil
        }
        let path = string("file_path").map {
            Paint.fg(244, "file_path: ") + Paint.fg(252, clip($0, max(8, inner - 11)))
        }
        switch request.toolName {
        case "edit_file":
            guard let old = string("old_string"), let new = string("new_string") else { return nil }
            return [path].compactMap { $0 } + diffRows(old: old, new: new, inner: inner)
        case "write_file":
            guard let content = string("content") else { return nil }
            return [path].compactMap { $0 } + diffRows(old: "", new: content, inner: inner)
        default:
            return nil
        }
    }

    /// A simple replace-style diff: removed lines in red, added lines in green, each capped.
    private func diffRows(old: String, new: String, inner: Int) -> [String] {
        let cap = 4
        func block(_ text: String, sign: String, color: Int) -> [String] {
            guard !text.isEmpty else { return [] }
            let lines = text.components(separatedBy: "\n")
            var rows = lines.prefix(cap).map { Paint.fg(color, sign + " " + clip($0, inner - 2)) }
            if lines.count > cap { rows.append(Paint.fg(238, "  … \(lines.count - cap) more")) }
            return rows
        }
        return block(old, sign: "-", color: 174) + block(new, sign: "+", color: 114)
    }
}
