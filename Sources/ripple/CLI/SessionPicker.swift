import Darwin
import DeepAgentsMLX
import Foundation

/// Interactive arrow-key picker for `ripple --resume` with no id: a self-contained raw-mode list of
/// this project's past sessions, drawn inline above the load bars. Returns the chosen session, or nil
/// to start fresh (Esc / `q` / `n` / Ctrl-D / EOF). Ctrl-C aborts the program (raw mode swallows the
/// usual SIGINT). It owns a short-lived synchronous read loop it fully starts and stops, so it never
/// competes with ``Terminal/keyStream()``'s reader thread, and renders to stderr to match the other
/// pre-TUI prompts in ``DeepAgentREPL``.
enum SessionPicker {
    /// One keystroke's intent, decoded purely from the raw bytes so the mapping stays unit-testable.
    enum Action: Equatable { case up, down, select, cancel, abort, ignore }

    /// Pick a session interactively. `sessions` must be non-empty and stdin/stderr a tty (the caller
    /// guards both). Returns the selection, or nil to start a fresh session.
    static func pick(_ sessions: [RippleSessionMeta]) -> RippleSessionMeta? {
        var original = termios()
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        // Match Terminal.enter()'s raw flags (no echo / line buffering / signal / flow keys) but no
        // alternate screen - the list is drawn inline so the load bars flow on below it.
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        func restore() { emit("\u{1B}[?25h"); tcsetattr(STDIN_FILENO, TCSAFLUSH, &original) }
        emit("\u{1B}[?25l") // hide the cursor for the duration of the pick
        defer { restore() }

        let height = max(1, min(sessions.count, visibleRows()))
        let lineCount = height + 3 // a leading blank, the header, the rows, and the footer hint
        var selected = 0
        var firstDraw = true
        while true {
            draw(sessions, selected: selected, height: height, redraw: !firstDraw, lineCount: lineCount)
            firstDraw = false
            switch decode(nextKey()) {
            case .up: selected = (selected - 1 + sessions.count) % sessions.count
            case .down: selected = (selected + 1) % sessions.count
            case .select: clearBlock(lineCount); confirm(sessions[selected]); return sessions[selected]
            case .cancel: clearBlock(lineCount); return nil
            case .abort: clearBlock(lineCount); restore(); exit(130)
            case .ignore: break
            }
        }
    }

    /// Read one keystroke's worth of bytes. A lone `Escape` is reconciled with a possible split escape
    /// sequence (`ESC` then `[A` over a slow tty / SSH) by a short poll, mirroring ``Terminal`` so an
    /// arrow is never misread as a cancel; an empty read (EOF) yields an empty batch.
    private static func nextKey() -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 8)
        let count = read(STDIN_FILENO, &buffer, 8)
        guard count > 0 else { return [] }
        var bytes = Array(buffer[0 ..< count])
        if bytes == [0x1B], pollInput() {
            var more = [UInt8](repeating: 0, count: 8)
            let extra = read(STDIN_FILENO, &more, 8)
            if extra > 0 { bytes += Array(more[0 ..< extra]) }
        }
        return bytes
    }

    /// Map a batch of input bytes to an ``Action``. Pure, so the key handling is unit-testable.
    static func decode(_ bytes: [UInt8]) -> Action {
        guard let first = bytes.first else { return .cancel } // EOF -> start fresh
        if first == 0x1B {
            if bytes.count == 1 { return .cancel } // a bare Escape
            guard bytes.count >= 3, bytes[1] == 0x5B || bytes[1] == 0x4F else { return .ignore }
            switch bytes[2] {
            case 0x41: return .up // ESC [ A / ESC O A
            case 0x42: return .down // ESC [ B / ESC O B
            default: return .ignore
            }
        }
        guard bytes.count == 1 else { return .ignore }
        switch first {
        case 0x0D, 0x0A: return .select // Enter
        case 0x03: return .abort // Ctrl-C
        case 0x04, 0x71, 0x51, 0x6E, 0x4E: return .cancel // Ctrl-D / q / Q / n / N
        case 0x6B: return .up // k
        case 0x6A: return .down // j
        default: return .ignore
        }
    }

    /// First visible row index for a `count`-long list shown `height` rows tall with `selected`
    /// highlighted: re-centered on the selection and clamped so the window stays inside the list.
    static func windowStart(count: Int, height: Int, selected: Int) -> Int {
        guard count > height else { return 0 }
        return min(max(0, selected - height / 2), count - height)
    }

    private static func draw(
        _ sessions: [RippleSessionMeta], selected: Int, height: Int, redraw: Bool, lineCount: Int
    ) {
        if redraw { emit("\u{1B}[\(lineCount - 1)A\r\u{1B}[0J") } // back to the block top, clear downward
        emit(render(sessions, selected: selected, height: height).joined(separator: "\r\n"))
    }

    private static func render(_ sessions: [RippleSessionMeta], selected: Int, height: Int) -> [String] {
        let relative = RelativeDateTimeFormatter()
        let cols = Terminal.size().cols
        let start = windowStart(count: sessions.count, height: height, selected: selected)
        var lines = ["", "  " + Paint.fg(Theme.text.xterm, "Resume a session in this project:")]
        for index in start ..< start + height {
            let meta = sessions[index]
            let chosen = index == selected
            let model = MlxModel.catalog.first { $0.id == meta.model }?.shortName ?? meta.model
            let suffix = "  \(relative.localizedString(for: meta.updatedAt, relativeTo: Date())) · \(model)"
            let title = truncate(meta.title, cols - 4 - suffix.count)
            let marker = chosen ? Paint.arrow("❯") : " "
            lines.append("  " + marker + " " + Paint.fg(chosen ? Theme.text.xterm : Theme.subtle.xterm, title)
                + Paint.fg(Theme.faint.xterm, suffix))
        }
        lines.append("  " + Paint.fg(Theme.faint.xterm, footer(selected: selected, total: sessions.count, height: height)))
        return lines
    }

    private static func footer(selected: Int, total: Int, height: Int) -> String {
        let hint = "↑/↓ move · enter resume · esc new session"
        return total > height ? "(\(selected + 1)/\(total))  " + hint : hint
    }

    /// Erase the rendered block, leaving the cursor where it began so later output continues cleanly.
    private static func clearBlock(_ lineCount: Int) { emit("\u{1B}[\(lineCount - 1)A\r\u{1B}[0J") }

    private static func confirm(_ meta: RippleSessionMeta) {
        let title = truncate(meta.title, max(10, Terminal.size().cols - 14))
        emit("  " + Paint.arrow("❯") + " " + Paint.fg(Theme.faint.xterm, "resuming ")
            + Paint.fg(Theme.text.xterm, title) + "\r\n")
    }

    private static func truncate(_ string: String, _ width: Int) -> String {
        guard string.count > width else { return string }
        guard width > 1 else { return String(string.prefix(max(0, width))) }
        return String(string.prefix(width - 1)) + "…"
    }

    /// Rows available for the list: the terminal height less the blank / header / footer chrome.
    private static func visibleRows() -> Int { max(1, Terminal.size().rows - 4) }

    /// Whether more input is already waiting on stdin, to disambiguate a trailing `ESC` from a split
    /// escape sequence (mirrors ``Terminal``'s poll).
    private static func pollInput() -> Bool {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        return poll(&pfd, 1, 50) > 0
    }

    private static func emit(_ string: String) { FileHandle.standardError.write(Data(string.utf8)) }
}
