# Plan panel & thinking

Ripple surfaces two real-time signals from the agent's internal processing: a **plan panel** that tracks the current todo list, and a **thinking display** that shows the model's reasoning stream as it generates.

---

## Plan panel

The plan panel is pinned just above the chat input and updated live as the agent works through a turn. It shows the agent's current todo list - a structured breakdown of the steps the agent intends to take (and has already completed) for the current request.

The panel header displays a summary line (e.g. "3 of 5 steps done"). Click or press ++enter++ on the header to toggle the panel between expanded (full step list) and collapsed (summary only). Collapsing is useful when the list is long and you want to focus on the agent's output.

### Where the plan comes from

The plan is produced by a **planning middleware** in the DeepAgents framework. This middleware intercepts the agent loop before each tool call, infers the current plan state from the conversation, and updates the todo list. The plan panel reflects that middleware output directly - it is not post-processed or buffered.

Because the plan is derived from the agent's own reasoning, the list may be revised mid-turn as the agent encounters new information (e.g. a file read reveals the problem is different from what was expected). This is expected behavior: the panel shows the agent's live working model of the task, not a static upfront plan.

!!! note
    The plan panel appears only when the planning middleware is active. It is enabled by default in `ripple chat`. You can disable it via `/config` or by adding `"planning"` to `disabledMiddleware` in `toolPolicy`.

---

## Thinking display

When the planner model supports extended thinking (reasoning models and on-device LFM models with thinking enabled), Ripple streams the thinking content live as the model generates it.

During generation, a `thinking...` indicator appears in the chat, with the reasoning text appended below it as tokens arrive. When the model finishes its reasoning phase and begins generating its actual response, the thinking block collapses to a single line:

```
Thought for 4s  ›
```

The collapsed line shows how long the model spent thinking. You can expand it again to re-read the reasoning.

### Why this matters

Thinking output is the model's internal chain-of-thought - it reflects the reasoning steps the model worked through before producing its answer or deciding on a tool call. For debugging unexpected agent behavior, the thinking trace is often the clearest signal: you can see exactly which assumptions the model made, which alternatives it considered, and why it chose a particular tool or answer.

### Performance note

Thinking tokens count against the model's context window and are included in the token estimate shown in the context meter. On a 32k-token on-device model, a long thinking trace can consume a meaningful fraction of the available context. If you're running many long turns, use `/compact` proactively to keep the context meter from climbing too fast.

See [Context & compaction](../config/compaction.md) for details on how the context meter and compaction work.
