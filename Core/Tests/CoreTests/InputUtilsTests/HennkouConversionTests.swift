@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil))
@MainActor struct HennkouConversionTests {
    @Test func dictionary() throws { try replay(useZenzai: false) }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"] != nil))
    func zenzai() throws { try replay(useZenzai: true) }

    private func replay(useZenzai: Bool) throws {
        let env = ProcessInfo.processInfo.environment
        let model = try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: #require(env["AUTO_MIXED_RUNTIME_MODEL"]))))
        let bridge = try ZenzaiSpanBridge(converter: .withDefaultDictionary(),
            applicationDirectory: .temporaryDirectory.appendingPathComponent("hennkou-regression-\(UUID())"),
            useZenzai: useZenzai, resources: env["AUTO_MIXED_ZENZAI_RESOURCES"].map { URL(fileURLWithPath: $0) }, learningEnabled: false)
        defer { bridge.releaseAll() }
        for context in [CommittedLeftContext.unavailable, .available(""), .available("日本語を入力して確定しました。"),
                        .available("今日はいい天気なので公園に出かけようと思います。")] {
            let engine = MixedCompositionEngine(segmenter: try JapanesePreferredSegmenter(model: model,
                lexicon: .bundled(), policy: .bundled(), context: context, focus: UUID()),
                converter: MixedSessionConverter(bridge: bridge, sessionID: UUID(), leftContext: context.text,
                                                 allowJapaneseReadingFallback: true),
                punctuation: .init(leftContext: context), backspaceEditor: RomanReadingBackspaceEditor())
            let raw = "hennkoutennga"
            #expect(RomanSpanReading.parse(raw)?.reading == "へんこうてんが")
            for key in raw { try engine.handle(.insert(String(key))) }
            #expect(engine.spans.map(\.kind) == [.japaneseRoman])
            #expect(engine.spans.first?.sourceRange == (try ScalarRange(0, raw.count)))
            #expect(try engine.markedText().text == "変更点が")
            #expect(!engine.usedRawFallback)
            try engine.handle(.tab())
            #expect(engine.selectionOptions.first?.text == "変更点が")
            try engine.handle(.enter)
            try engine.handle(.backspace)
            #expect(try engine.markedText().text == "へんこうてん")
            try engine.handle(.insert("ga"))
            #expect(try engine.markedText().text == "変更点が")
            #expect(try engine.handle(.enter).commit?.text == "変更点が")
            #expect(bridge.activeChildCount == 0)
            try engine.replaceRaw(raw)
            #expect(try engine.markedText().text == "変更点が")
            try engine.handle(.escape)
            #expect(try engine.handle(.enter).commit?.text == raw)
            #expect(bridge.activeChildCount == 0)
        }
        if useZenzai { #expect(bridge.backend == .zenzaiReady) }
    }
}
