import Foundation
#if canImport(os)
import os
#endif

/// Opt-in state tracing. Values deliberately cannot contain text, key codes, paths,
/// client names, error descriptions, candidates, or committed context.
public enum MixedDiagnostics {
    public enum Event: String, Sendable {
        case controllerActivate, controllerDeactivate, controllerCommit, modeNotification, modeApplied, activationGate
        case keyRoute, capabilityStart, capabilityReply, clientDeactivate, clientMismatch, clientReply, staleReply, manualExit
        case xpcSend, xpcReply, xpcFailure, xpcTimeout, xpcInterrupted, xpcInvalidated
        case serverReceive, serverReply, serverFailure, runtimeStage, performance, queueStart, displayApplied, keyQueued
    }
    public enum Field: String, Sendable {
        case owner, session, focus, operation, kind, action, mode, tag, recognized, active, pending, empty, japanese
        case standardRoman, sameClient, experiment, allowed, capability, accepted, success, reason, stage, status
        case pendingKeys, queueUS, serverQueueUS, responseUS, renderUS, judgmentUS, classificationUS, romanUS, conversionUS
        case sessionCreated, sessionReleased, candidateRequests, scorePasses
    }
    public enum Token: String, Sendable {
        case automatic, manualKey, probe, legacy, global, insert, enter, tab, space, backspace, escape, other
        case commit, stop, deactivate, candidate, acknowledge, disabled, failed, marker, model, lexicon, policy, bridge, ready
        case encode, decode, proxy, server, missingReply, guardRejected, unavailable, stale, unknown
        case kanaKey, romanKey, unsupportedInputStyle
    }
    public enum Value: Encodable, Sendable {
        case flag(Bool), number(Int), id(UUID), token(Token), mode(IMEInputMode), status(AutoMixedStatus)
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .flag(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .id(let value): try container.encode(value)
            case .token(let value): try container.encode(value.rawValue)
            case .mode(let value): try container.encode(value.rawValue)
            case .status(let value): try container.encode(value.rawValue)
            }
        }
    }

    private struct Configuration: Decodable { let enabled: Bool; let expiresAt: TimeInterval }
    private static let expiry: TimeInterval? = {
        guard IMEIdentity.current == .mixed, var directory = Bundle.main.executableURL?.deletingLastPathComponent() else {
            return nil
        }
        while directory.path != "/" {
            if directory.lastPathComponent == "Contents" {
                let file = directory.appendingPathComponent("Resources/auto-mixed-diagnostics.json")
                guard let data = try? Data(contentsOf: file), data.count <= 4096,
                      let config = try? JSONDecoder().decode(Configuration.self, from: data), config.enabled,
                      config.expiresAt <= Date().timeIntervalSince1970 + 86400 else {
                    return nil
                }
                return config.expiresAt
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }()
    @MainActor private static var emitted = 0
    public static var enabled: Bool { expiry.map { Date().timeIntervalSince1970 < $0 } ?? false }
#if canImport(os)
    private static let logger = Logger(subsystem: "dev.azookey.inputmethod.azooKeyMixed", category: "MixedDiagnostics")
#endif

    @MainActor public static func record(_ event: Event, _ fields: [Field: Value] = [:]) {
        guard enabled, emitted < 10000 else {
            return
        }
        emitted += 1
#if canImport(os)
        if let message = encoded(event, fields) { logger.notice("\(message, privacy: .public)") }
#endif
    }

    static func encoded(_ event: Event, _ fields: [Field: Value]) -> String? {
        struct Record: Encodable { let schema = 1; let event: String; let fields: [String: Value] }
        let record = Record(event: event.rawValue, fields: Dictionary(uniqueKeysWithValues: fields.map { ($0.key.rawValue, $0.value) }))
        guard let data = try? JSONEncoder().encode(record) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public static func performanceFields(_ snapshot: MixedPerformance.Snapshot) -> [Field: Value] {
        var result: [Field: Value] = [:]
        for (phase, field): (MixedPerformance.Phase, Field) in [(.judgment, .judgmentUS),
            (.classification, .classificationUS), (.roman, .romanUS), (.conversion, .conversionUS), (.render, .renderUS)] {
            result[field] = .number(Int(clamping: snapshot.microseconds[phase.rawValue, default: 0]))
        }
        for (counter, field): (MixedPerformance.Counter, Field) in [(.sessionCreated, .sessionCreated),
            (.sessionReleased, .sessionReleased), (.candidates, .candidateRequests), (.scorePass, .scorePasses)] {
            result[field] = .number(snapshot.counts[counter.rawValue, default: 0])
        }
        return result
    }

    public static func kind(_ command: ConverterSessionCommand) -> Token {
        switch command {
        case .autoMixed: return .automatic
        case .handleKeyEvent: return .manualKey
        case .composition(.snapshot): return .probe
        default: return .legacy
        }
    }
    public static func fields(for command: ConverterServerCommand) -> [Field: Value] {
        switch command {
        case .openSession(let session, let command), .session(let session, let command):
            var result: [Field: Value] = [.kind: .token(kind(command))]
            if let session = UUID(uuidString: session) { result[.session] = .id(session) }
            if case .autoMixed(let request) = command {
                result[.focus] = .id(request.focusID)
                result[.operation] = .number(Int(clamping: request.operationID))
                result[.action] = .token(kind(request.action))
            }
            return result
        default: return [.kind: .token(.global)]
        }
    }
    public static func kind(_ action: AutoMixedAction) -> Token {
        switch action {
        case .key(let event): return kind(event)
        case .commit: return .commit
        case .stop: return .stop
        case .deactivate: return .deactivate
        case .selectCandidate: return .candidate
        case .commitApplied: return .acknowledge
        }
    }
    public static func kind(_ event: KeyEventCore) -> Token {
        if event.keyCode == 104 {
            return .kanaKey
        }
        if event.keyCode == 102 {
            return .romanKey
        }
        switch AutoMixedKeyRouter.input(event) {
        case .insert: return .insert
        case .enter: return .enter
        case .space: return .space
        case .tab: return .tab
        case .backspace: return .backspace
        case .escape: return .escape
        default: return .other
        }
    }
}
