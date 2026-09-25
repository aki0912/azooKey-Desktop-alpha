import Foundation

/// Sequential transport adapter, testable without an XPC service or IMK registration.
/// Experimental IME commits do not learn yet. Pending commit texts are bounded and
/// acknowledgements retire them; engine candidate children are released on commit.
@MainActor public final class AutoMixedServerSession {
    public typealias Factory = (ConverterTextContext) throws -> MixedCompositionEngine
    private let factory: Factory
    public let epoch: UUID
    private var focus: UUID?
    private var engine: MixedCompositionEngine?
    private var compositionID = UUID()
    private var lastRequest: AutoMixedRequest?
    private var lastResponse: ConverterServerResponse?
    private var pendingCommits: [AutoMixedCommitEffect] = []
    public var pendingCommitCount: Int { pendingCommits.count }
    public static let maximumPendingCommits = 8

    public init(epoch: UUID, factory: @escaping Factory) {
        self.epoch = epoch
        self.factory = factory
    }

    public func close() {
        engine?.cancel()
        engine = nil
        focus = nil
        pendingCommits = []
        lastRequest = nil
        lastResponse = nil
    }

    public func handle(_ request: AutoMixedRequest) throws -> ConverterServerResponse {
        guard request.serverEpoch == epoch else {
            return try response(request, status: .restartRequired, expose: false)
        }
        if request == lastRequest, let lastResponse {
            return lastResponse
        }
        if let lastRequest, request.operationID <= lastRequest.operationID {
            return try response(request, status: .staleRequest, expose: false)
        }
        guard request.inputStyle == .defaultRomanToKana || request.inputStyle == .roman2kana else {
            return try response(request, status: .unsupportedInputStyle, expose: false)
        }
        if request.focusID != focus {
            guard request.startsFocus else {
                return try response(request, status: .staleRequest, expose: false)
            }
            engine?.cancel()
            pendingCommits = []
            focus = request.focusID
            compositionID = UUID()
            engine = nil
        }
        // An acknowledgement/stop must not capture empty context for the next input.
        if engine == nil, case .key(let key) = request.action, AutoMixedKeyRouter.input(key) != nil {
            let context = ConverterTextContext(
                leftSideContext: request.context.leftSideContext.map { String($0.suffix(30)) },
                rightSideContext: request.context.rightSideContext.map { String($0.prefix(30)) })
            engine = try factory(context)
        }
        var status = try apply(request.action)
        if status == .staleRequest {
            return try response(request, status: status)
        }
        if engine?.usedRawFallback == true { status = .rawFallback }
        if let engine, engine.buffer.isEmpty {
            engine.cancel()
            self.engine = nil
            compositionID = UUID()
        }
        let result = try response(request, status: status)
        lastRequest = request
        lastResponse = result
        return result
    }

    private func apply(_ action: AutoMixedAction) throws -> AutoMixedStatus {
        var status: AutoMixedStatus = .ready
        switch action {
        case .key(let key):
            return try applyKey(key)
        case .commit:
            // OS commit is not candidate adoption: commit the complete displayed composition.
            if let engine, try !commit(engine) { status = .awaitingAcknowledgement }
        case .stop:
            // An empty legacy manager is irrelevant. Preserve mixed raw until commit/deactivate.
            break
        case .deactivate:
            engine?.cancel()
            engine = nil
            pendingCommits = []
            focus = nil
        case .selectCandidate(let index, let revision, let adopt):
            guard let engine, try engine.selectCandidate(at: index, revision: revision, adopt: adopt) else {
                return .staleRequest
            }
        case .commitApplied(let commitID):
            pendingCommits.removeAll { $0.commitID == commitID }
        }
        return status
    }

    private func applyKey(_ key: KeyEventCore) throws -> AutoMixedStatus {
        var status: AutoMixedStatus = .ready
        if let engine, let input = AutoMixedKeyRouter.input(key) {
            switch input {
            case .insert(let text) where engine.buffer.offsets.scalarCount + text.unicodeScalars.count > 256:
                status = .inputLimit
            case .space where engine.buffer.offsets.scalarCount >= 256:
                status = .inputLimit
            case .enter where engine.state != .selecting:
                if try !commit(engine) { status = .awaitingAcknowledgement }
            default:
                _ = try engine.handle(input)
            }
        }
        return status
    }

    private func commit(_ engine: MixedCompositionEngine) throws -> Bool {
        guard !engine.buffer.isEmpty else {
            return true
        }
        // Bound missing acknowledgements without silently evicting unapplied commits.
        guard pendingCommits.count < Self.maximumPendingCommits else {
            return false
        }
        let effect = try AutoMixedCommitEffect(commitID: UUID(), compositionID: compositionID, text: engine.markedText().text)
        pendingCommits.append(effect)
        engine.cancel()
        compositionID = UUID()
        // Context is captured once per composition by the next request, never persisted.
        self.engine = nil
        return true
    }

    private func response(_ request: AutoMixedRequest, status: AutoMixedStatus, expose: Bool = true) throws -> ConverterServerResponse {
        let active = expose ? engine : nil
        let display = try active?.markedText()
        let raw = active?.buffer.text ?? ""
        let spans = display?.runs.map {
            AutoMixedWireSpan(id: $0.span.id, sourceRange: $0.span.sourceRange, displayRange: $0.displayRange, kind: $0.span.kind)
        } ?? []
        let mixed = AutoMixedResponse(serverEpoch: epoch, focusID: request.focusID, operationID: request.operationID,
                                      compositionID: compositionID, revision: active?.revision ?? 0, raw: raw,
                                      spans: spans, commits: expose ? pendingCommits : [], status: status)
        let state: ConverterInputState = raw.isEmpty ? .none : (active?.state == .selecting ? .selecting : .composing)
        let candidates: ConverterCandidateWindow = active?.state == .selecting
            ? .selecting(active!.selectionOptions.map { .init(text: $0.text) }, selectionIndex: active!.selectionIndex) : .hidden
        let elements: [ConverterMarkedText.Element] = display.map { display in
            display.runs.map { run in
                .init(content: (display.text as NSString).substring(with:
                    NSRange(location: run.displayRange.location, length: run.displayRange.length)),
                    focus: run.span.id == active?.selectedSpanID ? .focused : .unfocused)
            }
        } ?? []
        return ConverterServerResponse(inputState: state,
            snapshot: .init(markedText: .init(elements: elements,
                                            selectionRange: .init(location: display?.text.utf16.count ?? 0, length: 0)),
                            candidateWindow: candidates, isEmpty: raw.isEmpty, convertTarget: raw),
            autoMixed: mixed)
    }
}
