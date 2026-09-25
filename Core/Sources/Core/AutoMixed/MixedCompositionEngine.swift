import Foundation

/// Synchronous composition core. The playground and experimental server opt in;
/// the manual path is separate. Providers are injected; there is no default test model.
@MainActor public final class MixedCompositionEngine {
    public private(set) var buffer = RawCompositionBuffer()
    public private(set) var spans: [MixedSpan] = []
    public private(set) var state: MixedCompositionState = .idle
    public private(set) var revision: UInt64 = 0
    public private(set) var usedRawFallback = false
    public private(set) var characterType: CompositionCharacterType?
    private var characterTypeSpanID = UUID()
    public private(set) var selectionIndex: Int?
    public private(set) var selectionOptions: [MixedCandidate] = []
    public var selectedSpanID: UUID? { selectingSpanID }

    private let segmenter: any LanguageSegmenter
    private let converter: any JapaneseSpanConverting
    private let punctuation: MixedPunctuationPolicy?
    private let backspaceEditor: (any JapaneseBackspaceEditing)?
    private var readingPreview: (id: UUID, text: String)?
    private var candidates: [UUID: [MixedCandidate]] = [:]
    private var accepted: [UUID: MixedCandidate] = [:]
    private var selectingSpanID: UUID?
    private var selectionFromRawPreview = false
    private var clearsOnNextEscape = false

    public init(segmenter: any LanguageSegmenter, converter: any JapaneseSpanConverting,
                punctuation: MixedPunctuationPolicy? = nil,
                backspaceEditor: (any JapaneseBackspaceEditing)? = nil) {
        self.segmenter = segmenter
        self.converter = converter
        self.punctuation = punctuation
        self.backspaceEditor = backspaceEditor
    }

    /// Whole raw-field edits for the isolated playground; no IMK cursor mapping is implied.
    public func replaceRaw(_ raw: String) throws {
        clearsOnNextEscape = false
        revision &+= 1
        try edit {
            $0 = RawCompositionBuffer()
            try $0.insert(raw)
        }
    }

    public func cancel() {
        clearComposition()
        revision &+= 1
    }

    private func clearComposition() {
        clearsOnNextEscape = false
        characterType = nil
        characterTypeSpanID = UUID()
        readingPreview = nil
        segmenter.reset()
        converter.finishComposition()
        buffer = RawCompositionBuffer()
        spans = []
        candidates = [:]
        accepted = [:]
        closeSelection()
        state = .idle
        usedRawFallback = false
    }

    public func markedText() throws -> MixedMarkedText {
        if let characterType {
            return try MixedMarkedTextRenderer.renderCharacterType(
                raw: buffer.text, text: characterType.text(raw: buffer.text, reading: converter.reading(for: buffer.text)),
                id: characterTypeSpanID)
        }
        var displayed = candidates.compactMapValues(\.first)
        displayed.merge(accepted) { _, chosen in chosen }
        if let id = selectingSpanID, let index = selectionIndex,
           spans.contains(where: { $0.id == id && $0.kind == .japaneseRoman }),
           !selectionFromRawPreview {
            displayed[id] = selectionOptions[index]
        }
        return try MixedMarkedTextRenderer.render(
            raw: buffer.text, spans: spans, candidates: displayed,
            rawPreview: state == .rawPreview || selectionFromRawPreview, punctuation: punctuation
        )
    }

    @discardableResult
    public func handle(_ event: MixedInputEvent) throws -> MixedEventResult {
        if buffer.isEmpty, !startsComposition(event) {
            return MixedEventResult(disposition: .fallthroughToApplication, commit: nil)
        }
        revision &+= 1
        if case .escape = event {} else { clearsOnNextEscape = false }
        switch event {
        case .characterType(let type):
            characterType = type
            readingPreview = nil
            closeSelection()
            candidates = [:]
            accepted = [:]
            converter.finishComposition()
            state = .composing
            usedRawFallback = false
        case .insert(let text):
            if !text.isEmpty {
                try edit { try $0.insert(text) }
            }
        case .space:
            try edit { try $0.insert(" ") }
        case .backspace:
            try deleteBackward()
        case .tab(let reverse):
            try handleTab(reverse: reverse)
        case .escape:
            try escape()
        case .enter:
            return try enter()
        }
        return MixedEventResult(disposition: .consumed, commit: nil)
    }

    private func handleTab(reverse: Bool) throws {
        if characterType != nil {
            characterType = nil
            try edit { _ in }
        }
        if readingPreview != nil { try edit { _ in } }
        do {
            try cycleCandidate(reverse: reverse)
        } catch {
            try fallBackToRaw()
        }
    }

    private func startsComposition(_ event: MixedInputEvent) -> Bool {
        switch event {
        case .insert, .space: true
        default: false
        }
    }

    private func escape() throws {
        if clearsOnNextEscape {
            clearComposition()
            return
        }
        if characterType != nil {
            characterType = nil
            try edit { _ in }
        } else if state == .selecting {
            state = selectionFromRawPreview ? .rawPreview : .composing
            closeSelection()
        } else {
            readingPreview = nil
            state = .rawPreview
        }
        clearsOnNextEscape = true
    }

    private func enter() throws -> MixedEventResult {
        if state == .selecting {
            try adoptCandidate()
        } else {
            let commit = try MixedCommit(text: markedText().text, sourceScalarCount: buffer.offsets.scalarCount)
            clearComposition()
            return MixedEventResult(disposition: .consumed, commit: commit)
        }
        return MixedEventResult(disposition: .consumed, commit: nil)
    }

    private func closeSelection() {
        selectingSpanID = nil
        selectionIndex = nil
        selectionOptions = []
        selectionFromRawPreview = false
    }

    /// Apply one candidate-window action against the snapshot the host displayed.
    /// Direct selection must not replay Tab events or depend on the distance to the row.
    @discardableResult
    public func selectCandidate(at index: Int, revision expectedRevision: UInt64, adopt: Bool) throws -> Bool {
        guard state == .selecting, revision == expectedRevision, selectionOptions.indices.contains(index) else {
            return false
        }
        revision &+= 1
        clearsOnNextEscape = false
        selectionIndex = index
        if adopt { try adoptCandidate() }
        return true
    }

    private func adoptCandidate() throws {
        if let id = selectingSpanID, let index = selectionIndex, !selectionFromRawPreview,
           spans.contains(where: { $0.id == id && $0.kind == .japaneseRoman }) {
            accepted[id] = selectionOptions[index]
        }
        state = selectionFromRawPreview ? .rawPreview : .composing
        closeSelection()
        if state == .composing {
            do {
                try refreshCandidates()
            } catch {
                try fallBackToRaw()
            }
        }
    }

    private func cycleCandidate(reverse: Bool) throws {
        if let index = selectionIndex {
            selectionIndex = (index + (reverse ? -1 : 1) + selectionOptions.count) % selectionOptions.count
            return
        }
        // T1 has no span-navigation UI. Start with the rightmost JA span, or the last raw span.
        guard let span = spans.last(where: { $0.kind == .japaneseRoman }) ?? spans.last else {
            return
        }
        if state != .rawPreview, !usedRawFallback, span.kind == .japaneseRoman {
            let marked = try markedText()
            guard let offset = marked.displayOffset(forRawScalar: span.sourceRange.lowerBound) else {
                throw AutoMixedError.invalidRange
            }
            let leftDisplay = (marked.text as NSString).substring(to: offset)
            converter.prepare(revision: revision, sourceScalarCount: buffer.offsets.scalarCount,
                              retaining: Set(spans.filter { $0.kind == .japaneseRoman }.map(\.id)))
            if let options = try converter.selectionCandidates(for: buffer.offsets.slice(span.sourceRange),
                                                               span: span, leftDisplay: leftDisplay) {
                guard !options.isEmpty,
                      options.allSatisfy({ !$0.text.isEmpty && !$0.token.isEmpty }),
                      Set(options.map(\.token)).count == options.count else {
                    throw AutoMixedError.invalidCandidate
                }
                // Rich requests invalidate preview tokens. Preserve an explicit choice
                // only by rebinding its text to a candidate from the new response.
                let chosenText = accepted[span.id]?.text
                accepted[span.id] = options.first { $0.text == chosenText }
                candidates[span.id] = options
            }
        }
        selectionFromRawPreview = state == .rawPreview
        selectingSpanID = span.id
        if !selectionFromRawPreview, let options = candidates[span.id], !options.isEmpty {
            selectionOptions = options
        } else if !selectionFromRawPreview,
                  let literal = try punctuation?.displaySlices(raw: buffer.text, spans: spans)[span.id] {
            selectionOptions = [MixedCandidate(token: "keep-display", text: literal)]
        } else {
            selectionOptions = [try MixedCandidate(token: "keep-raw", text: buffer.offsets.slice(span.sourceRange))]
        }
        selectionIndex = accepted[span.id].flatMap { selectionOptions.firstIndex(of: $0) } ?? 0
        state = .selecting
    }

    private func deleteBackward() throws {
        let rawPreview = state == .rawPreview || selectionFromRawPreview
        if characterType == nil, !rawPreview, !usedRawFallback, buffer.cursorScalarOffset == buffer.offsets.scalarCount,
           let last = spans.last, last.kind == .japaneseRoman || last.kind == .japaneseKana,
           let replacement = backspaceEditor?.deletingLastUnit(in: try buffer.offsets.slice(last.sourceRange)) {
            var retained = Array(spans.dropLast())
            readingPreview = nil
            if !replacement.raw.isEmpty {
                let span = try MixedSpan(sourceRange: ScalarRange(last.sourceRange.lowerBound,
                    last.sourceRange.lowerBound + replacement.raw.unicodeScalars.count), kind: .japaneseKana)
                retained.append(span)
                readingPreview = (span.id, replacement.reading)
            }
            try edit(preservingSpans: retained) { try $0.replace(last.sourceRange, with: replacement.raw) }
        } else {
            try edit { _ = try $0.deleteBackward() }
            if backspaceEditor != nil, rawPreview, !buffer.isEmpty { state = .rawPreview }
        }
    }

    private func edit(preservingSpans: [MixedSpan]? = nil, _ operation: (inout RawCompositionBuffer) throws -> Void) throws {
        if preservingSpans == nil { readingPreview = nil }
        let oldBuffer = buffer
        let oldSpans = spans
        try operation(&buffer)
        closeSelection()
        usedRawFallback = false
        if buffer.isEmpty {
            clearComposition()
            return
        }
        if characterType != nil {
            spans = [try MixedSpan(id: characterTypeSpanID, sourceRange: ScalarRange(0, buffer.offsets.scalarCount), kind: .raw)]
            state = .composing
            return
        }
        do {
            let proposed = try preservingSpans ?? MixedPerformance.measure(.judgment) { try segmenter.segment(buffer.text) }
            try MixedMarkedTextRenderer.validate(spans: proposed, source: buffer.offsets)
            // Preserve explicit candidate choices for unchanged spans during suffix edits.
            // Central editing and remapping user overrides are the T6 editing layer.
            let suffixEdit = oldBuffer.text.unicodeScalars.starts(with: buffer.text.unicodeScalars)
                || buffer.text.unicodeScalars.starts(with: oldBuffer.text.unicodeScalars)
            var unchangedIDs = Set<UUID>()
            let previousByRange = Dictionary(uniqueKeysWithValues: oldSpans.map { ($0.sourceRange, $0) })
            spans = try proposed.enumerated().map { index, span in
                if let previous = previousByRange[span.sourceRange], previous.kind == span.kind,
                   try oldBuffer.offsets.slice(previous.sourceRange).unicodeScalars.elementsEqual(
                    buffer.offsets.slice(span.sourceRange).unicodeScalars
                   ) {
                    unchangedIDs.insert(previous.id)
                    return previous
                }
                // Only the final, one-to-one Japanese run may grow/shrink. All
                // preceding runs must be identical; splits/merges get fresh IDs.
                if suffixEdit, proposed.count == oldSpans.count, index == proposed.count - 1,
                   let previous = oldSpans.last, span.kind == .japaneseRoman,
                   previous.kind == .japaneseRoman,
                   previous.sourceRange.lowerBound == span.sourceRange.lowerBound,
                   previous.sourceRange.upperBound == oldBuffer.offsets.scalarCount,
                   span.sourceRange.upperBound == buffer.offsets.scalarCount,
                   oldSpans.dropLast().allSatisfy({ unchangedIDs.contains($0.id) }) {
                    return MixedSpan(id: previous.id, sourceRange: span.sourceRange, kind: span.kind)
                }
                return span
            }
            // Session continuity is not permission to keep an adopted candidate.
            accepted = accepted.filter { id, _ in unchangedIDs.contains(id) }
            try refreshCandidates()
        } catch {
            try fallBackToRaw()
        }
        state = .composing
    }

    private func fallBackToRaw() throws {
        readingPreview = nil
        segmenter.reset()
        converter.finishComposition()
        closeSelection()
        // Editing, opening candidates and adoption share the same reversible fallback.
        spans = [try MixedSpan(sourceRange: ScalarRange(0, buffer.offsets.scalarCount), kind: .unresolved)]
        candidates = [:]
        accepted = [:]
        usedRawFallback = true
        state = .composing
    }

    private func refreshCandidates() throws {
        converter.prepare(revision: revision, sourceScalarCount: buffer.offsets.scalarCount,
                          retaining: Set(spans.filter { $0.kind == .japaneseRoman }.map(\.id)))
        var updated: [UUID: [MixedCandidate]] = [:]
        let literals = try punctuation?.displaySlices(raw: buffer.text, spans: spans) ?? [:]
        var leftDisplay = ""
        for span in spans {
            let raw = try buffer.offsets.slice(span.sourceRange)
            guard span.kind == .japaneseRoman || span.kind == .japaneseKana else {
                leftDisplay += literals[span.id] ?? raw
                continue
            }
            if let preview = readingPreview, preview.id == span.id {
                updated[span.id] = [MixedCandidate(token: UUID().uuidString, text: preview.text)]
                leftDisplay += preview.text
            } else if let chosen = accepted[span.id] {
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
