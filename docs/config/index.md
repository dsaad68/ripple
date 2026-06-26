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
  "models": [
    {
      "name": "gpt4o",
      "baseURL": "https://api.openai.com/v1",
      "model": "gpt-4o",
      "apiKey": "${OPENAI_API_KEY}",
      "vision": true,
      "reasoning": false,
      "temperature": 0.7,
      "maxTokens": 4096,
      "topP": 0.9,
      "provider": "openai",
      "contextWindow": 128000
    }
  ],
  "selectedModel": "gpt4o",
  "toolPolicy": {
    "disabledMiddleware": ["clipboard"],
    "disabledTools": ["write_file"],
    "approvals": {
      "read_file": "approve",
      "shell": "ask"
    },
    "sandbox": "failover",
    "sandboxImage": "ghcr.io/astral-sh/uv:python3.13-alpine3.23"
  }
}
```

---

## Top-level keys

### `models`

An array of remote model definitions. Each entry is an `OpenAIModelConfig` object that names an
OpenAI-compatible endpoint. Local MLX models do not appear here - they are discovered from the
Hugging Face cache automatically. See [Remote models](../models/remote.md) for the full field
reference and provider-specific examples.

### `selectedModel`

The last planner model chosen with the `/model` picker. Ripple writes this field automatically
when you switch models in the session. You can also set it manually to pre-select a model. The
value is either a Hugging Face id (for a local MLX model) or the `name` of a registered remote
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

## The `/config` editor

Type `/config` in an interactive session to open the configuration overlay. It lets you toggle
middleware, change the sandbox mode, set logging, and review tool policy without editing the JSON
file by hand. Changes made in `/config` are written back to the project `settings.json`.

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
