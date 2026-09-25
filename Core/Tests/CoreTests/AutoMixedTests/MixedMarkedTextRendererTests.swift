import Core
import Foundation
import Testing

@Suite struct MixedMarkedTextRendererTests {
    @Test func kanaTailKeepsItsOwnAtomicRawRangeAndRestoresExactly() throws {
        let raw = "👩‍💻e\u{301}asitanote"
        let spans = try [MixedSpan(sourceRange: ScalarRange(0, 5), kind: .literal),
                         MixedSpan(sourceRange: ScalarRange(5, 12), kind: .japaneseRoman),
                         MixedSpan(sourceRange: ScalarRange(12, 14), kind: .japaneseKana)]
        let candidates = [spans[1].id: MixedCandidate(token: "kanji", text: "明日の"),
                          spans[2].id: MixedCandidate(token: "reading", text: "て")]
        let output = try MixedMarkedTextRenderer.render(raw: raw, spans: spans, candidates: candidates)
        #expect(output.text == "👩‍💻e\u{301}明日のて")
        #expect(output.displayOffset(forRawScalar: 12) == 10)
        #expect(output.displayOffset(forRawScalar: 13) == nil)
        #expect(output.displayOffset(forRawScalar: 14) == 11)
        #expect(output.rawScalarOffset(forDisplayUTF16: 10) == 12)
        #expect(output.rawScalarOffset(forDisplayUTF16: 11) == 14)
        let restored = try MixedMarkedTextRenderer.render(raw: raw, spans: spans, candidates: candidates, rawPreview: true)
        #expect(restored.text.unicodeScalars.elementsEqual(raw.unicodeScalars))
        #expect(restored.displayOffset(forRawScalar: 13) == 15)
    }

    @Test func atomicConversionMapsOnlyEndpoints() throws {
        let raw = "👩‍💻ashita e\u{301}"
        let spans = try [
            MixedSpan(sourceRange: ScalarRange(0, 3), kind: .literal),
            MixedSpan(sourceRange: ScalarRange(3, 9), kind: .japaneseRoman),
            MixedSpan(sourceRange: ScalarRange(9, 10), kind: .gap),
            MixedSpan(sourceRange: ScalarRange(10, 12), kind: .raw)
        ]
        let marked = try MixedMarkedTextRenderer.render(
            raw: raw, spans: spans, candidates: [spans[1].id: MixedCandidate(token: "tomorrow", text: "明日")]
        )
        #expect(marked.text == "👩‍💻明日 e\u{301}")
        #expect(try marked.runs.map(\.displayRange) == [
            UTF16Range(location: 0, length: 5), UTF16Range(location: 5, length: 2),
            UTF16Range(location: 7, length: 1), UTF16Range(location: 8, length: 2)
        ])
        #expect(marked.displayOffset(forRawScalar: 3) == 5)
        #expect(marked.displayOffset(forRawScalar: 6) == nil)
        #expect(marked.displayOffset(forRawScalar: 9) == 7)
        #expect(marked.displayOffset(forRawScalar: 12) == 10)
        #expect(marked.rawScalarOffset(forDisplayUTF16: 6) == nil)
        #expect(marked.rawScalarOffset(forDisplayUTF16: 1) == nil)
        #expect(marked.rawScalarOffset(forDisplayUTF16: 9) == 11)
        #expect(marked.rawScalarOffset(forDisplayUTF16: -1) == nil)
        #expect(marked.displayOffset(forRawScalar: 13) == nil)
        let restored = try MixedMarkedTextRenderer.render(raw: raw, spans: spans, rawPreview: true)
        #expect(Array(restored.text.unicodeScalars) == Array(raw.unicodeScalars))
        #expect(restored.displayOffset(forRawScalar: 6) == 8)
    }

    @Test func rejectsMissingOverlappingEmptyAndOutOfBoundsSpans() throws {
        let invalid: [[MixedSpan]] = try [
            [],
            [MixedSpan(sourceRange: ScalarRange(1, 3), kind: .raw)],
            [MixedSpan(sourceRange: ScalarRange(0, 2), kind: .raw)],
            [MixedSpan(sourceRange: ScalarRange(0, 4), kind: .raw)],
            [MixedSpan(sourceRange: ScalarRange(0, 0), kind: .raw), MixedSpan(sourceRange: ScalarRange(0, 3), kind: .raw)],
            [MixedSpan(sourceRange: ScalarRange(0, 2), kind: .raw), MixedSpan(sourceRange: ScalarRange(1, 3), kind: .raw)]
        ]
        for spans in invalid {
            #expect(throws: AutoMixedError.invalidSpanCoverage) {
                try MixedMarkedTextRenderer.render(raw: "ABC", spans: spans)
            }
        }
        let id = UUID()
        let duplicates = try [MixedSpan(id: id, sourceRange: ScalarRange(0, 1), kind: .raw),
                              MixedSpan(id: id, sourceRange: ScalarRange(1, 3), kind: .raw)]
        #expect(throws: AutoMixedError.invalidSpanCoverage) {
            try MixedMarkedTextRenderer.render(raw: "ABC", spans: duplicates)
        }
        let splitGrapheme = try [MixedSpan(sourceRange: ScalarRange(0, 1), kind: .literal),
                                 MixedSpan(sourceRange: ScalarRange(1, 2), kind: .literal)]
        #expect(throws: AutoMixedError.invalidSpanCoverage) {
            try MixedMarkedTextRenderer.render(raw: "e\u{301}", spans: splitGrapheme)
        }
    }

    @Test func nonJapaneseRunsAreAlwaysExactSourceSlices() throws {
        for kind: SpanKind in [.raw, .literal, .gap, .unresolved] {
            let raw = "API  e\u{301}👩‍💻"
            let span = try MixedSpan(sourceRange: ScalarRange(0, raw.unicodeScalars.count), kind: kind)
            let output = try MixedMarkedTextRenderer.render(raw: raw, spans: [span])
            #expect(Array(output.text.unicodeScalars) == Array(raw.unicodeScalars))
            #expect(throws: AutoMixedError.invalidCandidate) {
                try MixedMarkedTextRenderer.render(raw: raw, spans: [span], candidates: [span.id: .init(token: "x", text: "変更")])
            }
        }
        let empty = try MixedMarkedTextRenderer.render(raw: "", spans: [])
        #expect(empty.displayOffset(forRawScalar: 0) == 0)
        #expect(empty.rawScalarOffset(forDisplayUTF16: 0) == 0)
    }

    @Test func invalidCandidatesCannotEraseInput() throws {
        let span = try MixedSpan(sourceRange: ScalarRange(0, 6), kind: .japaneseRoman)
        for candidate in [MixedCandidate(token: "x", text: ""), MixedCandidate(token: "", text: "明日")] {
            #expect(throws: AutoMixedError.invalidCandidate) {
                try MixedMarkedTextRenderer.render(raw: "ashita", spans: [span], candidates: [span.id: candidate])
            }
        }
        #expect(throws: AutoMixedError.invalidCandidate) {
            try MixedMarkedTextRenderer.render(raw: "ashita", spans: [span], candidates: [UUID(): .init(token: "x", text: "明日")])
        }
    }
}
