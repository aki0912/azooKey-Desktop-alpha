@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@Suite @MainActor struct LongVowelTests {
    @Test func conversionCopyNormalizesHyphensBeforeUsingStandardTable() throws {
        for (raw, reading) in [("harike-nn", "はりけーん"), ("ko-hi-", "こーひー"),
                               ("su-pa-", "すーぱー"), ("ra-menn", "らーめん")] {
            var composing = ComposingText()
            composing.insertAtCursorPosition(raw, inputStyle: .roman2kana)
            // Upstream deliberately leaves ASCII hyphens literal. Only our conversion
            // copy normalizes them; this assertion records the actual dependency API.
            #expect(composing.convertTarget == reading.replacingOccurrences(of: "ー", with: "-"))
            let parsed = try #require(RomanSpanReading.parse(raw))
            #expect(parsed.prefix == raw)
            #expect(parsed.suffix.isEmpty)
            #expect(parsed.reading == reading)
            #expect(parsed.conversionInput == raw.replacingOccurrences(of: "-", with: "ー"))
        }
        let terminal = try #require(RomanSpanReading.parse("harike-n"))
        #expect(terminal.reading == "はりけーん")
        #expect(terminal.prefix == "harike-n")
        #expect(terminal.suffix.isEmpty)
        #expect(terminal.completesTerminalN)
        #expect(RomanSpanReading.parse("asitan")?.suffix == "n")
        #expect(RomanSpanReading.parse("harikeーn")?.reading == "はりけーん")
        #expect(RomanSpanReading.parse("harike-ny")?.suffix == "ny")
        #expect(RomanSpanReading.parse("harike-no")?.reading == "はりけーの")
        #expect(RomanSpanReading.parse("harike-nya")?.reading == "はりけーにゃ")
        for raw in ["harike-apple", "harike-3", "harike-.txt", "ha👩‍💻-n"] {
            #expect(RomanSpanReading.parse(raw) == nil)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil))
    func longVowelWordReachesConverterAsOneSpan() throws {
        let path = try #require(ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"])
        let model = try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let segmenter = try JapanesePreferredSegmenter(model: model, lexicon: .bundled(), policy: .bundled(), focus: UUID())
        let bridge = try ZenzaiSpanBridge(converter: .withDefaultDictionary(),
            applicationDirectory: .temporaryDirectory.appendingPathComponent("long-vowel-\(UUID())"),
            useZenzai: false, learningEnabled: false)
        defer { bridge.releaseAll() }
        let engine = MixedCompositionEngine(segmenter: segmenter, converter: MixedSessionConverter(bridge: bridge,
            sessionID: UUID(), allowJapaneseReadingFallback: true), punctuation: .init())
        for (raw, expected) in [("harike-n", "ハリケーン"), ("harike-nn", "ハリケーン"),
                                ("ko-hi-", "コーヒー"), ("su-pa-", "スーパー"), ("ra-men", "ラーメン")] {
            engine.cancel()
            for character in raw { try engine.handle(.insert(String(character))) }
            #expect(engine.spans.count == 1, "word: \(raw)")
            #expect(engine.spans.first?.sourceRange == (try ScalarRange(0, raw.unicodeScalars.count)))
            #expect(engine.spans.first?.kind == .japaneseRoman)
            #expect(engine.buffer.text == raw)
            try engine.handle(.tab())
            let index = try #require(engine.selectionOptions.firstIndex { $0.text == expected }, "word: \(raw)")
            for _ in 0..<index { try engine.handle(.tab()) }
            try engine.handle(.enter)
            #expect(try engine.handle(.enter).commit?.text == expected)
        }
        for raw in ["harike-n", "harike-no", "harike-ny", "harike-nya", "harike-nn"] {
            try engine.replaceRaw(raw)
            #expect(engine.buffer.text == raw)
            #expect(engine.spans.count == 1)
            #expect(!engine.usedRawFallback)
            try engine.handle(.escape)
            #expect(try engine.markedText().text == raw)
        }
        try engine.replaceRaw("harike-n")
        try engine.handle(.backspace)
        #expect(engine.buffer.text == "harike-")
        try engine.handle(.insert("n"))
        try engine.handle(.tab())
        #expect(engine.selectionOptions.contains { $0.text == "ハリケーン" })

        // A Japanese long-vowel word keeps one atomic original range after Unicode.
        let unicode = "👩‍💻e\u{301} harike-n"
        try engine.replaceRaw(unicode)
        let last = try #require(engine.spans.last)
        #expect(last.sourceRange == (try ScalarRange(6, 14)))
        #expect(last.kind == .japaneseRoman)
        let display = try engine.markedText()
        #expect(display.displayOffset(forRawScalar: 6) == 8)
        #expect(display.displayOffset(forRawScalar: 12) == nil)
        #expect(display.rawScalarOffset(forDisplayUTF16: 8) == 6)
        try engine.handle(.escape)
        #expect(try engine.handle(.enter).commit?.text == unicode)

        for raw in ["note-book", "apple-note", "https://example.com/harike-n",
                    "harike-n.txt", "file_harike-n", "2026-09-24", "3-2"] {
            try engine.replaceRaw(raw)
            #expect(try engine.markedText().text == raw, "protected: \(raw)")
        }
        try engine.replaceRaw("asita-3")
        #expect(try engine.markedText().text == "明日-3")
        // The frozen model already reads room as ろおm in this compound (verified
        // against the pre-change segmenter). Test the English/hyphen boundary here,
        // without pretending this long-vowel fix also improves that English decision.
        try engine.replaceRaw("meeting-room")
        #expect(try engine.markedText().text.hasPrefix("meeting-"))
        #expect(engine.spans.first?.kind == .raw)
        #expect(engine.buffer.text == "meeting-room")
        try engine.replaceRaw("harike-\u{301}n")
        #expect(!engine.usedRawFallback)
        try MixedMarkedTextRenderer.validate(spans: engine.spans, source: engine.buffer.offsets)
        try engine.handle(.escape)
        #expect(try engine.markedText().text == "harike-\u{301}n")
    }
}
