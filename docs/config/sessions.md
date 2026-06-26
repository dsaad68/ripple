# Sessions

Every Ripple conversation is a session. Sessions are scoped to the working directory where you
launched Ripple, automatically saved on exit, and resumable at any time.

---

## Storage layout

Each session is stored as a directory under:

```text
~/.ripple/sessions/<uuid>/
```

The directory contains three kinds of files:

| File | Description |
|---|---|
| `meta.json` | Session metadata (see below) |
| `messages.jsonl` | Canonical, model-agnostic message history (current state) |
| `history/part-{n}.jsonl` | Originals from older compactions, one file per compaction round |

### `meta.json`

```json
{
  "id": "9f2a1c43-...",
  "projectPath": "/Users/you/my-project",
  "model": "LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16",
  "title": "Refactor the parser module",
  "createdAt": "2026-06-20T10:14:00Z",
  "updatedAt": "2026-06-20T11:02:33Z"
}
```

The **title** is set from the first user message in the session. It appears in the session picker
and in log output. There is no way to rename a session manually - the title is fixed at creation.

The **`projectPath`** is what scopes sessions to a working directory. When you open the session
picker it shows only sessions whose `projectPath` matches your current working directory.

---

## Starting and resuming sessions

### New session (default)

Running `ripple` or `ripple chat` without `--resume` starts a fresh session with a new UUID.

### Session picker

```sh
ripple --resume
```

Bare `--resume` opens an interactive picker showing all sessions for the current project, sorted
most-recent first, with their title and age. Use the arrow keys to navigate and ++enter++ to
resume.

### Resume by id

```sh
ripple --resume 9f2a1c43-...
```

Pass a session UUID directly to skip the picker and resume that specific session. Useful in
scripts or when you know the id from a previous log.

---

## In-session commands

### `/fresh` and `/reset`

Both commands start a new conversation without ending the process. A fresh UUID is minted, the
in-memory history is cleared, and the new session starts recording. The old session remains on
disk and is fully resumable.

Use `/fresh` or `/reset` when you want to begin a different task in the same terminal window
without losing access to the prior conversation.

### `/clear`

Clears the visible terminal output (the scrollback transcript on screen) but does **not** create
a new session. The session id is unchanged, the message history is preserved, and the next turn
continues the existing conversation. This is equivalent to `clear` in a shell - it only affects
what you see.

### `/compact`

Manually triggers context compaction. The older turns in the current session are summarized and
the originals are offloaded to `history/part-{n}.jsonl`. See [Context & compaction](compaction.md).

---

## Compacted sessions

When a session has been compacted (automatically or with `/compact`), the live `messages.jsonl`
contains only the summary plus the recent tail of messages. The full original transcript is
preserved in `history/part-{n}.jsonl`.

When you resume a compacted session, Ripple renders the summary as a transcript note - not as a
fake user prompt - so the context is legible but clearly marked as synthesized. The agent
continues from the compacted state; subsequent turns are appended normally.

The originals in `history/` are never deleted by Ripple. You can inspect them with any JSON
viewer or text editor.

!!! note
    After several rolling compactions a session will have multiple part files:
    `history/part-1.jsonl`, `history/part-2.jsonl`, and so on. The current summary embeds a
    pointer to the `history/` directory so every part stays discoverable.

---

## Related pages

- [Context & compaction](compaction.md) - how and when history is summarized
