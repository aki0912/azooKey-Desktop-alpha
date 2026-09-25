@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

private struct RichCandidateSegmenter: LanguageSegmenter {
    func segment(_ raw: String) throws -> [MixedSpan] {
        let count = raw.unicodeScalars.count
        let start = count - 3
        return [try MixedSpan(sourceRange: ScalarRange(0, start), kind: .literal),
                try MixedSpan(sourceRange: ScalarRange(start, count), kind: .japaneseRoman)]
    }
}

@MainActor private final class RichCandidateConverter: JapaneseSpanConverting {
    var previews = 0, enumerations = 0
    var contexts: [String] = []
    var fails = false
    func candidates(for raw: String, span: MixedSpan) throws -> [MixedCandidate] {
        previews += 1
        return [.init(token: "preview", text: "回")]
    }
    func selectionCandidates(for raw: String, span: MixedSpan, leftDisplay: String) throws -> [MixedCandidate]? {
        enumerations += 1
        contexts.append(leftDisplay)
        if fails { throw AutoMixedError.invalidCandidate }
        return ["回", "階"].map { .init(token: "rich-\(enumerations)-\($0)", text: $0) }
    }
}

@Suite @MainActor struct MixedRichCandidateTests {
    @Test func enrichOnlyWhenOpeningAndRebindAdoptedTokens() throws {
        let converter = RichCandidateConverter()
        let engine = MixedCompositionEngine(segmenter: RichCandidateSegmenter(), converter: converter)
        try engine.replaceRaw("👩‍💻13kai")
        #expect(converter.enumerations == 0)
        #expect(try engine.markedText().text == "👩‍💻13回")
        try engine.handle(.tab())
        #expect(converter.contexts == ["👩‍💻13"])
        #expect(engine.selectionOptions.map(\.text) == ["回", "階"])
        try engine.handle(.tab())
        let oldToken = try #require(engine.selectionOptions.last?.token)
        #expect(converter.enumerations == 1)
        #expect(try engine.markedText().text == "👩‍💻13階")
        try engine.handle(.enter) // Adopt; opening the list again must keep this choice.
        try engine.handle(.tab())
        #expect(engine.selectionIndex == 1)
        #expect(engine.selectionOptions.last?.token != oldToken)
        #expect(converter.enumerations == 2)
        try engine.handle(.tab(reverse: true))
        #expect(engine.selectionIndex == 0)
        #expect(converter.enumerations == 2)
        try engine.handle(.escape)
        #expect(try engine.markedText().text == "👩‍💻13階")
        try engine.handle(.escape)
        try engine.handle(.tab())
        #expect(converter.enumerations == 2) // Raw preview must never invoke Zenzai.
        #expect(try engine.markedText().text == "👩‍💻13kai")
        engine.cancel()
        try engine.replaceRaw("13kai")
        converter.fails = true
        try engine.handle(.tab())
        #expect(engine.usedRawFallback)
        #expect(try engine.markedText().text == "13kai")
        #expect(engine.buffer.text == "13kai")
        #expect(engine.state == .composing)
        #expect(engine.selectionOptions.isEmpty)
        engine.cancel()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil
                  && ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"] != nil))
    func realZenzaiRanksFloorSecondWithoutRecomputingOnCandidateNavigation() throws {
        let env = ProcessInfo.processInfo.environment
        let model = try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: #require(env["AUTO_MIXED_RUNTIME_MODEL"]))))
        let resources = URL(fileURLWithPath: try #require(env["AUTO_MIXED_ZENZAI_RESOURCES"]))
        let bridge = try ZenzaiSpanBridge(converter: .withDefaultDictionary(),
            applicationDirectory: .temporaryDirectory.appendingPathComponent("rich-candidate-\(UUID())"),
            useZenzai: true, resources: resources, learningEnabled: false)
        defer { bridge.releaseAll() }
        let converter = MixedSessionConverter(bridge: bridge, sessionID: UUID(), leftContext: "", allowJapaneseReadingFallback: true)
        let engine = MixedCompositionEngine(segmenter: try JapanesePreferredSegmenter(model: model,
            lexicon: .bundled(), policy: .bundled(), context: .available(""), focus: UUID()),
            converter: converter, punctuation: .init(), backspaceEditor: RomanReadingBackspaceEditor())
        for key in "13kai" { try engine.handle(.insert(String(key))) }
        #expect(try engine.markedText().text == "13回")
        let previous = try #require(converter.lastResults.values.first)
        let previousToken = try #require(previous.candidates.first?.token)
        let count = bridge.candidateRequestCount
        let started = ContinuousClock.now
        try engine.handle(.tab())
        print("Rich candidate authored 13kai open duration: \(started.duration(to: .now))")
        #expect(engine.selectionOptions.prefix(2).map(\.text) == ["回", "階"])
        #expect(bridge.backend == .zenzaiReady)
        #expect(bridge.candidateRequestCount == count + 1)
        #expect(throws: JapaneseSpanBridgeError.self) {
            try bridge.recordCommittedSelection(previousToken, identity: previous.identity)
        }
        try engine.handle(.tab())
        #expect(try engine.markedText().text == "13階")
        #expect(bridge.candidateRequestCount == count + 1)
        try engine.handle(.enter)
        try engine.handle(.tab())
        #expect(engine.selectionIndex == 1)
        #expect(bridge.candidateRequestCount == count + 1)
        try engine.handle(.enter)
        #expect(try engine.handle(.enter).commit?.text == "13階")
        #expect(bridge.activeChildCount == 0)
        for key in "13kai" { try engine.handle(.insert(String(key))) }
        try engine.handle(.tab())
        try engine.handle(.tab())
        try engine.handle(.backspace)
        #expect(engine.selectionOptions.isEmpty)
        #expect(engine.buffer.text == "13ka")
        #expect(try engine.markedText().text == "13か")
        try engine.handle(.insert("i"))
        #expect(try engine.markedText().text == "13回")
        engine.cancel()
        #expect(bridge.activeChildCount == 0)
    }
}
