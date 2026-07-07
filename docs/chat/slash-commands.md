# Slash commands

Slash commands give you live control over the agent's configuration, tools, and session state without leaving the chat prompt. Every command is available through the `/` palette - type `/` at an empty prompt, then filter by typing, navigate with ++arrow-up++ / ++arrow-down++, and confirm with ++enter++. Pressing ++esc++ closes the palette without running anything.

## Quick reference

| Command | What it opens |
|---|---|
| `/model` | Model picker - choose the planner model, set idle timeout, browse and download local models, manage remote models |
| `/tools` | Two-level tool browser - all agent tools grouped by capability set |
| `/mcp` | MCP server list - servers, their tools, and per-server approval mode |
| `/config` | Config editor - capabilities, sandbox mode, and logging |
| `/compact` | Compact the current conversation immediately |
| `/help` | Keyboard reference and command list |
| `/fresh` | Start a new conversation (mints a fresh session id) |
| `/reset` | Start a new conversation (alias for `/fresh`) |
| `/clear` | Clear the visible screen (keeps the current session and history) |
| `/exit` | Quit Ripple |
| `/quit` | Quit Ripple (alias for `/exit`) |

---

## `/model` - model picker

Opens a unified overlay for managing the planner model. The overlay has three tabs:

- **Select** - choose an on-device MLX model or a registered remote model as the planner for this session. Also shows the idle timeout setting (how long Ripple holds a loaded model in memory before unloading it).
- **Local** - browse the Hugging Face model catalog, see which models are already in the local cache (`~/.cache/huggingface/hub/`), and trigger downloads from within the chat.
- **Remote** - browse OpenRouter's free model catalog, add models to your registry, and remove ones you no longer want.

Switching models takes effect for the next turn. The selected model is persisted to `settings.json` as `selectedModel`.

See [Models (overview)](../models/index.md) for a full discussion of model types, config, and download options.

---

## `/tools` - tool browser

A two-level browser that shows every tool the agent currently has access to:

- **Level 1** - capability sets (e.g. filesystem, shell, MCP server tools).
- **Level 2** (press ++enter++ on a set) - the individual tools within it, each with its description.

This is read-only - use [Configuration](../config/index.md) (`/config`) or `toolPolicy` in `settings.json` to enable or disable tools.

---

## `/mcp` - MCP server browser

Lists every configured MCP server alongside its transport type, authentication status, and approval mode. Press ++enter++ on a server to drill into its individual tools.

Additional actions from within the browser:

- Press `r` to initiate an OAuth sign-in for servers that require it.
- Press `x` to sign out (clear stored OAuth tokens) for a server.

See [MCP servers](../mcp.md) for configuration details, transport types, and troubleshooting.

---

## `/config` - configuration editor

An interactive editor for the session's live configuration:

- **Capabilities** - enable or disable middleware (e.g. clipboard integration, screenshot access).
- **Sandbox** - set the sandbox mode (`off`, `failover`, `container-only`).
- **Prefill cache** - keep the reusable prompt prefix (system prompt + tool schemas KV) on disk
  under `~/.cache/deepagents/prefix-kv`, so a fresh launch skips the multi-second prompt prefill.
  On by default; turn it off to reclaim the disk space (snapshots can be a few hundred MB per
  model). Persisted as `prefixKVCache` in `settings.json` and honored by headless `ripple -p`
  runs too.
- **Logging** - configure the JSONL debug transcript directory.

Changes made here are applied immediately for the current session and written back to `settings.json`. See [Configuration (overview)](../config/index.md) for the full settings schema.

---

## `/compact` - manual compaction

Triggers context compaction immediately, regardless of how full the context window currently is. Ripple summarizes the older turns of the conversation into a single summary turn, preserves the recent tail verbatim, and offloads the original messages to disk so nothing is lost.

!!! tip
    Compaction also fires automatically at 85% of the model's context window. Use `/compact` early when you know the conversation is about to grow large (e.g. before a long coding session) to keep the context meter low.

See [Context & compaction](../config/compaction.md) for details on the summarization strategy, configuration knobs, and recovery of original messages.

---

## `/help` - keyboard and command reference

Displays the full in-app keyboard reference and command list. This is a quick in-session lookup; the complete reference is in [Keyboard reference](keyboard.md).

---

## `/fresh` and `/reset` - new conversation

Both commands start a completely fresh conversation by minting a new session id. The old session is not deleted - it stays resumable via `ripple --resume`. Tool policy, model selection, and configuration carry over to the new session.

!!! note
    `/fresh` and `/reset` are equivalent. They exist as aliases to match different muscle memories.

---

## `/clear` - clear the screen

Clears the visible terminal output. The current session id, message history, and all state are preserved - `/clear` is purely cosmetic, unlike `/fresh` which starts a new session.

---

## `/exit` and `/quit` - quit

Both commands exit Ripple cleanly. The current session is saved to disk before exit and will be available the next time you run `ripple --resume`.
