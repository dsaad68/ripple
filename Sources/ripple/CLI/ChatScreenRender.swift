import DeepAgents
import DeepAgentsMLX
import Foundation

// The chrome around the input box for `ripple chat`: the overlay block that sits just above it (the
// command / `@file` palettes and the working indicator), the bottom status line (cwd, git, context
// meter, model), and the shared text/width helpers used across the view files. The approval cards,
// transcript, and banner live in their own ChatScreen* files; the model types in ChatScreenModel.
extension ChatScreen {
    // MARK: - Chrome

    /// The block just above the input box: a pending-approval card, else the working indicator, else
    /// the `/` command palette. They never coexist (approval and working need a turn; the palette is
    /// idle-only), so one array covers all three.
    func overlayLines(width: Int) -> [Line] {
        if let download = downloading { return [Line(downloadLine(download))] }
        if editingApproval != nil {
            return [Line("  " + Paint.fg(179, "✎ editing shell command")
                    + Paint.fg(240, "   enter to run · esc to go back"))]
        }
        if let pending = gate.pending { return approvalLines(pending, width: width) }
        // The ask_user card is drawn as the bottom region in `render()` (replacing the input box), not
        // here in the overlay block - so a pending prompt is handled before this is even called.
        if busy { return [Line(workingLine())] }
        if fileMenuActive { return fileMenuLines() }
        if menuActive { return menuLines() }
        return []
    }

    /// The `@file` fuzzy picker rows (just above the input box). Each row inserts that path on click.
    private func fileMenuLines() -> [Line] {
        fileMatches.enumerated().map { index, path in
            let marker = index == fileMenuSelection ? Paint.arrow("❯") : " "
            return Line("  \(marker) " + Paint.fg(Theme.code.xterm, "@") + Paint.fg(index == fileMenuSelection ? 252 : 245, path),
                        .selectFile(index))
        }
    }

    /// Tint `/command` and `@file` tokens as the input is typed; everything else is plain.
    func highlightInput(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            if word.hasPrefix("/") { return Paint.fg(111, String(word)) }
            if word.hasPrefix("@"), word.count > 1 { return Paint.mention(String(word)) }
            return Paint.fg(252, String(word))
        }.joined(separator: " ")
    }

    /// A line that sits just above the input box while a turn runs: spinner + elapsed + live tokens/sec
    /// + the stop hint. The label names the phase the wait is actually in - a cold model (re)load or
    /// the prompt prefill would otherwise both read as a long silent "working…".
    private func workingLine() -> String {
        let spinner = Self.spinnerFrames[spinnerFrame % Self.spinnerFrames.count]
        let elapsed = turnStart.map { Date().timeIntervalSince($0) } ?? 0
        let runningBang = { if case .bang(let bang)? = messages.last?.kind, bang.running { return true } else { return false } }()
        let verb = runningBang ? "running…" : "working…"
        let label: String
        if compacting {
            label = "compacting context…"
        } else if let name = modelLoadStatus() {
            label = String(format: "loading %@ into memory… %.1fs", name, elapsed)
        } else if loading {
            label = "switching model…"
        } else if !runningBang, awaitingFirstToken {
            label = String(format: "prefilling the prompt… %.1fs", elapsed)
        } else {
            label = String(format: "\(verb) %.1fs", elapsed)
        }
        var line = "  " + Paint.fg(179, spinner) + " " + Paint.fg(245, label)
        // A remote model streams multi-token SSE chunks (not one decoded token per event), so the
        // chunk count isn't a real token rate - only show tok/s for on-device variants. The rate
        // is decode-time based (reasoning + answer tokens over active generation time), so
        // prefill stretches and tool executions don't drag it down.
        if !variant.isRemote, let rate = liveAssistant?.tokensPerSecond {
            line += Paint.fg(238, "  ·  ") + Paint.fg(244, "\(Int(rate)) tok/s")
        }
        return line + Paint.fg(238, "   esc to stop")
    }

    /// True while the turn has produced nothing yet - no reasoning, no tool step, no answer token -
    /// i.e. the silent stretch that is the prompt prefill (long only when the prefix cache misses).
    private var awaitingFirstToken: Bool {
        guard let assistant = liveAssistant else { return true }
        return assistant.blocks.isEmpty && assistant.tokenCount == 0
    }

    /// The model-download progress bar (shown above the input box while a `/models-config` pull or a
    /// `/model` switch fetches weights - and inside the `/model` Local tab, which hides the overlay
    /// block). esc cancels it.
    func downloadLine(_ download: DownloadProgress) -> String {
        let bar = CLIProgressBar.barString(fraction: download.fraction, width: 22)
        let pct = String(format: "%3d%%", Int((download.fraction * 100).rounded()))
        return "  " + Paint.fg(141, "◇") + " " + Paint.fg(245, "downloading ") + Paint.fg(252, download.label)
            + "  " + bar + " " + Paint.fg(244, pct) + Paint.fg(238, "   esc cancel")
    }

    /// The `/` command palette rows (just above the input box). Each row is clickable to run it.
    private func menuLines() -> [Line] {
        commandMatches.enumerated().map { index, command in
            let selected = index == menuSelection
            let marker = selected ? Paint.arrow("❯") : " "
            let name = Paint.fg(selected ? 252 : 245, command.name)
            let pad = String(repeating: " ", count: max(1, 9 - command.name.count))
            return Line("  \(marker) " + name + pad + Paint.fg(240, command.description), .runCommand(index))
        }
    }

    // MARK: - Status line

    func statusLine(width: Int) -> String {
        let mode = modeChip()
        let modeWidth = mode.isEmpty ? 0 : visibleWidth(mode) + 1
        let git = gitSegment()
        // Right cluster: just the context percentage, then the model - the branch sits at the end of
        // the left cluster, so the percentage reads as sitting between the branch and the model name.
        let right = contextPercent() + Paint.fg(238, "  ·  ") + Paint.fg(244, plannerName)
        let rightWidth = visibleWidth(right)
        let gitWidth = git.isEmpty ? 0 : 2 + visibleWidth(git)
        var cwd = abbreviatedCWD()
        let maxCwd = max(6, width - rightWidth - gitWidth - modeWidth - 4)
        if cwd.count > maxCwd { cwd = "…" + cwd.suffix(maxCwd - 1) }
        let left = mode + (mode.isEmpty ? "" : " ") + Paint.fg(240, cwd) + (git.isEmpty ? "" : "  " + git)
        let gap = max(2, width - modeWidth - cwd.count - gitWidth - rightWidth)
        return "  " + left + String(repeating: " ", count: gap) + right
    }

    /// The permission-mode banner: a loud background chip for any non-default mode (and the YOLO
    /// arming prompt), or nothing in the default "ask" mode.
    private func modeChip() -> String {
        if pendingYolo { return Paint.bgFg(Theme.danger.xterm, 232, " ⚠ Tab again to ACCEPT ALL ") }
        guard permissionMode != .ask else { return "" }
        return Paint.bgFg(permissionMode.color.xterm, 232, " " + permissionMode.label + " ")
    }

    /// The cached git segment (branch / dirty / ahead-behind), refreshed off the main loop at most
    /// once every couple of seconds so a 120ms spinner render never shells out to git.
    private func gitSegment() -> String {
        if gitCheckedAt.map({ Date().timeIntervalSince($0) > 2 }) ?? true, !gitRefreshing {
            gitRefreshing = true
            Task.detached(priority: .utility) { [weak self] in
                let info = Self.computeGit()
                await MainActor.run {
                    guard let self else { return }
                    self.gitInfo = info
                    self.gitCheckedAt = Date()
                    self.gitRefreshing = false
                    self.requestRender()
                }
            }
        }
        return gitInfo ?? ""
    }

    /// Render the git segment by parsing one `git status -sb` (branch, upstream ahead/behind, dirty).
    private nonisolated static func computeGit() -> String? {
        guard let status = runGit(["status", "-sb", "--porcelain=v1"]) else { return nil }
        let lines = status.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.first, header.hasPrefix("## ") else { return nil }
        var branch = String(header.dropFirst(3))
        branch = String(branch.prefix { $0 != " " }) // drop the [ahead/behind] tail
        if let dots = branch.range(of: "...") { branch = String(branch[..<dots.lowerBound]) }
        let ahead = number(after: "ahead ", in: header)
        let behind = number(after: "behind ", in: header)
        let dirty = lines.dropFirst().contains { !$0.isEmpty }
        var out = Paint.fg(dirty ? Theme.warn.xterm : Theme.success.xterm, "⎇ " + branch + (dirty ? "*" : ""))
        if ahead > 0 { out += Paint.fg(244, " ↑\(ahead)") }
        if behind > 0 { out += Paint.fg(244, " ↓\(behind)") }
        return out
    }

    private nonisolated static func number(after prefix: String, in text: String) -> Int {
        guard let range = text.range(of: prefix) else { return 0 }
        return Int(text[range.upperBound...].prefix { $0.isNumber }) ?? 0
    }

    private nonisolated static func runGit(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    /// The session's context use as a gauge icon + percentage of a nominal window, shown in the
    /// status line between the git branch and the model name. The pie icon fills and the color
    /// escalates as the context does: green (empty / low) -> orange -> amber -> red (nearly full).
    private func contextPercent() -> String {
        let window = Double(agent.contextWindowTokens ?? 32768)
        let percent = min(100, Int((Double(sessionTokens) / window * 100).rounded()))
        let (icon, color): (String, Theme.Color) = switch percent {
        case 80...: ("●", Theme.danger)
        case 60 ..< 80: ("◕", Theme.warn)
        case 40 ..< 60: ("◑", Theme.code)
        case 20 ..< 40: ("◔", Theme.success)
        default: ("○", Theme.success)
        }
        return Paint.fg(color, icon + " \(percent)%")
    }

    // MARK: - Shared helpers

    static func name(_ id: String) -> String {
        if id.isEmpty { return "none" } // a text-only variant has no vision model
        return MlxModel.catalog.first { $0.id == id }?.shortName ?? id
    }

    func abbreviatedCWD() -> String {
        let cwd = FileManager.default.currentDirectoryPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }

    func clip(_ text: String, _ limit: Int) -> String { Self.clip(text, limit) }

    static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cap = max(8, limit)
        return flat.count > cap ? String(flat.prefix(cap - 1)) + "…" : flat
    }

    func wrap(_ text: String, _ width: Int) -> [String] {
        guard width > 6 else { return [text] }
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
                if line.isEmpty {
                    line = word
                } else if TextWidth.of(line) + 1 + TextWidth.of(word) <= width {
                    line += " " + word
                } else {
                    lines.append(line); line = word
                }
                while TextWidth.of(line) > width {
                    lines.append(String(line.prefix(width))); line = String(line.dropFirst(width))
                }
            }
            lines.append(line)
        }
        return lines
    }

    private func visibleWidth(_ s: String) -> Int { TextWidth.of(s) }
}
