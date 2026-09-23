import Core
import Foundation
import Testing

@Suite struct ProtectedSpanDetectorTests {
    @Test func protectsStructuredTokensWithoutSwallowingAcronymSuffixes() {
        let tokens = ["https://example.com/a?q=1", "https://example.com/ashitadesu", "www.example.net",
                      "test.user+tag@example.net", "src/main.swift", "C:\\work\\main.py", "snake_case", "foo::bar",
                      "model_v3.2", "2026-09-23", "v3.2", "readme.mdwohiraku"]
        for token in tokens {
            #expect(ProtectedSpanDetector.detect(token).scalars == Array(repeating: .literal, count: token.unicodeScalars.count))
        }
        #expect(ProtectedSpanDetector.detect("APIwotukau").scalars == Array(repeating: .raw, count: 3) + Array(repeating: .inferred, count: 7))
        #expect(ProtectedSpanDetector.detect("KYOU").scalars == Array(repeating: .raw, count: 4))
        #expect(ProtectedSpanDetector.detect("kan'i").scalars == Array(repeating: .inferred, count: 5))
        #expect(ProtectedSpanDetector.detect("desu.").scalars == Array(repeating: .inferred, count: 4) + [.literal])
    }

    @Test func unicodeClustersAndSpacesAreNeverSplitForInference() {
        #expect(ProtectedSpanDetector.detect("👩‍💻 e\u{301}\r\n\tA").scalars == [.literal, .literal, .literal, .gap, .literal, .literal, .gap, .gap, .gap, .inferred])
        #expect(ProtectedSpanDetector.detect("このAPI").scalars == [.literal, .literal, .raw, .raw, .raw])
        #expect(ProtectedSpanDetector.detect("Hello  world").scalars == Array(repeating: .inferred, count: 5) + [.gap, .gap] + Array(repeating: .inferred, count: 5))
        let swift = ProtectedSpanDetector.detect("kyouhaSwiftde")
        #expect(swift.boundaryHints == [6, 11])
        #expect(swift.scalars.allSatisfy { $0 == .inferred })
        #expect(ProtectedSpanDetector.detect("getUserName").scalars.allSatisfy { $0 == .inferred })
    }

    @Test func fixtureLiteralAndGapRangesStayProtected() throws {
        struct Record: Decodable {
            let id: String
            let raw: String
            let spans: [Span]
            struct Span: Decodable {
                let start: Int
                let end: Int
                let label: String
            }
        }
        let file = try String(contentsOf: autoMixedRepositoryFile("docs/auto-mixed/fixtures/span_cases.jsonl"), encoding: .utf8)
        let records = try file.split(separator: "\n").map { try JSONDecoder().decode(Record.self, from: Data($0.utf8)) }
        #expect(records.count == 50)
        for record in records {
            let policies = ProtectedSpanDetector.detect(record.raw).scalars
            #expect(policies.count == record.raw.unicodeScalars.count)
            for span in record.spans where span.label == "LITERAL" || span.label == "GAP" {
                let expected: ScalarProtection = span.label == "LITERAL" ? .literal : .gap
                #expect(policies[span.start..<span.end].allSatisfy { $0 == expected }, "\(record.id)")
            }
        }
    }

    @Test @MainActor func statisticalHypothesesRemainUnresolvedUntilRomanValidation() throws {
        let model = try LogisticLanguageModel(data: syntheticModelData {
            $0["vocabulary"] = [String]()
            $0["coefficients"] = [Double]()
            $0["intercept"] = 1000
            $0["calibration"] = ["a": 1, "c": 0]
            $0["decoder"] = ["switch_penalty": 0]
        })
        let segmenter = StatisticalLanguageSegmenter(model: model)
        let raw = "ashita APIwotukau 👩‍💻 e\u{301} https://example.com/ashita"
        let hypotheses = try segmenter.hypotheses(raw)
        #expect(hypotheses.contains { $0.kind == .japaneseRoman })
        let spans = try segmenter.segment(raw)
        #expect(!spans.contains { $0.kind == .japaneseRoman })
        #expect(spans.contains { $0.kind == .unresolved })
        try MixedMarkedTextRenderer.validate(spans: spans, source: TextOffsetMap(raw))
        let source = TextOffsetMap(raw)
        let hardRaw = try spans.filter { $0.kind == .raw }.map { try source.slice($0.sourceRange) }
        #expect(hardRaw == ["API"])
        #expect(try segmenter.segment("").isEmpty)
        let converter = UnexpectedConversion()
        let engine = MixedCompositionEngine(segmenter: segmenter, converter: converter)
        try engine.handle(.insert(raw))
        #expect(try engine.markedText().text.unicodeScalars.elementsEqual(raw.unicodeScalars))
        #expect(converter.requests == 0)
        #expect(try engine.handle(.enter).commit?.text == raw)
    }
}

@MainActor private final class UnexpectedConversion: JapaneseSpanConverting {
    private(set) var requests = 0
    func candidates(for raw: String, span: MixedSpan) throws -> [MixedCandidate] {
        requests += 1
        Issue.record("Unvalidated roman hypotheses must not reach the converter")
        return []
    }
}
