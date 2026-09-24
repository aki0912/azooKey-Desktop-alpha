import Core
import XCTest

@MainActor
final class ThinClientInputPipelineTests: XCTestCase {
    func testMixedInputOwnsTabAndSpaceButNotCommandShortcuts() {
        let tab = KeyEventCore(modifierFlags: [], characters: "\t", charactersIgnoringModifiers: "\t", keyCode: 48)
        XCTAssertFalse(AutoMixedKeyRouter.owns(tab, composing: false, pending: false))
        XCTAssertTrue(AutoMixedKeyRouter.owns(tab, composing: true, pending: false))
        let space = KeyEventCore(modifierFlags: [], characters: " ", charactersIgnoringModifiers: " ", keyCode: 49)
        XCTAssertTrue(AutoMixedKeyRouter.owns(space, composing: false, pending: false))
        let copy = KeyEventCore(modifierFlags: [.command], characters: "c", charactersIgnoringModifiers: "c", keyCode: 8)
        XCTAssertFalse(AutoMixedKeyRouter.owns(copy, composing: true, pending: true))
    }

    func testImmediateOSCommitRetiresFocusAndPreservesUnansweredKeys() {
        var ledger = AutoMixedClientLedger()
        ledger.activate(capability: .init(serverEpoch: UUID()))
        let originalFocus = ledger.focusID
        XCTAssertEqual(ledger.immediateCommitText(displayed: "明日"), "明日")
        ledger.recordKey(.init(modifierFlags: [], characters: "asita", charactersIgnoringModifiers: "asita", keyCode: 0), operationID: 1)
        ledger.recordKey(.init(modifierFlags: [], characters: "n", charactersIgnoringModifiers: "n", keyCode: 45), operationID: 2)
        XCTAssertEqual(ledger.immediateCommitText(displayed: ""), "asitan")
        ledger.deactivate()
        XCTAssertNotEqual(ledger.focusID, originalFocus)
        XCTAssertEqual(ledger.recoveryRaw(), "")
    }

    func testDelayedServerReplyKeepsFollowingInputOwnedAndOrdered() async {
        let printable = KeyEventCore(
            modifierFlags: [],
            characters: "a",
            charactersIgnoringModifiers: "a",
            keyCode: 0
        )
        XCTAssertEqual(
            ConverterClientEventRouter.disposition(
                event: printable,
                context: .init(typeBackSlash: true)
            ),
            .sendToServer
        )

        let backspace = KeyEventCore(
            modifierFlags: [],
            characters: "\u{7f}",
            charactersIgnoringModifiers: "\u{7f}",
            keyCode: 51
        )
        XCTAssertEqual(
            ConverterClientEventRouter.disposition(
                event: backspace,
                context: .init(hasPendingKeyEvents: true, typeBackSlash: true)
            ),
            .sendToServer,
            "未応答中の状態mirrorを信じてbackspaceをapplicationへ漏らしてはいけない"
        )

        let queue = OrderedAsyncCommandQueue<Int>()
        var firstFinish: OrderedAsyncCommandQueue<Int>.Finish?
        var starts: [Int] = []
        var completions: [Int] = []
        let completed = expectation(description: "both key events completed")
        completed.expectedFulfillmentCount = 2

        queue.enqueue(
            operation: { finish in
                starts.append(1)
                firstFinish = finish
            },
            completion: { value in
                completions.append(value)
                completed.fulfill()
            }
        )
        queue.enqueue(
            operation: { finish in
                starts.append(2)
                finish(.finish(2))
            },
            completion: { value in
                completions.append(value)
                completed.fulfill()
            }
        )

        XCTAssertEqual(starts, [1], "2件目は1件目の遅延応答より先にServerへ送ってはいけない")
        firstFinish?(.finish(1))
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(starts, [1, 2])
        XCTAssertEqual(completions, [1, 2])
    }

    func testCommandShortcutFallsThroughEvenWhileServerReplyIsPending() {
        let commandA = KeyEventCore(
            modifierFlags: [.command],
            characters: "a",
            charactersIgnoringModifiers: "a",
            keyCode: 0
        )
        XCTAssertEqual(
            ConverterClientEventRouter.disposition(
                event: commandA,
                context: .init(
                    acknowledgedInputState: .composing,
                    hasPendingKeyEvents: true,
                    typeBackSlash: true
                )
            ),
            .fallthroughToApplication
        )
    }
}
