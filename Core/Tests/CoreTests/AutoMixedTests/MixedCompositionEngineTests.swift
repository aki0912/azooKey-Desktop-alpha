import Core
import Foundation
import Testing

// Hand-authored test doubles, not a romanization table or a trained language model.
private let mockWords = ["ashita": ["明日", "あした"], "desu": ["です"], "kyou": ["今日"],
                         "kyouha": ["今日は"], "de": ["で"], "API": [], "wotataku": ["を叩く"]]

private struct MockSegmenter: LanguageSegmenter {
    var invalidCoverage = false
    func segment(_ raw: String) throws -> [MixedSpan] {
        if invalidCoverage {
            return []
        }
        var spans: [MixedSpan] = []
        var index = raw.startIndex
        var offset = 0
        let words = mockWords.keys.sorted { $0.count > $1.count }
        while index < raw.endIndex {
            let suffix = raw[index...]
            let word = words.first(where: { suffix.hasPrefix($0) && !(mockWords[$0]?.isEmpty ?? true) })
            let text = word ?? String(raw[index])
            let kind: SpanKind = word != nil ? .japaneseRoman : (text == " " ? .gap : .raw)
            let end = offset + text.unicodeScalars.count
            if kind != .japaneseRoman, let previous = spans.last, previous.kind == kind {
                spans.removeLast()
                spans.append(try MixedSpan(sourceRange: ScalarRange(previous.sourceRange.lowerBound, end), kind: kind))
            } else {
                spans.append(try MixedSpan(sourceRange: ScalarRange(offset, end), kind: kind))
            }
            index = raw.index(index, offsetBy: text.count)
            offset = end
        }
        return spans
    }
}

@MainActor private final class MockConverter: JapaneseSpanConverting {
    var requests: [String] = []
    var fails = false
    var invalidCandidate = false
    var leftDisplays: [String] = []
    var finishedCount = 0
    var selectionFailure = false
    var invalidSelection = false

    func reading(for raw: String) -> String { raw == "ashita main" ? "あした まいn" : raw }

    func selectionCandidates(for raw: String, span: MixedSpan, leftDisplay: String) throws -> [MixedCandidate]? {
        if selectionFailure { throw AutoMixedError.invalidCandidate }
        if invalidSelection {
            return [.init(token: "invalid", text: "")]
        }
        return nil
    }

    func candidates(for raw: String, span: MixedSpan, leftDisplay: String) throws -> [MixedCandidate] {
        leftDisplays.append(leftDisplay)
        return try candidates(for: raw, span: span)
    }

    func finishComposition() { finishedCount += 1 }

    func candidates(for raw: String, span: MixedSpan) throws -> [MixedCandidate] {
        requests.append(raw)
        if fails {
            throw AutoMixedError.invalidCandidate
        }
        if invalidCandidate {
            return [MixedCandidate(token: "invalid", text: "")]
        }
        return (mockWords[raw] ?? []).enumerated().map { index, text in
            MixedCandidate(token: "mock:\(raw):\(index)", text: text)
        }
    }
}

@Suite @MainActor struct MixedCompositionEngineTests {
    @Test func directSelectionValidatesRevisionAndDoesNotReplayNavigation() throws {
        let engine = MixedCompositionEngine(segmenter: MockSegmenter(), converter: MockConverter())
        try engine.replaceRaw("ashita")
        let composingRevision = engine.revision
        #expect(try !engine.selectCandidate(at: 0, revision: composingRevision, adopt: true))
        try engine.handle(.tab())
        let selectingRevision = engine.revision
        #expect(try !engine.selectCandidate(at: -1, revision: selectingRevision, adopt: false))
        #expect(try !engine.selectCandidate(at: 2, revision: selectingRevision, adopt: false))
        #expect(try !engine.selectCandidate(at: 1, revision: composingRevision, adopt: true))
        #expect(engine.revision == selectingRevision)
        #expect(try engine.selectCandidate(at: 1, revision: selectingRevision, adopt: false))
        #expect(engine.revision == selectingRevision + 1)
        #expect(try engine.markedText().text == "あした")
        #expect(try engine.selectCandidate(at: 1, revision: engine.revision, adopt: true))
        #expect(engine.revision == selectingRevision + 2)
        #expect(engine.state == .composing)
        #expect(try engine.handle(.enter).commit?.text == "あした")
    }

    @Test func candidateFailuresReleaseChildrenAndAllowRawCommitOrFurtherEditing() throws {
        for invalidSelection in [false, true] {
            let converter = MockConverter()
            let engine = MixedCompositionEngine(segmenter: MockSegmenter(), converter: converter)
            try engine.replaceRaw("ashita API👩‍💻")
            converter.selectionFailure = !invalidSelection
            converter.invalidSelection = invalidSelection
            try engine.handle(.tab())
            #expect(engine.usedRawFallback)
            #expect(engine.selectionOptions.isEmpty)
            #expect(engine.state == .composing)
            #expect(converter.finishedCount == 1)
            #expect(try engine.markedText().text == "ashita API👩‍💻")
            #expect(try engine.handle(.enter).commit?.text == "ashita API👩‍💻")
            converter.selectionFailure = false
            converter.invalidSelection = false
            try engine.handle(.insert("ashita"))
            #expect(!engine.usedRawFallback)
            #expect(try engine.markedText().text == "明日")
        }
        let converter = MockConverter()
        let engine = MixedCompositionEngine(segmenter: MockSegmenter(), converter: converter)
        try engine.replaceRaw("ashita kyou")
        try engine.handle(.tab())
        converter.fails = true // Refresh of the unselected left span fails during adoption.
        #expect(try engine.selectCandidate(at: 0, revision: engine.revision, adopt: true))
        #expect(engine.usedRawFallback)
        #expect(engine.selectionIndex == nil)
        #expect(try engine.handle(.enter).commit?.text == "ashita kyou")
    }

    @Test func wholeFieldEditingUsesAcceptedLeftDisplayAndReleasesOnCancel() throws {
        let converter = MockConverter()
        let engine = MixedCompositionEngine(segmenter: MockSegmenter(), converter: converter)
        try engine.replaceRaw("ashita")
        try engine.handle(.tab())
        try engine.handle(.tab())
        try engine.handle(.enter)
        try engine.replaceRaw("ashita kyou")
        #expect(try engine.markedText().text == "あした 今日")
        #expect(converter.leftDisplays.last == "あした ")
        engine.cancel()
        #expect(converter.finishedCount == 1)
        #expect(engine.buffer.isEmpty)
        #expect(try engine.markedText().text.isEmpty)
    }

    @Test func mixedRunsPreserveCaseSpacesAndSource() throws {
        let converter = MockConverter()
        let engine = MixedCompositionEngine(segmenter: MockSegmenter(), converter: converter)
        try engine.handle(.insert("kyouhaSwiftdeAPIwotataku"))
        #expect(engine.buffer.text == "kyouhaSwiftdeAPIwotataku")
        #expect(try engine.markedText().text == "今日はSwiftでAPIを叩く")
        #expect(converter.requests == ["kyouha", "de", "wotataku"])
        #expect(engine.state == .composing)
        #expect(try engine.markedText().displayOffset(forRawScalar: engine.buffer.cursorScalarOffset) == 15)
    }

    @Test func selectionCyclesAdoptsWithoutCommittingAndSurvivesAdjacentEdit() throws {
        let converter = MockConverter()
        let engine = MixedCompositionEngine(segmenter: MockSegmenter(), converter: converter)
        try engine.handle(.insert("ashita"))
        let revision = engine.revision
        try engine.handle(.tab())
        #expect(engine.state == .selecting)
        try engine.handle(.tab(reverse: true))
        #expect(try engine.markedText().text == "あした")
        try engine.handle(.tab())
        #expect(try engine.markedText().text == "明日")
        try engine.handle(.tab())
        #expect(try engine.handle(.enter).commit == nil)
        #expect(engine.state == .composing)
        #expect(engine.revision > revision)
        try engine.handle(.space)
        try engine.handle(.insert("Hello"))
        #expect(try engine.markedText().text == "あした Hello")
        #expect(converter.requests == ["ashita"])
        try engine.handle(.tab())
        #expect(engine.selectionOptions.count == 2)
        #expect(engine.selectionIndex == 1)
        try engine.handle(.tab())
        #expect(try engine.markedText().text == "明日 Hello")
        try engine.handle(.escape)
        #expect(try engine.markedText().text == "あした Hello")
        let result = try engine.handle(.enter)
        #expect(result.commit?.text == "あした Hello")
        #expect(result.commit?.sourceScalarCount == 12)
        #expect(engine.state == .idle)
        #expect(engine.buffer.isEmpty)
        #expect(try engine.handle(.enter).disposition == .fallthroughToApplication)
    }

    @Test func firstEscapeKeepsRawPreviewUntilTabResumesConversion() throws {
        let converter = MockConverter()
        let engine = MixedCompositionEngine(segmenter: MockSegmenter(), converter: converter)
        try engine.handle(.insert("ashita"))
        try engine.handle(.escape)
        #expect(engine.state == .rawPreview)
        #expect(try engine.markedText().text == "ashita")
        #expect(try engine.markedText().text == "ashita")
        try engine.handle(.tab())
        #expect(engine.state == .selecting)
        #expect(engine.selectionOptions.map(\.text) == ["明日", "あした"])
        #expect(try engine.markedText().text == "明日")
        try engine.handle(.escape)
        #expect(try engine.markedText().text == "明日")
        #expect(converter.requests == ["ashita", "ashita"])
        try engine.handle(.space)
        #expect(engine.state == .composing)
        #expect(try engine.markedText().text == "明日 ")
    }

    @Test func tabAfterEscapePreservesMixedRawAndSupportsReverseSelection() throws {
        for reverse in [false, true] {
            let engine = MixedCompositionEngine(segmenter: MockSegmenter(), converter: MockConverter())
            let raw = "ashita API👩‍💻"
            try engine.replaceRaw(raw)
            try engine.handle(.escape)
            #expect(try engine.markedText().text == raw)
            let opened = try engine.handle(.tab(reverse: reverse))
            #expect(opened.commit == nil && engine.state == .selecting)
            #expect(engine.buffer.text == raw)
            #expect(engine.selectionOptions.map(\.text) == ["明日", "あした"])
            #expect(try engine.markedText().text == "明日 API👩‍💻")
            #expect(try engine.handle(.enter).commit == nil)
            #expect(try engine.handle(.enter).commit?.text == "明日 API👩‍💻")
            try engine.replaceRaw("hello 👩‍💻")
            try engine.handle(.escape)
            try engine.handle(.tab(reverse: reverse))
            #expect(try engine.markedText().text == "hello 👩‍💻")
            #expect(engine.buffer.text == "hello 👩‍💻")
        }
    }

    @Test func secondEscapeCancelsEveryPreviewWithoutCommitting() throws {
        for setup: MixedInputEvent? in [nil, .tab(), .characterType(.katakana), .characterType(.halfWidthRoman)] {
            let converter = MockConverter()
            let engine = MixedCompositionEngine(segmenter: MockSegmenter(), converter: converter)
            try engine.handle(.insert("ashita API👩‍💻"))
            if let setup { try engine.handle(setup) }
            let first = try engine.handle(.escape)
            #expect(first.commit == nil && !engine.buffer.isEmpty)
            #expect(engine.characterType == nil && engine.selectionOptions.isEmpty)
            let finished = converter.finishedCount
            let second = try engine.handle(.escape)
            #expect(second.disposition == .consumed && second.commit == nil)
            #expect(engine.state == .idle && engine.buffer.isEmpty && engine.spans.isEmpty)
            #expect(try engine.markedText().text.isEmpty)
            #expect(converter.finishedCount == finished + 1)
            #expect(try engine.handle(.escape).disposition == .fallthroughToApplication)
            try engine.handle(.insert("ashita"))
            #expect(try engine.markedText().text == "明日")
            try engine.handle(.escape)
            #expect(try engine.markedText().text == "ashita")
        }
    }

    @Test func editingAndCandidateKeysRestartTheEscapeSequence() throws {
        for event: MixedInputEvent in [.insert("a"), .space, .backspace, .tab(), .characterType(.halfWidthRoman)] {
            let engine = MixedCompositionEngine(segmenter: MockSegmenter(), converter: MockConverter())
            try engine.handle(.insert("ashita"))
            try engine.handle(.escape)
            try engine.handle(event)
            try engine.handle(.escape)
            #expect(!engine.buffer.isEmpty)
            try engine.handle(.escape)
            #expect(engine.buffer.isEmpty)
        }
    }

    @Test func editWhileSelectingDiscardsTheCandidateGeneration() throws {
        let engine = MixedCompositionEngine(segmenter: MockSegmenter(), converter: MockConverter())
        try engine.handle(.insert("ashita"))
        try engine.handle(.tab())
        try engine.handle(.tab())
        let generation = engine.revision
        try engine.handle(.backspace)
        #expect(engine.revision > generation)
        #expect(engine.state == .composing)
        #expect(engine.selectionOptions.isEmpty)
        #expect(engine.selectionIndex == nil)
        #expect(engine.buffer.text == "ashit")
        #expect(try engine.handle(.enter).commit?.text == "ashit")
    }

    @Test func emptyKeysFallThroughAndEnglishTabIsConsumed() throws {
        let engine = MixedCompositionEngine(segmenter: MockSegmenter(), converter: MockConverter())
        for key: MixedInputEvent in [.enter, .escape, .tab(), .tab(reverse: true), .backspace] {
            #expect(try engine.handle(key).disposition == .fallthroughToApplication)
        }
        #expect(engine.revision == 0)
        try engine.handle(.space)
        #expect(engine.buffer.text == " ")
        try engine.handle(.backspace)
        #expect(engine.state == .idle)
        try engine.handle(.insert("Hello"))
        #expect(try engine.handle(.tab()).disposition == .consumed)
        #expect(try engine.handle(.enter).commit == nil)
        #expect(try engine.handle(.enter).commit?.text == "Hello")
    }

    @Test func providerFailuresKeepTheOriginalText() throws {
        let invalidConverter = MockConverter()
        invalidConverter.invalidCandidate = true
        let throwingConverter = MockConverter()
        throwingConverter.fails = true
        let engines = [
            MixedCompositionEngine(segmenter: MockSegmenter(invalidCoverage: true), converter: MockConverter()),
            MixedCompositionEngine(segmenter: MockSegmenter(), converter: invalidConverter),
            MixedCompositionEngine(segmenter: MockSegmenter(), converter: throwingConverter)
        ]
        for engine in engines {
            try engine.handle(.insert("ashita API👩‍💻"))
            #expect(engine.usedRawFallback)
            #expect(engine.buffer.text == "ashita API👩‍💻")
            #expect(try engine.markedText().text == "ashita API👩‍💻")
            #expect(try engine.handle(.enter).commit?.text == "ashita API👩‍💻")
        }
    }

    // Each optional expected field in the shared event fixture needs an independent assertion.
    // swiftlint:disable:next cyclomatic_complexity
    @Test func suppliedEventFixtureBasics() throws {
        let fixture = try loadEventFixture()
        let covered: Set<String> = ["space-literal", "double-space", "candidate-then-commit", "enter-pass-empty",
                                    "escape-raw", "backspace-prefix", "backspace-grapheme"]
        // These are explicitly later stages, not silently dropped fixture assertions.
        let deferred: Set<String> = ["explicit-raw", "duplicate-event", "duplicate-commit", "stale-focus",
                                     "command-pass", "old-capability", "fixture-rejected", "learn-after-ack", "buffer-capacity"]
        #expect(fixture.kind == "contract_fixture")
        #expect(Set(fixture.cases.map(\.id)) == covered.union(deferred))
        for scenario in fixture.cases where covered.contains(scenario.id) {
            let converter = MockConverter()
            let engine = MixedCompositionEngine(segmenter: MockSegmenter(), converter: converter)
            var commits: [MixedCommit] = []
            var lastDisposition: MixedEventDisposition?
            for event in scenario.events {
                if event.op == "assert" {
                    #expect(commits.count == event.insert_effect_count, "\(scenario.id)")
                    continue
                }
                let result = try engine.handle(event.inputEvent())
                if let commit = result.commit {
                    commits.append(commit)
                }
                lastDisposition = result.disposition
            }
            let expected = scenario.expected
            if let raw = expected.raw {
                #expect(engine.buffer.text == raw, "\(scenario.id)")
            }
            if let display = expected.display_with_mock {
                #expect(try engine.markedText().text == display, "\(scenario.id)")
            }
            if let count = expected.insert_effect_count {
                #expect(commits.count == count, "\(scenario.id)")
            }
            if let text = expected.inserted_text {
                #expect(commits.map(\.text).joined() == text, "\(scenario.id)")
            }
            if let empty = expected.composition_empty {
                #expect(engine.buffer.isEmpty == empty, "\(scenario.id)")
            }
            if let disposition = expected.last_event_disposition {
                #expect(disposition == "fallthroughToApplication")
                #expect(lastDisposition == .fallthroughToApplication, "\(scenario.id)")
            }
            // No learning operation exists on the T1 protocol. The fixture's dynamic
            // learned_ja_candidate_count assertion belongs to the T4/T5 acknowledgement tests.
            if scenario.id == "escape-raw" {
                #expect(converter.requests == ["ashita"])
            }
        }
    }
}

// Mirror the external Python fixture schema without renaming its fields.
// swiftlint:disable identifier_name
private struct EventFixture: Decodable {
    let kind: String
    let cases: [Scenario]
    struct Scenario: Decodable {
        let id: String
        let events: [Event]
        let expected: Expected
    }
    struct Event: Decodable {
        let op: String
        let text: String?
        let key: String?
        let insert_effect_count: Int?

        func inputEvent() throws -> MixedInputEvent {
            if op == "insert", let text {
                return .insert(text)
            }
            guard op == "key" else {
                throw FixtureError.unsupportedEvent
            }
            switch key {
            case "Space": return .space
            case "Tab": return .tab()
            case "Enter": return .enter
            case "Escape": return .escape
            case "Backspace": return .backspace
            default: throw FixtureError.unsupportedEvent
            }
        }
    }
    struct Expected: Decodable {
        let raw: String?
        let display_with_mock: String?
        let insert_effect_count: Int?
        let inserted_text: String?
        let composition_empty: Bool?
        let last_event_disposition: String?
    }
}
// swiftlint:enable identifier_name

private enum FixtureError: Error {
    case missingFixture, unsupportedEvent
}

private func loadEventFixture() throws -> EventFixture {
    // Locate the canonical, user-supplied fixture from both Core and the isolated harness.
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while directory.path != "/" {
        let file = directory.appendingPathComponent("docs/auto-mixed-old/fixtures/event_cases.json")
        if FileManager.default.fileExists(atPath: file.path) {
            return try JSONDecoder().decode(EventFixture.self, from: Data(contentsOf: file))
        }
        directory.deleteLastPathComponent()
    }
    throw FixtureError.missingFixture
}

extension MixedCompositionEngineTests {
    @Test func characterTypePreviewOverridesAllSpansAndKeepsOriginalKeys() throws {
        let converter = MockConverter()
        let engine = MixedCompositionEngine(segmenter: MockSegmenter(), converter: converter)
        try engine.replaceRaw("ashita main")
        try engine.handle(.tab())
        let oldRevision = engine.revision
        try engine.handle(.characterType(.katakana))
        #expect(try engine.markedText().text == "アシタ マイn")
        try engine.handle(.characterType(.halfWidthRoman))
        #expect(try engine.markedText().text == "ashita main")
        #expect(engine.state == .composing && engine.selectionOptions.isEmpty)
        #expect(try !engine.selectCandidate(at: 0, revision: oldRevision, adopt: true))
        let requestCount = converter.requests.count
        try engine.handle(.insert("shi"))
        try engine.handle(.backspace)
        #expect(try engine.markedText().text == "ashita mainsh")
        #expect(converter.requests.count == requestCount)
        try engine.handle(.space)
        try engine.handle(.insert("API👩‍💻"))
        #expect(try engine.markedText().text == "ashita mainsh API👩‍💻")
        #expect(engine.buffer.text == "ashita mainsh API👩‍💻")
        try engine.handle(.characterType(.fullWidthRoman))
        let marked = try engine.markedText()
        #expect(marked.text == "ａｓｈｉｔａ　ｍａｉｎｓｈ　ＡＰＩ👩‍💻")
        #expect(marked.runs.count == 1)
        #expect(marked.runs[0].span.sourceRange.upperBound == engine.buffer.text.unicodeScalars.count)
        #expect(marked.runs[0].displayRange.length == marked.text.utf16.count)
        #expect(marked.rawScalarOffset(forDisplayUTF16: 1) == nil)
        #expect(marked.displayOffset(forRawScalar: engine.buffer.text.unicodeScalars.count) == marked.text.utf16.count)
        #expect(try engine.handle(.enter).commit?.text == marked.text)
        #expect(engine.characterType == nil && engine.buffer.isEmpty)
        #expect(try engine.handle(.enter).disposition == .fallthroughToApplication)
        try engine.handle(.insert("ashita"))
        #expect(try engine.markedText().text == "明日")
    }

    @Test func characterTypeEscapeTabAndEmptyBufferRestoreAutomaticConversion() throws {
        let engine = MixedCompositionEngine(segmenter: MockSegmenter(), converter: MockConverter())
        #expect(try engine.handle(.characterType(.halfWidthRoman)).disposition == .fallthroughToApplication)
        for end: MixedInputEvent in [.escape, .tab()] {
            try engine.replaceRaw("ashita")
            try engine.handle(.characterType(.halfWidthRoman))
            try engine.handle(end)
            #expect(engine.characterType == nil)
            #expect(try engine.markedText().text == "明日")
            engine.cancel()
        }
        try engine.handle(.insert("a"))
        try engine.handle(.characterType(.fullWidthRoman))
        try engine.handle(.backspace)
        #expect(engine.characterType == nil && engine.buffer.isEmpty)
        try engine.handle(.insert("ashita"))
        #expect(try engine.markedText().text == "明日")
    }
}
