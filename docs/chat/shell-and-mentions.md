# Shell & file mentions

Two shorthand prefixes let you drop out of the agent conversation to run shell commands or pull file content inline, without leaving the chat prompt.

---

## Bang commands (`!` and `!!`)

Prefixing your input with `!` or `!!` runs a shell command directly, bypassing the normal agent turn and the tool approval card. Because you typed the command yourself, Ripple treats it as an explicit intent and does not ask for confirmation.

| Prefix | Where it runs | Approval card |
|---|---|---|
| `!cmd` | Apple Container sandbox (brought up automatically if not already running) | Bypassed |
| `!!cmd` | Local host shell (bypasses the sandbox entirely) | Bypassed |
| `!` (bare) | No-op | N/A |
| `!!` (bare) | No-op | N/A |

Both commands have a **120-second timeout**. If the command does not finish within that window, it is killed and an error is shown.

### `!cmd` - sandbox shell

`!` routes the command through the Apple Container sandbox. If the container is not already running, Ripple brings it up before executing. The container persists for the session - packages you install with `!pip install ...` or `!brew install ...` are available in later `!` commands without reinstalling.

The workspace is mounted at `/workspace` inside the container, so `!ls /workspace` shows your project directory. The sandbox requires Apple Silicon and macOS 26+, and the `container` CLI must be installed. See [Sandbox & shell](../sandbox.md) for full setup details and configuration options.

```text
> !python3 -c "import sys; print(sys.version)"
3.13.2 (main, ...)

> !uname -m
arm64
```

### `!!cmd` - local shell

`!!` sends the command directly to your local shell, completely bypassing the sandbox. Use this when you need access to host tools, environment variables, or paths that aren't inside the container.

```text
> !!git log --oneline -5
34ed508 Merge font-new into main
b9ceebe Fix Thinking chevron
...

> !!echo $HOME
/Users/you
```

!!! warning
    `!!` runs with full host permissions. It bypasses the sandbox and the approval system. The same command will behave differently under `!` (isolated container) vs `!!` (your full host environment).

### Why bang commands bypass approval

The approval system exists to let you review tool calls the agent initiates on your behalf. A `!` or `!!` command is an explicit, user-authored instruction - the intent is unambiguous, so no confirmation step is needed. The agent does not see bang commands as tool calls; they are handled directly by the chat screen.

---

## `@file` mentions

Type `@` at the start of or anywhere within your message to fuzzy-match files in the current working directory. Ripple presents a filterable list as you type; select a file with ++arrow-up++ / ++arrow-down++ and press ++enter++ or ++tab++ to insert it. The file's content is inlined into your message before it is sent to the agent.

```text
> Explain what @src/Agent.swift does and suggest improvements
```

This is useful when you want the agent to read a specific file without going through a tool call - the content arrives in the user turn itself rather than via `read_file`.

!!! tip
    `@` mentions are resolved from the working directory you launched Ripple from. They work alongside the agent's own `read_file` tool, which the agent can invoke autonomously. Use `@` when you know exactly which file you want to discuss up front.

### Fuzzy matching

The matcher filters files by the characters you type after `@` - you don't need to type a full path. Typing `@agent.sw` will match `src/Agent.swift`, `Sources/Agents/AgentLoop.swift`, and so on. The list is scoped to the project directory and excludes hidden and binary files.
