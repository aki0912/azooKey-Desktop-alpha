import Core
import Testing
import Foundation

private struct ContinuitySegmenter: LanguageSegmenter {
    func segment(_ raw: String) throws -> [MixedSpan] {
        let count = raw.unicodeScalars.count
        if raw.hasSuffix("!") {
            return [try MixedSpan(sourceRange: ScalarRange(0, 3), kind: .japaneseRoman),
                    try MixedSpan(sourceRange: ScalarRange(3, count), kind: .raw)]
        }
        if raw.hasSuffix("?") { return [try MixedSpan(sourceRange: ScalarRange(0, count), kind: .raw)] }
        return [try MixedSpan(sourceRange: ScalarRange(0, count), kind: .japaneseRoman)]
    }
}
@MainActor private final class ContinuityConverter: JapaneseSpanConverting {
    func candidates(for raw: String, span: MixedSpan) throws -> [MixedCandidate] {
        [MixedCandidate(token: UUID().uuidString, text: raw)]
    }
}
@Suite @MainActor struct MixedSessionContinuityTests {
    @Test func suffixOnlyContinuityAndSplitMergeLanguageReset() throws {
        let engine = MixedCompositionEngine(segmenter: ContinuitySegmenter(), converter: ContinuityConverter())
        try engine.replaceRaw("asita")
        let first = try #require(engine.spans.first?.id)
        try engine.handle(.insert("n"))
        #expect(engine.spans.first?.id == first)
        try engine.handle(.backspace)
        #expect(engine.spans.first?.id == first)
        try engine.replaceRaw("ashita") // Internal replacement, not a suffix edit.
        #expect(engine.spans.first?.id != first)
        let beforeSplit = try #require(engine.spans.first?.id)
        try engine.handle(.insert("!"))
        #expect(engine.spans.first?.id != beforeSplit)
        let splitIDs = Set(engine.spans.map(\.id))
        try engine.handle(.backspace)
        #expect(!splitIDs.contains(try #require(engine.spans.first?.id)))
        let beforeLanguage = try #require(engine.spans.first?.id)
        try engine.handle(.insert("?"))
        #expect(engine.spans.first?.id != beforeLanguage)
        engine.cancel()
        #expect(engine.spans.isEmpty)
    }
}
