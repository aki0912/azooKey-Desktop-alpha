@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@Suite @MainActor struct JapaneseAfterCommitTests {
    private func fixture(_ probability: Double) throws -> LogisticLanguageModel {
        let url = try autoMixedRepositoryFile("Tools/AutoMixedTraining/fixtures/language_model_v2_fixture.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["vocabulary"] = ["[\"ctx\",\"availability\",\"available\"]"]
        object["coefficients"] = [-15.0]
        object["intercept"] = log(probability / (1 - probability))
        object["calibration"] = ["a": 1.0, "c": 0.0]
        return try LogisticLanguageModel(testFixture: JSONSerialization.data(withJSONObject: object))
    }

    @Test func spellingControlRequiresIndependentEvidenceAndPreservesAmbiguousEnglish() throws {
        for probability in [0.1, 0.99] {
            let model = try fixture(probability)
            let preferred = try JapanesePreferredSegmenter(model: model, lexicon: .bundled(), policy: .bundled(),
                                                           context: .available("固定の文脈です。"), focus: UUID())
            let spans = try preferred.segment("👩‍💻 asita")
            #expect(spans.last?.kind == (probability > 0.65 ? .japaneseRoman : .japaneseKana))
            #expect(spans.last?.sourceRange == (try ScalarRange(4, 9)))
            try MixedMarkedTextRenderer.validate(spans: spans, source: TextOffsetMap("👩‍💻 asita"))
            for raw in ["made", "name", "note", "no", "to", "apple", "meeting"] {
                preferred.reset()
                #expect(try preferred.segment(raw).map(\.kind) == [.raw])
            }
            for raw in ["https://example.com/asita", "asita@example.com", "file_asita"] {
                #expect(try preferred.segment(raw).allSatisfy { $0.kind == .literal || $0.kind == .raw })
            }
        }
    }

    @Test func contextCannotInventEnglishBoundariesInsideRomanUnits() throws {
        let model = try fixture(0.99)
        let preferred = try JapanesePreferredSegmenter(model: model, lexicon: .bundled(), policy: .bundled(),
                                                       context: .available("固定の文脈です。"), focus: UUID())
        for raw in ["henn", "hennk", "hennkou", "hennkoutennga", "henkoutennga", "hennkoutenga", "henkoutenga"] {
            preferred.reset()
            let spans = try preferred.segment(raw)
            #expect(spans.map(\.kind) == [.japaneseRoman], "roman units must stay intact: \(raw)")
            #expect(spans.first?.sourceRange == (try ScalarRange(0, raw.count)))
        }
        // kitte is also an English dictionary prefix (kitten). Keep that existing
        // kana-only policy, while preventing kit + te from bisecting the tte unit.
        preferred.reset()
        let geminate = try preferred.segment("kitte")
        #expect(geminate.map(\.kind) == [.japaneseKana])
        #expect(geminate.first?.sourceRange == (try ScalarRange(0, 5)))
        // Whole English words retain the existing contextual decision.
        for raw in ["hen", "kit", "ten", "meeting", "note"] {
            preferred.reset()
            #expect(try preferred.segment(raw).map(\.kind) == [.raw])
        }
        let raw = "👩‍💻 hennkoutennga"
        let spans = try preferred.segment(raw)
        #expect(spans.last?.kind == .japaneseRoman)
        #expect(spans.last?.sourceRange == (try ScalarRange(4, 17)))
        try MixedMarkedTextRenderer.validate(spans: spans, source: TextOffsetMap(raw))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil))
    func dictionaryAfterCommit() throws { try replay(useZenzai: false) }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil
                  && ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"] != nil))
    func zenzaiAfterCommit() throws { try replay(useZenzai: true) }

    private func replay(useZenzai: Bool) throws {
        let env = ProcessInfo.processInfo.environment
        let model = try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: #require(env["AUTO_MIXED_RUNTIME_MODEL"]))))
        let bridge = try ZenzaiSpanBridge(converter: .withDefaultDictionary(),
            applicationDirectory: .temporaryDirectory.appendingPathComponent("ja-after-commit-\(UUID())"),
            useZenzai: useZenzai, resources: env["AUTO_MIXED_ZENZAI_RESOURCES"].map { URL(fileURLWithPath: $0) }, learningEnabled: false)
        defer { bridge.releaseAll() }
        let epoch = UUID(), focus = UUID()
        var captures = 0
        let session = AutoMixedServerSession(epoch: epoch) { context in
            captures += 1
            return try MixedCompositionEngine(segmenter: JapanesePreferredSegmenter(model: model,
                lexicon: .bundled(), policy: .bundled(),
                context: context.leftSideContext.map(CommittedLeftContext.available) ?? .unavailable, focus: UUID()),
                converter: MixedSessionConverter(bridge: bridge, sessionID: UUID(), leftContext: context.leftSideContext,
                                                 allowJapaneseReadingFallback: true),
                punctuation: .init(leftContext: context.leftSideContext.map(CommittedLeftContext.available) ?? .unavailable),
                backspaceEditor: RomanReadingBackspaceEditor())
        }
        defer { session.close() }
        var operation: UInt64 = 0
        func send(_ action: AutoMixedAction, left: String?) throws -> ConverterServerResponse {
            operation += 1
            return try session.handle(.init(serverEpoch: epoch, focusID: focus, operationID: operation,
                startsFocus: operation == 1, context: .init(leftSideContext: left), action: action))
        }
        func key(_ text: String, code: UInt16 = 0, left: String?) throws -> ConverterServerResponse {
            try send(.key(.init(modifierFlags: [], characters: text, charactersIgnoringModifiers: text, keyCode: code)), left: left)
        }
        func display(_ response: ConverterServerResponse) -> String { response.snapshot.markedText.elements.map(\.content).joined() }
        // Fixed authored text, not app context collected from the user.
        for context in ["日本語を入力して確定しました。", "今日はいい天気なので公園に出かけようと思います。",
                        "ある程度の日本語を入力して確定した後で、"] {
            _ = try key(context, left: nil)
            let first = try #require(try send(.commit, left: nil).autoMixed?.commits.first)
            #expect(first.text == context)
            _ = try send(.commitApplied(first.commitID), left: nil)
            let capturedBefore = captures
            let requestsBefore = bridge.candidateRequestCount
            var response = try key("a", left: first.text)
            for character in "sita" { response = try key(String(character), left: first.text) }
            #expect(captures == capturedBefore + 1)
            #expect(response.autoMixed?.spans.map(\.kind) == [.japaneseRoman])
            #expect(display(response) == "明日")
            #expect(bridge.candidateRequestCount > requestsBefore)
            let list = try key("\t", code: 48, left: first.text)
            guard case .selecting(let candidates, _) = list.snapshot.candidateWindow else {
                Issue.record("Expected conversion candidates"); continue
            }
            #expect(candidates.contains { $0.text == "明日" })
            #expect(display(try key("\u{7f}", code: 51, left: first.text)) == "あし")
            #expect(display(try key("ta", left: first.text)) == "明日")
            let committed = try #require(try send(.commit, left: first.text).autoMixed?.commits.first)
            #expect(committed.text == "明日")
            _ = try send(.commitApplied(committed.commitID), left: nil)
            #expect(session.pendingCommitCount == 0)
            #expect(bridge.activeChildCount == 0)
            for raw in ["kaihatu", "nihongo", "apple", "meeting", "note"] {
                response = try key(raw, left: context)
                if ["apple", "meeting", "note"].contains(raw) {
                    #expect(display(response) == raw)
                } else {
                    #expect(response.autoMixed?.spans.allSatisfy { $0.kind == .japaneseRoman } == true)
                }
                let commit = try #require(try send(.commit, left: context).autoMixed?.commits.first)
                _ = try send(.commitApplied(commit.commitID), left: nil)
            }
        }
        if useZenzai { #expect(bridge.backend == .zenzaiReady) }
    }
}
