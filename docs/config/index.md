# Configuration (overview)

Ripple uses JSON settings files to persist model registrations, the selected planner, and tool
policy. Two scopes are supported: project-level and global. They are merged at startup with the
project file taking precedence.

---

## Config file locations

| Scope | Path |
|---|---|
| Project | `<project>/.ripple/settings.json` |
| Global | `~/.ripple/settings.json` |

Ripple loads both files on startup and merges them. **The project file wins for any key that
appears in both.** This means you can set personal defaults globally (e.g. your API keys and
preferred model) and override them per-project (e.g. a stricter tool policy for a production
repo).

!!! note
    The "project" root is the working directory where you launch Ripple. Sessions, MCP config,
    and tool policy are all scoped to this directory.

---

## Full `settings.json` structure

```json
{
  "models": {
    "open-ai/gpt-5.4-mini": {
      "baseURL": "${OPENAI_BASE_URL:-https://api.openai.com/v1}",
      "model": "gpt-5.4-mini-2026-03-17",
      "apiKey": "$OPENAI_API_KEY",
      "vision": true,
      "reasoning": false,
      "temperature": 0.7,
      "maxTokens": 4096,
      "topP": 0.9,
      "provider": "openai",
      "contextWindow": 128000
    }
  },
  "selectedModel": "open-ai/gpt-5.4-mini",
  "toolPolicy": {
    "disabledMiddleware": ["clipboard"],
    "disabledTools": ["write_file"],
    "approvals": {
      "read_file": "approve",
      "shell": "ask"
    },
    "sandbox": "failover",
    "sandboxImage": "ghcr.io/astral-sh/uv:python3.13-alpine3.23",
    "toolSearch": true,
    "auxiliaryMiddleware": ["git", "text"],
    "auxiliaryTools": ["curl"],
    "coreMCPServers": ["deepwiki"],
    "toolSearchModel": "mlx-community/LFM2.5-ColBERT-350M-8bit",
    "toolSearchLimit": 5
  }
}
```

---

## Top-level keys

### `models`

An object of remote model definitions, keyed by name. Each entry's key is the identifier you use
with `--model` and the `/model` picker; the value is an `OpenAIModelConfig` object that names an
OpenAI-compatible endpoint. Local MLX models do not appear here - they are discovered from the
Hugging Face cache automatically. See [Remote models](../models/remote.md) for the full field
reference and provider-specific examples.

### `selectedModel`

The last planner model chosen with the `/model` picker. Ripple writes this field automatically
when you switch models in the session. You can also set it manually to pre-select a model. The
value is either a Hugging Face id (for a local MLX model) or the key of a registered remote
entry.

### `toolPolicy`

Controls which tools and middleware are active and how tool calls are gated.

| Field | Type | Description |
|---|---|---|
| `disabledMiddleware` | array of strings | Capability middleware ids to disable (e.g. `"clipboard"`, `"screenshot"`) |
| `disabledTools` | array of strings | Tool names to remove from the agent entirely |
| `approvals` | object | Per-tool approval mode: `"ask"`, `"approve"`, or `"deny"` |
| `sandbox` | string | Shell sandbox mode: `"off"`, `"failover"`, or `"container-only"` |
| `sandboxImage` | string | OCI image for the sandbox container |
| `toolSearch` | bool | Turn lazy tool loading on (default `false`) - see [Lazy tools](#lazy-tools) |
| `auxiliaryMiddleware` | array of strings | Capability middleware ids whose tools are auxiliary |
| `auxiliaryTools` | array of strings | Individual tool names to make auxiliary |
| `coreMCPServers` | array of strings | MCP servers to keep **core**; every other server is auxiliary |
| `toolSearchModel` | string | Retrieval model repo id; omit for the lexical retriever |
| `toolSearchLimit` | int | How many tools one `search_tools` call returns (default `5`) |

**Approval modes:**

- `"ask"` (default) - pause and show an approval card each time this tool is called.
- `"approve"` - auto-approve every call without prompting.
- `"deny"` - reject every call without prompting.

**Sandbox modes:**

- `"off"` - all shell commands run in the local shell.
- `"failover"` - run in an Apple Container; fall back to the local shell if the container is
  unavailable.
- `"container-only"` - run in an Apple Container; refuse if the container is unavailable.

See [Sandbox & shell](../sandbox.md) for the full sandbox documentation.

The default sandbox image is `ghcr.io/astral-sh/uv:python3.13-alpine3.23`. Override it with
`sandboxImage` or the `--sandbox-image` flag.

---

## Lazy tools

By default every enabled tool's JSON schema is written into the model's prompt on every query. With
around forty tools that is a large fixed cost paid before the model produces its first token, and
most queries use a handful of them.

Turn `toolSearch` on and tools split into two tiers:

- **Core** tools are in the prompt from the first token. Always callable, and paid for on every
  query.
- **Auxiliary** tools are not in the prompt at all. The agent calls `search_tools` with a
  description of what it needs ("read a file", "check git history"), gets back the matching names and
  signatures, and then calls the tool normally. They cost nothing until they are needed, at the price
  of one extra round the first time.

Auxiliary tools are still gated by their approval mode - the tier decides what is prefilled, not
what is permitted, so you will still see approval cards for tools you did not mark core.

Two tools are always present when the feature is on: `search_tools`, and `run_tool` for a planner
that will not call a tool absent from its own schema.

### Retrievers

`toolSearchModel` picks how `search_tools` ranks tools:

| Value | Behaviour |
|---|---|
| omitted | Lexical - IDF-weighted term overlap. No model, no download. |
| `mlx-community/LFM2.5-ColBERT-350M-8bit` | ColBERT late interaction, ~350 MB resident. The default choice in `/config`. |
| `mlx-community/LFM2.5-ColBERT-350M-bf16` | The same model at full precision, ~700 MB resident. |

The ColBERT retrievers score every query token against every tool token (MaxSim), which reads intent
considerably better than term overlap. They download on first use like any other model.

### Why moving a tier re-prefills once

The rendered tool set is part of Ripple's reusable prompt prefix, so changing which tools are core
invalidates the saved prefix once - the next query after an edit is a cold one, then it is warm
again. Discovering a tool through `search_tools` does *not* do this: the schemas arrive as a tool
result, which appends to the conversation instead of changing the prompt's prefix. See
[Compaction & the prefix cache](compaction.md).

---

## The `/config` editor

Type `/config` in an interactive session to open the configuration overlay. Its tabs are switched
with ←/→ and space acts on the highlighted row:

- **Capabilities** - toggle capability middleware on/off, and the developer message log.
- **Lazy Tools** - turn lazy tools on, pick the retriever and how many matches a search returns, and
  move each toolset and MCP server between core and auxiliary.
- **Sandbox** - the container sandbox mode and its image.
- **Cache** - the prefill cache switch, its limits, and what it is holding per model.

Changes made in `/config` are written back to the project `settings.json`. The MCP tier is stored
there too rather than in `mcp.json`, which may be a shared `.mcp.json` that other tools read.

---

## Legacy `tool-policy.json` migration

Earlier versions of Ripple stored tool policy in a separate file:

```text
<scope>/.ripple/tool-policy.json
```

On first load, Ripple detects this file, migrates its contents into `settings.json` under the
`toolPolicy` key, and removes the old file. No manual intervention is needed. If you have both
files, the migration runs once and the legacy file is deleted.

---

## Related pages

- [Remote models](../models/remote.md) - full `OpenAIModelConfig` schema
- [Sandbox & shell](../sandbox.md) - container lifecycle and shell governance
- [Sessions](sessions.md) - session storage and resuming conversations
- [Context & compaction](compaction.md) - automatic and manual context management
