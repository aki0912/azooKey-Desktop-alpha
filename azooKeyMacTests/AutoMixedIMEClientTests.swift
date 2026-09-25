import AppKit
import Core
import InputMethodKit
import XCTest
#if canImport(azooKeyMac)
@testable import azooKeyMac
#endif

@MainActor final class AutoMixedIMEClientTests: XCTestCase {
    final class Transport: AutoMixedCommandSending {
        var commands: [(ConverterSessionCommand, (ConverterServerResponse?) -> Void)] = []
        var timeouts: [TimeInterval?] = []
        var failRetirementSynchronously = false
        var retirements = 0
        func send(_ command: @escaping (String) -> ConverterSessionCommand, timeout: TimeInterval?,
                  completion: @escaping (ConverterServerResponse?) -> Void) {
            let resolved = command("test")
            commands.append((resolved, completion))
            timeouts.append(timeout)
            if case .autoMixed(let request) = resolved, case .deactivate = request.action {
                retirements += 1
                // Bound the test double so a regression reports recursion instead of crashing.
                if failRetirementSynchronously && retirements == 1 { completion(nil) }
            }
        }
    }
    final class Field: NSObject, IMKTextInput {
        var inserted: [String] = []
        func insertText(_ string: Any!, replacementRange: NSRange) { inserted.append(string as! String) }
        func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {}
        func selectedRange() -> NSRange { .init(location: 0, length: 0) }
        func markedRange() -> NSRange { .init(location: NSNotFound, length: 0) }
        func attributedSubstring(from range: NSRange) -> NSAttributedString! { nil }
        func length() -> Int { 0 }
        func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode,
                            inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { 0 }
        func attributes(forCharacterIndex index: Int, lineHeightRectangle: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! { [:] }
        func validAttributesForMarkedText() -> [Any]! { [] }
        func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {}
        func selectMode(_ modeIdentifier: String!) {}
        func supportsUnicode() -> Bool { true }
        func bundleIdentifier() -> String! { "test.field" }
        func windowLevel() -> CGWindowLevel { 0 }
        func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
        func uniqueClientIdentifierString() -> String! { "test.field" }
        func string(from range: NSRange, actualRange: UnsafeMutablePointer<NSRange>!) -> String! { nil }
        func firstRect(forCharacterRange range: NSRange, actualRange: UnsafeMutablePointer<NSRange>!) -> NSRect { .zero }
    }
    func key(_ text: String, code: UInt16 = 0) -> KeyEventCore {
        .init(modifierFlags: [], characters: text, charactersIgnoringModifiers: text, keyCode: code)
    }

    func testRetirementFailureCannotRecursivelyRecoverOrOverwriteNextComposition() throws {
        for keepMode in [false, true] {
            let server = Transport(), field = Field()
            var rendered: [ConverterServerResponse] = []
            let client = AutoMixedIMEClient(server: server, experimentEnabled: { true }) { rendered.append($0) }
            client.requestedPolicy = .automaticMixed
            client.activate(client: field, canEnable: { true })
            server.commands[0].1(.init(snapshot: .empty, autoMixedCapability: .init(serverEpoch: UUID())))
            _ = client.handle(key("asitan"), client: field, inputStyle: .defaultRomanToKana, context: { .init() })
            let pendingReply = server.commands[1].1
            server.failRetirementSynchronously = true
            XCTAssertTrue(client.finishImmediately(client: field, keepMode: keepMode))
            XCTAssertEqual(server.retirements, 1)
            XCTAssertEqual(field.inserted, ["asitan"])
            XCTAssertEqual(client.isActive, keepMode)
            XCTAssertEqual(rendered.count, 1)
            pendingReply(nil)
            XCTAssertEqual(field.inserted, ["asitan"])
            XCTAssertEqual(rendered.count, 1)
            if keepMode {
                _ = client.handle(key("next"), client: field, inputStyle: .defaultRomanToKana, context: { .init() })
                guard case .autoMixed(let request) = server.commands.last?.0 else { return XCTFail("Missing next input") }
                XCTAssertTrue(request.startsFocus)
                XCTAssertTrue(client.finishImmediately(client: field, keepMode: false))
                XCTAssertEqual(field.inserted, ["asitan", "next"])
            }
        }
    }

    func testSecondEscapePreventsRecoveryOnFocusLossOrConnectionFailure() {
        for losesFocus in [false, true] {
            let server = Transport(), field = Field()
            var rendered: [ConverterServerResponse] = []
            let client = AutoMixedIMEClient(server: server, experimentEnabled: { true }) { rendered.append($0) }
            client.requestedPolicy = .automaticMixed
            client.activate(client: field, canEnable: { true })
            server.commands[0].1(.init(snapshot: .empty, autoMixedCapability: .init(serverEpoch: UUID())))
            for event in [key("main👩‍💻"), key("\u{1b}", code: 53), key("\u{1b}", code: 53)] {
                XCTAssertEqual(client.handle(event, client: field, inputStyle: .defaultRomanToKana, context: { .init() }), true)
            }
            let replies = server.commands.dropFirst().map(\.1)
            if losesFocus {
                XCTAssertTrue(client.finishImmediately(client: field, keepMode: false))
            } else {
                replies.last?(nil)
            }
            XCTAssertTrue(field.inserted.isEmpty)
            XCTAssertTrue(rendered.last?.snapshot.isEmpty == true)
            for reply in replies { reply(nil) }
            XCTAssertTrue(field.inserted.isEmpty)
            XCTAssertEqual(rendered.count, 1)
        }
    }

    func testConnectionFailureRecoversOnceEvenWhenTeardownAlsoFails() {
        let server = Transport(), field = Field()
        let client = AutoMixedIMEClient(server: server, experimentEnabled: { true }, render: { _ in })
        client.requestedPolicy = .automaticMixed
        client.activate(client: field, canEnable: { true })
        server.commands[0].1(.init(snapshot: .empty, autoMixedCapability: .init(serverEpoch: UUID())))
        _ = client.handle(key("asita"), client: field, inputStyle: .defaultRomanToKana, context: { .init() })
        let reply = server.commands[1].1
        server.failRetirementSynchronously = true
        reply(nil)
        reply(nil)
        XCTAssertFalse(client.isActive)
        XCTAssertEqual(server.retirements, 1)
        XCTAssertEqual(field.inserted, ["asita"])
    }

    func testManualModeDoesNotNegotiateEvenWhenExperimentIsEnabled() {
        let server = Transport(), field = Field()
        let client = AutoMixedIMEClient(server: server, experimentEnabled: { true }, render: { _ in })
        client.activate(client: field, canEnable: { true })
        XCTAssertFalse(client.isActive)
        XCTAssertTrue(server.commands.isEmpty)
        XCTAssertNil(client.handle(key("a"), client: field, inputStyle: .defaultRomanToKana, context: { .init() }))
        XCTAssertNil(client.handle(key("かな", code: 104), client: field, inputStyle: .defaultRomanToKana, context: { .init() }))
    }

    func testKanaKeyKeepsAutomaticModeDuringNegotiationAndAfterCapability() {
        for negotiating in [true, false] {
            let server = Transport(), field = Field()
            let client = AutoMixedIMEClient(server: server, experimentEnabled: { true }, render: { _ in })
            client.requestedPolicy = .automaticMixed
            client.activate(client: field, canEnable: { true })
            if !negotiating {
                server.commands[0].1(.init(snapshot: .empty, autoMixedCapability: .init(serverEpoch: UUID())))
            }
            XCTAssertEqual(client.handle(key("かな", code: 104), client: field, inputStyle: .defaultRomanToKana,
                context: { XCTFail("A mode key must not read document context"); return .init() }), true)
            XCTAssertTrue(client.isActive)
            XCTAssertEqual(server.commands.count, 1, "Kana must neither cancel nor enter the raw buffer")
            XCTAssertTrue(field.inserted.isEmpty)
        }
    }

    func testFirstKeysWaitForCapabilityAndKeepTheirOrder() throws {
        let server = Transport(), field = Field()
        let client = AutoMixedIMEClient(server: server, experimentEnabled: { true }, render: { _ in })
        client.requestedPolicy = .automaticMixed
        client.activate(client: field, canEnable: { true })
        for text in ["a", "s", "i", "t", "a"] {
            XCTAssertEqual(client.handle(key(text), client: field, inputStyle: .defaultRomanToKana, context: { .init() }), true)
        }
        XCTAssertEqual(server.commands.count, 1)
        if case .composition(.snapshot) = server.commands[0].0 {} else { XCTFail("Must negotiate with an old command") }
        server.commands[0].1(.init(snapshot: .empty, autoMixedCapability: .init(serverEpoch: UUID())))
        XCTAssertEqual(server.commands.count, 6)
        let requests = server.commands.dropFirst().compactMap { command, _ -> AutoMixedRequest? in
            if case .autoMixed(let request) = command { return request }
            return nil
        }
        XCTAssertEqual(requests.map(\.operationID), [1, 2, 3, 4, 5])
        XCTAssertEqual(requests.map(\.startsFocus), [true, false, false, false, false])
        XCTAssertEqual(requests.compactMap { if case .key(let key) = $0.action { key.characters } else { nil } }, ["a", "s", "i", "t", "a"])
        XCTAssertTrue(server.timeouts.allSatisfy { $0 == 5 })
        XCTAssertTrue(field.inserted.isEmpty)
    }

    func testOldServerRecoversBufferedRawExactlyOnce() {
        let server = Transport(), field = Field()
        let client = AutoMixedIMEClient(server: server, experimentEnabled: { true }, render: { _ in })
        client.requestedPolicy = .automaticMixed
        client.activate(client: field, canEnable: { true })
        _ = client.handle(key("asita👩‍💻"), client: field, inputStyle: .defaultRomanToKana, context: { .init() })
        _ = client.handle(key("\u{7f}", code: 51), client: field, inputStyle: .defaultRomanToKana, context: { .init() })
        let reply = server.commands[0].1
        reply(.init(snapshot: .empty))
        reply(.init(snapshot: .empty))
        XCTAssertEqual(field.inserted, ["asita"])
        XCTAssertFalse(client.isActive)
    }

    func testOSCommitDuringNegotiationRetiresOldReplyAndKeepsOriginalField() {
        let server = Transport(), original = Field(), next = Field()
        let client = AutoMixedIMEClient(server: server, experimentEnabled: { true }, render: { _ in })
        client.requestedPolicy = .automaticMixed
        client.activate(client: original, canEnable: { true })
        _ = client.handle(key("asitan"), client: original, inputStyle: .defaultRomanToKana, context: { .init() })
        let reply = server.commands[0].1
        XCTAssertTrue(client.finishImmediately(client: original, keepMode: false))
        client.activate(client: next, canEnable: { true })
        reply(.init(snapshot: .empty, autoMixedCapability: .init(serverEpoch: UUID())))
        XCTAssertEqual(original.inserted, ["asitan"])
        XCTAssertTrue(next.inserted.isEmpty)
        XCTAssertEqual(server.commands.count, 2)
    }

    func testKanaKeyPreservesCompositionJapaneseCommitEnglishInputAndNextField() throws {
        struct Segmenter: LanguageSegmenter {
            func segment(_ raw: String) throws -> [MixedSpan] {
                raw.isEmpty ? [] : [try .init(sourceRange: ScalarRange(0, raw.unicodeScalars.count),
                                             kind: raw == "asita" ? .japaneseRoman : .raw)]
            }
        }
        final class Converter: JapaneseSpanConverting {
            func candidates(for raw: String, span: MixedSpan) -> [MixedCandidate] {
                [.init(token: "test-asita", text: "明日")]
            }
        }
        let epoch = UUID()
        let host = AutoMixedServerSession(epoch: epoch) { _ in
            MixedCompositionEngine(segmenter: Segmenter(), converter: Converter())
        }
        let transport = Transport()
        var displayed = ""
        let client = AutoMixedIMEClient(server: transport, experimentEnabled: { true }) {
            displayed = $0.snapshot.markedText.elements.map(\.content).joined()
        }
        var cursor = 0
        func flush() throws {
            while cursor < transport.commands.count {
                let (command, reply) = transport.commands[cursor]
                cursor += 1
                switch command {
                case .composition(.snapshot): reply(.init(snapshot: .empty, autoMixedCapability: .init(serverEpoch: epoch)))
                case .autoMixed(let request): reply(try host.handle(request))
                default: XCTFail("Automatic input must not be dispatched to the manual converter")
                }
            }
        }
        let codes: [Character: UInt16] = ["a": 0, "s": 1, "i": 34, "t": 17, "p": 35, "l": 37, "e": 14]
        for _ in 0..<2 {
            let field = Field()
            client.requestedPolicy = .automaticMixed
            client.activate(client: field, canEnable: { true })
            func pressKana() {
                let count = transport.commands.count
                XCTAssertEqual(client.handle(key("かな", code: 104), client: field,
                    inputStyle: .defaultRomanToKana, context: { XCTFail("Mode key must not read context"); return .init() }), true)
                XCTAssertEqual(transport.commands.count, count)
                XCTAssertTrue(client.isActive)
            }
            pressKana() // capability negotiation
            try flush()
            pressKana() // empty automatic composition
            func type(_ text: String) throws {
                for character in text {
                    XCTAssertEqual(client.handle(key(String(character), code: codes[character]!), client: field,
                        inputStyle: .defaultRomanToKana, context: { .init(leftSideContext: field.inserted.joined()) }), true)
                    pressKana() // conversion response is still pending
                    try flush()
                }
            }
            try type("asita")
            pressKana() // displayed Japanese must remain uncommitted
            XCTAssertTrue(field.inserted.isEmpty)
            XCTAssertEqual(displayed, "明日")
            XCTAssertEqual(client.handle(key("\r", code: 36), client: field, inputStyle: .defaultRomanToKana,
                                         context: { .init() }), true)
            try flush()
            XCTAssertEqual(field.inserted, ["明日"])
            XCTAssertTrue(client.isActive)
            pressKana() // exact user reproduction: Japanese commit followed by English
            try type("apple")
            XCTAssertEqual(displayed, "apple")
            XCTAssertTrue(client.finishImmediately(client: field, keepMode: true))
            try flush()
            XCTAssertEqual(field.inserted, ["明日", "apple"])
            XCTAssertTrue(client.isActive)
            client.deactivate()
            try flush()
        }
    }

    func testRomanKeyAndUnsupportedStyleStillLeaveAutomaticAndRecoverPendingRaw() {
        let cases: [(KeyEventCore, ConverterInputStyle)] = [
            (key("英数", code: 102), .defaultRomanToKana),
            (key("かな", code: 104), .defaultKanaJIS)]
        for negotiating in [true, false] {
            for (event, style) in cases {
                let server = Transport(), field = Field()
                let client = AutoMixedIMEClient(server: server, experimentEnabled: { true }, render: { _ in })
                client.requestedPolicy = .automaticMixed
                client.activate(client: field, canEnable: { true })
                if !negotiating {
                    server.commands[0].1(.init(snapshot: .empty, autoMixedCapability: .init(serverEpoch: UUID())))
                }
                XCTAssertEqual(client.handle(key("asitan"), client: field, inputStyle: .defaultRomanToKana, context: { .init() }), true)
                XCTAssertNil(client.handle(event, client: field, inputStyle: style, context: { .init() }))
                XCTAssertFalse(client.isActive)
                XCTAssertEqual(field.inserted, ["asitan"])
                if negotiating {
                    server.commands[0].1(.init(snapshot: .empty, autoMixedCapability: .init(serverEpoch: UUID())))
                    XCTAssertFalse(client.isActive)
                    XCTAssertEqual(field.inserted, ["asitan"])
                } else if case .autoMixed(let request) = server.commands.last?.0 {
                    if case .deactivate = request.action {} else { XCTFail("Must retire the automatic session") }
                } else { XCTFail("Missing deactivation") }
            }
        }
    }
}

extension AutoMixedIMEClientTests {
    func testCharacterTypeKeysDuringNegotiationCommitOnceAndIgnoreRetiredReplies() throws {
        struct Segmenter: LanguageSegmenter {
            func segment(_ raw: String) throws -> [MixedSpan] {
                raw.isEmpty ? [] : [try .init(sourceRange: ScalarRange(0, raw.unicodeScalars.count), kind: .raw)]
            }
        }
        final class Converter: JapaneseSpanConverting {
            func reading(for raw: String) -> String { CompositionCharacterType.hiragana.text(raw: raw) }
            func candidates(for raw: String, span: MixedSpan) -> [MixedCandidate] { [] }
        }
        let epoch = UUID()
        let matchingHost = AutoMixedServerSession(epoch: epoch) { _ in
            MixedCompositionEngine(segmenter: Segmenter(), converter: Converter())
        }
        let transport = Transport(), field = Field()
        var displayed = ""
        let client = AutoMixedIMEClient(server: transport, experimentEnabled: { true }) {
            displayed = $0.snapshot.markedText.elements.map(\.content).joined()
        }
        client.requestedPolicy = .automaticMixed
        client.activate(client: field, canEnable: { true })
        let optionX = KeyEventCore(modifierFlags: .option, characters: "≈", charactersIgnoringModifiers: "x", keyCode: 7)
        let controlColon = KeyEventCore(modifierFlags: [.control, .shift], characters: ":", charactersIgnoringModifiers: ":", keyCode: 41)
        func press(_ event: KeyEventCore) {
            XCTAssertEqual(client.handle(event, client: field, inputStyle: .defaultRomanToKana, context: { .init() }), true)
        }
        var cursor = 0
        func flush() throws {
            while cursor < transport.commands.count {
                let (command, reply) = transport.commands[cursor]
                cursor += 1
                switch command {
                case .composition(.snapshot): reply(.init(snapshot: .empty, autoMixedCapability: .init(serverEpoch: epoch)))
                case .autoMixed(let request): reply(try matchingHost.handle(request))
                default: XCTFail("Unexpected manual command")
                }
            }
        }
        press(key("main"))
        press(optionX)
        try flush()
        XCTAssertEqual(displayed, "マイn")
        XCTAssertTrue(field.inserted.isEmpty)
        press(controlColon)
        try flush()
        XCTAssertEqual(displayed, "main")
        XCTAssertTrue(field.inserted.isEmpty)
        press(key("\r", code: 36))
        try flush()
        XCTAssertEqual(field.inserted, ["main"])
        XCTAssertEqual(client.handle(key("\r", code: 36), client: field, inputStyle: .defaultRomanToKana, context: { .init() }), false)
        XCTAssertEqual(client.handle(optionX, client: field, inputStyle: .defaultRomanToKana, context: { .init() }), false)
        press(key("main"))
        try flush()
        press(optionX) // End focus before the transform reply arrives.
        guard case .autoMixed(let delayed) = transport.commands.last!.0 else { return XCTFail("Expected mixed key") }
        let reply = transport.commands.last!.1
        let lateResponse = try matchingHost.handle(delayed)
        XCTAssertTrue(client.finishImmediately(client: field, keepMode: false))
        XCTAssertEqual(field.inserted, ["main", "マイn"])
        reply(lateResponse)
        XCTAssertEqual(field.inserted, ["main", "マイn"])
    }
}
