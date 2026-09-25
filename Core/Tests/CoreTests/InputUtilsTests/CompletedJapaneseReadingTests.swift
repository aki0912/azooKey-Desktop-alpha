@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil))
@MainActor struct CompletedJapaneseReadingTests {
    @Test func dictionary() throws { try replay(useZenzai: false) }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"] != nil))
    func zenzai() throws { try replay(useZenzai: true) }

    private func replay(useZenzai: Bool) throws {
        let env = ProcessInfo.processInfo.environment
        let model = try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: #require(env["AUTO_MIXED_RUNTIME_MODEL"]))))
        let bridge = try ZenzaiSpanBridge(converter: .withDefaultDictionary(),
            applicationDirectory: .temporaryDirectory.appendingPathComponent("complete-reading-\(UUID())"),
            useZenzai: useZenzai, resources: env["AUTO_MIXED_ZENZAI_RESOURCES"].map { URL(fileURLWithPath: $0) }, learningEnabled: false)
        defer { bridge.releaseAll() }
        for context in [CommittedLeftContext.unavailable, .available(""), .available("ソフトウェアを")] {
            let engine = MixedCompositionEngine(segmenter: try JapanesePreferredSegmenter(model: model,
                lexicon: .bundled(), policy: .bundled(), context: context, focus: UUID()),
                converter: MixedSessionConverter(bridge: bridge, sessionID: UUID(), leftContext: context.text,
                                                 allowJapaneseReadingFallback: true),
                punctuation: .init(leftContext: context), backspaceEditor: RomanReadingBackspaceEditor())
            for raw in ["kaihatu", "kaihatsu"] {
                engine.cancel()
                for key in raw { try engine.handle(.insert(String(key))) }
                #expect(engine.spans.map(\.kind) == [.japaneseRoman])
                #expect(engine.spans.first?.sourceRange == (try ScalarRange(0, raw.count)))
                #expect(try engine.markedText().text == "開発")
                #expect(!engine.usedRawFallback)
                try engine.handle(.tab())
                #expect(engine.selectionOptions.first?.text == "開発")
                try engine.handle(.backspace)
                #expect(try engine.markedText().text == "かいは")
                try engine.handle(.insert(raw == "kaihatu" ? "tu" : "tsu"))
                #expect(try engine.markedText().text == "開発")
                #expect(try engine.handle(.enter).commit?.text == "開発")
                #expect(bridge.activeChildCount == 0)
                try engine.replaceRaw(raw)
                #expect(try engine.markedText().text == "開発")
                try engine.handle(.escape)
                #expect(try engine.handle(.enter).commit?.text == raw)
                #expect(bridge.activeChildCount == 0)
            }
            // A candidate adopted for the shorter reading must not survive the join.
            try engine.replaceRaw("kaiha")
            try engine.handle(.tab())
            try engine.handle(.enter)
            try engine.handle(.insert("tu"))
            #expect(try engine.markedText().text == "開発")
            #expect(engine.spans.map(\.kind) == [.japaneseRoman])
            #expect(bridge.activeChildCount == 1)
            engine.cancel()
            #expect(bridge.activeChildCount == 0)
        }
        if useZenzai { #expect(bridge.backend == .zenzaiReady) }
    }
}
