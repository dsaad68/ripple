# Local MLX models

Ripple can run any MLX-quantized model from Hugging Face directly on your Mac. All inference
happens on-device via Apple Silicon's unified memory architecture - no network call, no API key,
no token cost.

---

## Model id format

Local model ids follow the Hugging Face `<provider>/<name>` convention exactly:

```text
LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16
LiquidAI/LFM2.5-8B-Instruct-MLX-bf16
```

The same id is used everywhere: `--model`, the `/model` picker, and `ripple model pull`.

---

## Hugging Face cache

Downloaded models land in the standard Hugging Face hub cache:

```text
~/.cache/huggingface/hub/
```

Ripple does not maintain its own model store. If you already have a model cached (by `huggingface_hub`,
the Python `transformers` library, or `hf` CLI), Ripple will find and use it without re-downloading.

---

## Managing models with `ripple model`

The `ripple model` sub-command (alias `ripple models`) covers listing, downloading, and removing
local MLX models.

### List downloaded models

```sh
ripple model list
ripple model ls          # alias
```

Prints every model currently in the Hugging Face cache that Ripple recognizes, along with its
disk footprint.

### Download models

```sh
ripple model pull LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16
ripple model download <id>   # alias
ripple model get <id>        # alias
```

You can pass multiple ids in one command:

```sh
ripple model pull LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16 LiquidAI/LFM2.5-8B-Instruct-MLX-bf16
```

Two special variant names are also accepted:

| Variant | Meaning |
|---|---|
| `default` | The recommended starter model (currently LFM2.5 1.2B bf16) |
| `all` | Every model in Ripple's built-in catalog |

```sh
ripple model pull default     # download the recommended model
ripple model pull all         # download the full catalog
```

### Remove models

```sh
ripple model rm LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16
ripple model remove <id>      # alias
ripple model delete <id>      # alias
```

This removes the model from `~/.cache/huggingface/hub/`. The id must match exactly.

---

## The `/model` Local tab

Inside an interactive session, type `/model` and switch to the **Local** tab. It shows the
Hugging Face catalog of supported MLX models with their size and download status. You can start a
download directly from the picker without leaving the chat. Progress is shown inline; once
complete the model becomes immediately selectable in the **Select** tab.

---

## Download-on-run behavior

Ripple does **not** silently download a model when you start a session or pass `--model`. The
behavior depends on whether you are running interactively or headlessly:

**Interactive (`ripple chat` or bare `ripple`):** Ripple detects the missing model before the
session starts and prompts:

```text
Model LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16 is not downloaded. Download now? [y/N]
```

Answer `y` to download, `n` to abort. Pass `--yes` (or `--download`) to skip the prompt and
download automatically:

```sh
ripple --model LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16 --yes
```

**Headless (`ripple -p "..."`):** If the model is missing and `--yes` is not set, Ripple prints
a hint and exits with a non-zero status. Headless runs are designed for scripting and pipelines
where an unexpected interactive prompt would hang. Pass `--yes` to allow the download:

```sh
ripple -p "summarize README.md" --model LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16 --yes
```

!!! warning
    In CI or other non-interactive environments always pre-fetch models before running Ripple
    (see below), or pass `--yes` explicitly. Without `--yes` a headless run against a missing
    model will fail immediately.

---

## Pre-fetching with `hf download`

For scripts or CI pipelines, pre-fetch a model with the Hugging Face CLI so it is already in
the cache when Ripple starts:

```sh
hf download LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16
```

Install the CLI with `pip install huggingface_hub` or `uv tool install huggingface_hub` if you
do not already have it. The model lands in `~/.cache/huggingface/hub/` and Ripple will use it
without prompting.

---

## Requirements

- Apple Silicon (arm64) - MLX does not run on Intel Macs.
- macOS 26 (Tahoe) or later.
- Sufficient RAM: the 1.2B bf16 model needs roughly 2-3 GB; the 8B model needs 10-16 GB.

See [Installation](../getting-started/installation.md) for the full setup checklist.
