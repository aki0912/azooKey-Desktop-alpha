@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil))
@MainActor struct EnglishJapaneseSuffixTests {
    @Test func dictionary() throws { try replay(useZenzai: false) }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"] != nil))
    func zenzai() throws { try replay(useZenzai: true) }

    private func replay(useZenzai: Bool) throws {
        let env = ProcessInfo.processInfo.environment
        let model = try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: #require(env["AUTO_MIXED_RUNTIME_MODEL"]))))
        let bridge = try ZenzaiSpanBridge(converter: .withDefaultDictionary(),
            applicationDirectory: .temporaryDirectory.appendingPathComponent("english-suffix-\(UUID())"),
            useZenzai: useZenzai, resources: env["AUTO_MIXED_ZENZAI_RESOURCES"].map { URL(fileURLWithPath: $0) }, learningEnabled: false)
        defer { bridge.releaseAll() }
        for context in [CommittedLeftContext.unavailable, .available(""), .available("今日は晴れです。")] {
            let segmenter = try JapanesePreferredSegmenter(model: model, lexicon: .bundled(), policy: .bundled(), context: context, focus: UUID())
            let engine = MixedCompositionEngine(segmenter: segmenter, converter: MixedSessionConverter(bridge: bridge,
                sessionID: UUID(), leftContext: context.text, allowJapaneseReadingFallback: true),
                punctuation: .init(leftContext: context), backspaceEditor: RomanReadingBackspaceEditor())
            for english in ["sample", "meeting", "apple"] {
                let raw = english + "node-ta"
                engine.cancel()
                for (index, key) in raw.enumerated() {
                    try engine.handle(.insert(String(key)))
                    if index >= english.count {
                        #expect(engine.spans.first?.kind == .raw)
                        #expect(engine.spans.first?.sourceRange == (try ScalarRange(0, english.count)))
                    }
                }
                #expect(try engine.markedText().text == english + "のデータ", "authored \(raw), context available \(context.isAvailable)")
                #expect(try engine.spans.map { try engine.buffer.offsets.slice($0.sourceRange) } == [english, "node-ta"])
                #expect(engine.buffer.text == raw)
                #expect(!engine.usedRawFallback)
                try engine.handle(.backspace)
                #expect(try engine.markedText().text == english + "のでー")
                try engine.handle(.insert("ta"))
                #expect(try engine.markedText().text == english + "のデータ")
                try engine.handle(.tab())
                #expect(engine.selectionOptions.contains { $0.text == "のデータ" })
                engine.cancel()
                try engine.replaceRaw(raw)
                #expect(try engine.markedText().text == english + "のデータ")
                try engine.handle(.escape)
                #expect(try engine.handle(.enter).commit?.text == raw)
            }
            for raw in ["sample", "samples", "sampler", "sampling", "sample-note", "sample-data", "apple-note",
                        "sample-node", "https://example.com/samplenode-ta", "samplenode-ta.txt", "sample_node-ta", "3-2"] {
                engine.cancel()
                for key in raw { try engine.handle(.insert(String(key))) }
                #expect(try engine.markedText().text == raw, "protected \(raw)")
                #expect(engine.buffer.text == raw)
            }
            // Test segmentation independently of the backend's surface preference:
            // Zenzai can legitimately return "coffee" for ko-hi- after English context.
            for (suffix, reading) in [("ko-do", "こーど"), ("ko-hi-", "こーひー")] {
                engine.cancel()
                #expect(RomanSpanReading.parse(suffix)?.reading == reading)
                let control = try bridge.candidates(for: JapaneseSpanRequest(
                    identity: .init(sessionID: UUID(), compositionID: UUID(), spanID: UUID(), revision: 1),
                    sourceRange: ScalarRange(0, suffix.count), raw: suffix,
                    leftContext: (context.text ?? "") + "sample", isAtBufferEnd: true))
                let expected = "sample" + (try #require(control.candidates.first?.text))
                let raw = "sample" + suffix
                for key in raw { try engine.handle(.insert(String(key))) }
                let parts = try engine.spans.map { try engine.buffer.offsets.slice($0.sourceRange) }
                #expect(parts == ["sample", suffix])
                #expect(engine.spans.last?.kind == .japaneseRoman)
                let actual = try engine.markedText().text
                #expect(actual == expected, "authored \(raw)")
                bridge.release(sessionID: control.identity.sessionID)
            }
            engine.cancel()
            try engine.replaceRaw("👩‍💻 samplenode-ta")
            #expect(try engine.markedText().text == "👩‍💻 sampleのデータ")
            try MixedMarkedTextRenderer.validate(spans: engine.spans, source: engine.buffer.offsets)
            engine.cancel()
        }
        if useZenzai { #expect(bridge.backend == .zenzaiReady) }
    }
}
