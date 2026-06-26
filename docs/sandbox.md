# Sandbox & shell

Ripple can execute shell commands in two environments: the **local shell** (your macOS environment)
and an **[Apple Container](https://github.com/apple/container) sandbox** (an isolated, ephemeral
Linux container). The sandbox mode controls which environment the agent uses, and whether a
fallback is permitted.

!!! info "Built on Apple Container"
    The sandbox is powered by [Apple's `container`](https://github.com/apple/container), an
    open-source tool for running Linux containers on Mac (Apple Silicon, macOS 26+). Install it
    before using `failover` or `container-only` mode.

---

## Sandbox modes

| Mode | Value | Behavior |
|---|---|---|
| Off | `off` | **(default)** All shell commands run in the local macOS shell. No container is started. |
| Failover | `failover` | Commands run in the container. If the container is unavailable (CLI not installed, Apple Silicon missing), Ripple falls back to the local shell. |
| Container only | `container-only` | Commands run in the container. If the container is unavailable, Ripple refuses and prints an error - no fallback. |

Choose `container-only` when you want a hard guarantee that the agent never touches your local
filesystem or tools. Use `failover` as a softer default that degrades gracefully on machines that
don't have the container CLI installed.

---

## Setting the sandbox mode

There are three ways to configure the sandbox, evaluated in priority order:

=== "CLI flag"

    ```sh
    # Explicit mode
    ripple chat --sandbox failover
    ripple chat --sandbox container-only

    # Bare --sandbox defaults to failover
    ripple chat --sandbox
    ```

=== "settings.json"

    In `.ripple/settings.json` (project) or `~/.ripple/settings.json` (global):

    ```json
    {
      "toolPolicy": {
        "sandbox": "failover"
      }
    }
    ```

=== "/config in chat"

    Type `/config` inside `ripple chat` to open the capabilities panel, where sandbox mode is
    a toggle. Changes are written to the project-scoped `settings.json` and take effect for the
    next session.

The CLI flag overrides `settings.json`, which overrides the built-in default (`off`). See
[Configuration](config/index.md) for the full `settings.json` schema.

---

## Custom container image

The default container image is `ghcr.io/astral-sh/uv:python3.13-alpine3.23` - a minimal Alpine
image with Python 3.13 and `uv` (a fast Python package manager) pre-installed.

To use a different image, set `sandboxImage`:

=== "CLI flag"

    ```sh
    ripple chat --sandbox-image ghcr.io/myorg/my-image:latest
    ```

=== "settings.json"

    ```json
    {
      "toolPolicy": {
        "sandbox": "failover",
        "sandboxImage": "ghcr.io/myorg/my-image:latest"
      }
    }
    ```

The image must be available to the `container` CLI (pulled or in the local store). Any OCI-
compatible image works; the only requirement is that it runs on `linux/arm64`.

---

## Container lifecycle

Ripple manages the container lazily and reuses it for the whole session:

1. **Lazy start** - the container is created the first time a command needs it
   (`ensureRunning()`). No container is started unless sandbox mode is enabled and a
   shell command fires.
2. **Persistent for the session** - the same container is reused for all subsequent commands.
   Packages you install with `pip install` or `apk add` inside the container remain available
   for the rest of the session.
3. **Workspace mount** - your working directory is mounted at `/workspace` inside the container.
   Files you create or modify under `/workspace` are reflected on the host.
4. **Torn down on exit** - the container is stopped when Ripple exits. State that lives outside
   `/workspace` (e.g. installed packages) is discarded.

!!! note "Installed packages do not persist across sessions"
    Because the container is recreated each session, any packages installed at runtime are lost
    when Ripple exits. For a stable environment, bake your dependencies into a custom image.

---

## Requirements

| Requirement | Details |
|---|---|
| Apple Silicon | The `container` CLI and Apple's virtualization layer require arm64. |
| macOS 26+ (Tahoe) | Minimum OS for the `container` CLI. |
| `container` CLI | Install [Apple's `container`](https://github.com/apple/container). Ripple delegates all lifecycle operations to it. |

If any requirement is unmet and mode is `failover`, Ripple falls back to the local shell and logs
a warning. If mode is `container-only`, Ripple refuses to run.

---

## Bang commands

In addition to tool-invoked shell calls, you can run commands directly from the `ripple chat`
input line using bang syntax:

| Prefix | Target | Notes |
|---|---|---|
| `!command` | Container sandbox | Container is brought up if not running. |
| `!!command` | Local shell | Always bypasses the sandbox, regardless of mode. |

Both variants bypass the approval card - because you typed the command yourself, Ripple treats it
as implicit approval. Each has a 120-second timeout.

Bare `!` or `!!` (no command text) does nothing.

See [Shell & file mentions](chat/shell-and-mentions.md) for more on inline shell interaction.

---

## Sandbox and approvals

When sandbox mode is enabled, agent-initiated shell calls are still subject to the approval system:

- In `ask` mode, every shell call shows an approval card (approve / reject / edit).
- In `auto-reads` mode, file reads are auto-approved; shell writes prompt.
- In `accept-all` mode, everything runs without prompting.

Bang commands (`!` / `!!`) are **not** gated by approvals because they are user-initiated.

See [Approvals & permission modes](chat/approvals.md) for the full permission model.

---

## See also

- [Shell & file mentions](chat/shell-and-mentions.md) - bang commands, `@file` mentions
- [Approvals & permission modes](chat/approvals.md)
- [Configuration](config/index.md)
- [Command reference](reference/commands.md) - `--sandbox`, `--sandbox-image` flags
