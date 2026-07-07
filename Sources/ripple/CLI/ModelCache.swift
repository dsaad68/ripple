import DeepAgents
import DeepAgentsMLX
import Foundation

/// Ripple's single view onto the local Hugging Face model cache: "is this model on disk?", plus the
/// fetch / delete the `ripple model` command, the `chat` startup, and the in-REPL `/models-config` browser
/// all go through. A thin facade over ``MlxModelLoader``'s cache helpers so there's one source of
/// truth (a model counts as present once its weights - a `.safetensors` - are on disk, so a
/// half-finished download correctly reads as missing).
enum ModelCache {
    /// Whether `repoId`'s weights are present locally. A pure filesystem check - no network.
    static func isDownloaded(_ repoId: String) -> Bool {
        MlxModelLoader.isDownloadedOnDisk(repoId)
    }

    /// The subset of `ids` that aren't downloaded yet, in the given order.
    static func missing(_ ids: [String]) -> [String] {
        ids.filter { !isDownloaded($0) }
    }

    /// Download `repoId`'s weights + tokenizer into the cache, reporting a 0...1 fraction. Already
    /// complete? It returns the cached copy without re-fetching.
    ///
    /// The hub's Xet transport reports no incremental progress through the library callback (a bar
    /// driven by it alone sits at 0% for a multi-GB pull, which reads as "download doesn't work" -
    /// and freezes any UI that gates on an in-flight download). So the library fraction is blended
    /// with the live in-flight temp-file bytes, monotonically, the same way the app's download rows
    /// do it.
    static func download(_ repoId: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let expectedBytes = Int64((MlxModel.catalog.first { $0.id == repoId }?.approxGB ?? 0) * 1_000_000_000)
        let holder = ProgressHolder()
        let report: @Sendable (Double) -> Void = { fraction in
            holder.set(fraction) // monotonic: whichever source is further along wins
            progress(holder.fraction)
        }
        let startedAt = Date()
        let poll: Task<Void, Never>? = expectedBytes <= 0 ? nil : Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                let bytes = MlxModelLoader.inFlightDownloadBytes(since: startedAt)
                report(min(0.99, Double(bytes) / Double(expectedBytes)))
            }
        }
        defer { poll?.cancel() }
        try await MlxModelLoader.downloadSnapshot(id: repoId) { report($0) }
    }

    /// Remove `repoId`'s files from the cache.
    static func remove(_ repoId: String) {
        MlxModelLoader.removeFromDisk(repoId)
    }
}
