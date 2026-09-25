import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

public struct JapaneseSpanIdentity: Sendable, Hashable {
    public let sessionID: UUID
    public let compositionID: UUID
    public let spanID: UUID
    public let revision: UInt64

    public init(sessionID: UUID, compositionID: UUID, spanID: UUID, revision: UInt64) {
        self.sessionID = sessionID
        self.compositionID = compositionID
        self.spanID = spanID
        self.revision = revision
    }
}

/// Ephemeral request. Context and raw are never encoded or logged by this adapter.
public struct JapaneseSpanRequest: CustomDebugStringConvertible {
    public let identity: JapaneseSpanIdentity
    public let sourceRange: ScalarRange
    public let raw: String
    public let leftContext: String?
    public let rightContext: String?
    public let rich: Bool
    public let settingsVersion: UInt64
    public let isAtBufferEnd: Bool

    public init(identity: JapaneseSpanIdentity, sourceRange: ScalarRange, raw: String,
                leftContext: String? = nil, rightContext: String? = nil,
                rich: Bool = false, settingsVersion: UInt64 = 0, isAtBufferEnd: Bool = false) {
        self.identity = identity
        self.sourceRange = sourceRange
        self.raw = raw
        self.leftContext = leftContext.map { String($0.suffix(30)) }
        self.rightContext = rightContext.map { String($0.prefix(30)) }
        self.rich = rich
        self.settingsVersion = settingsVersion
        self.isAtBufferEnd = isAtBufferEnd
    }

    public var debugDescription: String { "JapaneseSpanRequest(<redacted>)" }
}

public enum JapaneseSpanFallback: String, Sendable {
    case invalidRoman, noCompletePrefix, incompleteInternalSpan, sessionLimit, noFullCandidate, modelUnavailable
}

public enum MixedConversionBackend: Sendable { case dictionary, zenzaiPending, zenzaiReady, zenzaiUnavailable }

public struct JapaneseSpanResult: Sendable {
    public let identity: JapaneseSpanIdentity
    public let convertedRange: ScalarRange
    public let suffixRange: ScalarRange
    /// Display texts cover the full requested raw, including the original suffix.
    public let candidates: [MixedCandidate]
    public let fallback: JapaneseSpanFallback?
}

public enum JapaneseSpanBridgeError: Error { case invalidToken, missingZenzaiWeights }

/// A single owner per shared Converter. Call outside a legacy withSession operation.
/// Child sessions contain composition state, not another model or dictionary instance.
@MainActor public final class ZenzaiSpanBridge {
    private struct Key: Hashable {
        let session: UUID
        let composition: UUID
        let span: UUID
    }

    private struct PreviewKey: Equatable {
        let conversionInput: String
        let completesTerminalN: Bool
        let left: String?
        let right: String?
        let rich: Bool
        let settings: UInt64
    }

    private struct Child {
        let session: KanaKanjiConverter.ConversionSessionID
        let manager: SegmentsManager
        var cacheKey: PreviewKey?
        var request: JapaneseSpanRequest?
        var actual: [Candidate] = []
        var candidates: [MixedCandidate] = []
        var tokens: [String: Candidate] = [:]
    }

    private let converter: KanaKanjiConverter
    private let directory: URL
    private let container: URL?
    private let context: SegmentsManager.Context
    private let expectedModelStatus: String?
    private var children: [Key: Child] = [:]
    public private(set) var candidateRequestCount = 0
    public private(set) var sessionLimitHitCount = 0
    public private(set) var sessionCreatedCount = 0
    public private(set) var sessionReleasedCount = 0
    public var activeChildCount: Int { children.count }
    public var backend: MixedConversionBackend {
        guard let expectedModelStatus else {
            return .dictionary
        }
        if converter.zenzStatus.isEmpty {
            return .zenzaiPending
        }
        return converter.zenzStatus == expectedModelStatus ? .zenzaiReady : .zenzaiUnavailable
    }
    public static let maximumChildren = 32

    public init(converter: KanaKanjiConverter, applicationDirectory: URL, container: URL? = nil,
                useZenzai: Bool, resources: URL? = nil, learningEnabled: Bool = true) throws {
        if useZenzai {
            guard let resources,
                  FileManager.default.isReadableFile(atPath: resources.appendingPathComponent("ggml-model-Q5_K_M.gguf").path) else {
                throw JapaneseSpanBridgeError.missingZenzaiWeights
            }
        }
        self.converter = converter
        self.directory = applicationDirectory
        self.container = container
        self.context = .init(useZenzai: useZenzai, resourcesDirectoryURL: resources, learningEnabled: learningEnabled)
        expectedModelStatus = useZenzai ? resources.map { "load \($0.appendingPathComponent("ggml-model-Q5_K_M.gguf").absoluteString)" } : nil
    }

    public func candidates(for request: JapaneseSpanRequest) throws -> JapaneseSpanResult {
        guard request.sourceRange.count == request.raw.unicodeScalars.count else { throw AutoMixedError.invalidRange }
        let key = Key(session: request.identity.sessionID, composition: request.identity.compositionID,
                      span: request.identity.spanID)
        func fallback(_ reason: JapaneseSpanFallback) throws -> JapaneseSpanResult {
            release(key)
            return JapaneseSpanResult(identity: request.identity,
                                      convertedRange: try ScalarRange(request.sourceRange.lowerBound, request.sourceRange.lowerBound),
                                      suffixRange: request.sourceRange, candidates: [], fallback: reason)
        }
        guard let parsed = RomanSpanReading.parse(request.raw) else {
            return try fallback(.invalidRoman)
        }
        guard parsed.suffix.isEmpty || request.isAtBufferEnd else {
            return try fallback(.incompleteInternalSpan)
        }
        guard !parsed.prefix.isEmpty else {
            return try fallback(.noCompletePrefix)
        }
        let settingsChanged = children[key]?.request.map { $0.settingsVersion != request.settingsVersion } ?? false
        let cacheKey = PreviewKey(conversionInput: parsed.conversionInput, completesTerminalN: parsed.completesTerminalN,
                                  left: request.leftContext, right: request.rightContext,
                                  rich: request.rich, settings: request.settingsVersion)
        invalidateChild(key, for: request, cacheKey: cacheKey)
        guard var child = child(for: key) else {
            return try fallback(.sessionLimit)
        }
        if child.cacheKey != cacheKey {
            let actual = try requestCandidates(request, parsed: parsed, child: child, settingsChanged: settingsChanged)
            if expectedModelStatus != nil, backend != .zenzaiReady {
                return try fallback(.modelUnavailable)
            }
            child.actual = actual
            child.cacheKey = cacheKey
            // Invalidate presentation even if a caller reused its revision.
            child.request = nil
        }
        if child.request?.raw != request.raw || child.request?.sourceRange != request.sourceRange
            || child.request?.identity.revision != request.identity.revision {
            child.tokens = [:]
            child.candidates = []
            var seen = Set<String>()
            for candidate in child.actual where !candidate.text.isEmpty && seen.insert(candidate.text).inserted {
                let token = UUID().uuidString
                child.tokens[token] = candidate
                child.candidates.append(MixedCandidate(token: token, text: candidate.text + parsed.suffix))
            }
            child.request = request
            children[key] = child
        }
        guard !child.candidates.isEmpty else {
            return try fallback(.noFullCandidate)
        }
        let end = request.sourceRange.lowerBound + parsed.prefix.unicodeScalars.count
        return JapaneseSpanResult(identity: request.identity,
                                  convertedRange: try ScalarRange(request.sourceRange.lowerBound, end),
                                  suffixRange: try ScalarRange(end, request.sourceRange.upperBound),
                                  candidates: child.candidates, fallback: nil)
    }

    private func invalidateChild(_ key: Key, for request: JapaneseSpanRequest, cacheKey: PreviewKey) {
        if let previous = children[key]?.request {
            let suffixEdit = previous.raw.unicodeScalars.starts(with: request.raw.unicodeScalars)
                || request.raw.unicodeScalars.starts(with: previous.raw.unicodeScalars)
            if !suffixEdit || previous.sourceRange.lowerBound != request.sourceRange.lowerBound
                || previous.leftContext != request.leftContext || previous.rightContext != request.rightContext
                || previous.settingsVersion != request.settingsVersion || previous.rich != request.rich {
                release(key)
            }
        }
        // Zenzai's session cache also carries a previous-candidate prefix constraint.
        // It is not a pure calculation cache: across readings it can change ranking
        // (observed in the installed shared server with an empty left context).
        // The pinned public API cannot clear that constraint independently. Keep
        // exact-reading reuse, and the converter-wide pure memoization cache, but
        // start fresh for changed Zenzai readings to preserve the existing display.
        // Dictionary-only lattice sessions can still reuse suffix edits.
        if expectedModelStatus != nil, let previous = children[key]?.cacheKey, previous != cacheKey {
            release(key)
        }
    }

    private func child(for key: Key) -> Child? {
        if let child = children[key] {
            return child
        }
        guard children.count < Self.maximumChildren else {
            sessionLimitHitCount += 1
            return nil
        }
        sessionCreatedCount += 1
        MixedPerformance.count(.sessionCreated)
        let child = Child(session: converter.createSession(), manager: SegmentsManager(
            kanaKanjiConverter: converter, applicationDirectoryURL: directory, containerURL: container, context: context
        ))
        children[key] = child
        return child
    }

    private func requestCandidates(_ request: JapaneseSpanRequest, parsed: RomanSpanReading,
                                   child: Child, settingsChanged: Bool) throws -> [Candidate] {
        let actual = try MixedPerformance.measure(.conversion) {
            try converter.withSession(child.session) {
                if settingsChanged {
                    child.manager.activate()
                    child.manager.reloadUserDictionary()
                }
                return child.manager.replaceCompositionFromRaw(parsed.conversionInput, leftContext: request.leftContext,
                    rightContext: request.rightContext, rich: request.rich, completeRomanInput: parsed.completesTerminalN)
            }
        }
        MixedPerformance.count(.candidates)
        candidateRequestCount += 1
        return actual
    }

    /// T5 must call this only after the host has applied a commit, while its tokens are retained.
    /// Cancelling/releasing or a new preview invalidates old tokens. No Candidate is reconstructed.
    public func recordCommittedSelection(_ token: String, identity: JapaneseSpanIdentity) throws {
        let key = Key(session: identity.sessionID, composition: identity.compositionID, span: identity.spanID)
        guard let child = children[key], child.request?.identity.revision == identity.revision,
              let candidate = child.tokens[token] else {
            throw JapaneseSpanBridgeError.invalidToken
        }
        try converter.withSession(child.session) { child.manager.recordMixedCommittedCandidate(candidate) }
        release(key)
    }

    public func retain(sessionID: UUID, compositionID: UUID, spanIDs: Set<UUID>) {
        for key in Array(children.keys) where key.session == sessionID &&
            (key.composition != compositionID || !spanIDs.contains(key.span)) {
            release(key)
        }
    }

    public func release(sessionID: UUID) {
        for key in Array(children.keys) where key.session == sessionID { release(key) }
    }

    public func releaseAll() {
        for key in Array(children.keys) { release(key) }
    }

    private func release(_ key: Key) {
        guard let child = children.removeValue(forKey: key) else {
            return
        }
        // stopComposition would also end the shared Zenzai session. Removing this child suffices.
        converter.removeSession(child.session)
        sessionReleasedCount += 1
        MixedPerformance.count(.sessionReleased)
    }
}
