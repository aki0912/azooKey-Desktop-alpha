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
    @Test func installedHelperDeletesReadingUnitsAndResumesConversion() async throws {
        let probe = MixedIMEProbe()
        let session = "installed-reading-backspace-" + UUID().uuidString
        let opened = try await probe.send(.openSession(sessionID: session, command: .composition(.snapshot)))
        let capability = try #require(opened.autoMixedCapability)
        var focus = UUID(), operation: UInt64 = 0
        var startsFocus = true
        func send(_ action: AutoMixedAction) async throws -> ConverterServerResponse {
            operation += 1
            let request = AutoMixedRequest(serverEpoch: capability.serverEpoch, focusID: focus,
                operationID: operation, startsFocus: startsFocus, context: .init(leftSideContext: ""), action: action)
            startsFocus = false
            return try await probe.send(.session(sessionID: session, command: .autoMixed(request)))
        }
        func key(_ text: String, code: UInt16 = 0) async throws -> ConverterServerResponse {
            try await send(.key(.init(modifierFlags: [], characters: text, charactersIgnoringModifiers: text, keyCode: code)))
        }
        func display(_ response: ConverterServerResponse) -> String {
            response.snapshot.markedText.elements.map(\.content).joined()
        }
        func commit(_ expected: String) async throws {
            let result = try await send(.commit)
            if expected.isEmpty { #expect(result.autoMixed?.commits.isEmpty == true) }
            else {
                let effect = try #require(result.autoMixed?.commits.first)
                #expect(effect.text == expected)
                let ack = try await send(.commitApplied(effect.commitID))
                #expect(ack.autoMixed?.raw.isEmpty == true)
                #expect(ack.autoMixed?.commits.isEmpty == true)
            }
        }
        for (raw, expected) in [("asita", "あし"), ("ashita", "あし"), ("kitte", "きっ"), ("kanji", "かん"),
                                ("kya", ""), ("sha", ""), ("fa", ""), ("harike-n", "はりけー"),
                                ("apple asita", "apple あし")] {
            for character in raw { _ = try await key(String(character)) }
            let deleted = try await key("\u{7f}", code: 51)
            #expect(deleted.autoMixed?.status == .ready)
            #expect(display(deleted) == expected, "authored: \(raw)")
            try await commit(expected)
        }
        _ = try await key("asita")
        #expect(display(try await key("\u{7f}", code: 51)) == "あし")
        #expect(display(try await key("\u{7f}", code: 51)) == "あ")
        #expect(display(try await key("sita")) == "明日")
        _ = try await key("\u{7f}", code: 51)
        let selection = try await key("\t", code: 48)
        let revision = try #require(selection.autoMixed?.revision)
        guard case .selecting(let candidates, _) = selection.snapshot.candidateWindow else {
            Issue.record("Reading preview must reopen conversion candidates"); try await probe.close(session); return
        }
        let index = try #require(candidates.firstIndex { $0.text == "足" })
        _ = try await send(.selectCandidate(index: index, revision: revision, adopt: true))
        #expect(display(try await key("\u{7f}", code: 51)) == "あ")
        #expect(try await send(.selectCandidate(index: index, revision: revision, adopt: true)).autoMixed?.status == .staleRequest)
        try await commit("あ")
        _ = try await key("asitanx")
        for expected in ["明日n", "明日", "あし"] {
            #expect(display(try await key("\u{7f}", code: 51)) == expected)
        }
        #expect(display(try await key("\u{1b}", code: 53)) == "asi")
        #expect(display(try await key("\u{7f}", code: 51)) == "as")
        try await commit("as")
        _ = try await key("asita")
        _ = try await key("\u{7f}", code: 51)
        _ = try await send(.deactivate)
        focus = UUID(); startsFocus = true
        #expect(display(try await key("asita")) == "明日")
        try await commit("明日")
        try await probe.close(session)
    }

    @Test func installedHelperKeepsJapaneseWhenTypingAfterPunctuation() async throws {
        let probe = MixedIMEProbe()
        let session = "installed-punctuation-continuation-" + UUID().uuidString
        let opened = try await probe.send(.openSession(sessionID: session, command: .composition(.snapshot)))
        let capability = try #require(opened.autoMixedCapability)
        let focus = UUID()
        var operation: UInt64 = 0
        func send(_ action: AutoMixedAction, left: String?) async throws -> ConverterServerResponse {
            operation += 1
            return try await probe.send(.session(sessionID: session, command: .autoMixed(.init(
                serverEpoch: capability.serverEpoch, focusID: focus, operationID: operation,
                startsFocus: operation == 1, context: .init(leftSideContext: left), action: action))))
        }
        func type(_ text: String, left: String?) async throws -> String {
            var display = ""
            for character in text {
                let response = try await send(.key(.init(modifierFlags: [], characters: String(character),
                    charactersIgnoringModifiers: String(character), keyCode: 0)), left: left)
                #expect(response.autoMixed?.status == .ready)
                display = response.snapshot.markedText.elements.map(\.content).joined()
            }
            return display
        }
        let contexts: [String?] = [nil, "", "今日は晴れです。"]
        for left in contexts {
            for stem in ["asita", "asitanotennkiwosirabetehosii"] {
                for (punctuation, rendered) in [(".", "。"), (",", "、")] {
                    let before = try await type(stem, left: left)
                    #expect(before != stem)
                    #expect(try await type(punctuation, left: left) == before + rendered)
                    #expect(try await type("d", left: left) == before + rendered + "d")
                    let removed = try await send(.key(.init(modifierFlags: [], characters: "\u{7f}",
                        charactersIgnoringModifiers: "\u{7f}", keyCode: 51)), left: left)
                    #expect(removed.snapshot.markedText.elements.map(\.content).joined() == before + rendered)
                    #expect(try await type("d", left: left) == before + rendered + "d")
                    let commit = try #require(try await send(.commit, left: left).autoMixed?.commits.first)
                    #expect(commit.text == before + rendered + "d")
                    let ack = try await send(.commitApplied(commit.commitID), left: left)
                    #expect(ack.autoMixed?.raw.isEmpty == true)
                    #expect(ack.autoMixed?.commits.isEmpty == true)
                }
            }
        }
        try await probe.close(session)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_STRESS"] == "1"))
    func installedHelperAcknowledgesThousandCompositions() async throws {
        let probe = MixedIMEProbe()
        let session = "installed-latency-stress-" + UUID().uuidString
        let opened = try await probe.send(.openSession(sessionID: session, command: .composition(.snapshot)))
        let capability = try #require(opened.autoMixedCapability)
        var focus = UUID(), operation: UInt64 = 0
        var startsFocus = true
        func send(_ action: AutoMixedAction) async throws -> ConverterServerResponse {
            operation += 1
            let command = ConverterServerCommand.session(sessionID: session, command: .autoMixed(.init(
                serverEpoch: capability.serverEpoch, focusID: focus, operationID: operation,
                startsFocus: startsFocus, action: action)))
            startsFocus = false
            return try await probe.send(command)
        }
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<1000 {
            for text in ["asita", "n"] {
                let response = try await send(.key(.init(modifierFlags: [], characters: text,
                    charactersIgnoringModifiers: text, keyCode: 0)))
                #expect(response.autoMixed?.status == .ready)
                #expect(response.snapshot.markedText.elements.map(\.content).joined() == (text == "n" ? "明日n" : "明日"))
            }
            let commit = try #require(try await send(.commit).autoMixed?.commits.first)
            #expect(commit.text == "明日n")
            let ack = try await send(.commitApplied(commit.commitID))
            #expect(ack.autoMixed?.commits.isEmpty == true)
            #expect(ack.autoMixed?.raw.isEmpty == true)
            if index % 100 == 99 {
                _ = try await send(.deactivate)
                focus = UUID(); startsFocus = true
            }
        }
        print("Real Mach XPC stress: 1000 compositions, microseconds=\((DispatchTime.now().uptimeNanoseconds - start) / 1000)")
        try await probe.close(session)
    }

    @Test func installedHelperConvertsLongVowelWordsAndKeepsOriginalRanges() async throws {
        let probe = MixedIMEProbe()
        let session = "installed-long-vowel-probe-" + UUID().uuidString
        let opened = try await probe.send(.openSession(sessionID: session, command: .composition(.snapshot)))
        let capability = try #require(opened.autoMixedCapability)
        let focus = UUID()
        var operation: UInt64 = 0
        func send(_ action: AutoMixedAction) async throws -> ConverterServerResponse {
            operation += 1
            return try await probe.send(.session(sessionID: session, command: .autoMixed(.init(
                serverEpoch: capability.serverEpoch, focusID: focus, operationID: operation,
                startsFocus: operation == 1, action: action))))
        }
        for (raw, expected) in [("harike-n", "ハリケーン"), ("harike-nn", "ハリケーン"),
                                ("ko-hi-", "コーヒー"), ("su-pa-", "スーパー"), ("ra-men", "ラーメン")] {
            var prefix = ""
            for character in raw {
                prefix.append(character)
                let response = try await send(.key(.init(modifierFlags: [], characters: String(character),
                    charactersIgnoringModifiers: String(character), keyCode: 0)))
                #expect(response.autoMixed?.raw == prefix)
                #expect(response.autoMixed?.status == .ready)
            }
            let selection = try await send(.key(.init(modifierFlags: [], characters: "\t", charactersIgnoringModifiers: "\t", keyCode: 48)))
            let mixed = try #require(selection.autoMixed)
            #expect(mixed.spans.count == 1)
            #expect(mixed.spans.first?.sourceRange == (try ScalarRange(0, raw.unicodeScalars.count)))
            guard case .selecting(let candidates, _) = selection.snapshot.candidateWindow else {
                Issue.record("Expected whole-word candidates"); continue
            }
            let index = try #require(candidates.firstIndex { $0.text == expected }, "authored: \(raw)")
            _ = try await send(.selectCandidate(index: index, revision: mixed.revision, adopt: true))
            let commit = try #require(try await send(.commit).autoMixed?.commits.first)
            #expect(commit.text == expected)
            _ = try await send(.commitApplied(commit.commitID))
        }
        _ = try await send(.key(.init(modifierFlags: [], characters: "harike-n", charactersIgnoringModifiers: "harike-n", keyCode: 0)))
        _ = try await send(.key(.init(modifierFlags: [], characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", keyCode: 53)))
        let rawCommit = try #require(try await send(.commit).autoMixed?.commits.first)
        #expect(rawCommit.text == "harike-n")
        _ = try await send(.commitApplied(rawCommit.commitID))
        try await probe.close(session)
    }

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
                                       ("asita?", "", "明日？"), ("asita!", "", "明日！"),
                                       ("asita?!", "", "明日？！"), ("apple?!", "明日", "apple?!"),
                                       ("?", "明日", "？"), ("!", "明日", "！"),
                                       ("()", "明日", "（）"), ("()", "apple", "()"),
                                       ("asita(apple)", "", "明日（apple）"),
                                       ("apple(asita)", "", "apple(明日)"),
                                       (")", "（apple", "）"), (")", "apple(明日", ")"),
                                       ("(3)", "", "(3)"),
                                       ("https://example.com/a(b)", "", "https://example.com/a(b)"),
                                       ("?", "apple", "?"), ("!", "apple", "!"),
                                       ("https://example.com/?q=日本語!", "", "https://example.com/?q=日本語!"),
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

    @Test func installedHelperKeepsJapaneseAroundInvalidRoman() async throws {
        let probe = MixedIMEProbe()
        let session = "installed-invalid-roman-probe-" + UUID().uuidString
        let opened = try await probe.send(.openSession(sessionID: session, command: .composition(.snapshot)))
        let capability = try #require(opened.autoMixedCapability)
        let focus = UUID()
        var operation: UInt64 = 0
        func send(_ action: AutoMixedAction) async throws -> ConverterServerResponse {
            operation += 1
            return try await probe.send(.session(sessionID: session, command: .autoMixed(.init(
                serverEpoch: capability.serverEpoch, focusID: focus, operationID: operation,
                startsFocus: operation == 1, action: action))))
        }
        func key(_ text: String, code: UInt16 = 0) -> AutoMixedAction {
            .key(.init(modifierFlags: [], characters: text, charactersIgnoringModifiers: text, keyCode: code))
        }
        let raw = "zuttotukatteirutodanndannnyuuryokugaosokunarukigasurnndakedo"
        var prefix = String(raw.prefix(51))
        let before = try await send(key(prefix))
        let japanese = before.snapshot.markedText.elements.map(\.content).joined()
        #expect(!japanese.isEmpty && !japanese.contains(where: \.isASCII))
        var display = ""
        for character in raw.dropFirst(51) {
            prefix.append(character)
            let response = try await send(key(String(character)))
            #expect(response.autoMixed?.status == .ready)
            #expect(response.autoMixed?.raw == prefix)
            display = response.snapshot.markedText.elements.map(\.content).joined()
            #expect(display.hasPrefix(japanese + "r"))
        }
        #expect(display.hasSuffix("んだけど"))
        #expect(display.filter(\.isASCII) == "r")
        let commit = try #require(try await send(.commit).autoMixed?.commits.first)
        #expect(commit.text == display)
        _ = try await send(.commitApplied(commit.commitID))
        let pasted = try await send(key(raw))
        #expect(pasted.snapshot.markedText.elements.map(\.content).joined() == display)
        _ = try await send(key("\u{1b}", code: 53))
        let original = try #require(try await send(.commit).autoMixed?.commits.first)
        #expect(original.text == raw)
        _ = try await send(.commitApplied(original.commitID))
        try await probe.close(session)
    }
}
#endif
