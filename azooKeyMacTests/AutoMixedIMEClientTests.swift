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
        func send(_ command: @escaping (String) -> ConverterSessionCommand, timeout: TimeInterval?,
                  completion: @escaping (ConverterServerResponse?) -> Void) {
            commands.append((command("test"), completion))
            timeouts.append(timeout)
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

    func testManualModeDoesNotNegotiateEvenWhenExperimentIsEnabled() {
        let server = Transport(), field = Field()
        let client = AutoMixedIMEClient(server: server, experimentEnabled: { true }, render: { _ in })
        client.activate(client: field, canEnable: { true })
        XCTAssertFalse(client.isActive)
        XCTAssertTrue(server.commands.isEmpty)
        XCTAssertNil(client.handle(key("a"), client: field, inputStyle: .defaultRomanToKana, context: { .init() }))
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
}
