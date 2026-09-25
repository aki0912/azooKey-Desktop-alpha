@testable import Core
import Foundation
import Testing

private struct OneJapaneseRun: LanguageSegmenter {
    func segment(_ raw: String) throws -> [MixedSpan] {
        [try MixedSpan(sourceRange: ScalarRange(0, raw.unicodeScalars.count), kind: .japaneseRoman)]
    }
}

@Suite @MainActor struct MixedSessionReuseTests {
    @Test func tailReuseInvalidatesTokensAndContextSettingsRecreateChildren() throws {
        let bridge = try ZenzaiSpanBridge(converter: .withDefaultDictionary(), applicationDirectory: .temporaryDirectory,
                                         useZenzai: false, learningEnabled: false)
        defer { bridge.releaseAll() }
        let owner = UUID(), composition = UUID(), span = UUID()
        func request(_ raw: String, _ revision: UInt64, left: String? = nil, settings: UInt64 = 0) throws -> JapaneseSpanRequest {
            try .init(identity: .init(sessionID: owner, compositionID: composition, spanID: span, revision: revision),
                      sourceRange: ScalarRange(0, raw.count), raw: raw, leftContext: left,
                      settingsVersion: settings, isAtBufferEnd: true)
        }
        let firstRequest = try request("asita", 1)
        let first = try bridge.candidates(for: firstRequest)
        let nextRequest = try request("asitan", 2)
        let next = try bridge.candidates(for: nextRequest)
        #expect(next.candidates.map(\.text) == first.candidates.map { $0.text + "n" })
        #expect(bridge.candidateRequestCount == 1)
        #expect(bridge.sessionCreatedCount == 1)
        #expect(next.candidates.first?.token != first.candidates.first?.token)
        #expect(throws: JapaneseSpanBridgeError.self) {
            try bridge.recordCommittedSelection(#require(first.candidates.first?.token), identity: firstRequest.identity)
        }
        #expect(throws: JapaneseSpanBridgeError.self) {
            try bridge.recordCommittedSelection(#require(next.candidates.first?.token), identity: firstRequest.identity)
        }
        _ = try bridge.candidates(for: request("asita", 3))
        #expect(bridge.candidateRequestCount == 1)
        _ = try bridge.candidates(for: request("asitano", 4))
        #expect(bridge.candidateRequestCount == 2)
        #expect(bridge.sessionCreatedCount == 1)
        _ = try bridge.candidates(for: request("asitano", 5, left: "予定は"))
        _ = try bridge.candidates(for: request("asitano", 6, left: "予定は", settings: 1))
        #expect(bridge.sessionCreatedCount == 3)
        #expect(bridge.sessionReleasedCount == 2)
        bridge.releaseAll()
        #expect(bridge.sessionCreatedCount == bridge.sessionReleasedCount)
    }

    @Test func engineKeepsSessionButDropsAdoptedCandidateWhenEdited() throws {
        let bridge = try ZenzaiSpanBridge(converter: .withDefaultDictionary(), applicationDirectory: .temporaryDirectory,
                                         useZenzai: false, learningEnabled: false)
        defer { bridge.releaseAll() }
        let engine = MixedCompositionEngine(segmenter: OneJapaneseRun(),
            converter: MixedSessionConverter(bridge: bridge, sessionID: UUID()))
        try engine.replaceRaw("asita")
        let id = try #require(engine.spans.first?.id)
        try engine.handle(.tab(reverse: false))
        let choice = try #require(engine.selectionOptions.firstIndex { $0.text == "あした" })
        #expect(try engine.selectCandidate(at: choice, revision: engine.revision, adopt: false))
        try engine.handle(.enter)
        #expect(try engine.markedText().text == "あした")
        let richRequests = bridge.candidateRequestCount
        let richSessions = bridge.sessionCreatedCount
        try engine.handle(.insert("n"))
        #expect(engine.spans.first?.id == id)
        #expect(try engine.markedText().text == "明日n")
        // Leaving rich selection invalidates its tokens and starts a preview child.
        #expect(bridge.candidateRequestCount == richRequests + 1)
        #expect(bridge.sessionCreatedCount == richSessions + 1)
        try engine.handle(.insert("o"))
        #expect(bridge.sessionCreatedCount == richSessions + 1)
        #expect(bridge.candidateRequestCount == richRequests + 2)
        try engine.handle(.backspace)
        try engine.handle(.escape)
        #expect(try engine.handle(.enter).commit?.text == "asitan")
        #expect(bridge.activeChildCount == 0)
        try engine.replaceRaw("asita")
        engine.cancel()
        #expect(bridge.activeChildCount == 0)
        #expect(bridge.sessionCreatedCount == bridge.sessionReleasedCount)
    }

    @Test func evidenceIsSharedWithinCallButNotAcrossInputsOrContext() throws {
        let url = try autoMixedRepositoryFile("Tools/AutoMixedTraining/fixtures/language_model_v2_fixture.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["vocabulary"] = [String](); object["coefficients"] = [Double](); object["intercept"] = 12.0
        object["calibration"] = ["a": 1.0, "c": 0.0]
        let model = try LogisticLanguageModel(testFixture: JSONSerialization.data(withJSONObject: object))
        let segmenter = try JapanesePreferredSegmenter(model: model, lexicon: .bundled(), policy: .bundled(), focus: UUID())
        let trace = MixedPerformance.Trace()
        try MixedPerformance.$trace.withValue(trace) {
            _ = try segmenter.segment("asita")
            #expect(trace.snapshot().counts["scorePass"] == 1)
            _ = try segmenter.segment("asita")
            #expect(trace.snapshot().counts["scorePass"] == 2)
        }
        object["intercept"] = log(0.95 / 0.05)
        let uncertain = try LogisticLanguageModel(testFixture: JSONSerialization.data(withJSONObject: object))
        let pending = try TrainedMixedSegmenter(model: uncertain, focus: UUID())
        let prefixTrace = MixedPerformance.Trace()
        try MixedPerformance.$trace.withValue(prefixTrace) { _ = try pending.segment("asitan") }
        // The current raw and shortened prefix have different EOS features.
        #expect(prefixTrace.snapshot().counts["scorePass"] == 2)
        let judge = try ContextualLanguageSegmenter(model: model)
        for context: CommittedLeftContext in [.unavailable, .available(""), .available("明日")] {
            for raw in ["asita", "asitan", "apple", "asitanote", "👩‍💻 asita"] {
                let input = LanguageJudgmentInput(raw: raw, leftCommittedContext: context, focusIdentity: UUID(), revision: 1)
                let evidence = try judge.evidence(input)
                let direct = try judge.judge(input).hypotheses
                let shared = try judge.judge(input, evidence: evidence).hypotheses
                #expect(direct.map(\.kind) == shared.map(\.kind))
                #expect(direct.map(\.sourceRange) == shared.map(\.sourceRange))
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil
                  && ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"] != nil))
    func realZenzaiEmptyContextKeepsFreshConversionRanking() throws {
        let env = ProcessInfo.processInfo.environment
        let model = try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: #require(env["AUTO_MIXED_RUNTIME_MODEL"]))))
        let bridge = try ZenzaiSpanBridge(converter: .withDefaultDictionary(),
            applicationDirectory: .temporaryDirectory.appendingPathComponent("mixed-ranking-\(UUID())"),
            useZenzai: true, resources: URL(fileURLWithPath: #require(env["AUTO_MIXED_ZENZAI_RESOURCES"])), learningEnabled: false)
        defer { bridge.releaseAll() }
        for context: CommittedLeftContext in [.unavailable, .available("")] {
            let segmenter = try JapanesePreferredSegmenter(model: model, lexicon: .bundled(), policy: .bundled(),
                context: context, focus: UUID())
            // Propagate the same context to BOTH the judge and converter, as the real app does.
            let engine = MixedCompositionEngine(segmenter: segmenter, converter: MixedSessionConverter(bridge: bridge,
                sessionID: UUID(), leftContext: context.text, allowJapaneseReadingFallback: true), punctuation: .init())
            for (suffix, display) in [(".", "。"), (",", "、"), ("?", "？"), ("!", "！")] {
                for key in "asita" { try engine.handle(.insert(String(key))) }
                #expect(try engine.markedText().text == "明日")
                let requests = bridge.candidateRequestCount, created = bridge.sessionCreatedCount
                try engine.handle(.insert("n"))
                #expect(try engine.markedText().text == "明日n")
                #expect(bridge.candidateRequestCount == requests)
                #expect(bridge.sessionCreatedCount == created)
                try engine.handle(.backspace)
                try engine.handle(.insert(suffix))
                #expect(try engine.markedText().text == "明日" + display)
                #expect(try engine.handle(.enter).commit?.text == "明日" + display)
                #expect(bridge.activeChildCount == 0)
            }
        }
        #expect(bridge.backend == .zenzaiReady)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_STRESS"] == "1"))
    func thousandCompositionsReleaseChildrenAndDrainOrderedQueue() throws {
        let resources = try #require(ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"])
        let bridge = try ZenzaiSpanBridge(converter: .withDefaultDictionary(), applicationDirectory: .temporaryDirectory,
            useZenzai: true, resources: URL(fileURLWithPath: resources), learningEnabled: false)
        defer { bridge.releaseAll() }
        let engine = MixedCompositionEngine(segmenter: OneJapaneseRun(),
            converter: MixedSessionConverter(bridge: bridge, sessionID: UUID()))
        let queue = OrderedAsyncCommandQueue<Int>()
        var completed = 0
        for index in 0..<1000 {
            var failure: Error?
            queue.enqueue(operation: { finish in
                do {
                    for key in "asitan" { try engine.handle(.insert(String(key))) }
                    try engine.handle(.backspace)
                    try engine.handle(.enter)
                } catch { failure = error }
                finish(.finish(index))
            }, completion: { value in
                #expect(value == index)
                completed += 1
            })
            if let failure { throw failure }
            #expect(bridge.activeChildCount == 0)
            #expect(queue.count == 0)
            #expect(bridge.sessionCreatedCount == bridge.sessionReleasedCount)
            #expect(engine.buffer.isEmpty)
        }
        #expect(completed == 1000)
        #expect(bridge.backend == .zenzaiReady)
    }
}
