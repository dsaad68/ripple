@testable import DeepAgents
import Foundation
@testable import ripple
import Testing

/// `ripple chat` loads project instructions (AGENTS.md / CLAUDE.md / RIPPLE.md) from the working
/// directory up to - and including - the git repo root, merging every level. These cover the walk
/// boundary (inclusive stop at `.git`, `.git` as a file as well as a directory, no escaping above the
/// root), the load-all ordering within a directory, and the derived labels / system-prompt block.
/// All use temp directories - no real repo is touched.
struct RippleInstructionsTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ripple-instr-\(UUID().uuidString)", isDirectory: true)
    }

    private func write(_ text: String, to dir: URL, _ name: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    /// Mark `dir` as a git repo root. `asFile` writes a `.git` *file* (a worktree / submodule pointer,
    /// as in this very repo) instead of a directory, which must still be recognized.
    private func markRepo(_ dir: URL, asFile: Bool = false) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let git = dir.appendingPathComponent(".git")
        if asFile {
            try Data("gitdir: /elsewhere\n".utf8).write(to: git)
        } else {
            try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        }
    }

    @Test func loadsAllThreeFilesInOrderFromTheWorkingDirectory() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try markRepo(root)
        try write("agents", to: root, "AGENTS.md")
        try write("claude", to: root, "CLAUDE.md")
        try write("ripple", to: root, "RIPPLE.md")

        let loaded = RippleInstructions.load(workingDirectory: root)
        #expect(loaded.labels == ["AGENTS.md", "CLAUDE.md", "RIPPLE.md"])
        #expect(loaded.files.map(\.contents) == ["agents", "claude", "ripple"])
        let prompt = try #require(loaded.promptText)
        #expect(prompt.contains("## Project instructions"))
        #expect(prompt.contains("### AGENTS.md\nagents"))
    }

    @Test func walksUpToAndIncludingTheGitRootButNoHigher() throws {
        let outside = tempDir() // an ancestor *above* the repo root - must be ignored
        defer { try? FileManager.default.removeItem(at: outside) }
        let repo = outside.appendingPathComponent("repo", isDirectory: true)
        let nested = repo.appendingPathComponent("src/feature", isDirectory: true)
        try write("outside", to: outside, "AGENTS.md") // above the root: never loaded
        try markRepo(repo)
        try write("root-claude", to: repo, "CLAUDE.md")
        try write("feature-ripple", to: nested, "RIPPLE.md")

        let loaded = RippleInstructions.load(workingDirectory: nested)
        // Repo root first, working directory last; the file above the root is excluded.
        #expect(loaded.labels == ["CLAUDE.md", "src/feature/RIPPLE.md"])
        #expect(loaded.files.map(\.contents) == ["root-claude", "feature-ripple"])
        #expect(loaded.promptText?.contains("outside") == false)
    }

    @Test func recognizesAGitFileAsTheRoot() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("a/b", isDirectory: true)
        try markRepo(root, asFile: true) // `.git` is a file, not a directory
        try write("root", to: root, "AGENTS.md")
        try write("leaf", to: nested, "CLAUDE.md")

        let loaded = RippleInstructions.load(workingDirectory: nested)
        #expect(loaded.labels == ["AGENTS.md", "a/b/CLAUDE.md"])
        #expect(RippleInstructions.searchChain(from: nested).count == 3) // root, a, a/b
    }

    @Test func withoutAGitRootReadsOnlyTheWorkingDirectory() throws {
        let base = tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let leaf = base.appendingPathComponent("x/y", isDirectory: true)
        try write("parent", to: base, "AGENTS.md") // a parent dir, but no `.git` anywhere
        try write("leaf", to: leaf, "CLAUDE.md")

        let loaded = RippleInstructions.load(workingDirectory: leaf)
        #expect(loaded.labels == ["CLAUDE.md"]) // only the working directory, parent ignored
        #expect(loaded.files.map(\.contents) == ["leaf"])
    }

    @Test func doesNotDescendIntoSubdirectories() throws {
        // The walk goes UP only: launching at the repo root must not pull a subfolder's file.
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try markRepo(root)
        try write("root", to: root, "AGENTS.md")
        try write("buried", to: root.appendingPathComponent("src", isDirectory: true), "CLAUDE.md")

        let loaded = RippleInstructions.load(workingDirectory: root)
        #expect(loaded.labels == ["AGENTS.md"]) // the subdirectory's CLAUDE.md is not loaded
        #expect(loaded.files.map(\.contents) == ["root"])
    }

    @Test func sameFilenameAtMultipleLevelsMergesRootFirst() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("pkg", isDirectory: true)
        try markRepo(root)
        try write("root-agents", to: root, "AGENTS.md")
        try write("pkg-agents", to: nested, "AGENTS.md")

        let loaded = RippleInstructions.load(workingDirectory: nested)
        // Both load, distinct repo-root-relative labels, root-first (general -> specific).
        #expect(loaded.labels == ["AGENTS.md", "pkg/AGENTS.md"])
        #expect(loaded.files.map(\.contents) == ["root-agents", "pkg-agents"])
    }

    @Test func stopsAtTheNearestGitRootWhenReposAreNested() throws {
        let outer = tempDir()
        defer { try? FileManager.default.removeItem(at: outer) }
        let inner = outer.appendingPathComponent("inner", isDirectory: true)
        let leaf = inner.appendingPathComponent("a", isDirectory: true)
        try markRepo(outer)
        try write("outer", to: outer, "AGENTS.md") // above the nearest root: ignored
        try markRepo(inner) // a nested repo - the nearest root for `leaf`
        try write("inner", to: inner, "CLAUDE.md")
        try write("leaf", to: leaf, "RIPPLE.md")

        let loaded = RippleInstructions.load(workingDirectory: leaf)
        #expect(loaded.labels == ["CLAUDE.md", "a/RIPPLE.md"]) // stops at `inner`, not `outer`
        #expect(loaded.files.map(\.contents) == ["inner", "leaf"])
    }

    @Test @MainActor func projectInstructionsReachThePlannerSystemPrompt() {
        let agent = RippleDeepAgent.make(
            textModel: FakeChatModel(answer: "ok"),
            projectInstructions: "## Project instructions\nNEVER_USE_TABS"
        )
        let prompt = agent.systemPrompt ?? ""
        #expect(prompt.contains("NEVER_USE_TABS")) // the loaded block reached the planner prompt
        #expect(prompt.contains("Plan first")) // ...after the planner's own DeepScreenPrompt guidance
    }

    @Test @MainActor func plannerPromptOmitsTheBlockWhenNoInstructions() {
        let agent = RippleDeepAgent.make(textModel: FakeChatModel(answer: "ok"))
        let prompt = agent.systemPrompt ?? ""
        #expect(prompt.contains("Plan first")) // the base guidance is unchanged
        #expect(!prompt.contains("Project instructions")) // no empty block is appended
    }

    @Test func skipsEmptyFilesAndReportsEmptyWhenNothingFound() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try markRepo(root)
        try write("   \n\t\n", to: root, "AGENTS.md") // whitespace-only -> skipped

        let loaded = RippleInstructions.load(workingDirectory: root)
        #expect(loaded.isEmpty)
        #expect(loaded.labels.isEmpty)
        #expect(loaded.promptText == nil)
    }
}
