# MCP servers

Ripple can use tools from [Model Context Protocol](https://modelcontextprotocol.io) servers - the
same open standard the Mispher app supports. Since Ripple has no settings UI, you configure servers
in **JSON files** using the **Claude Code `mcpServers` schema**. Configured servers' tools join the
main agent, namespaced by server name, and you can inspect them live with `/mcp` inside
`ripple chat`.

---

## Where Ripple reads config

When you run `ripple chat` (or bare `ripple`), MCP config is loaded by **merging** three files in
order. The **first definition** of a given server name wins:

| Priority | Path | Purpose |
|---|---|---|
| 1 (highest) | `<project>/.mcp.json` | Standard Claude Code project file; commit with the repo |
| 2 | `<project>/.ripple/mcp.json` | Ripple's own project-scoped config |
| 3 (lowest) | `~/.ripple/mcp.json` | Global fallback for all projects |

`<project>` is the working directory you launch Ripple from. A missing file is silently skipped, so
you can use any subset of the three locations.

!!! tip "Sharing config with Claude Code"
    If your team already uses `.mcp.json` for Claude Code, Ripple picks it up automatically - no
    duplication needed.

---

## Config format

A top-level `mcpServers` object keyed by server name. Each entry describes one server:

=== "HTTP server"

    ```json
    {
      "mcpServers": {
        "search": {
          "type": "http",
          "url": "https://search.parallel.ai/mcp",
          "approvalMode": "ask"
        },
        "api-server": {
          "type": "http",
          "url": "${API_BASE_URL:-https://api.example.com}/mcp",
          "headers": { "Authorization": "Bearer ${API_KEY}" }
        }
      }
    }
    ```

=== "stdio server"

    ```json
    {
      "mcpServers": {
        "filesystem": {
          "command": "/opt/homebrew/bin/npx",
          "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/work"],
          "env": {}
        }
      }
    }
    ```

=== "OAuth server"

    ```json
    {
      "mcpServers": {
        "my-oauth-server": {
          "type": "http",
          "url": "https://mcp.example.com/mcp"
        }
      }
    }
    ```

    You usually **don't** need an `oauth` key. Like Claude Code, Ripple discovers that an HTTP
    server needs sign-in from its `401` challenge at connect time - a plain `{"type":"http","url":…}`
    entry that requires auth shows up in `/mcp` as "press r to sign in". Add an explicit `"oauth": {}`
    only to *force* the OAuth flow (skipping the probe), e.g. pinning the authorization server:

    ```json
    "my-oauth-server": {
      "type": "http",
      "url": "https://mcp.example.com/mcp",
      "oauth": { "authServerMetadataUrl": "https://auth.example.com/.well-known/oauth-authorization-server" }
    }
    ```

    A server with a static `"Authorization"` header is treated as header auth, not OAuth - Ripple
    never offers it the sign-in flow.

### Field reference

| Key | Type | Description |
|---|---|---|
| `type` | `"http"` \| `"sse"` \| `"stdio"` | Transport. Inferred from presence of `url` or `command` when omitted. |
| `url` | string | Endpoint URL for HTTP/SSE servers. |
| `headers` | object | HTTP headers sent with every request (e.g. a Bearer token). |
| `command` | string | Absolute path to the stdio server executable. |
| `args` | string[] | Arguments passed to `command`. |
| `env` | object | Extra environment variables for the subprocess. |
| `oauth` | object | **Optional.** Forces the browser OAuth flow even before a `401` is seen. Empty `{}` uses discovery; `{ "authServerMetadataUrl": "…" }` pins the authorization server. Omit it to let Ripple auto-detect auth from the server's `401` (Claude Code-style). |
| `approvalMode` | `"approve"` \| `"ask"` \| `"deny"` | Per-server approval policy (Ripple extension; default `ask`). Omit for full Claude Code schema compatibility. |

!!! warning "stdio: use absolute paths"
    Always specify `command` as an absolute path. Ripple does not inherit your shell's `$PATH`.
    The server's stderr is captured to `$TMPDIR/mispher-mcp-<name>.log` for debugging.

### Environment variable expansion

Any string value in the config may use `${VAR}` or `${VAR:-default}`. Values are expanded from
the process environment at load time - keys are never written to disk.

```sh
# Pass a secret at launch time rather than hardcoding it
API_KEY=sk-... ripple chat
```

`${VAR:-default}` substitutes `default` when `VAR` is unset or empty. This is useful for optional
overrides: `"${API_BASE_URL:-https://api.example.com}/mcp"` uses the production URL unless you set
`API_BASE_URL` in your shell.

---

## Per-server approval modes

Each MCP server has an independent `approvalMode` that controls how its tools are gated during a
session:

| Mode | Behavior |
|---|---|
| `approve` | Tools run immediately with no prompt. Use for trusted, read-only servers. |
| `ask` | **(default)** Ripple pauses before every call and shows an approval card. |
| `deny` | Every call is rejected automatically - the server's tools are effectively disabled. |

Inside `ripple chat`, when an `ask` tool fires, respond with:

- `a` / `y` to approve
- `r` / `d` / `n` to reject

Press ++tab++ to cycle the global permission mode for the session (ask - auto-reads - plan -
accept-all). See [Approvals & permission modes](chat/approvals.md) for the full interaction model.

---

## Disabling capabilities

To turn off built-in capabilities or specific tools, set `toolPolicy` in
`.ripple/settings.json` (project) or `~/.ripple/settings.json` (global). See
[Configuration](config/index.md) for the full schema. For example, to disable clipboard
middleware and prevent any write operations:

```json
{
  "toolPolicy": {
    "disabledMiddleware": ["clipboard"],
    "disabledTools": ["write_file"],
    "approvals": {
      "read_file": "approve",
      "shell": "ask"
    }
  }
}
```

---

## Inspecting servers: `/mcp`

Inside `ripple chat`, type `/mcp` to open the MCP overview:

- **Level 1 - servers:** one row per configured server showing its transport, auth status, and
  approval mode (e.g. `search   HTTP - approval: Ask`).
- **Level 2 - tools:** press ++enter++ on a server to see all its tools with descriptions.

From the server list:

- `r` - start the OAuth sign-in flow for the highlighted server. Works for any HTTP server that
  needs auth - whether you declared `"oauth": {}` or Ripple discovered the requirement from a `401`.
  A server that needs sign-in is flagged in yellow ("press r to sign in"); the `r` / `x` hints in the
  footer only appear when the highlighted row can actually sign in.
- `x` - log out (remove the stored token from Keychain).

!!! tip
    `/tools` lists *all* agent tools (built-in + MCP) grouped by capability. Use `/mcp` when you
    specifically need to inspect or manage individual server connections.

---

## OAuth sign-in

For any HTTP server that requires OAuth - configured with `"oauth": {}` **or** auto-detected from its
`401` challenge - Ripple uses a browser loopback flow:

1. When the server challenges the connection, your default browser opens automatically.
2. You complete sign-in on the provider's page.
3. The browser redirects to `localhost` - Ripple captures the token.
4. The token is saved to your macOS **Keychain** under service `ai.ripple.mcp.oauth`.

No custom URL scheme or redirect setup is needed. Tokens persist across sessions; use `x` in the
`/mcp` browser to log out.

---

## Example: connect to a remote search server

Create `.ripple/mcp.json` in your project directory:

```json
{
  "mcpServers": {
    "parallel-search": {
      "type": "http",
      "url": "https://search.parallel.ai/mcp",
      "approvalMode": "ask"
    }
  }
}
```

Then start a session:

```sh
ripple chat
```

Inside the REPL:

```text
> /mcp
# parallel-search   HTTP - approval: Ask
#   web_search      Search the web for current information
#   web_fetch       Fetch and extract content from a URL

> Search the web for the latest Swift concurrency proposals
# [approval card appears for parallel-search__web_search]
# a
# [agent proceeds with results]
```

!!! info "Anonymous vs. authenticated endpoints"
    Parallel's `/mcp` endpoint works anonymously. Its authenticated endpoint (`/mcp-oauth`) uses
    `"oauth": {}` or a `Bearer` header.

---

## Troubleshooting

**A server shows no tools in `/mcp`.**
The server connected but advertised no tools, or its endpoint requires auth. If it needs OAuth,
Ripple flags it in yellow ("press r to sign in") - highlight the row and press `r`. Per-server
connection failures are logged and skipped - one bad server will not prevent the others from loading.

**A stdio server won't start.**
Check that `command` is an absolute path and the binary is executable. The server's stderr goes to
`$TMPDIR/mispher-mcp-<name>.log` - inspect that file first.

**Tools appear but calls always fail.**
Verify your `headers` or env vars contain the expected credentials. Run `API_KEY=... ripple chat`
to confirm the expansion works.

**OAuth sign-in page opens but Ripple doesn't capture the token.**
Make sure nothing else is listening on the loopback port Ripple uses for the redirect. Quit and
retry.

---

## See also

- [Slash commands](chat/slash-commands.md) - `/mcp`, `/tools`, `/config`
- [Approvals & permission modes](chat/approvals.md)
- [Configuration](config/index.md)
- [Model Context Protocol spec](https://modelcontextprotocol.io)
