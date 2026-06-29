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
    static func download(_ repoId: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await MlxModelLoader.downloadSnapshot(id: repoId, progress: progress)
    }

    /// Remove `repoId`'s files from the cache.
    static func remove(_ repoId: String) {
        MlxModelLoader.removeFromDisk(repoId)
    }
}
