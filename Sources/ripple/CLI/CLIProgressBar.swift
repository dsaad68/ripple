import Foundation

/// A reusable single-line, in-place progress bar for the pre-TUI command output (carriage-return
/// redraws to stderr): the `chat` startup model load / download, and `ripple model pull`. The bar's
/// sweeping highlight keeps a 0% or stalled phase (e.g. the weight-loading tail after a download)
/// from looking frozen. ``barString(fraction:width:)`` returns the same glyphs without any cursor
/// codes, for embedding in the full-screen ``ChatScreen`` download line.
@MainActor
enum CLIProgressBar {
    static let width = 22

    /// Run `operation`, animating a bar fed by the fraction it reports, then print a final ✓/✗ line.
    /// Returns the operation's own success. `verb`/`doneVerb` label the in-progress and finished
    /// lines (e.g. "downloading" / "downloaded"); `role` is an optional right-hand tag.
    static func run(
        label: String, role: String = "", verb: String = "loading", doneVerb: String = "loaded",
        _ operation: (@escaping @Sendable (Double) -> Void) async -> Bool
    ) async -> Bool {
        let holder = ProgressHolder()
        let animation = Task { @MainActor in
            var frame = 0
            while !Task.isCancelled {
                draw(label: label, role: role, verb: verb, fraction: holder.fraction, frame: frame)
                frame += 1
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
        let ok = await operation { holder.set($0) }
        animation.cancel()
        finish(label: label, role: role, verb: ok ? doneVerb : "failed", ok: ok)
        return ok
    }

    /// A plain bar (no carriage return / cursor codes) for embedding in another renderer, e.g. the
    /// full-screen TUI download line.
    static func barString(fraction: Double, width: Int) -> String {
        let fraction = max(0, min(1, fraction))
        let filled = Int((Double(width) * fraction).rounded())
        var bar = ""
        for index in 0 ..< width {
            bar += Paint.fg(index < filled ? 111 : 238, index < filled ? "█" : "░")
        }
        return bar
    }

    private static func draw(label: String, role: String, verb: String, fraction: Double, frame: Int) {
        let fraction = max(0, min(1, fraction))
        let filled = Int((Double(width) * fraction).rounded())
        let sweep = frame % width // a highlight that loops across, so 0% still reads as "working"
        var bar = ""
        for index in 0 ..< width {
            if index < filled {
                bar += Paint.fg(index == sweep ? 255 : 111, "█")
            } else {
                bar += index == sweep ? Paint.fg(111, "▒") : Paint.fg(238, "░")
            }
        }
        let pct = String(format: "%3d%%", Int((fraction * 100).rounded()))
        write("\r  " + Paint.fg(141, "◇") + " " + Paint.fg(245, verb + " ") + Paint.fg(252, label)
            + roleSuffix(role) + "  " + bar + " " + Paint.fg(244, pct) + "\u{1B}[K")
    }

    private static func finish(label: String, role: String, verb: String, ok: Bool) {
        let mark = ok ? Paint.fg(114, "✓") : Paint.fg(174, "✗")
        write("\r  " + mark + " " + Paint.fg(245, verb + " ") + Paint.fg(252, label)
            + roleSuffix(role) + "\u{1B}[K\n")
    }

    private static func roleSuffix(_ role: String) -> String {
        role.isEmpty ? "" : Paint.fg(238, " · " + role)
    }

    private static func write(_ s: String) {
        FileHandle.standardError.write(Data(s.utf8))
    }
}

/// A tiny lock-guarded box for the progress fraction, shared between an operation's `@Sendable`
/// progress callback (called off the main actor) and the main-actor bar animation that reads it.
final class ProgressHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0

    /// Monotonic: never let a late, smaller fraction make the bar jump backwards.
    func set(_ fraction: Double) {
        lock.lock()
        value = max(value, fraction)
        lock.unlock()
    }

    var fraction: Double {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
