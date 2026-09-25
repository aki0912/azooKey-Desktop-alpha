@testable import Core
import Crypto
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@Suite @MainActor struct AutoMixedTransportTests {
    struct Segmenter: LanguageSegmenter {
        func segment(_ raw: String) throws -> [MixedSpan] {
            raw.isEmpty ? [] : [try .init(sourceRange: ScalarRange(0, raw.unicodeScalars.count),
                                         kind: raw == "asita" ? .japaneseRoman : .raw)]
        }
    }
    final class Converter: JapaneseSpanConverting {
        var finishes = 0
        func reading(for raw: String) -> String { CompositionCharacterType.hiragana.text(raw: raw) }
        func candidates(for raw: String, span: MixedSpan) -> [MixedCandidate] {
            [.init(token: "mock-1", text: "明日"), .init(token: "mock-2", text: "あした")]
        }
        func finishComposition() { finishes += 1 }
    }
    func key(_ text: String, code: UInt16 = 0, flags: KeyEventCore.ModifierFlag = []) -> KeyEventCore {
        .init(modifierFlags: flags, characters: text, charactersIgnoringModifiers: text, keyCode: code)
    }
    func session(epoch: UUID, converter: Converter = Converter()) -> AutoMixedServerSession {
        AutoMixedServerSession(epoch: epoch) { _ in MixedCompositionEngine(segmenter: Segmenter(), converter: converter) }
    }

    @Test func legacyJSONAndCapabilityNegotiationRemainOptional() throws {
        let old = ConverterServerResponse(snapshot: .empty)
        let data = try ConverterServerCodec.encode(old)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["autoMixed"] == nil)
        #expect(object["autoMixedCapability"] == nil)
        let decoded = try ConverterServerCodec.decodeResponse(from: data)
        #expect(decoded.autoMixed == nil && decoded.autoMixedCapability == nil)
        var ledger = AutoMixedClientLedger()
        ledger.activate(capability: .init(serverEpoch: UUID(), version: 999))
        #expect(ledger.capability == nil)
        let command = ConverterServerCommand.session(sessionID: "test", command: .composition(.snapshot))
        if case .session(_, .composition(.snapshot)) = try ConverterServerCodec.decodeCommand(from: ConverterServerCodec.encode(command)) {} else {
            Issue.record("Capability probe must use an existing command")
        }
    }

    @Test func wireRoundTripAndUnicodeOffsetsDoNotExposeContentInDiagnostics() throws {
        let epoch = UUID(), focus = UUID()
        let request = AutoMixedRequest(serverEpoch: epoch, focusID: focus, operationID: 1, startsFocus: true,
            context: .init(leftSideContext: String(repeating: "秘", count: 40)), action: .key(key("👩‍💻e\u{301}  asita")))
        #expect(request.context.leftSideContext?.count == 30)
        #expect(!String(reflecting: request).contains("秘"))
        let command = ConverterServerCommand.session(sessionID: "test", command: .autoMixed(request))
        if case .session(_, .autoMixed(let decoded)) = try ConverterServerCodec.decodeCommand(from: ConverterServerCodec.encode(command)) {
            #expect(decoded == request)
        } else { Issue.record("Missing mixed request") }
        let response = try session(epoch: epoch).handle(request)
        let wire = try ConverterServerCodec.decodeResponse(from: ConverterServerCodec.encode(response))
        #expect(wire.snapshot.markedText.elements.first?.content == "👩‍💻e\u{301}  asita")
        #expect(wire.snapshot.markedText.selectionRange.location == 14)
        #expect(wire.autoMixed?.spans.first?.sourceRange.upperBound == 12)
        #expect(wire.autoMixed?.raw == "👩‍💻e\u{301}  asita")
    }

    @Test func duplicateCommitsAreSeparateFromStaleSnapshotsAndAcknowledgedOnce() throws {
        let epoch = UUID()
        var ledger = AutoMixedClientLedger()
        ledger.activate(capability: .init(serverEpoch: epoch))
        let host = session(epoch: epoch)
        func request(_ id: UInt64, _ action: AutoMixedAction) -> AutoMixedRequest {
            .init(serverEpoch: epoch, focusID: ledger.focusID, operationID: id, startsFocus: id == 1, action: action)
        }
        let insert = request(1, .key(key("asita")))
        _ = try host.handle(insert)
        #expect(try host.handle(insert).autoMixed?.raw == "asita")
        let commitRequest = request(2, .commit)
        let committed = try #require(host.handle(commitRequest).autoMixed)
        #expect(committed.commits.map(\.text) == ["明日"])
        #expect(try host.handle(commitRequest).autoMixed?.commits == committed.commits)
        let newer = try #require(host.handle(request(3, .key(key("next")))).autoMixed)
        let acceptsNew = ledger.acceptSnapshot(newer)
        let acceptsOld = ledger.acceptSnapshot(committed)
        #expect(acceptsNew)
        #expect(!acceptsOld)
        #expect(ledger.takeCommits(committed).map(\.text) == ["明日"])
        #expect(ledger.takeCommits(newer).isEmpty)
        #expect(host.pendingCommitCount == 1)
        let ack = request(4, .commitApplied(committed.commits[0].commitID))
        _ = try host.handle(ack)
        _ = try host.handle(ack)
        #expect(host.pendingCommitCount == 0)
        #expect(try host.handle(insert).autoMixed?.status == .staleRequest)
    }

    @Test func candidateGenerationEnterAndOSCommitHaveDifferentContracts() throws {
        let epoch = UUID(), focus = UUID()
        let host = session(epoch: epoch)
        func request(_ id: UInt64, _ action: AutoMixedAction) -> AutoMixedRequest {
            .init(serverEpoch: epoch, focusID: focus, operationID: id, startsFocus: id == 1, action: action)
        }
        _ = try host.handle(request(1, .key(key("asita"))))
        let selecting = try host.handle(request(2, .key(key("\t", code: 48))))
        #expect(selecting.inputState == .selecting)
        #expect(selecting.snapshot.markedText.elements.first?.focus == .focused)
        let revision = try #require(selecting.autoMixed?.revision)
        #expect(try host.handle(request(3, .selectCandidate(index: 1, revision: revision - 1, adopt: false))).autoMixed?.status == .staleRequest)
        let chosen = try host.handle(request(4, .selectCandidate(index: 1, revision: revision, adopt: true)))
        #expect(chosen.autoMixed?.commits.isEmpty == true)
        #expect(chosen.snapshot.markedText.elements.first?.content == "あした")
        _ = try host.handle(request(5, .key(key("\t", code: 48))))
        #expect(try host.handle(request(6, .commit)).autoMixed?.commits.first?.text == "あした")
    }

    @Test func stopPreservesMixedRawAndFocusEpochRejectsLateEffects() throws {
        let epoch = UUID(), focus = UUID()
        let host = session(epoch: epoch)
        _ = try host.handle(.init(serverEpoch: epoch, focusID: focus, operationID: 1, startsFocus: true, action: .key(key("asita"))))
        #expect(try host.handle(.init(serverEpoch: epoch, focusID: focus, operationID: 2, action: .stop)).autoMixed?.raw == "asita")
        let result = try #require(host.handle(.init(serverEpoch: epoch, focusID: focus, operationID: 3, action: .commit)).autoMixed)
        var ledger = AutoMixedClientLedger()
        ledger.activate(capability: .init(serverEpoch: epoch))
        #expect(ledger.takeCommits(result).isEmpty)
        let acceptsOldFocus = ledger.acceptSnapshot(result)
        #expect(!acceptsOldFocus)
        #expect(try host.handle(.init(serverEpoch: UUID(), focusID: focus, operationID: 4, action: .commit)).autoMixed?.status == .restartRequired)
        #expect(try host.handle(.init(serverEpoch: epoch, focusID: UUID(), operationID: 4, action: .commit)).autoMixed?.status == .staleRequest)
        _ = try host.handle(.init(serverEpoch: epoch, focusID: focus, operationID: 5, action: .deactivate))
        #expect(try host.handle(.init(serverEpoch: epoch, focusID: focus, operationID: 6, action: .key(key("x")))).autoMixed?.status == .staleRequest)
    }

    @Test func boundedPendingCommitsAndInputLimitPreserveText() throws {
        let epoch = UUID(), focus = UUID()
        let host = session(epoch: epoch)
        var id: UInt64 = 0
        func send(_ action: AutoMixedAction) throws -> ConverterServerResponse {
            id += 1
            return try host.handle(.init(serverEpoch: epoch, focusID: focus, operationID: id, startsFocus: id == 1, action: action))
        }
        for _ in 0..<AutoMixedServerSession.maximumPendingCommits {
            _ = try send(.key(key("a")))
            _ = try send(.commit)
        }
        _ = try send(.key(key("keep")))
        let blocked = try send(.commit)
        #expect(blocked.autoMixed?.status == .awaitingAcknowledgement)
        #expect(blocked.autoMixed?.raw == "keep")
        #expect(host.pendingCommitCount == 8)
        let commit = try #require(blocked.autoMixed?.commits.first)
        _ = try send(.commitApplied(commit.commitID))
        #expect(try send(.commit).autoMixed?.raw.isEmpty == true)
        let limit = String(repeating: "a", count: 256)
        _ = try send(.key(key(limit)))
        let overflow = try send(.key(key("b")))
        #expect(overflow.autoMixed?.status == .inputLimit)
        #expect(overflow.autoMixed?.raw == limit)
        #expect(try host.handle(.init(serverEpoch: epoch, focusID: focus, operationID: id + 1,
                                     inputStyle: .defaultAZIK, action: .commit)).autoMixed?.status == .unsupportedInputStyle)
    }

    @Test func routerAndRecoveryJournalPreserveConsumedInputWithoutInference() {
        #expect(AutoMixedKeyRouter.owns(key("\t", code: 48), composing: false, pending: false) == false)
        #expect(AutoMixedKeyRouter.owns(key("\t", code: 48), composing: true, pending: false))
        #expect(AutoMixedKeyRouter.owns(key("\u{7f}", code: 51), composing: false, pending: true))
        #expect(!AutoMixedKeyRouter.owns(key("a", flags: .command), composing: true, pending: true))
        var ledger = AutoMixedClientLedger()
        ledger.recordKey(key("asita👩‍💻"), operationID: 1)
        ledger.recordKey(key("\u{7f}", code: 51), operationID: 2)
        ledger.recordKey(key("\r", code: 36), operationID: 3)
        #expect(ledger.recoveryRaw() == "asita")
        #expect(ledger.immediateCommitText(displayed: "明日") == "asita")
        ledger.deactivate()
        #expect(ledger.recoveryRaw().isEmpty)
    }

    @Test func contextIsCapturedOnlyForNewInputAndClearedWhenBufferEmpties() throws {
        let epoch = UUID(), focus = UUID()
        var contexts: [String?] = []
        let host = AutoMixedServerSession(epoch: epoch) { context in
            contexts.append(context.leftSideContext)
            return MixedCompositionEngine(segmenter: Segmenter(), converter: Converter())
        }
        func send(_ id: UInt64, _ action: AutoMixedAction, _ context: String? = nil) throws -> ConverterServerResponse {
            try host.handle(.init(serverEpoch: epoch, focusID: focus, operationID: id, startsFocus: id == 1,
                context: .init(leftSideContext: context), action: action))
        }
        _ = try send(1, .stop)
        #expect(contexts.isEmpty)
        _ = try send(2, .key(key("asita")), "最初")
        let commit = try #require(send(3, .commit).autoMixed?.commits.first)
        _ = try send(4, .commitApplied(commit.commitID))
        #expect(contexts == ["最初"])
        _ = try send(5, .key(key("a")), "次")
        _ = try send(6, .key(key("\u{7f}", code: 51)))
        _ = try send(7, .key(key("b")), "削除後")
        #expect(contexts == ["最初", "次", "削除後"])
        host.close()
        #expect(host.pendingCommitCount == 0)
    }

    @Test func runtimeRequiresExplicitOptInChecksumAndNonFixtureModel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-runtime-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let converter = KanaKanjiConverter.withDefaultDictionary()
        #expect(AutoMixedExperiment.configuration(in: directory) == nil)
        #expect(throws: (any Error).self) {
            try AutoMixedRuntime(resources: directory, converter: converter, applicationDirectory: directory)
        }
        let fixture = try languageFixtureData()
        try fixture.write(to: directory.appendingPathComponent("auto-mixed-model.json"))
        func marker(enabled: Bool, hash: String) throws {
            try JSONSerialization.data(withJSONObject: ["enabled": enabled, "modelSHA256": hash])
                .write(to: directory.appendingPathComponent("auto-mixed-experiment.json"))
        }
        let hash = SHA256.hash(data: fixture).map { String(format: "%02x", $0) }.joined()
        try marker(enabled: false, hash: hash)
        #expect(AutoMixedExperiment.configuration(in: directory) == nil)
        try marker(enabled: true, hash: String(repeating: "0", count: 64))
        #expect(throws: EnglishLexiconError.invalidData) {
            try AutoMixedRuntime(resources: directory, converter: converter, applicationDirectory: directory)
        }
        try marker(enabled: true, hash: hash)
        #expect(throws: LanguageModelError.fixtureNotAllowed) {
            try AutoMixedRuntime(resources: directory, converter: converter, applicationDirectory: directory)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil))
    func trainedModelRunsThroughMixedWireSession() throws { try replayRealModel(useZenzai: false) }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil
                  && ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"] != nil))
    func realZenzaiRunsThroughMixedWireSession() throws { try replayRealModel(useZenzai: true) }

    private func replayRealModel(useZenzai: Bool) throws {
        let path = try #require(ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"])
        let model = try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let bridge = try ZenzaiSpanBridge(converter: .withDefaultDictionary(),
            applicationDirectory: .temporaryDirectory.appendingPathComponent("mixed-transport-\(UUID())"),
            useZenzai: useZenzai, resources: ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"].map(URL.init(fileURLWithPath:)),
            learningEnabled: false)
        defer { bridge.releaseAll() }
        let epoch = UUID(), focus = UUID()
        let host = AutoMixedServerSession(epoch: epoch) { context in
            try MixedCompositionEngine(segmenter: JapanesePreferredSegmenter(model: model, lexicon: .bundled(),
                policy: .bundled(), context: context.leftSideContext.map(CommittedLeftContext.available) ?? .unavailable, focus: focus),
                converter: MixedSessionConverter(bridge: bridge, sessionID: UUID(), allowJapaneseReadingFallback: true))
        }
        let raw = "asitahameetinggaarimasu"
        let response = try host.handle(.init(serverEpoch: epoch, focusID: focus, operationID: 1, startsFocus: true, action: .key(key(raw))))
        let decoded = try ConverterServerCodec.decodeResponse(from: ConverterServerCodec.encode(response))
        #expect(decoded.snapshot.markedText.elements.map(\.content).joined() == "明日はmeetingがあります")
        #expect(decoded.autoMixed?.raw == raw)
        let committed = try host.handle(.init(serverEpoch: epoch, focusID: focus, operationID: 2, action: .commit))
        #expect(committed.autoMixed?.commits.map(\.text) == ["明日はmeetingがあります"])
        #expect(bridge.activeChildCount == 0)
        #expect(host.pendingCommitCount == 1)
        if useZenzai { #expect(bridge.backend == .zenzaiReady) }
    }
}

extension AutoMixedTransportTests {
    @Test func characterTypeKeysPreviewAndCommitExactlyOnceThroughWire() throws {
        let epoch = UUID(), focus = UUID()
        let host = session(epoch: epoch)
        var operation: UInt64 = 0
        func send(_ event: KeyEventCore) throws -> ConverterServerResponse {
            operation += 1
            let request = AutoMixedRequest(serverEpoch: epoch, focusID: focus, operationID: operation,
                                           startsFocus: operation == 1, action: .key(event))
            return try host.handle(request)
        }
        _ = try send(key("main"))
        let option = try send(key("x", flags: .option))
        #expect(option.snapshot.markedText.elements.map(\.content).joined() == "マイn")
        #expect(option.autoMixed?.commits.isEmpty == true)
        let control = try send(key(":", flags: .control))
        #expect(control.snapshot.markedText.elements.map(\.content).joined() == "main")
        #expect(control.autoMixed?.raw == "main")
        #expect(control.autoMixed?.commits.isEmpty == true)
        #expect(control.inputState == .composing)
        let committed = try send(key("\r", code: 36))
        #expect(committed.autoMixed?.commits.map(\.text) == ["main"])
        #expect(committed.inputState == .none)
        let duplicate = try host.handle(.init(serverEpoch: epoch, focusID: focus, operationID: operation,
                                              action: .key(key("\r", code: 36))))
        #expect(duplicate.autoMixed?.commits == committed.autoMixed?.commits)
        var ledger = AutoMixedClientLedger()
        ledger.activate(capability: .init(serverEpoch: epoch))
        // Ledger needs its own focus; use a separate host to exercise pending preview recovery.
        let pendingHost = session(epoch: epoch)
        let typing = key("main")
        let transform = key("x", flags: .option)
        ledger.recordKey(typing, operationID: 1)
        let typed = try #require(pendingHost.handle(.init(serverEpoch: epoch, focusID: ledger.focusID,
            operationID: 1, startsFocus: true, action: .key(typing))).autoMixed)
        let acceptedTyped = ledger.acceptSnapshot(typed)
        #expect(acceptedTyped)
        ledger.recordKey(transform, operationID: 2)
        #expect(ledger.immediateCommitText(displayed: "main") == "マイn")
        #expect(ledger.recoveryRaw() == "main")
        let transformed = try #require(pendingHost.handle(.init(serverEpoch: epoch, focusID: ledger.focusID,
            operationID: 2, action: .key(transform))).autoMixed)
        let acceptedTransform = ledger.acceptSnapshot(transformed)
        #expect(acceptedTransform)
        ledger.recordKey(key("a"), operationID: 3)
        #expect(ledger.immediateCommitText(displayed: "マイn") == "マイナ")
        ledger.recordKey(key("\r", code: 36), operationID: 4)
        #expect(ledger.immediateCommitText(displayed: "マイn") == "マイナ")
    }
}

extension AutoMixedTransportTests {
    @Test func pendingDeletionOfWholePreviewDoesNotLockNextComposition() throws {
        let epoch = UUID()
        var ledger = AutoMixedClientLedger()
        ledger.activate(capability: .init(serverEpoch: epoch))
        let host = session(epoch: epoch)
        let events = [key("a"), key("c", flags: .option), key("\u{7f}", code: 51), key("b")]
        for (index, event) in events.enumerated() {
            let operation = UInt64(index + 1)
            ledger.recordKey(event, operationID: operation)
            let result = try #require(host.handle(.init(serverEpoch: epoch, focusID: ledger.focusID,
                operationID: operation, startsFocus: operation == 1, action: .key(event))).autoMixed)
            // Skip the intermediate empty snapshot to exercise delayed/out-of-order replies.
            if operation != 3 {
                if operation == 4 { #expect(ledger.immediateCommitText(displayed: "ａ") == "b") }
                let accepted = ledger.acceptSnapshot(result)
                #expect(accepted)
            }
        }
        ledger.recordKey(key("x"), operationID: 5)
        #expect(ledger.immediateCommitText(displayed: "b") == "bx")
    }
}
