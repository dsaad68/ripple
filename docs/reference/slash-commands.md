# Slash command reference

Quick-reference table of all slash commands available inside `ripple chat`. Type `/` to open the
command palette - commands filter as you type, and arrow keys navigate the list.

For full detail on each command, see [Slash commands](../chat/slash-commands.md).

---

## Commands

| Command | Description |
|---|---|
| `/model` | Open the model picker - select the planner model (on-device MLX or remote), browse and download local models, add/remove remote models from the registry, set idle timeout. |
| `/tools` | Browse all agent tools grouped by capability (two-level browser: toolset - tools). Covers both built-in tools and MCP tools. |
| `/mcp` | Inspect MCP servers and their tools; sign in with OAuth (`r`) or log out (`x`). See [MCP servers](../mcp.md). |
| `/config` | Edit capabilities, sandbox mode, and logging for the current project. Changes are saved to `.ripple/settings.json`. See [Configuration](../config/index.md). |
| `/compact` | Summarize older turns to free context window space. Equivalent to the automatic compaction that fires at ~85% context usage. See the compaction guide. |
| `/fresh` | Start a new conversation - mints a fresh session id. The current session remains resumable with `--resume`. |
| `/reset` | Alias for `/fresh`. |
| `/clear` | Clear the screen. Does not affect the session id or message history. |
| `/help` | Show a quick reference of keyboard shortcuts and available commands. |
| `/exit` | Quit Ripple. |
| `/quit` | Alias for `/exit`. |

---

## See also

- [Slash commands](../chat/slash-commands.md) - full documentation for each command
- [Keyboard reference](../chat/keyboard.md) - keyboard shortcuts
- [MCP servers](../mcp.md) - `/mcp` command detail
- [Configuration](../config/index.md) - `/config` command detail
