import AppKit
import InputMethodKit
import Core

/// IMK boundary for the opt-in bundle. The existing controller remains the manual path.
@MainActor final class AutoMixedIMEClient {
    private let server: ConverterServerClient
    private let render: (ConverterServerResponse) -> Void
    private var ledger = AutoMixedClientLedger()
    private var operationID: UInt64 = 0
    private var startsFocus = true
    private var active = false
    private var activation = UUID()
    private weak var origin: AnyObject?
    private var pending = 0
    private var lastMixed: AutoMixedResponse?
    private var lastDisplayed = ""
    private var manualInputStarted = false
    var requestedPolicy: CompositionPolicy = .automaticMixed
    var isActive: Bool { active }

    init(server: ConverterServerClient, render: @escaping (ConverterServerResponse) -> Void) {
        self.server = server
        self.render = render
    }

    func activate(client: IMKTextInput, canEnable: @escaping () -> Bool) {
        ledger.deactivate()
        activation = UUID()
        let generation = activation
        origin = client as AnyObject
        active = false
        pending = 0
        startsFocus = true
        lastMixed = nil
        lastDisplayed = ""
        manualInputStarted = false
        guard requestedPolicy == .automaticMixed, let resources = Bundle.main.resourceURL,
              AutoMixedExperiment.configuration(in: resources) != nil else { return }
        // This command is understood by old servers; no new enum case before negotiation.
        server.send({ _ in .composition(.snapshot) }) { [weak self] response in
            guard let self, self.activation == generation, !self.manualInputStarted, canEnable() else { return }
            self.ledger.activate(capability: response?.autoMixedCapability)
            self.active = self.ledger.capability != nil
        }
    }

    func handle(_ event: KeyEventCore, client: IMKTextInput, inputStyle: ConverterInputStyle,
                context: () -> ConverterTextContext) -> Bool? {
        guard active else {
            if AutoMixedKeyRouter.input(event) != nil { manualInputStarted = true }
            return nil
        }
        guard origin === (client as AnyObject) else { deactivate(); return nil }
        if event.keyCode == 102 || event.keyCode == 104 || inputStyle != .defaultRomanToKana {
            leaveForManual()
            return nil
        }
        guard AutoMixedKeyRouter.owns(event, composing: !(lastMixed?.raw.isEmpty ?? true), pending: pending > 0) else { return false }
        send(.key(event), context: context())
        return true
    }

    /// IMK requests immediate completion. Do not wait for XPC across a focus change:
    /// commit the displayed snapshot, or the raw recovery journal if keys are in flight.
    @discardableResult func finishImmediately(client: IMKTextInput?, keepMode: Bool) -> Bool {
        guard active, let client, origin === (client as AnyObject) else { return false }
        let capability = ledger.capability
        let text = ledger.immediateCommitText(displayed: lastDisplayed)
        send(.deactivate)
        activation = UUID() // invalidate replies for the retired composition before insertion
        ledger.activate(capability: keepMode ? capability : nil)
        startsFocus = true
        pending = 0
        lastMixed = nil
        lastDisplayed = ""
        active = keepMode && ledger.capability != nil
        if !text.isEmpty { client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        render(ConverterServerResponse(snapshot: .empty))
        return true
    }
    func leaveForManual() {
        _ = finishImmediately(client: origin as? IMKTextInput, keepMode: false)
    }
    @discardableResult func stop() -> Bool {
        guard active else { return false }
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
        if ledger.capability != nil { send(.deactivate) }
        active = false
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
        server.send({ _ in .autoMixed(request) }) { [weak self] response in
            guard let self, self.activation == generation, let client = self.origin as? IMKTextInput else { return }
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
