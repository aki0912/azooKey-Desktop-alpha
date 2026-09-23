import Foundation

public struct MixedDisplayRun: Sendable, Equatable {
    public let span: MixedSpan
    public let displayRange: UTF16Range
    public let isAtomic: Bool
}

public struct MixedMarkedText: Sendable {
    public let text: String
    public let runs: [MixedDisplayRun]
    private let source: TextOffsetMap

    fileprivate init(text: String, runs: [MixedDisplayRun], source: TextOffsetMap) {
        self.text = text
        self.runs = runs
        self.source = source
    }

    /// nil means the host must expand an atomic converted run before editing it.
    public func displayOffset(forRawScalar offset: Int) -> Int? {
        guard (0...source.scalarCount).contains(offset) else {
            return nil
        }
        for run in runs {
            let range = run.span.sourceRange
            if offset == range.lowerBound {
                return run.displayRange.location
            }
            if offset == range.upperBound {
                return run.displayRange.upperBound
            }
            if offset > range.lowerBound, offset < range.upperBound {
                guard !run.isAtomic,
                      let start = try? source.utf16Offset(atScalar: range.lowerBound),
                      let position = try? source.utf16Offset(atScalar: offset) else {
                    return nil
                }
                return run.displayRange.location + position - start
            }
        }
        return offset == 0 && runs.isEmpty ? 0 : nil
    }

    public func rawScalarOffset(forDisplayUTF16 offset: Int) -> Int? {
        for run in runs {
            let display = run.displayRange
            if offset == display.location {
                return run.span.sourceRange.lowerBound
            }
            if offset == display.upperBound {
                return run.span.sourceRange.upperBound
            }
            if offset > display.location, offset < display.upperBound {
                guard !run.isAtomic,
                      let start = try? source.utf16Offset(atScalar: run.span.sourceRange.lowerBound) else {
                    return nil
                }
                return source.scalarOffset(atUTF16: start + offset - display.location)
            }
        }
        return offset == 0 && runs.isEmpty ? 0 : nil
    }
}

public enum MixedMarkedTextRenderer {
    public static func validate(spans: [MixedSpan], source: TextOffsetMap) throws {
        var end = 0
        var identifiers = Set<UUID>()
        for span in spans {
            let range = span.sourceRange
            guard range.lowerBound == end, range.count > 0, range.upperBound <= source.scalarCount,
                  source.isGraphemeBoundary(range.lowerBound), source.isGraphemeBoundary(range.upperBound),
                  identifiers.insert(span.id).inserted else {
                throw AutoMixedError.invalidSpanCoverage
            }
            end = range.upperBound
        }
        guard end == source.scalarCount else {
            throw AutoMixedError.invalidSpanCoverage
        }
    }

    public static func render(
        raw: String,
        spans: [MixedSpan],
        candidates: [UUID: MixedCandidate] = [:],
        rawPreview: Bool = false
    ) throws -> MixedMarkedText {
        let source = TextOffsetMap(raw)
        try validate(spans: spans, source: source)
        var text = ""
        var runs: [MixedDisplayRun] = []
        for span in spans {
            let candidate = rawPreview ? nil : candidates[span.id]
            if let candidate {
                guard span.kind == .japaneseRoman, !candidate.text.isEmpty, !candidate.token.isEmpty else {
                    throw AutoMixedError.invalidCandidate
                }
            }
            let content = try candidate?.text ?? source.slice(span.sourceRange)
            let displayRange = try UTF16Range(location: text.utf16.count, length: content.utf16.count)
            text += content
            runs.append(MixedDisplayRun(span: span, displayRange: displayRange, isAtomic: candidate != nil))
        }
        guard candidates.keys.allSatisfy({ id in spans.contains(where: { $0.id == id }) }) else {
            throw AutoMixedError.invalidCandidate
        }
        return MixedMarkedText(text: text, runs: runs, source: source)
    }
}
