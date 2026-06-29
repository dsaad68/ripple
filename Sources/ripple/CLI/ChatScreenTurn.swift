import DeepAgents
import DeepAgentsMLX
import Foundation
import MLX

// Running a turn in `ripple chat`: submitting the prompt, driving the deep agent, gating its tool
// calls (the approval cards + permission modes), switching the planner, and the busy/intro
// animations. Split out of ChatScreen to keep that file within budget; the model types live in
// ChatScreenModel.
extension ChatScreen {
    // MARK: - Approvals

    /// Keys while a tool call awaits the user: a/y approve, r/d/n reject, A always-allow this tool,
    /// Enter confirms the highlighted choice, arrows move it, Ctrl-C stops the turn. Others ignored.
    func handleApprovalByte(_ byte: UInt8) {
        switch byte {
        case 0x1B: pendingEsc = true // arrow keys (consumed as a CSI sequence) move the selection
        case 0x0D, 0x0A: confirmApproval()
        case 0x61, 0x79: resolveApproval(.approve) // a / y
        case 0x72, 0x64, 0x6E: resolveApproval(.reject(message: nil)) // r / d / n
        case 0x41: alwaysAllow() // A: approve and remember this tool for the session
        case 0x65: beginEditingApproval() // e: edit the command before running (shell only)
        case 0x03: cancelTurn() // Ctrl-C stops the whole turn
        case 0x04: quit = true // Ctrl-D
        default: break
        }
    }

    func confirmApproval() {
        switch approvalSelection {
        case 1: resolveApproval(.reject(message: nil))
        case 2: if gate.pending?.toolName == "shell" { beginEditingApproval() } else { alwaysAllow() }
        default: resolveApproval(.approve)
        }
    }

    func alwaysAllow() {
        guard gate.pending?.toolName != "shell" else { return } // shell can't be one-key allowlisted
        if let tool = gate.pending?.toolName { allowlist.insert(tool) }
        resolveApproval(.approve)
    }

    func resolveApproval(_ decision: ToolApprovalDecision) {
        approvalSelection = 0
        editingApproval = nil
        gate.resolve(decision)
    }

    /// Load the pending shell command into the input box for editing. A no-op for tools that don't
    /// allow the edit decision.
    func beginEditingApproval() {
        guard let request = gate.pending, request.allowedDecisions.contains(.edit),
              case .string(let command)? = request.arguments["command"] else { return }
        editingApproval = request
        setInput(command)
    }

    /// Abandon the edit and return to the approval card with the original command intact.
    func cancelEditingApproval() {
        editingApproval = nil
        clearInput()
    }

    /// Resolve the pending call with the edited command (preserving its other arguments). An empty
    /// edit just cancels back to the card.
    func submitEditedApproval(_ request: ToolApprovalRequest) {
        let edited = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !edited.isEmpty else { cancelEditingApproval(); return }
        var arguments = request.arguments
        arguments["command"] = .string(edited)
        clearInput()
        resolveApproval(.edit(arguments: arguments))
    }

    /// The pending card offers three choices - Approve / Reject and a third (Edit for shell, "always
    /// allow" otherwise). Drives the arrow-key wraparound.
    var approvalChoiceCount: Int { 3 }

    /// Seed a freshly-arrived approval's selection - Reject for the loud shell card, Approve
    /// otherwise. Only re-seeds when the pending call changes, so it never clobbers navigation on
    /// the redraws ``ApprovalGate/onChange`` fires.
    func seedApprovalSelection() {
        let id = gate.pending?.id
        guard id != lastApprovalID else { return }
        lastApprovalID = id
        approvalSelection = (gate.pending?.toolName == "shell") ? 1 : 0
    }

    // MARK: - Permission mode

    /// The auto-decision for a gated call, or nil to prompt the user. Allowlisted tools and the
    /// current permission mode resolve calls without a card ever showing.
    func autoDecision(for request: ToolApprovalRequest) -> ToolApprovalDecision? {
        if allowlist.contains(request.toolName) { return .approve }
        return permissionMode.decision(for: request.toolName)
    }

    /// Tab / Shift-Tab cycle the mode. Landing on "accept all" arms it; a second Tab confirms (the
    /// loud one-step guard), and Esc disarms.
    func cyclePermissionMode(reverse: Bool) {
        if pendingYolo { permissionMode = .acceptAll; pendingYolo = false; return }
        let modes = PermissionMode.allCases
        let index = modes.firstIndex(of: permissionMode) ?? 0
        let next = modes[(index + (reverse ? modes.count - 1 : 1)) % modes.count]
        if next == .acceptAll { pendingYolo = true } else { permissionMode = next; pendingYolo = false }
    }

    // MARK: - Turn lifecycle

    /// Cancel the in-flight turn (Esc / Ctrl-C while generating). `runTurn` sees the cancellation,
    /// stops consuming, and re-enables the input; the model finishes in the background and is dropped.
    /// Any approval the run is suspended on is rejected first so the producer can unwind.
    func cancelTurn() {
        editingApproval = nil
        gate.resolve(.reject(message: "The turn was cancelled."))
        askUserEditing = false
        askGate.resolve(.cancelled) // unblock the agent if it's suspended on an ask_user prompt
        currentTurn?.cancel()
    }

    func submit() {
        guard !busy else { return }
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        if history.last != prompt { history.append(prompt) } // shell-style recall (no consecutive dupes)
        if prompt.hasPrefix("!") { startBang(prompt); return } // `!cmd` / `!!cmd`: run it directly
        switch prompt.lowercased() {
        case "/exit", "/quit": quit = true; return
        case "/model": clearInput(); openModelHub(); return
        case "/models-config": clearInput(); openModelHub(tab: .local); return // retired alias -> the Local tab
        case "/tools": clearInput(); toolsBrowser = makeToolsBrowser(); toolsScrollTop = true; return
        case "/mcp": clearInput(); toolsBrowser = makeMCPBrowser(); toolsScrollTop = true; return
        case "/config": clearInput(); config = makeConfigEditor(); return
        case "/compact": clearInput(); startCompact(); return
        case "/help": clearInput(); help = true; return
        case "/fresh", "/reset": // `/reset` kept as an alias
            // A new resumable session: mint a fresh id (so the store + log target a new
            // `~/.ripple/sessions/<id>`) and rebuild the agent so both retarget; the prior session
            // stays on disk, resumable with `ripple --resume`.
            sessionContext.id = UUID().uuidString
            messages.removeAll(); invalidateTranscriptCache()
            contextChars = 0; scrollOffset = 0; clearPlan(); clearInput(); rebuildAgent(); return
        case "/clear": messages.removeAll(); invalidateTranscriptCache(); scrollOffset = 0; clearPlan(); clearInput(); return
        default: break
        }
        clearInput()
        scrollOffset = 0
        clearPlan() // a new task starts plan-less; the agent repopulates the panel as it writes todos
        messages.append(Message(kind: .user(prompt)))
        contextChars += prompt.count
        sessionTokens += max(1, prompt.count / 4) // rough prompt-token estimate for the context meter
        let assistant = Assistant()
        messages.append(Message(kind: .assistant(assistant)))
        liveAssistant = assistant
        running = true
        turnStart = Date()
        startSpinner()
        let agent = agent
        let threadId = threadId
        currentTurn = Task { await self.runTurn(prompt: prompt, into: assistant, agent: agent, threadId: threadId) }
    }

    /// Drop the pinned plan (a new task, or a cleared / fresh conversation, starts without one).
    func clearPlan() { plan.removeAll(); planCollapsed = false }

    // MARK: - Compaction

    /// `/compact`: summarize the older turns now (the same rolling compaction the 85% trigger runs),
    /// freeing the context window. Drives ``ReactAgent/compact(threadId:)`` off the main loop behind
    /// the "compacting context…" indicator, then drops a transcript note with the before/after sizes.
    func startCompact() {
        guard !busy, !messages.isEmpty else { return }
        scrollOffset = 0
        compacting = true
        turnStart = Date()
        startSpinner()
        let agent = agent
        let threadId = threadId
        currentTurn = Task { await self.runCompact(agent: agent, threadId: threadId) }
    }

    func runCompact(agent: ReactAgent, threadId: String) async {
        let outcome = await agent.compact(threadId: threadId)
        compacting = false
        turnStart = nil
        currentTurn = nil
        spinnerTask?.cancel()
        if let outcome {
            sessionTokens = outcome.tokensAfter
            contextChars = outcome.tokensAfter * 4 // keep the char proxy roughly in step with the meter
            messages.append(Message(kind: .note(Self.compactionNote(outcome))))
        } else {
            messages.append(Message(kind: .note("Nothing to compact yet.")))
        }
        invalidateTranscriptCache()
        requestRender()
        MLX.Memory.clearCache()
    }

    /// Insert an automatic-compaction note just before this round's streaming assistant turn, so the
    /// transcript reads in order (earlier turns, the compaction, then this answer), and drop the meter.
    func noteAutoCompaction(before: Int, after: Int) {
        sessionTokens = after
        contextChars = after * 4
        let note = Message(kind: .note(
            "Context compacted automatically: \(Self.tokens(before)) -> \(Self.tokens(after)) tokens "
                + "(older turns summarized; originals saved to this session's history)."
        ))
        messages.insert(note, at: max(0, messages.count - 1))
        invalidateTranscriptCache()
    }

    /// The `/compact` result note: the before/after sizes and where the originals were saved.
    static func compactionNote(_ outcome: CompactionOutcome) -> String {
        var note = "Context compacted: \(tokens(outcome.tokensBefore)) -> \(tokens(outcome.tokensAfter)) tokens."
        if let path = outcome.archivePath { note += " Original messages saved to \(path)." }
        return note
    }

    /// A compact token count for a note, e.g. `31.2k` or `840`.
    static func tokens(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    // MARK: - Bang commands

    /// A command typed with a bang prefix, run directly instead of sent to the agent: `!!cmd` in the
    /// local shell, `!cmd` in the container sandbox. It bypasses the approval card (the user typed it
    /// themselves), streams its output into the transcript, and locks the input like a turn until it
    /// finishes. A bare `!` / `!!` does nothing.
    func startBang(_ raw: String) {
        let local = raw.hasPrefix("!!")
        let command = String(raw.dropFirst(local ? 2 : 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { clearInput(); return }
        clearInput()
        scrollOffset = 0
        let bang = BangCommand(command: command, target: local ? .local : .container)
        messages.append(Message(kind: .bang(bang)))
        running = true
        turnStart = Date()
        startSpinner()
        currentTurn = Task { await self.runBang(bang) }
    }

    /// Run the bang command off the main loop, streaming its output. Mirrors ``runTurn``: a detached
    /// producer does the work and feeds an event stream the main actor drains, so esc / ctrl-c
    /// (``cancelTurn``) unblocks the UI at once while the process finishes and is dropped in the
    /// background. The container path is taken unconditionally for `!` (the user asked for it), so it
    /// brings the sandbox up even when the `/config` toggle is off; an unavailable container reports
    /// the reason rather than falling over to the local shell.
    func runBang(_ bang: BangCommand) async {
        let (events, continuation) = AsyncStream<BangEvent>.makeStream()
        let target = bang.target
        let command = bang.command
        let workspace = WorkspaceRoot(rootURL: workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser)
        let image = policy.sandboxImage
        if target == .container { sandboxEverEnabled = true } // so the REPL tears the container down on exit
        let producer = Task.detached {
            let onOutput: @Sendable (String) -> Void = { continuation.yield(.output($0)) }
            do {
                let result: ProcessRunner.Result
                switch target {
                case .local:
                    result = try await ProcessRunner.run(
                        "/bin/sh", ["-c", command], cwd: workspace.rootURL,
                        timeout: Self.bangTimeout, onOutput: onOutput
                    )
                case .container:
                    let sandbox = AppleContainerSandbox(root: workspace, image: image)
                    try await sandbox.ensureRunning()
                    result = try await sandbox.exec(command, timeout: Self.bangTimeout, onOutput: onOutput)
                }
                continuation.yield(.done(result))
            } catch {
                continuation.yield(.failed(error.localizedDescription))
            }
            continuation.finish()
        }
        await withTaskCancellationHandler {
            for await event in events {
                switch event {
                case .output(let chunk): bang.stream(chunk)
                case .done(let result): bang.complete(result)
                case .failed(let message): bang.fail(message)
                }
                requestRender()
            }
        } onCancel: {
            continuation.finish() // unblock the for-await the instant esc / ctrl-c fires
        }
        if Task.isCancelled { producer.cancel(); bang.stop() }
        running = false
        turnStart = nil
        currentTurn = nil
        spinnerTask?.cancel()
        requestRender()
    }

    /// How long a bang command may run before it's killed. The bang syntax has no timeout argument,
    /// so this is generous enough for builds and installs.
    static let bangTimeout: TimeInterval = 120

    /// Swap the live agent over to `choice` (its models are already on disk): rebuild behind the
    /// "switching model…" indicator and start a fresh thread. A no-op if it's already the current one.
    func switchToVariant(_ choice: DeepAgentVariant) {
        guard choice.id != variant.id else { return }
        loading = true
        startSpinner()
        requestRender()
        Task {
            if let newAgent = await build(choice, policy) {
                agent = newAgent
                variant = choice
                plannerName = Self.name(choice.textModelID)
                // Keep the same session across a `/model` switch - the history carries over (the new
                // agent's store is keyed by the unchanged session id).
                // Remember this as the project's default planner, so reopening ripple here starts on it.
                if let workingDirectory {
                    try? RippleAgentConfig.saveSelectedModel(choice.textModelID, workingDirectory: workingDirectory)
                }
            }
            loading = false
            requestRender()
        }
    }

    func runTurn(prompt: String, into assistant: Assistant, agent: ReactAgent, threadId: String) async {
        let (events, continuation) = AsyncStream<AgentEvent>.makeStream()
        let producer = Task.detached {
            _ = await agent.run([.human(prompt)], threadId: threadId) { continuation.yield($0) }
            continuation.finish()
        }
        await withTaskCancellationHandler {
            for await event in events {
                if case .token = event { sessionTokens += 1 }
                if case .todosUpdated(let todos) = event { plan = todos } // refresh the pinned plan in place
                if case .contextCompacted(let before, let after) = event { noteAutoCompaction(before: before, after: after) }
                assistant.consume(event)
                requestRender()
            }
        } onCancel: {
            continuation.finish() // unblock the for-await the instant Esc / Ctrl-C fires
        }
        if Task.isCancelled {
            producer.cancel() // the model finishes in the background; its output is dropped
            assistant.interrupt()
        } else {
            await producer.value
            assistant.complete()
        }
        contextChars += assistant.answer.count
        running = false
        turnStart = nil
        currentTurn = nil
        liveAssistant = nil
        spinnerTask?.cancel()
        requestRender()
        MLX.Memory.clearCache()
    }

    // MARK: - Animations

    /// Drive the empty-state banner's color shimmer: advance `introFrame` on a steady cadence so the
    /// highlight keeps sweeping across the wordmark (the sweep repeats - see `rippleArt`), re-rendering
    /// each frame. Runs until the first message is sent (the banner is gone), or a turn starts / the
    /// user quits, so it never fights the live UI.
    func startIntro() {
        guard messages.isEmpty else { return }
        introTask?.cancel()
        introTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(55))
                guard let self, messages.isEmpty, !busy, !quit, !Task.isCancelled else { break }
                introFrame += 1
                requestRender()
            }
        }
    }

    /// Re-render on a timer while busy so the spinner animates and the elapsed time ticks up.
    func startSpinner() {
        spinnerTask?.cancel()
        spinnerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, busy else { break }
                spinnerFrame += 1
                requestRender()
            }
        }
    }
}

/// One step of a running bang command: a streamed output chunk, the final result, or a launch
/// failure. Sendable so the detached producer can hand it across to the main-actor consumer.
private enum BangEvent: Sendable {
    case output(String)
    case done(ProcessRunner.Result)
    case failed(String)
}
