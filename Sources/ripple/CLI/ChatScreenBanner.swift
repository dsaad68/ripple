import DeepAgents
import Foundation

// The full-screen overlays for `ripple chat`: the empty-state launch banner (with the shimmering
// "ripple" wordmark art) and the `/help` cheat sheet. Split out of the render layer to keep that file
// within budget; the model types live in ChatScreenModel.
extension ChatScreen {
    // MARK: - Banner

    /// The empty-state launch banner: a two-pane bordered box - brand + loaded models on the left,
    /// getting-started hints on the right - with a gradient "ripple" wordmark that shimmers in on
    /// launch (see `introFrame`). Narrow terminals fall back to a borderless stacked banner.
    func bannerLines(width: Int) -> [Line] {
        guard width >= 58 else { return compactBanner() }
        // Servers that need a browser sign-in: declared OAuth without a token, or a plain HTTP server
        // whose auth we discovered from a 401 - the same predicate the `/mcp` browser uses.
        let needsAuth = mcpServers.filter { mcpRuntime?.authState($0) == .needsAuth }.map(\.name)
        return Self.bannerBox(
            width: width, planner: plannerName, vision: Self.name(variant.visionModelID),
            cwd: abbreviatedCWD(), mcp: mcpServers.map(\.name), needsAuth: needsAuth,
            instructions: instructionFiles, introFrame: introFrame
        )
    }

    /// The two-pane box body, pure so it can be unit-tested for border alignment at any width.
    /// Every returned line is exactly `width` display columns wide (after the 2-space indent).
    /// `mcp` is the configured MCP server names; the left pane lists the first three (then `…`).
    /// `needsAuth` are the names that need a sign-in - shown as a yellow nudge under the list.
    static func bannerBox(
        width: Int, planner: String, vision: String, cwd: String, mcp: [String] = [],
        needsAuth: [String] = [], instructions: [String] = [], introFrame: Int
    ) -> [Line] {
        let edge = Theme.border.xterm
        let inner = width - 2 // columns between ╭ and ╮
        // Split the content into a wide left pane and a narrower right pane, with a divider:
        //   "  " │ " " left(leftW) " " │ " " right(rightW) " " │   ->  leftW + rightW = width - 7.
        let rightW = max(18, (width - 7) * 2 / 5) // ~40% right pane -> divider near 58%, fills wide screens
        let leftW = (width - 7) - rightW

        // The role label (grey) in a fixed column, then the model name (white) - e.g. "main agent  8B-A1B".
        func modelRow(_ role: String, _ id: String) -> String {
            let name = clip(id, max(1, leftW - 14))
            let pad = String(repeating: " ", count: max(2, 12 - TextWidth.of(role)))
            return Paint.fg(245, role) + Paint.fg(252, pad + name)
        }
        func hint(_ key: String, _ label: String) -> String {
            let pad = String(repeating: " ", count: max(1, 4 - TextWidth.of(key)))
            return Paint.fg(111, key) + Paint.fg(250, pad + label)
        }
        // The wordmark is the big three-row ASCII-art banner (18 columns; the left pane is >= 31 here,
        // since the box only renders at width >= 58, so it never needs clipping).
        let art = rippleArt(frame: introFrame)
        var left: [String] = [
            "",
            art[0],
            art[1],
            art[2],
            Paint.fg(244, "on-device deep agent"),
            "",
            Paint.fg(244, "models"),
            modelRow("main agent", planner),
            modelRow("vision", vision)
        ]
        if !mcp.isEmpty { // the first three configured MCP servers, then `…`
            let summary = mcp.prefix(3).joined(separator: ", ") + (mcp.count > 3 ? ", …" : "")
            left += ["", Paint.fg(244, "available mcps: ") + Paint.fg(245, clip(summary, leftW - 16))]
            if !needsAuth.isEmpty { // a yellow nudge that some need a sign-in (do it in /mcp)
                let label = needsAuth.count == 1 ? "\(needsAuth[0]) needs sign-in" : "\(needsAuth.count) need sign-in"
                left += [Paint.fg(179, clip("⚠ " + label + " · /mcp", leftW))]
            }
        }
        if !instructions.isEmpty { // the loaded AGENTS.md / CLAUDE.md / RIPPLE.md, first three then `…`
            let summary = instructions.prefix(3).joined(separator: ", ") + (instructions.count > 3 ? ", …" : "")
            left += ["", Paint.fg(244, "instructions: ") + Paint.fg(245, clip(summary, leftW - 14))]
        }
        left += ["", Paint.fg(240, clip(cwd, leftW))]
        let right: [String] = [
            "",
            Paint.bold(Paint.fg(141, "Getting started")),
            "",
            hint("›", "type a message"),
            hint("/", "for commands"),
            hint("!", "container shell"),
            hint("!!", "local shell"),
            hint("tab", "cycles modes"),
            hint("?", "opens /help")
        ]

        let bar = Paint.fg(edge, "│")
        func rowText(_ leftCell: String, _ rightCell: String) -> String {
            let lpad = String(repeating: " ", count: max(0, leftW - TextWidth.of(leftCell)))
            let rpad = String(repeating: " ", count: max(0, rightW - TextWidth.of(rightCell)))
            return "  " + bar + " " + leftCell + lpad + " " + bar + " " + rightCell + rpad + " " + bar
        }

        // Title rides the top border ("╭─ Ripple ─...─╮"); the bottom border is plain.
        let title = Paint.bold(Paint.gradient("Ripple", from: Theme.accent, to: Theme.agent))
        let topFill = max(0, inner - (TextWidth.of("Ripple") + 3)) // "─ " + title + " "
        let top = "  " + Paint.fg(edge, "╭─ ") + title
            + Paint.fg(edge, " " + String(repeating: "─", count: topFill) + "╮")
        let bottom = "  " + Paint.fg(edge, "╰" + String(repeating: "─", count: inner) + "╯")

        var out: [Line] = [Line(""), Line(top)]
        for index in 0 ..< max(left.count, right.count) {
            out.append(Line(rowText(
                index < left.count ? left[index] : "",
                index < right.count ? right[index] : ""
            )))
        }
        out += [Line(bottom), Line("")]
        return out
    }

    /// The borderless launch banner for terminals too narrow for the box.
    private func compactBanner() -> [Line] {
        var out: [Line] = [
            Line(""),
            Line("  " + Paint.fg(141, "◇ ") + Self.rippleWordmark("ripple", frame: introFrame)
                + Paint.fg(240, "  ·  on-device deep agent")),
            Line("  " + Paint.fg(245, "main agent ") + Paint.fg(252, plannerName)
                + Paint.fg(245, "   vision ") + Paint.fg(252, Self.name(variant.visionModelID)))
        ]
        if !instructionFiles.isEmpty {
            out.append(Line("  " + Paint.fg(238, "instructions  ")
                    + Paint.fg(244, instructionFiles.joined(separator: ", "))))
        }
        out += [
            Line(""),
            Line("  " + Paint.fg(240, "Type a message to begin.  ")
                + Paint.fg(238, "/ commands · Tab permission mode · ? via /help")),
            Line("")
        ]
        return out
    }

    /// The "ripple" wordmark - an accent->agent gradient with a bright highlight band that sweeps
    /// across the letters as `frame` advances, rests off the right edge, then repeats (so the shimmer
    /// keeps pulsing while the banner is up). Bold; truecolor only (256-color gets the solid gradient).
    static func rippleWordmark(_ text: String, frame: Int) -> String {
        let chars = Array(text)
        guard Theme.depth == .truecolor, chars.count > 1 else {
            return Paint.bold(Paint.gradient(text, from: Theme.accent, to: Theme.agent))
        }
        let last = Double(chars.count - 1)
        let center = Double(frame % 22) * 0.9 - 3 // sweeps left->right, then rests off-edge and repeats
        func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        var out = "\u{1B}[1m"
        for (index, char) in chars.enumerated() {
            let t = Double(index) / last
            var r = mix(Double(Theme.accent.r), Double(Theme.agent.r), t)
            var g = mix(Double(Theme.accent.g), Double(Theme.agent.g), t)
            var b = mix(Double(Theme.accent.b), Double(Theme.agent.b), t)
            let distance = Double(index) - center
            let highlight = exp(-(distance * distance) / 1.7) * 0.85
            r = mix(r, Double(Theme.bright.r), highlight)
            g = mix(g, Double(Theme.bright.g), highlight)
            b = mix(b, Double(Theme.bright.b), highlight)
            out += "\u{1B}[38;2;\(Int(r.rounded()));\(Int(g.rounded()));\(Int(b.rounded()))m\(char)"
        }
        return out + "\u{1B}[0m"
    }

    /// The "ripple" wordmark as a compact three-row ASCII-art banner (rounded box-drawing glyphs, 18
    /// columns wide), italic and carrying the same accent->agent gradient as the inline wordmark - but
    /// flowing left-to-right across the *columns*, so the color lines up vertically down all three rows,
    /// and the launch highlight sweeps across as `frame` advances. Truecolor gets the gradient + sweep;
    /// 256-color a solid accent; `NO_COLOR` the raw glyphs. Every row is exactly 18 display columns.
    static func rippleArt(frame: Int) -> [String] {
        let rows = [
            "╭─ • ╭─╮ ╭─╮ ╷ ╭─╮",
            "│  │ ├─╯ ├─╯ │ ├─╴",
            "╵  ╵ ╵   ╵   ╵ ╰─╯"
        ]
        guard Theme.depth != .none else { return rows }
        let italic = "\u{1B}[3m"
        guard Theme.depth == .truecolor else { return rows.map { italic + Paint.fg(Theme.accent, $0) } }

        let columns = rows[0].count // all three rows share the column count, so the gradient aligns
        // The highlight sweeps left->right across the columns, then rests off the right edge before the
        // cycle repeats - so the shimmer keeps pulsing while the banner is up, not just once at launch.
        let center = Double(frame % 30) * 1.4 - 4
        func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        return rows.map { row in
            var out = italic
            for (index, char) in row.enumerated() {
                let t = Double(index) / Double(columns - 1)
                var r = mix(Double(Theme.accent.r), Double(Theme.agent.r), t)
                var g = mix(Double(Theme.accent.g), Double(Theme.agent.g), t)
                var b = mix(Double(Theme.accent.b), Double(Theme.agent.b), t)
                let distance = Double(index) - center
                let highlight = exp(-(distance * distance) / 2.2) * 0.85
                r = mix(r, Double(Theme.bright.r), highlight)
                g = mix(g, Double(Theme.bright.g), highlight)
                b = mix(b, Double(Theme.bright.b), highlight)
                out += "\u{1B}[38;2;\(Int(r.rounded()));\(Int(g.rounded()));\(Int(b.rounded()))m\(char)"
            }
            return out + "\u{1B}[0m"
        }
    }

    // MARK: - Help

    /// The `/help` overlay: a static cheat sheet of keys + slash commands. Dismissed by any key.
    func helpLines(width: Int) -> [Line] {
        let keys: [(String, String)] = [
            ("enter", "send the message"),
            ("esc", "stop a running turn / clear the input"),
            ("ctrl-c", "stop a turn, or quit"),
            ("ctrl-d", "quit"),
            ("up / down", "recall previous prompts"),
            ("left / right", "move the cursor"),
            ("home / end", "jump to line start / end"),
            ("ctrl-a / ctrl-e", "jump to start / end"),
            ("ctrl-w", "delete the previous word"),
            ("ctrl-u", "clear the input"),
            ("delete", "delete forward"),
            ("pageup / pagedown", "scroll the transcript"),
            ("mouse wheel", "scroll the transcript"),
            ("click a thought", "expand / collapse the reasoning"),
            ("tab / shift-tab", "cycle permission mode (ask / auto-reads / plan / accept-all)"),
            ("/", "open the command palette"),
            ("! command", "run a command in the container sandbox"),
            ("!! command", "run a command in the local shell")
        ]
        func two(_ left: String, _ right: String, leftColor: Int, rightColor: Int) -> Line {
            let pad = String(repeating: " ", count: max(2, 20 - left.count))
            return Line("    " + Paint.fg(leftColor, left) + pad + Paint.fg(rightColor, right))
        }
        // Body rows only; the "Keys & commands" title + "press any key to close" hint ride the panel
        // borders (see ``menuChrome``).
        var out: [Line] = keys.map { two($0.0, $0.1, leftColor: 250, rightColor: 244) }
        out += [Line(""), Line("  " + Paint.fg(244, "Commands"))]
        out += Self.commands.map { two($0.name, $0.description, leftColor: 252, rightColor: 240) }
        return out
    }
}
