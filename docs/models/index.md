# Models (overview)

Ripple supports two classes of planner model: **on-device MLX** models that run entirely on your
Mac, and **remote OpenAI-compatible** models that call an external API. Both are selected through
the same interface and can be swapped at any time without restarting.

---

## On-device MLX models

MLX models run locally on Apple Silicon using the MLX inference stack. No data leaves the machine
and there is no per-token cost. The trade-off is that a large-enough model can consume significant
RAM and the first-token latency is higher than a remote call on a fast connection.

Model ids use the Hugging Face `<provider>/<name>` form, for example:

```text
LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16
```

Models are downloaded from Hugging Face on demand and cached at
`~/.cache/huggingface/hub/`. Ripple never downloads a model silently - it always prompts before
starting a transfer (or requires `--yes`). See [Local MLX models](local.md) for the full download
workflow and the `ripple model` sub-commands.

MLX inference requires Apple Silicon and macOS 26+. On Intel Macs the MLX adapter is unavailable
and you must use a remote model.

---

## Remote models

Remote models are any service that speaks the OpenAI Chat Completions API, including OpenAI
itself, Azure OpenAI, Anthropic (via its OpenAI-compatible proxy), and Amazon Bedrock. They are
defined as named entries in `settings.json` and are available to all projects that share that
config.

Because the call goes over the network, keys and costs live outside your machine, but you get
access to the largest models and the highest context windows. See [Remote models](remote.md) for
the full config schema and provider-specific notes.

---

## How a planner is selected

Ripple resolves the active planner model in this order:

1. **`--model <id>`** flag - highest priority, overrides everything for that session.
2. **`/model` picker** - the in-session overlay; persists the choice to `selectedModel` in
   `settings.json`.
3. **`selectedModel`** in `settings.json` - the last model you picked with `/model`.
4. A built-in default (the smallest available local model, or the first remote entry).

The `--model` value can be either a Hugging Face id for a local MLX model or the `name` field of
a registered remote entry.

### The `/model` picker

Type `/model` at the prompt to open the model overlay. It has three tabs:

=== "Select"

    Presents all available planners - both downloaded local models and registered remote models -
    as a single list. Selecting one makes it active for the session and writes `selectedModel` to
    `settings.json` so the choice persists across restarts. You can also set the idle timeout here.

=== "Local"

    Browse the Hugging Face catalog of MLX-quantized models. Shows download status and size.
    You can trigger a download without leaving the chat. See [Local MLX models](local.md).

=== "Remote"

    Browse OpenRouter's free catalog. Add or remove models from your remote registry.
    See [Remote models](remote.md).

---

## When to use local vs remote

| Consideration | Local MLX | Remote |
|---|---|---|
| Data privacy | Data never leaves the device | Data sent to provider's API |
| Cost | Free (electricity / RAM) | Per-token billing |
| Context window | Typically 4k-32k depending on model | Up to 200k+ |
| First-token latency | Higher (model loaded in RAM) | Lower on fast connections |
| Availability | Works offline | Requires network and valid key |
| Vision | Model-dependent | Provider-dependent |
| Apple Silicon required | Yes | No |

For tasks that handle sensitive code or documents, local models are the natural choice. For long
multi-file refactors, research tasks, or when you need a frontier reasoning model, a remote model
is more practical.

!!! tip
    You can switch models mid-session with `/model` without losing your history or session state.
    The new model picks up exactly where the previous one left off.
