@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil))
@MainActor struct EnglishAfterJapaneseTests {
    private func model() throws -> LogisticLanguageModel {
        let path = try #require(ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"])
        return try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    @Test func completeAppleRemainsEnglishAfterJapaneseContext() throws {
        let model = try model()
        let contexts = [CommittedLeftContext.unavailable] + [
            "", "明日", "これは", "明日の予定は", "日本語", "今日は", "入力", "テスト", "です", "。",
            "あ", "あいう", "アップル", "単語", "アプリ", "日本語を入力", "これで", "を", " ", "\n"
        ].map(CommittedLeftContext.available)
        for (index, context) in contexts.enumerated() {
            let preferred = try JapanesePreferredSegmenter(model: model, lexicon: .bundled(), policy: .bundled(),
                                                           context: context, focus: UUID())
            // Forward typing, deleting, and retyping must agree once the English evidence exists.
            for count in Array(1...5) + [4, 3, 4, 5] {
                let raw = String("apple".prefix(count))
                let spans = try preferred.segment(raw)
                if count >= 3 {
                    #expect(spans.map(\.kind) == [.raw], "apple prefix case \(index), length \(count)")
                    #expect(spans.map(\.sourceRange) == [try ScalarRange(0, count)])
                }
            }
            preferred.reset()
            #expect(try preferred.segment("apple").map(\.kind) == [.raw], "pasted apple case \(index)")
        }
    }

    @Test func otherIncompleteRomanEnglishWordsAndJapaneseControls() throws {
        let model = try model()
        for context in ["", "明日", "これは"] {
            let preferred = try JapanesePreferredSegmenter(model: model, lexicon: .bundled(), policy: .bundled(),
                                                           context: .available(context), focus: UUID())
            for raw in ["apple", "apply", "application", "simple", "sample", "example", "people"] {
                preferred.reset()
                #expect(RomanSpanReading.parse(raw)?.suffix.isEmpty != true)
                #expect(try preferred.segment(raw).map(\.kind) == [.raw], "authored English control: \(raw)")
            }
            for raw in ["asita", "asitano", "asitanote", "sushi", "made", "name", "note", "no", "to"] {
                preferred.reset()
                #expect(RomanSpanReading.parse(raw)?.suffix.isEmpty == true)
                #expect(try preferred.segment(raw).allSatisfy { $0.kind == .japaneseRoman || $0.kind == .japaneseKana },
                        "authored Japanese control: \(raw)")
            }
            for raw in ["https://example.com/apple", "apple@example.com", "file_apple"] {
                let spans = try preferred.segment(raw)
                #expect(spans.allSatisfy { $0.kind == .raw || $0.kind == .literal })
                #expect(try MixedMarkedTextRenderer.render(raw: raw, spans: spans).text == raw)
            }
        }
    }

    @Test func committedJapaneseThenEnglishRemainsUsableAcrossRepeatedCompositions() throws {
        try replayJapaneseThenEnglish(useZenzai: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"] != nil))
    func realZenzaiKeepsEnglishAfterRepeatedJapaneseCommits() throws {
        try replayJapaneseThenEnglish(useZenzai: true)
    }

    private func replayJapaneseThenEnglish(useZenzai: Bool) throws {
        let model = try model()
        let bridge = try ZenzaiSpanBridge(converter: .withDefaultDictionary(),
            applicationDirectory: .temporaryDirectory.appendingPathComponent("english-after-ja-\(UUID())"),
            useZenzai: useZenzai, resources: ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"].map {
                URL(fileURLWithPath: $0)
            }, learningEnabled: false)
        defer { bridge.releaseAll() }
        let epoch = UUID(), focus = UUID()
        let session = AutoMixedServerSession(epoch: epoch) { context in
            let id = UUID()
            return try MixedCompositionEngine(segmenter: JapanesePreferredSegmenter(model: model, lexicon: .bundled(),
                policy: .bundled(), context: context.leftSideContext.map(CommittedLeftContext.available) ?? .unavailable,
                focus: id), converter: MixedSessionConverter(bridge: bridge, sessionID: id, allowJapaneseReadingFallback: true))
        }
        defer { session.close() }
        var operation: UInt64 = 0
        func send(_ action: AutoMixedAction, left: String? = nil) throws -> ConverterServerResponse {
            operation += 1
            return try session.handle(.init(serverEpoch: epoch, focusID: focus, operationID: operation,
                startsFocus: operation == 1, context: .init(leftSideContext: left), action: action))
        }
        func type(_ text: String, left: String? = nil) throws -> ConverterServerResponse {
            try send(.key(.init(modifierFlags: [], characters: text, charactersIgnoringModifiers: text, keyCode: 0)), left: left)
        }
        for _ in 0..<3 {
            #expect(try type("asita").snapshot.markedText.elements.map(\.content).joined() == "明日")
            let japanese = try #require(try send(.commit).autoMixed?.commits.first)
            #expect(japanese.text == "明日")
            _ = try send(.commitApplied(japanese.commitID))
            for (index, character) in "apple".enumerated() {
                let response = try type(String(character), left: "明日")
                #expect(response.autoMixed?.raw == String("apple".prefix(index + 1)))
                if index >= 2 {
                    #expect(response.snapshot.markedText.elements.map(\.content).joined() == String("apple".prefix(index + 1)))
                }
            }
            let english = try #require(try send(.commit).autoMixed?.commits.first)
            #expect(english.text == "apple")
            _ = try send(.commitApplied(english.commitID))
            #expect(session.pendingCommitCount == 0)
            #expect(bridge.activeChildCount == 0)
        }
        if useZenzai { #expect(bridge.backend == .zenzaiReady) }
    }
}
