@testable import DeepAgents
import Foundation
@testable import ripple
import Testing

/// The live tokens/sec readout measures *decode* speed: every generated token (reasoning and
/// answer) over active generation time only. The old `answer tokens / whole-turn elapsed` readout
/// collapsed on reasoning models (thousands of uncounted `<think>` tokens, all of their time
/// counted) and sank further with every tool execution.
@MainActor
struct TokenRateTests {
    @Test("Stalls (prefill, tool runs) don't dilute the rate; reasoning tokens count")
    func rateMeasuresActiveDecodingOnly() {
        let assistant = Assistant()
        var now = Date(timeIntervalSinceReferenceDate: 0)
        // A reasoning burst: 20 tokens at 50 ms apart (a 20 tok/s decode).
        for _ in 0 ..< 20 {
            assistant.noteToken(at: now)
            now += 0.05
        }
        // A 5 s stall - a tool executing, or the next round's prefill.
        now += 5
        // An answer burst at the same decode speed.
        for _ in 0 ..< 20 {
            assistant.noteToken(at: now)
            now += 0.05
        }
        let rate = assistant.tokensPerSecond
        #expect(rate != nil)
        // 40 tokens over ~1.9 s of active decoding ≈ 21 tok/s. The old readout would have
        // reported 40 / 7 s ≈ 5.7 - and far worse once reasoning tokens went uncounted.
        #expect(rate.map { $0 > 19 && $0 < 23 } == true)
    }

    @Test("No reading until there is enough signal for a stable one")
    func rateNeedsSignal() {
        let assistant = Assistant()
        var now = Date(timeIntervalSinceReferenceDate: 0)
        for _ in 0 ..< 7 {
            assistant.noteToken(at: now)
            now += 0.05
        }
        #expect(assistant.tokensPerSecond == nil)
    }

    @Test("Both token channels feed the counter through consume")
    func consumeCountsBothChannels() {
        let assistant = Assistant()
        assistant.consume(.reasoningToken("thinking"))
        assistant.consume(.token("answer", isFinal: false))
        #expect(assistant.generatedTokens == 2)
        #expect(assistant.tokenCount == 1) // answer-only counter (first-token phase detection)
    }
}
