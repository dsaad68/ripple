import Foundation
@testable import ripple
import Testing

/// The OpenRouter catalog decoder: keep only the `:free` variants, detect vision from
/// `input_modalities`, sort by name, and derive provider/short-name labels. Pure decoding - no network.
struct OpenRouterCatalogTests {
    @Test func keepsOnlyColonFreeModelsAndDetectsVision() throws {
        let json = """
        { "data": [
            { "id": "a/vlm:free", "name": "Alpha VLM (free)", "context_length": 131072,
              "architecture": { "input_modalities": ["text", "image"] } },
            { "id": "b/text:free", "name": "Beta Text (free)", "context_length": 8192,
              "architecture": { "input_modalities": ["text"] } },
            { "id": "c/preview", "name": "Gamma Preview", "pricing": { "prompt": "0", "completion": "0" },
              "architecture": { "input_modalities": ["text"] } },
            { "id": "d/trial:free-trial", "name": "Delta" }
        ] }
        """
        let models = try OpenRouterCatalog.models(from: Data(json.utf8))
        // Only ids ending in ":free" survive - the zero-priced "c/preview" and the "d/...:free-trial"
        // (suffix isn't exactly ":free") are excluded. Sorted by name: Alpha, Beta.
        #expect(models.map(\.id) == ["a/vlm:free", "b/text:free"])

        let vlm = models.first { $0.id == "a/vlm:free" }
        #expect(vlm?.vision == true) // input_modalities includes "image"
        #expect(vlm?.contextLength == 131_072)
        #expect(models.first { $0.id == "b/text:free" }?.vision == false)
    }

    @Test func derivesProviderAndShortName() {
        let model = OpenRouterModel(
            id: "meta-llama/llama-3.3-70b-instruct:free",
            name: "Meta: Llama 3.3 70B Instruct (free)", contextLength: 131_072, vision: false
        )
        #expect(model.providerSlug == "meta-llama")
        #expect(model.providerLabel == "Meta") // the name prefix before ": "
        #expect(model.shortName == "Llama 3.3 70B Instruct") // provider prefix and " (free)" stripped
    }

    @Test func providerLabelFallsBackToSlugWithoutColon() {
        let model = OpenRouterModel(id: "qwen/qwen3-4b:free", name: "qwen3 4b", contextLength: nil, vision: false)
        #expect(model.providerLabel == "qwen") // no ": " in the name -> the slug
        #expect(model.shortName == "qwen3 4b")
    }
}
