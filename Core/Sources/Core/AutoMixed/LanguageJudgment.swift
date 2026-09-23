import Foundation

/// Ephemeral input only. Availability must be established by the caller before construction.
/// Do not encode, log, hash for telemetry, or retain this value in a persistent cache.
public struct CommittedLeftContext: Sendable, CustomDebugStringConvertible {
    public static let scalarLimit = 30
    public static let unavailable = Self(text: nil)
    public var isAvailable: Bool { text != nil }
    let text: String?

    private init(text: String?) { self.text = text }

    /// A successful empty read is different from unavailable. No normalization or whitespace trim.
    public static func available(_ text: String) -> Self {
        Self(text: String(String.UnicodeScalarView(text.unicodeScalars.suffix(scalarLimit))))
    }

    public var debugDescription: String { "CommittedLeftContext(<redacted>)" }
}

/// Each snapshot gets a new identity, even if only its context or availability changed.
/// This is a new pure-Core API, not the existing ConverterTextContext XPC payload.
public struct LanguageJudgmentInput: Sendable, CustomDebugStringConvertible {
    public let raw: String
    public let leftCommittedContext: CommittedLeftContext
    public let focusIdentity: UUID
    public let revision: UInt64
    public let requestID: UUID

    public init(raw: String, leftCommittedContext: CommittedLeftContext = .unavailable,
                focusIdentity: UUID, revision: UInt64) {
        self.raw = raw
        self.leftCommittedContext = leftCommittedContext
        self.focusIdentity = focusIdentity
        self.revision = revision
        self.requestID = UUID()
    }

    public var debugDescription: String { "LanguageJudgmentInput(<redacted>)" }
}

public protocol ContextualLanguageJudging {
    func judge(_ input: LanguageJudgmentInput) throws -> LanguageJudgment
}

/// Contains no context text or feature keys. JA is still only a hypothesis pending T4 validation.
public struct LanguageJudgment: Sendable {
    public let requestID: UUID
    public let hypotheses: [MixedSpan]

    public func isCurrent(for input: LanguageJudgmentInput) -> Bool {
        requestID == input.requestID
    }

    public var safeSpans: [MixedSpan] {
        hypotheses.map { span in
            MixedSpan(id: span.id, sourceRange: span.sourceRange,
                      kind: span.kind == .japaneseRoman ? .unresolved : span.kind)
        }
    }
}
