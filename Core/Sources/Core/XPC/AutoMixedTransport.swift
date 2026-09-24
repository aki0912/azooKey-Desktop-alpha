import Foundation

public enum CompositionPolicy: String, Codable, Sendable { case manual, automaticMixed }

public struct AutoMixedCapability: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public let version: Int
    public let serverEpoch: UUID
    public init(serverEpoch: UUID, version: Int = currentVersion) {
        self.serverEpoch = serverEpoch
        self.version = version
    }
}

public enum AutoMixedAction: Codable, Sendable, Equatable {
    case key(KeyEventCore)
    case commit
    case stop
    case deactivate
    case selectCandidate(index: Int, revision: UInt64, adopt: Bool)
    case commitApplied(UUID)
}

/// Ephemeral wire value. No user text is printed by diagnostic interpolation.
public struct AutoMixedRequest: Codable, Sendable, Equatable, CustomDebugStringConvertible {
    public let serverEpoch: UUID
    public let focusID: UUID
    public let operationID: UInt64
    public let startsFocus: Bool
    public let inputStyle: ConverterInputStyle
    public let context: ConverterTextContext
    public let action: AutoMixedAction
    public init(serverEpoch: UUID, focusID: UUID, operationID: UInt64, startsFocus: Bool = false,
                inputStyle: ConverterInputStyle = .defaultRomanToKana,
                context: ConverterTextContext = .init(), action: AutoMixedAction) {
        self.serverEpoch = serverEpoch
        self.focusID = focusID
        self.operationID = operationID
        self.startsFocus = startsFocus
        self.inputStyle = inputStyle
        self.context = .init(leftSideContext: context.leftSideContext.map { String($0.suffix(30)) },
                             rightSideContext: context.rightSideContext.map { String($0.prefix(30)) })
        self.action = action
    }
    public var debugDescription: String { "AutoMixedRequest(<redacted>)" }
}

public struct AutoMixedCommitEffect: Codable, Sendable, Equatable {
    public let commitID: UUID
    public let compositionID: UUID
    public let text: String
}

public struct AutoMixedWireSpan: Codable, Sendable, Equatable {
    public let id: UUID
    public let sourceRange: ScalarRange
    public let displayRange: UTF16Range
    public let kind: SpanKind
}

public enum AutoMixedStatus: String, Codable, Sendable {
    case ready, rawFallback, inputLimit, awaitingAcknowledgement, unsupportedInputStyle, staleRequest, restartRequired, unavailable
}

public struct AutoMixedResponse: Codable, Sendable {
    public let serverEpoch: UUID
    public let focusID: UUID
    public let operationID: UInt64
    public let compositionID: UUID
    public let revision: UInt64
    public let raw: String
    public let spans: [AutoMixedWireSpan]
    public let commits: [AutoMixedCommitEffect]
    public let status: AutoMixedStatus
    public static func rejected(_ request: AutoMixedRequest, epoch: UUID, status: AutoMixedStatus) -> Self {
        Self(serverEpoch: epoch, focusID: request.focusID, operationID: request.operationID,
             compositionID: UUID(), revision: 0, raw: "", spans: [], commits: [], status: status)
    }
}

/// Deduplicates commit effects separately from replaceable snapshots. A new focus
/// creates a new lease; responses from another field or server epoch are never applied.
public struct AutoMixedClientLedger {
    public private(set) var capability: AutoMixedCapability?
    public private(set) var focusID = UUID()
    public private(set) var lastSnapshotOperation: UInt64 = 0
    private var appliedCommits = Set<UUID>()
    private var acknowledgedRaw = ""
    private var pendingKeys: [(UInt64, KeyEventCore)] = []
    public init() {}
    public mutating func activate(capability: AutoMixedCapability?) {
        self.capability = capability?.version == AutoMixedCapability.currentVersion ? capability : nil
        focusID = UUID()
        lastSnapshotOperation = 0
        appliedCommits = []
        acknowledgedRaw = ""
        pendingKeys = []
    }
    public mutating func deactivate() { activate(capability: nil) }
    public func accepts(_ response: AutoMixedResponse) -> Bool {
        capability?.serverEpoch == response.serverEpoch && focusID == response.focusID
    }
    public mutating func acceptSnapshot(_ response: AutoMixedResponse) -> Bool {
        guard accepts(response), response.operationID >= lastSnapshotOperation else { return false }
        lastSnapshotOperation = response.operationID
        acknowledgedRaw = response.raw
        pendingKeys.removeAll { $0.0 <= response.operationID }
        return true
    }
    public mutating func recordKey(_ event: KeyEventCore, operationID: UInt64) {
        pendingKeys.append((operationID, event))
    }
    /// Failure recovery only. Unacknowledged Enter must not delete text that IMK
    /// has not inserted; this journal never performs language or candidate inference.
    public func recoveryRaw() -> String {
        var buffer = RawCompositionBuffer()
        try? buffer.insert(acknowledgedRaw)
        for (_, key) in pendingKeys {
            switch AutoMixedKeyRouter.input(key) {
            case .insert(let text): try? buffer.insert(text)
            case .space: try? buffer.insert(" ")
            case .backspace: _ = try? buffer.deleteBackward()
            default: break
            }
        }
        return buffer.text
    }
    public func immediateCommitText(displayed: String) -> String {
        pendingKeys.isEmpty ? displayed : recoveryRaw()
    }
    public mutating func takeCommits(_ response: AutoMixedResponse) -> [AutoMixedCommitEffect] {
        guard accepts(response) else { return [] }
        var effects: [AutoMixedCommitEffect] = []
        for effect in response.commits where appliedCommits.insert(effect.commitID).inserted {
            effects.append(effect)
        }
        // Keep IDs for this focus lease; evicting an ID could reapply a delayed effect.
        return effects
    }
}

public enum AutoMixedKeyRouter {
    public static func input(_ event: KeyEventCore) -> MixedInputEvent? {
        guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.option) else { return nil }
        switch event.keyCode {
        case 36, 76: return .enter
        case 48: return .tab(reverse: event.modifierFlags.contains(.shift))
        case 49: return .space
        case 51: return .backspace
        case 53: return .escape
        default:
            guard let text = event.characters, !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ $0.value >= 32 && !(0x7f...0x9f).contains($0.value)
                      && !(0xf700...0xf8ff).contains($0.value) }) else { return nil }
            return .insert(text)
        }
    }
    public static func owns(_ event: KeyEventCore, composing: Bool, pending: Bool) -> Bool {
        if event.modifierFlags.contains(.command) { return false }
        if pending { return true }
        guard let input = input(event) else { return composing }
        switch input {
        case .insert, .space: return true
        default: return composing
        }
    }
}
