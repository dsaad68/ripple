import DeepAgents
import DeepAgentsMacTools
import DeepAgentsMLX
import Foundation

/// Errors raised while resolving a scenario spec into a runnable agent.
enum ScenarioError: Error, CustomStringConvertible {
    case unknownMiddleware(String)
    case unknownTool(String)
    case unknownModel(String)

    var description: String {
        switch self {
        case .unknownMiddleware(let name):
            return "Unknown middleware \"\(name)\". Known: screenshot, clipboard, utility, "
                + "apple_notes, web, search, text, git, macos."
        case .unknownTool(let name):
            return "Unknown tool \"\(name)\". Known: calculator, current_datetime."
        case .unknownModel(let name):
            return "Unknown model id \"\(name)\" - not in MlxModel.catalog."
        }
    }
}

/// Resolves the string names a scenario TOML uses into concrete middleware, tools, and system
/// prompts. Keeping these maps in one place makes the set of building blocks a scenario can wire
/// explicit and trivially extensible - add a case here and it becomes available to every TOML.
enum ScenarioRegistry {
    /// Build a middleware by registry name. `screenCapture` is injected into `screenshot` so the
    /// harness can substitute fixtures for the live screen.
    static func middleware(
        named name: String, screenCapture: any ScreenCaptureProviding
    ) throws -> any AgentMiddleware {
        switch name {
        case "screenshot":
            // The deep agent's planner is blind: captures are forwarded to the vision subagent,
            // not spliced into the planner's own turn (matches `RippleDeepAgent`).
            return ScreenshotMiddleware(attachToConversation: false, screenCapture: screenCapture)
        case "clipboard":
            return ClipboardMiddleware()
        case "utility":
            return UtilityMiddleware()
        case "apple_notes":
            return AppleNotesMiddleware()
        case "web":
            return WebToolsMiddleware()
        case "search":
            return SearchToolsMiddleware(root: harnessRoot)
        case "text":
            return TextToolsMiddleware(root: harnessRoot)
        case "git":
            return GitToolsMiddleware(root: harnessRoot)
        case "macos":
            return MacToolsMiddleware(root: harnessRoot)
        default:
            throw ScenarioError.unknownMiddleware(name)
        }
    }

    /// The working folder the disk/system command-line tools are rooted at in the headless
    /// harness: the directory `ripple run` was launched from.
    private static var harnessRoot: WorkspaceRoot {
        WorkspaceRoot(rootURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    }

    /// Build a standalone tool by registry name. The tools normally provided by a middleware
    /// (clipboard, filesystem, screenshot, todos, task) are attached via that middleware instead;
    /// this covers the small always-safe extras a scenario may want directly on an agent.
    static func tool(named name: String) throws -> any AgentTool {
        switch name {
        case "calculator": return CalculatorTool()
        case "current_datetime": return CurrentDateTimeTool()
        default:
            throw ScenarioError.unknownTool(name)
        }
    }

    /// Resolve a system prompt: a known registry key returns the built-in prompt; any other
    /// non-nil string is used verbatim as inline prompt text. `nil` stays `nil` (no extra prompt).
    static func prompt(_ value: String?) -> String? {
        guard let value else { return nil }
        switch value {
        case "DeepScreenPrompt": return DeepScreenPrompt.system
        case "DeepVisionPrompt": return DeepVisionPrompt.system
        case "AskPrompt": return AskPrompt.system
        case "VisionPrompt": return VisionPrompt.system
        default: return value // inline prompt text
        }
    }
}
