import AppKit
import InputMethodKit
import Core

@MainActor protocol AutoMixedCommandSending {
    func send(_ command: @escaping (String) -> ConverterSessionCommand, timeout: TimeInterval?,
              completion: @escaping (ConverterServerResponse?) -> Void)
}
extension ConverterServerClient: AutoMixedCommandSending {}

/// IMK boundary for the opt-in bundle. The existing controller remains the manual path.
@MainActor final class AutoMixedIMEClient {
    private let server: any AutoMixedCommandSending
    private let experimentEnabled: () -> Bool
    private let render: (ConverterServerResponse) -> Void
    private let diagnosticID: UUID
    private var ledger = AutoMixedClientLedger()
    private var operationID: UInt64 = 0
    private var startsFocus = true
    private var active = false
    private var activation = UUID()
    private weak var origin: AnyObject?
    private var pending = 0
    private var lastMixed: AutoMixedResponse?
    private var lastDisplayed = ""
    private var negotiating = false
    private var bufferedKeys: [(KeyEventCore, ConverterTextContext)] = []
    var requestedPolicy: CompositionPolicy = .manual
    var isActive: Bool { active || negotiating }

    init(server: any AutoMixedCommandSending, experimentEnabled: @escaping () -> Bool = {
        guard let resources = Bundle.main.resourceURL else { return false }
        return AutoMixedExperiment.configuration(in: resources) != nil
    }, diagnosticID: UUID = UUID(), render: @escaping (ConverterServerResponse) -> Void) {
        self.server = server
        self.experimentEnabled = experimentEnabled
        self.render = render
        self.diagnosticID = diagnosticID
    }

    func activate(client: IMKTextInput, canEnable: @escaping () -> Bool) {
        ledger.deactivate()
        activation = UUID()
        let generation = activation
        origin = client as AnyObject
        active = false
        negotiating = false
        bufferedKeys = []
        pending = 0
        startsFocus = true
        lastMixed = nil
        lastDisplayed = ""
        let enabled = requestedPolicy == .automaticMixed && experimentEnabled()
        MixedDiagnostics.record(.capabilityStart, [.owner: .id(diagnosticID), .experiment: .flag(enabled),
            .allowed: .flag(requestedPolicy == .automaticMixed)])
        guard requestedPolicy == .automaticMixed, enabled else { return }
        negotiating = true
        // This command is understood by old servers; no new enum case before negotiation.
        server.send({ _ in .composition(.snapshot) }, timeout: 5) { [weak self] response in
            guard let self, self.activation == generation else { return }
            let raw = self.ledger.recoveryRaw()
            let keys = self.bufferedKeys
            self.bufferedKeys = []
            self.negotiating = false
            let allowed = canEnable()
            MixedDiagnostics.record(.capabilityReply, [.owner: .id(self.diagnosticID), .allowed: .flag(allowed),
                .success: .flag(response != nil), .capability: .flag(response?.autoMixedCapability != nil)])
            guard allowed else {
                self.recoverNegotiation(raw: raw)
                return
            }
            self.ledger.activate(capability: response?.autoMixedCapability)
            self.active = self.ledger.capability != nil
            if self.active {
                for (key, context) in keys { self.send(.key(key), context: context) }
            } else { self.recoverNegotiation(raw: raw) }
        }
    }

    private func recoverNegotiation(raw: String) {
        let client = origin as? IMKTextInput
        deactivate()
        if !raw.isEmpty { client?.insertText(raw, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        render(ConverterServerResponse(snapshot: .empty))
    }

    func handle(_ event: KeyEventCore, client: IMKTextInput, inputStyle: ConverterInputStyle,
                context: () -> ConverterTextContext) -> Bool? {
        guard isActive else { return nil }
        guard origin === (client as AnyObject) else {
            MixedDiagnostics.record(.clientMismatch, [.owner: .id(diagnosticID), .sameClient: .flag(false)])
            deactivate(); return nil
        }
        if event.keyCode == 102 || inputStyle != .defaultRomanToKana {
            MixedDiagnostics.record(.manualExit, [.owner: .id(diagnosticID),
                .reason: .token(event.keyCode == 102 ? .romanKey : .unsupportedInputStyle)])
            leaveForManual()
            return nil
        }
        // Kana reaffirms Japanese-priority automatic input. Sending it to the manual
        // converter would switch the controller to Japanese and bypass segmentation.
        if event.keyCode == 104 { return true }
        guard AutoMixedKeyRouter.owns(event, composing: !(lastMixed?.raw.isEmpty ?? true), pending: pending > 0 || !bufferedKeys.isEmpty) else { return false }
        if negotiating {
            bufferedKeys.append((event, context()))
            ledger.recordKey(event, operationID: operationID &+ UInt64(bufferedKeys.count))
            return true
        }
        send(.key(event), context: context())
        return true
    }

    /// IMK requests immediate completion. Do not wait for XPC across a focus change:
    /// commit the displayed snapshot, or the raw recovery journal if keys are in flight.
    @discardableResult func finishImmediately(client: IMKTextInput?, keepMode: Bool) -> Bool {
        guard isActive, let client, origin === (client as AnyObject) else { return false }
        let capability = ledger.capability
        let text = ledger.immediateCommitText(displayed: lastDisplayed)
        send(.deactivate)
        activation = UUID() // invalidate replies for the retired composition before insertion
        ledger.activate(capability: keepMode ? capability : nil)
        startsFocus = true
        pending = 0
        negotiating = false
        bufferedKeys = []
        lastMixed = nil
        lastDisplayed = ""
        active = keepMode && ledger.capability != nil
        if !text.isEmpty { client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        render(ConverterServerResponse(snapshot: .empty))
        if keepMode && capability == nil { activate(client: client, canEnable: { true }) }
        return true
    }
    func leaveForManual() {
        _ = finishImmediately(client: origin as? IMKTextInput, keepMode: false)
    }
    @discardableResult func stop() -> Bool {
        guard isActive else { return false }
        send(.stop)
        return true
    }
    @discardableResult func select(index: Int?, adopt: Bool) -> Bool {
        guard active, let mixed = lastMixed else { return false }
        if let index { send(.selectCandidate(index: index, revision: mixed.revision, adopt: adopt)) }
        else { send(.key(.init(modifierFlags: [], characters: "\r", charactersIgnoringModifiers: "\r", keyCode: 36))) }
        return true
    }

    func deactivate() {
        MixedDiagnostics.record(.clientDeactivate, [.owner: .id(diagnosticID), .active: .flag(isActive), .pending: .number(pending)])
        if ledger.capability != nil { send(.deactivate) }
        active = false
        negotiating = false
        bufferedKeys = []
        activation = UUID()
        origin = nil
        ledger.deactivate()
        lastMixed = nil
        lastDisplayed = ""
    }

    private func send(_ action: AutoMixedAction, context: ConverterTextContext = .init()) {
        guard let capability = ledger.capability else { return }
        operationID &+= 1
        let request = AutoMixedRequest(serverEpoch: capability.serverEpoch, focusID: ledger.focusID,
            operationID: operationID, startsFocus: startsFocus, context: context, action: action)
        startsFocus = false
        if case .key(let key) = action { ledger.recordKey(key, operationID: operationID) }
        pending += 1
        let generation = activation
        // A cold GGUF/Metal initialization can exceed the legacy one-second timeout.
        server.send({ _ in .autoMixed(request) }, timeout: 5) { [weak self] response in
            guard let self else { return }
            guard self.activation == generation, let client = self.origin as? IMKTextInput else {
                MixedDiagnostics.record(.staleReply, [.owner: .id(self.diagnosticID)])
                return
            }
            var diagnostic: [MixedDiagnostics.Field: MixedDiagnostics.Value] = [
                .owner: .id(self.diagnosticID), .operation: .number(Int(clamping: request.operationID)),
                .success: .flag(response != nil), .active: .flag(response?.autoMixed != nil)]
            if let mixed = response?.autoMixed {
                diagnostic[.accepted] = .flag(self.ledger.accepts(mixed))
                diagnostic[.status] = .status(mixed.status)
            }
            MixedDiagnostics.record(.clientReply, diagnostic)
            self.pending = max(0, self.pending - 1)
            guard let response, let mixed = response.autoMixed,
                  self.ledger.accepts(mixed), mixed.status != .restartRequired,
                  mixed.status != .unavailable, mixed.status != .unsupportedInputStyle else {
                // Recover in the original, still-active field once, then return to manual.
                let raw = self.ledger.recoveryRaw()
                self.deactivate()
                if !raw.isEmpty { client.insertText(raw, replacementRange: NSRange(location: NSNotFound, length: 0)) }
                self.render(ConverterServerResponse(snapshot: .empty))
                return
            }
            guard mixed.status != .staleRequest else { return }
            for effect in self.ledger.takeCommits(mixed) {
                client.insertText(effect.text, replacementRange: NSRange(location: NSNotFound, length: 0))
                self.send(.commitApplied(effect.commitID))
            }
            if self.ledger.acceptSnapshot(mixed) {
                self.lastMixed = mixed
                self.lastDisplayed = response.snapshot.markedText.elements.map(\.content).joined()
                self.render(response)
            }
            if mixed.status == .inputLimit || mixed.status == .awaitingAcknowledgement { NSSound.beep() }
        }
    }
}
