import CoreGraphics
import DeepAgents
import DeepAgentsMacTools
import Foundation
import ImageIO

/// A ``ScreenCaptureProviding`` backed by pre-baked PNG fixtures instead of the live screen.
/// The headless scenario harness injects this so screen-dependent scenarios (the per-window
/// vision flow) run deterministically and need no Screen Recording permission. The forwarded
/// URLs point at the scenario's own PNG files on disk, so the vision subagent renders the exact
/// fixture image — the same path a live capture takes, just with a fixed picture.
struct FixtureScreenCapture: ScreenCaptureProviding {
    /// One fixture window: the human-facing name the planner sees in the numbered manifest and
    /// the PNG the vision subagent looks at.
    struct Window: Sendable {
        let name: String
        let url: URL
    }

    /// The fixture windows, front-to-back (index 0 is the "frontmost"), matching the numbered
    /// manifest `take_window_screenshots` returns.
    let windows: [Window]
    /// Optional dedicated full-screen fixture for `take_screenshot`; falls back to the first
    /// window when absent.
    let screen: Window?

    init(windows: [Window], screen: Window? = nil) {
        self.windows = windows
        self.screen = screen
    }

    func capture(fullScreen _: Bool) async throws -> (url: URL, size: CGSize) {
        guard let shot = screen ?? windows.first else {
            throw ScreenshotCapture.CaptureError(
                message: "No screenshot fixture is configured for this scenario."
            )
        }
        return (shot.url, Self.pixelSize(of: shot.url))
    }

    func captureWindows() async throws -> [ScreenshotCapture.WindowCapture] {
        guard !windows.isEmpty else {
            throw ScreenshotCapture.CaptureError(
                message: "No window screenshot fixtures are configured for this scenario."
            )
        }
        return windows.map {
            ScreenshotCapture.WindowCapture(
                url: $0.url, window: $0.name, size: Self.pixelSize(of: $0.url)
            )
        }
    }

    /// Read a PNG's pixel dimensions without fully decoding it. Falls back to a nominal size if
    /// the file can't be read — the size is only used for the planner-facing "W×H" result text,
    /// never for the actual image the vision model loads.
    private static func pixelSize(of url: URL) -> CGSize {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = props[kCGImagePropertyPixelWidth] as? Int,
            let height = props[kCGImagePropertyPixelHeight] as? Int
        else {
            return CGSize(width: 1280, height: 800)
        }
        return CGSize(width: width, height: height)
    }
}
