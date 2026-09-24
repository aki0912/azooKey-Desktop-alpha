@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil))
@MainActor struct PunctuationModelRegressionTests {
    @Test func punctuationKeepsCompleteJapaneseReadingWithDictionary() throws {
        try replay(useZenzai: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"] != nil))
    func punctuationKeepsCompleteJapaneseReadingWithRealZenzai() throws {
        try replay(useZenzai: true)
    }

    private func replay(useZenzai: Bool) throws {
        let path = try #require(ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"])
        let model = try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let resources = ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"].map { URL(fileURLWithPath: $0) }
        let bridge = try ZenzaiSpanBridge(converter: .withDefaultDictionary(),
            applicationDirectory: .temporaryDirectory.appendingPathComponent("punctuation-model-\(UUID())"),
            useZenzai: useZenzai, resources: resources, learningEnabled: false)
        defer { bridge.releaseAll() }
        for context in [CommittedLeftContext.unavailable, .available("")] {
            let segmenter = try JapanesePreferredSegmenter(model: model, lexicon: .bundled(), policy: .bundled(),
                context: context, focus: UUID())
            let engine = MixedCompositionEngine(segmenter: segmenter, converter: MixedSessionConverter(
                bridge: bridge, sessionID: UUID(), allowJapaneseReadingFallback: true), punctuation: .init())
            for raw in ["asitanotennkiwoosiete", "asitanotennkiwooshiete"] {
                engine.cancel()
                for character in raw { try engine.handle(.insert(String(character))) }
                #expect(try engine.markedText().text == "明日の天気を教えて")
                for (suffix, display) in [(".", "。"), (",", "、")] {
                    try engine.handle(.insert(suffix))
                    #expect(try engine.markedText().text == "明日の天気を教えて" + display)
                    #expect(engine.buffer.text == raw + suffix)
                    #expect(engine.spans.first?.sourceRange == (try ScalarRange(0, raw.unicodeScalars.count)))
                    #expect(engine.spans.first?.kind == .japaneseRoman)
                    #expect(!engine.usedRawFallback)
                    try engine.handle(.backspace)
                    #expect(try engine.markedText().text == "明日の天気を教えて")
                }
                engine.cancel()
                try engine.replaceRaw(raw + ".")
                #expect(try engine.markedText().text == "明日の天気を教えて。")
                #expect(try engine.handle(.enter).commit?.text == "明日の天気を教えて。")
                try engine.replaceRaw(raw + ".")
                try engine.handle(.escape)
                #expect(try engine.handle(.enter).commit?.text == raw + ".")
            }
        }
        if useZenzai { #expect(bridge.backend == .zenzaiReady) }
    }
}
