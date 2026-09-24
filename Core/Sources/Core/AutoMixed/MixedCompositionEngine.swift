import Foundation

/// Synchronous composition core. The isolated playground opts in; the server and manual
/// input path do not construct it. Providers must be injected; there is no default test model.
@MainActor public final class MixedCompositionEngine {
    public private(set) var buffer = RawCompositionBuffer()
    public private(set) var spans: [MixedSpan] = []
    public private(set) var state: MixedCompositionState = .idle
    public private(set) var revision: UInt64 = 0
    public private(set) var usedRawFallback = false
    public private(set) var selectionIndex: Int?
    public private(set) var selectionOptions: [MixedCandidate] = []

    private let segmenter: any LanguageSegmenter
    private let converter: any JapaneseSpanConverting
    private var candidates: [UUID: [MixedCandidate]] = [:]
    private var accepted: [UUID: MixedCandidate] = [:]
    private var selectingSpanID: UUID?
    private var selectionFromRawPreview = false

    public init(segmenter: any LanguageSegmenter, converter: any JapaneseSpanConverting) {
        self.segmenter = segmenter
        self.converter = converter
    }

    /// Whole raw-field edits for the isolated playground; no IMK cursor mapping is implied.
    public func replaceRaw(_ raw: String) throws {
        revision &+= 1
        try edit {
            $0 = RawCompositionBuffer()
            try $0.insert(raw)
        }
    }

    public func cancel() {
        converter.finishComposition()
        buffer = RawCompositionBuffer()
        spans = []
        candidates = [:]
        accepted = [:]
        closeSelection()
        state = .idle
        usedRawFallback = false
        revision &+= 1
    }

    public func markedText() throws -> MixedMarkedText {
        var displayed = candidates.compactMapValues(\.first)
        displayed.merge(accepted) { _, chosen in chosen }
        if let id = selectingSpanID, let index = selectionIndex,
           spans.contains(where: { $0.id == id && $0.kind == .japaneseRoman }),
           !selectionFromRawPreview {
            displayed[id] = selectionOptions[index]
        }
        return try MixedMarkedTextRenderer.render(
            raw: buffer.text, spans: spans, candidates: displayed,
            rawPreview: state == .rawPreview || selectionFromRawPreview
        )
    }

    @discardableResult
    public func handle(_ event: MixedInputEvent) throws -> MixedEventResult {
        if buffer.isEmpty {
            switch event {
            case .insert, .space:
                break
            default:
                return MixedEventResult(disposition: .fallthroughToApplication, commit: nil)
            }
        }
        revision &+= 1
        switch event {
        case .insert(let text):
            if !text.isEmpty {
                try edit { try $0.insert(text) }
            }
        case .space:
            try edit { try $0.insert(" ") }
        case .backspace:
            try edit { _ = try $0.deleteBackward() }
        case .tab(let reverse):
            try selectCandidate(reverse: reverse)
        case .escape:
            if state == .selecting {
                state = selectionFromRawPreview ? .rawPreview : .composing
                closeSelection()
            } else {
                state = .rawPreview
            }
        case .enter:
            if state == .selecting {
                if let id = selectingSpanID, let index = selectionIndex, !selectionFromRawPreview,
                   spans.contains(where: { $0.id == id && $0.kind == .japaneseRoman }) {
                    accepted[id] = selectionOptions[index]
                }
                state = selectionFromRawPreview ? .rawPreview : .composing
                closeSelection()
                if state == .composing { try refreshCandidates() }
            } else {
                let commit = try MixedCommit(text: markedText().text, sourceScalarCount: buffer.offsets.scalarCount)
                converter.finishComposition()
                buffer = RawCompositionBuffer()
                spans = []
                candidates = [:]
                accepted = [:]
                closeSelection()
                usedRawFallback = false
                state = .idle
                return MixedEventResult(disposition: .consumed, commit: commit)
            }
        }
        return MixedEventResult(disposition: .consumed, commit: nil)
    }

    private func closeSelection() {
        selectingSpanID = nil
        selectionIndex = nil
        selectionOptions = []
        selectionFromRawPreview = false
    }

    private func selectCandidate(reverse: Bool) throws {
        if let index = selectionIndex {
            selectionIndex = (index + (reverse ? -1 : 1) + selectionOptions.count) % selectionOptions.count
            return
        }
        // T1 has no span-navigation UI. Start with the rightmost JA span, or the last raw span.
        guard let span = spans.last(where: { $0.kind == .japaneseRoman }) ?? spans.last else {
            return
        }
        selectionFromRawPreview = state == .rawPreview
        selectingSpanID = span.id
        if !selectionFromRawPreview, let options = candidates[span.id], !options.isEmpty {
            selectionOptions = options
        } else {
            selectionOptions = [try MixedCandidate(token: "keep-raw", text: buffer.offsets.slice(span.sourceRange))]
        }
        selectionIndex = accepted[span.id].flatMap { selectionOptions.firstIndex(of: $0) } ?? 0
        state = .selecting
    }

    private func edit(_ operation: (inout RawCompositionBuffer) throws -> Void) throws {
        let oldBuffer = buffer
        let oldSpans = spans
        try operation(&buffer)
        closeSelection()
        usedRawFallback = false
        if buffer.isEmpty {
            converter.finishComposition()
            spans = []
            candidates = [:]
            accepted = [:]
            state = .idle
            return
        }
        do {
            let proposed = try segmenter.segment(buffer.text)
            try MixedMarkedTextRenderer.validate(spans: proposed, source: buffer.offsets)
            // Preserve explicit candidate choices for unchanged spans during suffix edits.
            // Central editing and remapping user overrides are the T6 editing layer.
            spans = try proposed.map { span in
                if let previous = oldSpans.first(where: { $0.sourceRange == span.sourceRange && $0.kind == span.kind }),
                   try oldBuffer.offsets.slice(previous.sourceRange).unicodeScalars.elementsEqual(
                    buffer.offsets.slice(span.sourceRange).unicodeScalars
                   ) {
                    return previous
                }
                return span
            }
            accepted = accepted.filter { id, _ in spans.contains(where: { $0.id == id }) }
            try refreshCandidates()
        } catch {
            converter.finishComposition()
            // Provider failure is reversible and cannot remove the original input.
            spans = [try MixedSpan(sourceRange: ScalarRange(0, buffer.offsets.scalarCount), kind: .unresolved)]
            candidates = [:]
            accepted = [:]
            usedRawFallback = true
        }
        state = .composing
    }

    private func refreshCandidates() throws {
        converter.prepare(revision: revision, sourceScalarCount: buffer.offsets.scalarCount,
                          retaining: Set(spans.filter { $0.kind == .japaneseRoman }.map(\.id)))
        var updated: [UUID: [MixedCandidate]] = [:]
        var leftDisplay = ""
        for span in spans {
            let raw = try buffer.offsets.slice(span.sourceRange)
            guard span.kind == .japaneseRoman else {
                leftDisplay += raw
                continue
            }
            if let chosen = accepted[span.id] {
                updated[span.id] = candidates[span.id] ?? [chosen]
                leftDisplay += chosen.text
            } else {
                let options = try converter.candidates(for: raw, span: span, leftDisplay: leftDisplay)
                guard options.allSatisfy({ !$0.text.isEmpty && !$0.token.isEmpty }),
                      Set(options.map(\.token)).count == options.count else {
                    throw AutoMixedError.invalidCandidate
                }
                updated[span.id] = options
                leftDisplay += options.first?.text ?? raw
            }
        }
        candidates = updated
    }
}
