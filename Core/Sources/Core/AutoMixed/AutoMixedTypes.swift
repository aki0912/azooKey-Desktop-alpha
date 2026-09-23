import Foundation

public enum AutoMixedError: Error, Equatable {
    case invalidRange
    case notGraphemeBoundary
    case invalidSpanCoverage
    case invalidCandidate
}

/// End-exclusive offsets in the original Unicode scalar sequence, never Character counts.
public struct ScalarRange: Codable, Sendable, Equatable, Hashable {
    public let lowerBound: Int
    public let upperBound: Int
    public var count: Int { upperBound - lowerBound }

    public init(_ lowerBound: Int, _ upperBound: Int) throws {
        guard lowerBound >= 0, upperBound >= lowerBound else {
            throw AutoMixedError.invalidRange
        }
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(values.decode(Int.self, forKey: .lowerBound), values.decode(Int.self, forKey: .upperBound))
    }
}

/// Offsets in the displayed UTF-16 sequence, suitable for an IMK NSRange.
public struct UTF16Range: Codable, Sendable, Equatable {
    public let location: Int
    public let length: Int
    public var upperBound: Int { location + length }

    public init(location: Int, length: Int) throws {
        guard location >= 0, length >= 0, location <= Int.max - length else {
            throw AutoMixedError.invalidRange
        }
        self.location = location
        self.length = length
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(location: values.decode(Int.self, forKey: .location), length: values.decode(Int.self, forKey: .length))
    }
}

public enum SpanKind: String, Codable, Sendable {
    case japaneseRoman, raw, literal, gap, unresolved
}

public struct MixedSpan: Sendable, Equatable {
    public let id: UUID
    public let sourceRange: ScalarRange
    public let kind: SpanKind

    public init(id: UUID = UUID(), sourceRange: ScalarRange, kind: SpanKind) {
        self.id = id
        self.sourceRange = sourceRange
        self.kind = kind
    }
}

/// T1 candidates cover the complete requested span. Prefix/suffix conversion belongs to T4.
public struct MixedCandidate: Sendable, Equatable {
    public let token: String
    public let text: String

    public init(token: String, text: String) {
        self.token = token
        self.text = text
    }
}

/// Injection boundary only; T1 supplies no production classifier or model loader.
public protocol LanguageSegmenter {
    func segment(_ raw: String) throws -> [MixedSpan]
}

/// Preview-only boundary. No learning or OS insertion is performed by the pure engine.
/// The real session-aware Zenzai adapter and commit acknowledgement contract belong to T4/T5.
@MainActor public protocol JapaneseSpanConverting {
    func candidates(for raw: String, span: MixedSpan) throws -> [MixedCandidate]
}

public enum MixedCompositionState: Sendable, Equatable {
    case idle, composing, selecting, rawPreview
}

public enum MixedInputEvent: Sendable {
    case insert(String)
    case space
    case tab(reverse: Bool = false)
    case enter
    case escape
    case backspace
}

public enum MixedEventDisposition: Sendable, Equatable {
    case consumed, fallthroughToApplication
}

/// A value for the future host to apply, not an XPC effect or an exactly-once transaction.
public struct MixedCommit: Sendable, Equatable {
    public let text: String
    public let sourceScalarCount: Int
}

public struct MixedEventResult: Sendable, Equatable {
    public let disposition: MixedEventDisposition
    public let commit: MixedCommit?
}
