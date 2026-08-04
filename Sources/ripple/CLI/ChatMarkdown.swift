import DeepAgents
import Foundation

/// A small Markdown -> ANSI renderer for the chat answer: inline `**bold**`, `*italic*`, `` `code` ``,
/// `~~strike~~`, and `[links](url)`; ATX headers, nested bullet/numbered lists, blockquotes, fenced
/// code blocks, pipe tables, and rules. Width-aware (word-wraps to `width`). Stream-safe: an
/// unterminated marker just renders the rest of the text in that style until it closes on a later frame.
enum ChatMarkdown {
    private struct Cell { let char: Character; let style: UInt8 }
    private static let bold: UInt8 = 1
    private static let italic: UInt8 = 2
    private static let code: UInt8 = 4
    private static let strike: UInt8 = 8
    private static let link: UInt8 = 16
    private static let dim: UInt8 = 32

    static func render(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var inFence = false
        let raws = text.components(separatedBy: "\n")
        var index = 0
        while index < raws.count {
            let raw = raws[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") { inFence.toggle(); index += 1; continue }
            if inFence { lines += codeBlock(raw, width: width); index += 1; continue }
            if isTableStart(raws, index) {
                let (rows, consumed) = tableLines(raws, from: index, width: width)
                lines += rows
                index += consumed
                continue
            }
            lines += blockLines(raw, trimmed, width: width)
            index += 1
        }
        return lines
    }

    // MARK: - Blocks

    /// Lines for a single ordinary (non-fence, non-table) source line.
    private static func blockLines(_ raw: String, _ trimmed: String, width: Int) -> [String] {
        if trimmed.isEmpty { return [""] }
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            return [fg(Theme.border, String(repeating: "─", count: width))]
        }
        if let level = headerLevel(trimmed) {
            let title = String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            return wrapCells(parse(title), width: width).map { emit($0, header: level > 0) }
        }
        if let (marker, body) = listPrefix(trimmed) {
            let indent = String(repeating: " ", count: min(8, raw.prefix { $0 == " " }.count))
            let glyph = marker == "• " ? bulletGlyph(for: indent.count) + " " : marker
            return paragraph(body, marker: indent + fg(Theme.muted, glyph),
                             markerWidth: indent.count + glyph.count, width: width)
        }
        if trimmed.hasPrefix("> ") {
            return paragraph(String(trimmed.dropFirst(2)), marker: fg(Theme.faint, "│ "),
                             markerWidth: 2, everyLine: true, width: width)
        }
        return paragraph(trimmed, marker: "", markerWidth: 0, width: width)
    }

    /// Nested-list bullets cycle by depth so levels read distinctly.
    private static func bulletGlyph(for indent: Int) -> String {
        switch indent / 2 {
        case 0: "•"
        case 1: "◦"
        default: "▪"
        }
    }

    private static func paragraph(_ body: String, marker: String, markerWidth: Int,
                                  everyLine: Bool = false, width: Int) -> [String] {
        let wrapped = wrapCells(parse(body), width: max(4, width - markerWidth))
        return wrapped.enumerated().map { index, cells in
            let lead = (index == 0 || everyLine) ? marker : String(repeating: " ", count: markerWidth)
            return lead + emit(cells, header: false)
        }
    }

    private static func codeBlock(_ raw: String, width: Int) -> [String] {
        let chunkWidth = max(4, width - 2)
        var remainder = Substring(raw)
        var out: [String] = []
        repeat {
            out.append(fg(Theme.faint, "│ ") + fg(Theme.codeBlock, String(remainder.prefix(chunkWidth))))
            remainder = remainder.dropFirst(chunkWidth)
        } while !remainder.isEmpty
        return out.isEmpty ? [fg(Theme.faint, "│ ")] : out
    }

    private static func headerLevel(_ s: String) -> Int? {
        guard s.hasPrefix("#") else { return nil }
        let hashes = s.prefix { $0 == "#" }.count
        return (1 ... 6).contains(hashes) && s.dropFirst(hashes).hasPrefix(" ") ? hashes : nil
    }

    private static func listPrefix(_ s: String) -> (marker: String, body: String)? {
        if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ") {
            return ("• ", String(s.dropFirst(2)))
        }
        let digits = s.prefix { $0.isNumber }
        if !digits.isEmpty, s.dropFirst(digits.count).hasPrefix(". ") {
            return ("\(digits). ", String(s.dropFirst(digits.count + 2)))
        }
        return nil
    }

    // MARK: - Tables

    /// True when `lines[i]` is a pipe-table header (has a `|`) and `lines[i+1]` is its `---|---` rule.
    private static func isTableStart(_ lines: [String], _ index: Int) -> Bool {
        guard index + 1 < lines.count, lines[index].contains("|") else { return false }
        let sep = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard sep.contains("-"), sep.contains("|") else { return false }
        return sep.allSatisfy { "-:| ".contains($0) }
    }

    /// Render a GitHub pipe table starting at `from`; returns its lines and how many source lines it ate.
    private static func tableLines(_ lines: [String], from: Int, width: Int) -> (lines: [String], consumed: Int) {
        let header = splitRow(lines[from])
        var consumed = 2 // header + separator
        var body: [[String]] = []
        var cursor = from + 2
        while cursor < lines.count, lines[cursor].contains("|") {
            body.append(splitRow(lines[cursor]))
            cursor += 1
            consumed += 1
        }
        let columns = max(header.count, body.map(\.count).max() ?? 0)
        guard columns > 0 else { return ([], consumed) }

        var widths = (0 ..< columns).map { col -> Int in
            let cells = [header] + body
            return cells.map { col < $0.count ? TextWidth.of($0[col]) : 0 }.max() ?? 0
        }
        let sepCost = 3 * (columns - 1)
        let budget = max(columns * 3, width - sepCost)
        if widths.reduce(0, +) > budget {
            let cap = max(3, budget / columns)
            widths = widths.map { min($0, cap) }
        }

        var out = [tableRow(header, widths: widths, header: true)]
        out.append(widths.map { fg(Theme.faint, String(repeating: "─", count: $0)) }.joined(separator: fg(Theme.faint, "─┼─")))
        out += body.map { tableRow($0, widths: widths, header: false) }
        return (out, consumed)
    }

    private static func splitRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func tableRow(_ cells: [String], widths: [Int], header: Bool) -> String {
        var parts: [String] = []
        for col in widths.indices {
            let raw = col < cells.count ? cells[col] : ""
            var cell = parse(raw)
            while cellsWidth(cell) > widths[col], !cell.isEmpty { cell.removeLast() }
            let pad = String(repeating: " ", count: max(0, widths[col] - cellsWidth(cell)))
            parts.append(emit(cell, header: header) + pad)
        }
        return parts.joined(separator: fg(Theme.faint, " │ "))
    }

    // MARK: - Inline

    private static func parse(_ s: String) -> [Cell] {
        var cells: [Cell] = []
        var style: UInt8 = 0
        let chars = Array(s)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if style & code != 0 { // inside `code` only a backtick ends it
                if char == "`" { style &= ~code } else { cells.append(Cell(char: char, style: style)) }
                index += 1
                continue
            }
            if char == "`" { style |= code; index += 1; continue }
            if char == "[", let consumed = appendLink(chars, from: index, into: &cells, style: style) {
                index += consumed
                continue
            }
            if char == "*", index + 1 < chars.count, chars[index + 1] == "*" { style ^= bold; index += 2; continue }
            if char == "~", index + 1 < chars.count, chars[index + 1] == "~" { style ^= strike; index += 2; continue }
            if char == "*" { style ^= italic; index += 1; continue }
            cells.append(Cell(char: char, style: style))
            index += 1
        }
        return cells
    }

    /// Parse `[text](url)` at `from`. Appends the link text (underlined) plus a dimmed ` (url)` when the
    /// url adds information, and returns the number of source characters consumed - or nil if not a link.
    private static func appendLink(_ chars: [Character], from: Int, into cells: inout [Cell], style: UInt8) -> Int? {
        guard let close = chars[from...].firstIndex(of: "]"),
              close + 1 < chars.count, chars[close + 1] == "(",
              let paren = chars[(close + 2)...].firstIndex(of: ")")
        else { return nil }
        let text = chars[(from + 1) ..< close]
        let url = String(chars[(close + 2) ..< paren])
        for char in text { cells.append(Cell(char: char, style: style | link)) }
        if !url.isEmpty, url != String(text) {
            for char in " (\(url))" { cells.append(Cell(char: char, style: dim)) }
        }
        return paren - from + 1
    }

    private static func cellsWidth(_ cells: [Cell]) -> Int { cells.reduce(0) { $0 + TextWidth.of($1.char) } }

    private static func wrapCells(_ cells: [Cell], width: Int) -> [[Cell]] {
        guard width > 2 else { return [cells] }
        var lines: [[Cell]] = []
        var line: [Cell] = []
        var lineWidth = 0
        var lastSpace = -1
        for cell in cells {
            line.append(cell)
            lineWidth += TextWidth.of(cell.char)
            if cell.char == " " { lastSpace = line.count - 1 }
            if lineWidth > width {
                if lastSpace > 0 {
                    let rest = Array(line[(lastSpace + 1)...])
                    lines.append(Array(line[..<lastSpace]))
                    line = rest
                    lineWidth = cellsWidth(rest)
                    lastSpace = -1
                } else {
                    lines.append(line)
                    line = []
                    lineWidth = 0
                    lastSpace = -1
                }
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines.isEmpty ? [[]] : lines
    }

    private static func emit(_ cells: [Cell], header: Bool) -> String {
        var out = ""
        var index = 0
        while index < cells.count {
            let style = cells[index].style
            var run = ""
            while index < cells.count, cells[index].style == style {
                run.append(cells[index].char)
                index += 1
            }
            out += sgr(style, header: header, run)
        }
        return out
    }

    private static func sgr(_ style: UInt8, header: Bool, _ run: String) -> String {
        var codes: [String] = []
        if header || style & bold != 0 { codes.append("1") }
        if style & italic != 0 { codes.append("3") }
        if style & link != 0 { codes.append("4") } // underline
        if style & strike != 0 { codes.append("9") }
        if let fg = Paint.fgParams(foreground(style, header: header)) { codes.append(fg) }
        return codes.isEmpty ? run : "\u{1B}[\(codes.joined(separator: ";"))m\(run)\u{1B}[0m"
    }

    private static func foreground(_ style: UInt8, header: Bool) -> Theme.Color {
        if style & code != 0 { return Theme.code }
        if style & link != 0 { return Theme.link }
        if style & dim != 0 { return Theme.faint }
        return header ? Theme.bright : Theme.body
    }

    private static func fg(_ color: Theme.Color, _ s: String) -> String { Paint.fg(color, s) }
}
