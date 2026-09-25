@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

// Authored segmentation isolates punctuation policy from model accuracy.
private struct PunctuationSegmenter: LanguageSegmenter {
    func segment(_ raw: String) throws -> [MixedSpan] {
        let source = TextOffsetMap(raw)
        let protection = ProtectedSpanDetector.detect(raw).scalars
        var spans: [MixedSpan] = []
        var start = 0
        while start < protection.count {
            var end = start + 1
            while end < protection.count, protection[end] == protection[start] { end += 1 }
            let range = try ScalarRange(start, end)
            let text = try source.slice(range)
            let kind: SpanKind = protection[start] == .gap ? .gap : protection[start] == .literal ? .literal
                : ["asita", "desu"].contains(text) ? .japaneseRoman : .raw
            spans.append(MixedSpan(sourceRange: range, kind: kind))
            start = end
        }
        return spans
    }
}

@MainActor private final class PunctuationConverter: JapaneseSpanConverting {
    var leftDisplays: [String] = []
    var fails = false
    func candidates(for raw: String, span: MixedSpan) throws -> [MixedCandidate] {
        if fails { throw AutoMixedError.invalidCandidate }
        return [.init(token: raw, text: raw == "asita" ? "明日" : "です")]
    }
    func candidates(for raw: String, span: MixedSpan, leftDisplay: String) throws -> [MixedCandidate] {
        leftDisplays.append(leftDisplay)
        return try candidates(for: raw, span: span)
    }
}

@Suite @MainActor struct MixedPunctuationTests {
    private func engine(context: CommittedLeftContext = .unavailable) -> MixedCompositionEngine {
        MixedCompositionEngine(segmenter: PunctuationSegmenter(), converter: PunctuationConverter(),
                               punctuation: MixedPunctuationPolicy(leftContext: context))
    }

    @Test func japaneseDefaultEnglishAdjacencyAndWhitespace() throws {
        let engine = engine()
        for (raw, expected) in [("-.,[]?!", "ー。、「」？！"), ("asita-.,", "明日ー。、"),
                                ("asita?", "明日？"), ("asita!", "明日！"), ("asita?!", "明日？！"),
                                ("apple?!", "apple?!"), ("API!", "API!"), ("apple ?", "apple ？"),
                                ("apple日本語!", "apple日本語！"), ("asita?apple!", "明日？apple!"),
                                ("apple!desu?", "apple!です？"),
                                ("apple-.,", "apple-.,"), ("API.", "API."),
                                ("apple .", "apple 。"), ("apple日本語.", "apple日本語。"),
                                ("asita,apple.", "明日、apple."), ("apple,desu.", "apple,です。") ] {
            try engine.replaceRaw(raw)
            #expect(try engine.markedText().text == expected, "authored: \(raw)")
            #expect(engine.buffer.text == raw)
            #expect(try engine.handle(.enter).commit?.text == expected)
        }
        // Unresolved Latin raw is not positive English evidence.
        let span = try MixedSpan(sourceRange: ScalarRange(0, 1), kind: .unresolved)
        let dot = try MixedSpan(sourceRange: ScalarRange(1, 2), kind: .literal)
        #expect(try MixedMarkedTextRenderer.render(raw: "n.", spans: [span, dot], punctuation: .init()).text == "n。")
    }

    @Test func pairedBracketsFollowTheirOpeningIncludingCommittedContext() throws {
        for (raw, expected) in [("[apple]", "「apple」"), ("apple[asita]", "apple[明日]"),
                                ("[[apple]]", "「「apple」」"), ("asita[apple]", "明日「apple」"),
                                ("apple]", "apple]"), ("[3]", "[3]"),
                                ("()", "（）"), ("asita()", "明日（）"),
                                ("(apple)", "（apple）"), ("apple(asita)", "apple(明日)"),
                                ("((apple))", "（（apple））"), ("([apple])", "（「apple」）"),
                                ("asita(apple)", "明日（apple）"), ("apple()", "apple()"),
                                ("apple ()", "apple （）"), ("apple)", "apple)"), ("asita)", "明日）"),
                                ("(3)", "(3)"), ("(apple3)", "（apple3）")] {
            let engine = engine()
            try engine.replaceRaw(raw)
            #expect(try engine.markedText().text == expected, "authored: \(raw)")
        }
        for (context, raw, expected) in [("明日", ".", "。"), ("apple", ".", "."),
                                         ("明日", "?!", "？！"), ("apple", "?!", "?!"),
                                         ("明日？", "!", "！"), ("apple ", "?", "？"),
                                         ("apple ", ".", "。"), ("「apple", "]", "」"),
                                         ("apple[明日", "]", "]"), ("", ",", "、"),
                                         ("明日", "()", "（）"), ("apple", "()", "()"),
                                         ("（apple", ")", "）"), ("apple(明日", ")", ")"),
                                         ("（「apple", "])", "」）"), ("（apple）", ")", "）")] {
            let engine = engine(context: .available(context))
            try engine.replaceRaw(raw)
            #expect(try engine.markedText().text == expected)
        }
    }

    @Test func structuredTokensNumbersAndExistingUnicodeStayVerbatim() throws {
        let engine = engine()
        for raw in ["https://example.com/a-b[x]", "www.example.com", "name@example.com", "main.swift", "src/a-b.swift",
                    "https://example.com/?q=日本語!", "foo_bar?!", "5!", "?3", "3?",
                    "snake_case[0]", "foo::bar[1]", "1.", "-3.14", "1,234.5", "2026-09-24", "v3.2",
                    "ー。、「」？！（）", "https://example.com/a(b)", "(\u{301}", ".\u{301}", "?\u{301}", "!\u{301}", "👩‍💻e\u{301}"] {
            try engine.replaceRaw(raw)
            #expect(try engine.markedText().text == raw, "protected: \(raw)")
        }
        let continuedURL = self.engine(context: .available("https://example.com"))
        try continuedURL.replaceRaw("/a-b[x].?!")
        #expect(try continuedURL.markedText().text == "/a-b[x].?!")
        let numeric = self.engine(context: .available("3"))
        try numeric.replaceRaw(".")
        #expect(try numeric.markedText().text == ".")
    }

    @Test func unicodeOffsetsEscapeDeletionAndCandidateDisplayRemainConsistent() throws {
        let engine = engine()
        for (suffix, expected) in [("-.,[]", "ー。、「」"), ("?!", "？！"), ("()", "（）")] {
            let raw = "👩‍💻e\u{301}" + suffix
            try engine.replaceRaw(raw)
            let marked = try engine.markedText()
            #expect(marked.text == "👩‍💻e\u{301}" + expected)
            for offset in 5...raw.unicodeScalars.count {
                #expect(marked.displayOffset(forRawScalar: offset) == offset + 2)
                #expect(marked.rawScalarOffset(forDisplayUTF16: offset + 2) == offset)
            }
            try engine.handle(.backspace)
            #expect(engine.buffer.text == String(raw.dropLast()))
            try engine.handle(.insert(String(suffix.suffix(1))))
            #expect(try engine.markedText().text == marked.text)
            try engine.handle(.escape)
            #expect(try engine.markedText().text == raw)
            #expect(try engine.handle(.enter).commit?.text == raw)
        }
        for (raw, expected) in [(".", "。"), ("?", "？"), ("!", "！"), ("(", "（"), (")", "）")] {
            try engine.replaceRaw(raw)
            try engine.handle(.tab())
            #expect(engine.selectionOptions.map(\.text) == [expected])
            #expect(try engine.markedText().text == expected)
            try engine.handle(.enter)
            #expect(try engine.handle(.enter).commit?.text == expected)
            try engine.replaceRaw(raw)
            try engine.handle(.escape)
            #expect(try engine.markedText().text == raw)
            try engine.handle(.tab())
            #expect(engine.selectionOptions.map(\.text) == [expected])
            #expect(engine.buffer.text == raw)
            try engine.handle(.enter)
            #expect(try engine.handle(.enter).commit?.text == expected)
        }
    }

    @Test func converterContextUsesDisplayedPunctuationAndLegacyDefaultStaysExact() throws {
        let converter = PunctuationConverter()
        let engine = MixedCompositionEngine(segmenter: PunctuationSegmenter(), converter: converter, punctuation: .init())
        try engine.replaceRaw("[asita]")
        #expect(converter.leftDisplays.last == "「")
        #expect(try engine.markedText().text == "「明日」")
        converter.fails = true
        try engine.replaceRaw("asita.")
        #expect(engine.usedRawFallback)
        #expect(try engine.markedText().text == "asita.")
        let legacy = MixedCompositionEngine(segmenter: PunctuationSegmenter(), converter: PunctuationConverter())
        try legacy.replaceRaw("asita-.,[]?!")
        #expect(try legacy.markedText().text == "明日-.,[]?!")
    }

    @Test func transportCommitUsesFreshContextAndKeepsRawAndWireSchema() throws {
        let epoch = UUID(), focus = UUID()
        let session = AutoMixedServerSession(epoch: epoch) { context in
            engine(context: context.leftSideContext.map(CommittedLeftContext.available) ?? .unavailable)
        }
        var operation: UInt64 = 0
        func send(_ action: AutoMixedAction, context: String? = nil) throws -> AutoMixedResponse {
            operation += 1
            let response = try session.handle(.init(serverEpoch: epoch, focusID: focus, operationID: operation,
                startsFocus: operation == 1, context: .init(leftSideContext: context), action: action))
            let encoded = try ConverterServerCodec.encode(response)
            return try #require(ConverterServerCodec.decodeResponse(from: encoded).autoMixed)
        }
        for (context, raw, expected) in [("明日", ".", "。"), ("apple", ".", "."), ("", ".", "。"),
                                         ("明日", "?", "？"), ("apple", "?", "?"),
                                         ("明日", "!", "！"), ("apple", "!", "!")] {
            let inserted = try send(.key(.init(modifierFlags: [], characters: raw, charactersIgnoringModifiers: raw, keyCode: 0)), context: context)
            #expect(inserted.raw == raw)
            #expect(inserted.spans.count == 1)
            #expect(inserted.spans.first?.kind == .literal)
            let commit = try #require(send(.commit).commits.first)
            #expect(commit.text == expected)
            #expect(try send(.commitApplied(commit.commitID)).commits.isEmpty)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil))
    func trainedSegmenterAndDictionaryConversionKeepPunctuationPolicy() throws {
        let path = try #require(ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"])
        let model = try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let segmenter = try JapanesePreferredSegmenter(model: model, lexicon: .bundled(), policy: .bundled(), focus: UUID())
        let bridge = try ZenzaiSpanBridge(converter: .withDefaultDictionary(),
            applicationDirectory: .temporaryDirectory.appendingPathComponent("punctuation-\(UUID())"),
            useZenzai: false, learningEnabled: false)
        defer { bridge.releaseAll() }
        let engine = MixedCompositionEngine(segmenter: segmenter, converter: MixedSessionConverter(bridge: bridge,
            sessionID: UUID(), allowJapaneseReadingFallback: true), punctuation: .init())
        for (raw, expected) in [("asita.", "明日。"), ("asita,", "明日、"), ("apple.", "apple."),
                                ("asita?", "明日？"), ("asita!", "明日！"), ("asita?!", "明日？！"),
                                ("apple?", "apple?"), ("apple!", "apple!"),
                                ("[apple]", "「apple」"), ("asita-", "明日ー"), ("asita(apple)", "明日（apple）"), ("apple(asita)", "apple(明日)"), ("()", "（）")] {
            engine.cancel()
            for character in raw { try engine.handle(.insert(String(character))) }
            #expect(try engine.markedText().text == expected, "runtime: \(raw)")
            #expect(engine.buffer.text == raw)
            #expect(!engine.usedRawFallback)
            #expect(try engine.handle(.enter).commit?.text == expected)
        }
    }
}
