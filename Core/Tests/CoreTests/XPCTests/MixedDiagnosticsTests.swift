@testable import Core
import Foundation
import Testing

@Suite struct MixedDiagnosticsTests {
    @Test func rawContextAndUnvalidatedSessionNamesCannotReachLogPayload() throws {
        let epoch = UUID(), focus = UUID()
        func payload(_ text: String) throws -> String {
            let request = AutoMixedRequest(serverEpoch: epoch, focusID: focus, operationID: 7,
                context: .init(leftSideContext: text, rightSideContext: text),
                action: .key(.init(modifierFlags: [], characters: text, charactersIgnoringModifiers: text, keyCode: 0)))
            let command = ConverterServerCommand.openSession(sessionID: text, command: .autoMixed(request))
            return try #require(MixedDiagnostics.encoded(.serverReceive, MixedDiagnostics.fields(for: command)))
        }
        let first = try payload("PRIVATE_RAW_AND_CONTEXT_1")
        let second = try payload("全く異なる確定文脈と入力")
        let a = try #require(JSONSerialization.jsonObject(with: Data(first.utf8)) as? NSDictionary)
        let b = try #require(JSONSerialization.jsonObject(with: Data(second.utf8)) as? NSDictionary)
        #expect(a == b)
        #expect(!first.contains("PRIVATE_RAW_AND_CONTEXT_1"))
        let fields = try #require(a["fields"] as? [String: Any])
        #expect(fields["session"] == nil)
        #expect(fields["kind"] as? String == "automatic")
        #expect(fields["action"] as? String == "insert")
        #expect(fields["operation"] as? Int == 7)
    }

    @Test func correlationIDsAndCommandKindsRemainUsableWithoutText() throws {
        let session = UUID()
        let command = ConverterServerCommand.session(sessionID: session.uuidString, command: .composition(.snapshot))
        let payload = try #require(MixedDiagnostics.encoded(.xpcSend, MixedDiagnostics.fields(for: command)))
        #expect(payload.contains(session.uuidString))
        #expect(payload.contains("probe"))
        #expect(MixedDiagnostics.kind(.key(.init(modifierFlags: [], characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 36))) == .enter)
        #expect(MixedDiagnostics.kind(.key(.init(modifierFlags: [], characters: "p", charactersIgnoringModifiers: "p", keyCode: 35))) == .insert)
        #expect(MixedDiagnostics.kind(.key(.init(modifierFlags: [], characters: "かな", charactersIgnoringModifiers: "かな", keyCode: 104))) == .kanaKey)
        #expect(MixedDiagnostics.kind(.key(.init(modifierFlags: [], characters: "", charactersIgnoringModifiers: "", keyCode: 102))) == .romanKey)
    }

    @Test func performancePayloadContainsOnlyNumericDurationsAndCounters() throws {
        let trace = MixedPerformance.Trace()
        MixedPerformance.$trace.withValue(trace) {
            MixedPerformance.measure(.roman) { MixedPerformance.count(.sessionCreated) }
        }
        let payload = try #require(MixedDiagnostics.encoded(.performance, MixedDiagnostics.performanceFields(trace.snapshot())))
        let object = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let fields = try #require(object["fields"] as? [String: Any])
        #expect(fields.values.allSatisfy { $0 is NSNumber })
        #expect(fields["sessionCreated"] as? Int == 1)
        #expect(fields["sessionReleased"] as? Int == 0)
        #expect(MixedPerformance.trace == nil)
    }

    @Test func unmarkedTestBundleDoesNotEnableDiagnostics() {
        #expect(!MixedDiagnostics.enabled)
    }
}
