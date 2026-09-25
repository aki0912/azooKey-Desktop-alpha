@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil))
@MainActor struct PunctuationModelRegressionTests {
    @Test func punctuationContinuationWithDictionary() throws {
        try continuation(useZenzai: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"] != nil))
    func punctuationContinuationWithRealZenzai() throws {
        try continuation(useZenzai: true)
    }

    private func continuation(useZenzai: Bool) throws {
        let env = ProcessInfo.processInfo.environment
        let model = try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath:
            #require(env["AUTO_MIXED_RUNTIME_MODEL"]))))
        let bridge = try ZenzaiSpanBridge(converter: .withDefaultDictionary(),
            applicationDirectory: .temporaryDirectory.appendingPathComponent("punctuation-continuation-\(UUID())"),
            useZenzai: useZenzai, resources: env["AUTO_MIXED_ZENZAI_RESOURCES"].map { URL(fileURLWithPath: $0) },
            learningEnabled: false)
        defer { bridge.releaseAll() }
        for context in [CommittedLeftContext.unavailable, .available(""), .available("今日は晴れです。") ] {
            let segmenter = try JapanesePreferredSegmenter(model: model, lexicon: .bundled(), policy: .bundled(),
                context: context, focus: UUID())
            let engine = MixedCompositionEngine(segmenter: segmenter, converter: MixedSessionConverter(
                bridge: bridge, sessionID: UUID(), leftContext: context.text, allowJapaneseReadingFallback: true),
                punctuation: .init(leftContext: context))
            for stem in ["asita", "asitanotennkiwosirabetehosii"] {
                for (punctuation, display) in [(".", "。"), (",", "、"), ("。", "。"), ("、", "、")] {
                    engine.cancel()
                    for character in stem { try engine.handle(.insert(String(character))) }
                    let before = try engine.markedText().text
                    #expect(before != stem)
                    try engine.handle(.insert(punctuation))
                    #expect(try engine.markedText().text == before + display)
                    try engine.handle(.insert("d"))
                    let raw = stem + punctuation + "d"
                    let continued = try engine.markedText().text
                    #expect(engine.buffer.text == raw)
                    #expect(!engine.usedRawFallback)
                    #expect(continued == before + display + "d", "continuation: \(raw), context: \(context.text ?? "unavailable")")
                    if stem.count > 5 && punctuation == "." && !context.isAvailable {
                        print("Authored punctuation continuation, Zenzai=\(useZenzai): \(continued)")
                    }
                    try engine.handle(.backspace)
                    #expect(try engine.markedText().text == before + display)
                    try engine.handle(.insert("d"))
                    #expect(try engine.handle(.enter).commit?.text == before + display + "d")
                    // Pasted input must use the same decision without typing history.
                    try engine.replaceRaw(raw)
                    #expect(try engine.markedText().text == before + display + "d")
                    try engine.handle(.escape)
                    #expect(try engine.handle(.enter).commit?.text == raw)
                    try engine.replaceRaw(stem + punctuation)
                    for character in "desu" {
                        try engine.handle(.insert(String(character)))
                        #expect(try engine.markedText().text.hasPrefix(before + display))
                        #expect(!engine.usedRawFallback)
                    }
                    #expect(try engine.markedText().text == before + display + "です")
                    try engine.handle(.enter)
                    try engine.replaceRaw(stem + punctuation + "apple")
                    #expect(try engine.markedText().text == before + display + "apple")
                    try engine.handle(.enter)
                }
            }
            for raw in ["main.swift", "main.c", "readme.mdwohiraku", "note.txt", "name.md", "made.d",
                        "example.com", "./asita.d", "https://asita.d", "www.asita.d", "asita@example.com", "file_name.d", "v3.2"] {
                engine.cancel()
                for character in raw { try engine.handle(.insert(String(character))) }
                #expect(try engine.markedText().text == raw, "protected: \(raw)")
                #expect(try engine.handle(.enter).commit?.text == raw)
            }
        }
        if useZenzai { #expect(bridge.backend == .zenzaiReady) }
    }

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
                for (suffix, display) in [(".", "。"), (",", "、"), ("?", "？"), ("!", "！"), ("(", "（"), (")", "）")] {
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
