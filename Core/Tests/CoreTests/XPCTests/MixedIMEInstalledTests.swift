#if os(macOS)
import Core
import Foundation
import Testing

@objc private protocol MixedIMEProbeProtocol {
    func handleCommand(_ data: Data, with reply: @escaping @Sendable (Data?, NSString?) -> Void)
    func closeSession(_ sessionID: String, with reply: @escaping @Sendable (Bool) -> Void)
}

private enum ProbeError: Error { case timeout, connection, server }

private final class ProbeReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    init(_ continuation: CheckedContinuation<Data, any Error>) { self.continuation = continuation }
    func finish(_ result: Result<Data, any Error>) {
        let pending = lock.withLock {
            let value = continuation
            continuation = nil
            return value
        }
        pending?.resume(with: result)
    }
}

@MainActor private final class MixedIMEProbe {
    let connection = NSXPCConnection(machServiceName: IMEIdentity.mixed.machServiceName)
    init() {
        connection.remoteObjectInterface = NSXPCInterface(with: MixedIMEProbeProtocol.self)
        connection.resume()
    }
    func send(_ command: ConverterServerCommand) async throws -> ConverterServerResponse {
        let encoded = try ConverterServerCodec.encode(command)
        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            let reply = ProbeReply(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { reply.finish(.failure(ProbeError.timeout)) }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in reply.finish(.failure(ProbeError.connection)) }) as? MixedIMEProbeProtocol else {
                reply.finish(.failure(ProbeError.connection))
                return
            }
            proxy.handleCommand(encoded) { data, error in
                if let data, error == nil { reply.finish(.success(data)) }
                else { reply.finish(.failure(ProbeError.server)) }
            }
        }
        return try ConverterServerCodec.decodeResponse(from: data)
    }
    func close(_ session: String) async throws {
        defer { connection.invalidate() }
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            let reply = ProbeReply(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { reply.finish(.failure(ProbeError.timeout)) }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in reply.finish(.failure(ProbeError.connection)) }) as? MixedIMEProbeProtocol else {
                reply.finish(.failure(ProbeError.connection))
                return
            }
            proxy.closeSession(session) { closed in
                reply.finish(closed ? .success(Data()) : .failure(ProbeError.server))
            }
        }
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_INSTALLED_TEST"] == "1"))
@MainActor struct MixedIMEInstalledTests {
    @Test func installedHelperPrefersJapanesePunctuationExceptAfterEnglish() async throws {
        let probe = MixedIMEProbe()
        let session = "installed-punctuation-probe-" + UUID().uuidString
        let opened = try await probe.send(.openSession(sessionID: session, command: .composition(.snapshot)))
        let capability = try #require(opened.autoMixedCapability)
        let focus = UUID()
        var operation: UInt64 = 0
        func send(_ action: AutoMixedAction, left: String? = nil) async throws -> ConverterServerResponse {
            operation += 1
            return try await probe.send(.session(sessionID: session, command: .autoMixed(.init(
                serverEpoch: capability.serverEpoch, focusID: focus, operationID: operation,
                startsFocus: operation == 1, context: .init(leftSideContext: left), action: action))))
        }
        for (raw, left, expected) in [("asita.", "", "明日。"), ("asita,", "", "明日、"),
                                       ("asita-", "", "明日ー"), ("[apple]", "", "「apple」"),
                                       ("apple-.,", "明日", "apple-.,"), (".", "明日", "。"),
                                       (".", "apple", "."), ("3.14", "", "3.14"),
                                       ("https://example.com/a-b[x]", "", "https://example.com/a-b[x]")] {
            var display = ""
            var prefix = ""
            for character in raw {
                prefix.append(character)
                let response = try await send(.key(.init(modifierFlags: [], characters: String(character),
                    charactersIgnoringModifiers: String(character), keyCode: 0)), left: left)
                #expect(response.autoMixed?.raw == prefix)
                #expect(response.autoMixed?.status == .ready)
                display = response.snapshot.markedText.elements.map(\.content).joined()
            }
            #expect(display == expected, "authored runtime case: \(raw)")
            let commit = try #require(try await send(.commit).autoMixed?.commits.first)
            #expect(commit.text == expected)
            _ = try await send(.commitApplied(commit.commitID))
        }
        _ = try await send(.key(.init(modifierFlags: [], characters: "asita.", charactersIgnoringModifiers: "asita.", keyCode: 0)))
        let restored = try await send(.key(.init(modifierFlags: [], characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", keyCode: 53)))
        #expect(restored.snapshot.markedText.elements.map(\.content).joined() == "asita.")
        let rawCommit = try #require(try await send(.commit).autoMixed?.commits.first)
        #expect(rawCommit.text == "asita.")
        _ = try await send(.commitApplied(rawCommit.commitID))
        try await probe.close(session)
    }

    @Test func installedHelperKeepsAppleAfterJapaneseCommit() async throws {
        let probe = MixedIMEProbe()
        let session = "installed-apple-probe-" + UUID().uuidString
        let opened = try await probe.send(.openSession(sessionID: session, command: .composition(.snapshot)))
        let capability = try #require(opened.autoMixedCapability)
        let focus = UUID()
        var operation: UInt64 = 0
        func send(_ action: AutoMixedAction, left: String? = nil) async throws -> ConverterServerResponse {
            operation += 1
            return try await probe.send(.session(sessionID: session, command: .autoMixed(.init(
                serverEpoch: capability.serverEpoch, focusID: focus, operationID: operation,
                startsFocus: operation == 1, context: .init(leftSideContext: left), action: action))))
        }
        func key(_ text: String) -> AutoMixedAction {
            .key(.init(modifierFlags: [], characters: text, charactersIgnoringModifiers: text, keyCode: 0))
        }
        _ = try await send(key("asita"))
        let japanese = try #require(try await send(.commit).autoMixed?.commits.first)
        #expect(japanese.text == "明日")
        _ = try await send(.commitApplied(japanese.commitID))
        for (index, character) in "apple".enumerated() {
            let response = try await send(key(String(character)), left: "明日")
            #expect(response.autoMixed?.raw == String("apple".prefix(index + 1)))
            if index >= 2 {
                #expect(response.snapshot.markedText.elements.map(\.content).joined() == String("apple".prefix(index + 1)))
                #expect(response.autoMixed?.spans.map(\.kind) == [.raw])
            }
        }
        let english = try #require(try await send(.commit).autoMixed?.commits.first)
        #expect(english.text == "apple")
        _ = try await send(.commitApplied(english.commitID))
        try await probe.close(session)
    }

    @Test func registeredHelperNegotiatesConvertsAndDeduplicatesThroughMachXPC() async throws {
        let probe = MixedIMEProbe()
        let session = "installed-mixed-probe-" + UUID().uuidString
        let opened = try await probe.send(.openSession(sessionID: session, command: .composition(.snapshot)))
        let capability = try #require(opened.autoMixedCapability)
        #expect(capability.version == 1)
        var ledger = AutoMixedClientLedger()
        ledger.activate(capability: capability)
        func request(_ operation: UInt64, _ action: AutoMixedAction) -> ConverterServerCommand {
            .session(sessionID: session, command: .autoMixed(.init(serverEpoch: capability.serverEpoch,
                focusID: ledger.focusID, operationID: operation, startsFocus: operation == 1, action: action)))
        }
        let raw = "asitahameetinggaarimasu"
        let composed = try await probe.send(request(1, .key(.init(modifierFlags: [], characters: raw, charactersIgnoringModifiers: raw, keyCode: 0))))
        #expect(composed.snapshot.markedText.elements.map(\.content).joined() == "明日はmeetingがあります")
        #expect(composed.autoMixed?.raw == raw)
        let committed = try #require(try await probe.send(request(2, .commit)).autoMixed)
        #expect(ledger.takeCommits(committed).map(\.text) == ["明日はmeetingがあります"])
        let duplicate = try #require(try await probe.send(request(2, .commit)).autoMixed)
        #expect(ledger.takeCommits(duplicate).isEmpty)
        let effect = try #require(committed.commits.first)
        let ack = try await probe.send(request(3, .commitApplied(effect.commitID)))
        #expect(ack.autoMixed?.commits.isEmpty == true)
        try await probe.close(session)
    }
}
#endif
