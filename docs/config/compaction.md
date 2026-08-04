# Context & compaction

Long conversations eventually approach a model's context window limit. On the 32k-token on-device
LFM models this overflows quickly; on cloud models it silently inflates cost and latency. Ripple
handles this with a **summarization middleware** that compacts older turns into a single summary
while keeping the most recent turns verbatim.

---

## The context meter

The status line at the bottom of the chat shows a context meter: the percentage of the active
model's context window currently occupied by the conversation history, the system prompt, and the
tool schemas. Tool schemas are included because the model re-reads them on every turn - a session
with many tools compacts at the right time rather than overflowing while the raw message count
still looks small.

Token counts are approximate (roughly 4 characters per token, uniform across all backends, since
no backend exposes a live tokenizer counter). The 15% headroom below the trigger threshold is
sized to absorb this imprecision.

---

## Automatic compaction

Ripple automatically compacts the conversation when the context meter reaches **85%** of the
model's context window. The compaction happens transparently before the next model call: the
trimmed history is both what the model receives for that turn and what gets persisted to disk.

You will see a dim transcript note with the before/after token sizes and the path where the
originals were saved. The context meter drops noticeably after compaction.

---

## Manual compaction

Type `/compact` at any time to compact immediately, regardless of the current context size. This
is useful when you are about to start a long tool-calling sequence and want to reclaim headroom
proactively, or when you want to reduce cost on a remote model mid-session.

---

## What the rewritten history looks like

After compaction the conversation history becomes:

```
[ summary turn    ]   -- a condensed summary of the evicted older turns
[ acknowledgment  ]   -- a short synthetic "understood, continuing" assistant turn
[ recent tail     ]   -- the most recent turns, kept verbatim
```

**The summary is stored as a human turn**, not a system or tool turn. This matches the
LangChain convention and is required in practice: a second system message mid-history is rejected
by some providers and breaks the local LFM2 chat template. The turn is tagged
(`source == "summarization"`) so a later compaction recognizes it and folds it into the next
summary rather than treating it as original content.

**The acknowledgment turn** keeps the human/assistant role alternation that Anthropic's API
requires.

**Rolling compaction:** each subsequent automatic compaction folds the prior summary plus the
next block of messages into a fresh summary. The history stays in `[summary] + tail` form
indefinitely, no matter how long the session runs.

### How the tail is bounded

The tail keeps the most recent turns subject to two independent limits, whichever is more
restrictive:

| Limit | Default | Meaning |
|---|---|---|
| `keepRecentMessages` | 6 | Maximum number of messages in the tail |
| `keepRecentFraction` | 0.25 | Maximum tail size as a fraction of the context window |

The cut is then snapped to a user-turn boundary so the tail never starts on an orphan tool result
and an assistant tool call is never split from its response.

---

## Originals are preserved

Before the summary replaces the older messages, the evicted originals are written to disk:

```text
~/.ripple/sessions/<id>/history/part-{n}.jsonl
```

One part file is created per compaction round (`part-1.jsonl`, `part-2.jsonl`, ...). The current
summary embeds a pointer to the `history/` directory so every part stays discoverable across
multiple rolling compactions.

The offload happens **only after** a valid, shrinking summary is produced. A failed or no-op
compaction (one where the summary is not smaller than what it replaces) leaves the history
untouched and does not create a part file. The live `messages.jsonl` and the parts are always in
sync.

!!! note
    A compaction is rejected as a no-op if the summary it generates would not actually reduce the
    history size. Re-running a compaction that cannot shrink anything further does nothing.

---

## `SummarizationConfig` knobs

The middleware is wired in by default. Its tunable parameters are:

| Knob | Default | Meaning |
|---|---|---|
| `triggerFraction` | `0.85` | Context-window fraction at which automatic compaction fires |
| `fallbackContextWindow` | `32768` | Window assumed when the model does not report one |
| `keepRecentMessages` | `6` | Upper bound on how many recent messages the tail keeps |
| `keepRecentFraction` | `0.25` | Token ceiling on the tail as a fraction of the window |
| `reservedOutputTokens` | `4096` | Tokens reserved for the summary's own generation |
| `summaryPrompt` | (built-in) | Instruction given to the model when generating the summary |

The built-in summary prompt asks the model to preserve: the user's goals and constraints, key
decisions and their reasoning, files and artifacts created or modified (with paths), important
facts learned from tool calls, and the current state plus what remains to do.

---

## Known limitations

**Approximate token accounting.** The char-based estimate can drift from the true token count.
The 15% headroom is intended to cover this, but very dense content (code, JSON) may compact
slightly later than expected.

**Message granularity.** Compaction cuts at message boundaries and cannot split a single message.
One very large message (e.g. a massive tool result) resists eviction. The existing 6000-character
tool-result truncation in the agent mitigates the most common cause of this.

**Single-turn boundary.** A conversation that has only one user-turn boundary (a single request
driving a very long tool-calling chain with no subsequent user messages) cannot compact until
another user turn exists. Normal multi-turn chat self-heals as each new message adds a fresh
boundary.

**Images.** The summarizer produces text only, so image context from earlier turns is not carried
into the summary. Images are also not counted toward the context trigger. Vision conversations
that include many images earlier in the session will lose that visual context after compaction.

---

## Related pages

- [Sessions](sessions.md) - session layout and part files
- [Plan panel & thinking](../chat/plan-and-thinking.md) - the status line and context meter display
