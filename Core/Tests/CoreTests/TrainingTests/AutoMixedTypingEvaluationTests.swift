@testable import Core
import Crypto
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Dedicated offline process. Responses contain ranges/kinds, never corpus text/context.
@Suite @MainActor struct AutoMixedTypingEvaluationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_TYPING_REQUEST"] != nil,
                   "Invoked by evaluate-typing on development data"))
    func replayDevelopmentPrefixes() throws {
        let env = ProcessInfo.processInfo.environment
        let input = URL(fileURLWithPath: try #require(env["AUTO_MIXED_TYPING_REQUEST"]))
        let output = URL(fileURLWithPath: try #require(env["AUTO_MIXED_TYPING_RESPONSE"]))
        let modelURL = URL(fileURLWithPath: try #require(env["AUTO_MIXED_TYPING_MODEL"]))
        let data = try Data(contentsOf: input), modelData = try Data(contentsOf: modelURL)
        let request = try JSONDecoder().decode(TypingRequest.self, from: data)
        let model = try LogisticLanguageModel(data: modelData)
        let lexicon = try EnglishLexicon.bundled(), policy = try EnglishDecisionPolicy.bundled()
        // ComposingText's DEBUG helpers can print input. Silence this dedicated process
        // while handling authored corpus data, including error unwinding.
        let savedOutput = dup(STDOUT_FILENO), savedError = dup(STDERR_FILENO)
        let null = open("/dev/null", O_WRONLY)
        guard savedOutput >= 0, savedError >= 0, null >= 0 else { throw TypingEvaluationError.redirection }
        fflush(nil)
        defer {
            fflush(nil)
            dup2(savedOutput, STDOUT_FILENO); dup2(savedError, STDERR_FILENO)
            close(savedOutput); close(savedError); close(null)
        }
        guard dup2(null, STDOUT_FILENO) >= 0, dup2(null, STDERR_FILENO) >= 0 else { throw TypingEvaluationError.redirection }
        var rows: [TypingResult] = []
        for row in request.rows {
            let context = row.left_context.map(CommittedLeftContext.available) ?? .unavailable
            let segmenter = try JapanesePreferredSegmenter(model: model, lexicon: lexicon, policy: policy,
                context: context, focus: UUID())
            var prefixes = [""]
            for character in row.raw { prefixes.append(prefixes.last! + String(character)) }
            func frame(_ raw: String) throws -> TypingFrame {
                let start = DispatchTime.now().uptimeNanoseconds
                let spans = try segmenter.segment(raw)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                try MixedMarkedTextRenderer.validate(spans: spans, source: TextOffsetMap(raw))
                return TypingFrame(end: raw.unicodeScalars.count, milliseconds: elapsed,
                    spans: spans.map { .init(start: $0.sourceRange.lowerBound, end: $0.sourceRange.upperBound, kind: $0.kind.rawValue) })
            }
            let forward = try prefixes.map(frame)
            let backward = try prefixes.dropLast().reversed().map(frame)
            let paste = try prefixes.map { raw in segmenter.reset(); return try frame(raw) }
            rows.append(.init(forward: forward, backward: backward, paste: paste))
        }
        func sha(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
        let response = TypingResponse(request_sha256: sha(data), model_sha256: sha(modelData), rows: rows)
        try JSONEncoder().encode(response).write(to: output, options: .withoutOverwriting)
    }
}

private enum TypingEvaluationError: Error { case redirection }
private struct TypingRequest: Decodable {
    let rows: [Row]
    struct Row: Decodable { let raw: String; let left_context: String? }
}
private struct TypingSpan: Encodable { let start: Int; let end: Int; let kind: String }
private struct TypingFrame: Encodable { let end: Int; let milliseconds: Double; let spans: [TypingSpan] }
private struct TypingResult: Encodable { let forward: [TypingFrame]; let backward: [TypingFrame]; let paste: [TypingFrame] }
private struct TypingResponse: Encodable { let request_sha256: String; let model_sha256: String; let rows: [TypingResult] }
