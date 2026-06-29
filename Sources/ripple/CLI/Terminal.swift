import Darwin
import DeepAgents
import Foundation

/// Low-level terminal control for the full-screen `ripple chat` UI: the alternate screen buffer,
/// raw input mode (no line buffering / echo), terminal size + resize notifications, and a byte
/// stream of keystrokes. All escape-sequence rendering is done by `ChatScreen`; this just owns the
/// terminal mode and input.
enum Terminal {
    private nonisolated(unsafe) static var saved = termios()

    /// Enter the alternate screen and raw mode. Pair with ``leave()`` (call it on every exit path).
    static func enter() {
        tcgetattr(STDIN_FILENO, &saved)
        var raw = saved
        // No echo, no canonical line buffering, no signal/flow keys (we handle ^C/^D and Enter).
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        // Alt screen + home, mouse reporting (1000 = buttons/wheel, 1006 = SGR coordinates), and
        // bracketed paste (2004) so a multi-line paste arrives as one block, not as Enter presses.
        // `>4;1m` is xterm modifyOtherKeys mode 1: conservative (Escape, arrows, and Ctrl-letters keep
        // their legacy bytes) but it disambiguates modified specials, so Shift-Enter arrives as a
        // distinct `CSI 27;2;13~` that the input box turns into a newline.
        write("\u{1B}[?1049h\u{1B}[?1000h\u{1B}[?1006h\u{1B}[?2004h\u{1B}[>4;1m\u{1B}[H")
    }

    /// Leave the alternate screen and restore the original terminal mode. Clears synchronized-update
    /// mode (`?2026l`) too, in case an exit interrupts a frame mid-draw and leaves it open.
    static func leave() {
        write("\u{1B}[?2026l\u{1B}[>4m\u{1B}[?2004l\u{1B}[?1000l\u{1B}[?1006l\u{1B}[?25h\u{1B}[?1049l")
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
    }

    /// Current terminal size; falls back to 24×80.
    static func size() -> (rows: Int, cols: Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_row > 0 {
            return (Int(ws.ws_row), Int(ws.ws_col))
        }
        return (24, 80)
    }

    static func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    /// One decoded keystroke: a raw byte, or a lone `Escape` (disambiguated from escape sequences).
    enum Key: Sendable, Equatable {
        case byte(UInt8)
        case escape
    }

    /// Turn a batch of input bytes into keys. A `0x1B` that is the **last** byte of the batch is
    /// ambiguous - it might begin a CSI/SS3 sequence whose remaining bytes haven't arrived yet - so
    /// `moreAvailable()` decides lone `Escape` vs sequence start. An `ESC` with more bytes after it in
    /// the same batch is unambiguously a sequence, so it's never misclassified (robust when a sequence
    /// is split across reads, as over SSH). Pure, so the disambiguation is unit-testable.
    static func classify(_ bytes: [UInt8], moreAvailable: () -> Bool) -> [Key] {
        bytes.enumerated().map { offset, byte in
            byte == 0x1B && offset == bytes.count - 1
                ? (moreAvailable() ? .byte(0x1B) : .escape)
                : .byte(byte)
        }
    }

    /// Keystrokes as a stream of **batches** - one element per terminal `read`, which is typically a
    /// whole keystroke or a complete mouse/escape packet. A detached thread does the blocking reads.
    /// The consumer processes a batch then asks for a single coalesced frame, so a multi-byte sequence
    /// or a fast wheel burst costs one render, not one per byte.
    ///
    /// A bare `0x1B` is disambiguated from the start of a CSI/SS3 sequence only when it is the **last**
    /// byte of a batch (its continuation, if any, hasn't arrived yet): a short `poll` decides lone
    /// `Escape` vs sequence start. An `ESC` followed by more bytes in the same batch is unambiguously a
    /// sequence, so it's never misread - which makes arrows / mouse robust when bytes arrive split
    /// (common over SSH), where the old per-byte poll could drop a real sequence as a lone Escape.
    static func keyStream() -> AsyncStream<[Key]> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let thread = Thread {
                let capacity = 4096
                var buffer = [UInt8](repeating: 0, count: capacity)
                while true {
                    let count = read(STDIN_FILENO, &buffer, capacity)
                    if count <= 0 { break }
                    continuation.yield(classify(Array(buffer[0 ..< count]), moreAvailable: pollHasInput))
                }
                continuation.finish()
            }
            thread.start()
        }
    }

    /// Whether more input is already waiting on stdin (a short `poll`), used to disambiguate a trailing
    /// `ESC`. A slightly longer-than-instant deadline tolerates a sequence whose bytes arrive split.
    private static func pollHasInput() -> Bool {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        return poll(&pfd, 1, 50) > 0
    }

    /// Invoke `handler` (on the main queue) whenever the terminal is resized. Returns the source,
    /// which must be retained for the subscription to stay live.
    static func onResize(_ handler: @escaping @Sendable () -> Void) -> any DispatchSourceSignal {
        signal(SIGWINCH, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        return source
    }
}
