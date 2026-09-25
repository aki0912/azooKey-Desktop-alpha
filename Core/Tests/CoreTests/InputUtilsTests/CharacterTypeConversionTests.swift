import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@Suite @MainActor struct CharacterTypeConversionTests {
    func key(_ logical: String, _ flags: KeyEventCore.ModifierFlag = [], code: UInt16 = 0, characters: String? = nil) -> KeyEventCore {
        .init(modifierFlags: flags, characters: characters ?? logical, charactersIgnoringModifiers: logical, keyCode: code)
    }

    func action(_ event: KeyEventCore, state: InputState = .composing,
                type: CompositionCharacterType? = nil, live: Bool = true,
                language: InputLanguage = .japanese) -> (ClientAction, ClientActionCallback) {
        state.event(eventCore: event, userAction: UserAction.getUserAction(eventCore: event, inputLanguage: language),
                    inputLanguage: language, liveConversionEnabled: live, enableDebugWindow: false,
                    enableSuggestion: false, characterType: type)
    }

    func manager() -> SegmentsManager {
        SegmentsManager(kanaKanjiConverter: .withDefaultDictionary(),
                        applicationDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
                        containerURL: nil, context: .init(useZenzai: false, learningEnabled: false))
    }

    func display(_ manager: SegmentsManager) -> String {
        manager.getCurrentMarkedText(inputState: .composing).map(\.content).joined()
    }

    @Test func shortcutsUseBothFamiliesAndFunctionKeysWithoutCommitting() {
        let cases: [(KeyEventCore, CompositionCharacterType)] = [
            (key("z", .option, characters: "Ω"), .hiragana), (key("j", .control), .hiragana),
            (key("x", .option, characters: "≈"), .katakana), (key("k", .control), .katakana),
            (key("a", .option, characters: "å"), .halfWidthRoman), (key("s", .option, characters: "ß"), .halfWidthRoman),
            (key(";", .control), .halfWidthRoman), (key(":", .control), .halfWidthRoman),
            (key(":", [.control, .shift]), .halfWidthRoman), (key("'", .control), .halfWidthRoman),
            (key("c", .option, characters: "ç"), .fullWidthRoman), (key("l", .control), .fullWidthRoman),
            (key("", code: 97), .hiragana), (key("", code: 98), .katakana),
            (key("", code: 100), .halfWidthKatakana), (key("", code: 101), .fullWidthRoman), (key("", code: 109), .halfWidthRoman)
        ]
        for (event, expected) in cases {
            #expect(CharacterTypeShortcut.resolve(event) == expected)
            for state: InputState in [.composing, .previewing, .selecting] {
                let (result, callback) = action(event, state: state)
                guard case .previewCharacterType(let type) = result,
                      case .transition(.composing) = callback else {
                    Issue.record("Shortcut must preview the whole composition: \(event)"); continue
                }
                #expect(type == expected)
            }
            guard case .characterType(let mixedType) = AutoMixedKeyRouter.input(event) else {
                Issue.record("Missing mixed shortcut: \(event)"); continue
            }
            #expect(mixedType == expected)
            #expect(!AutoMixedKeyRouter.owns(event, composing: false, pending: false))
            #expect(AutoMixedKeyRouter.owns(event, composing: false, pending: true))
        }
    }

    @Test func unrelatedModifiersAndEmptyInputKeepExistingBehavior() {
        for event in [key("a", [.command, .option]), key("z", [.option, .shift]),
                      key("j", [.control, .shift]), key("s", .control), key("u", [.control, .shift])] {
            #expect(CharacterTypeShortcut.resolve(event) == nil)
        }
        if case .previewCharacterType = action(key("a", .option), state: .none).0 {
            Issue.record("Empty input must not start a character-type preview")
        }
        if case .previewCharacterType = action(key("a", .option), language: .english).0 {
            Issue.record("English Option input must keep its existing meaning")
        }
        guard case .fallthrough = action(key("a", [.command, .option])).0 else {
            Issue.record("Command shortcuts must reach the host"); return
        }
    }

    @Test func originalKeysSurviveTypeSwitchingAndRomanBackspace() {
        let manager = manager()
        manager.insertAtCursorPosition("main", inputStyle: .roman2kana)
        manager.previewCharacterType(.katakana)
        #expect(display(manager) == "マイn")
        manager.previewCharacterType(.halfWidthRoman)
        #expect(display(manager) == "main")
        manager.previewCharacterType(.halfWidthRoman)
        #expect(display(manager) == "main")
        manager.insertAtCursorPosition("shi", inputStyle: .roman2kana)
        #expect(display(manager) == "mainshi")
        manager.deleteBackwardFromCursorPosition()
        #expect(display(manager) == "mainsh")
        manager.previewCharacterType(.fullWidthRoman)
        #expect(display(manager) == "ｍａｉｎｓｈ")
        #expect(manager.commitMarkedText(inputState: .composing) == "ｍａｉｎｓｈ")
        #expect(manager.characterType == nil && manager.isEmpty)
        #expect(manager.commitMarkedText(inputState: .none).isEmpty)
        manager.insertAtCursorPosition("asita", inputStyle: .roman2kana)
        #expect(manager.characterType == nil)
    }

    @Test func wholeCompositionReplacesEditedSegmentSelectionAndPreservesUnicode() {
        let manager = manager()
        manager.insertAtCursorPosition("asitamain", inputStyle: .roman2kana)
        manager.editSegment(count: -1)
        manager.previewCharacterType(.halfWidthRoman)
        #expect(display(manager) == "asitamain")
        manager.insertAtCursorPosition("API👩‍💻", inputStyle: .roman2kana)
        #expect(display(manager) == "asitamainAPI👩‍💻")
        let marked = manager.getCurrentMarkedText(inputState: .composing)
        #expect(marked.selectionRange.location == "asitamainAPI👩‍💻".utf16.count)
        manager.deleteBackwardFromCursorPosition()
        #expect(display(manager) == "asitamainAPI")
        #expect(manager.requestPredictionCandidates().isEmpty)
        #expect(manager.requestTypoCorrectionPredictionCandidates().isEmpty)
        if case .hidden = manager.getCurrentCandidateWindow(inputState: .selecting) {} else {
            Issue.record("A whole-composition preview must hide candidates")
        }
        manager.deactivate(flushLearningData: false)
        #expect(manager.characterType == nil)
    }

    @Test func enterEscapeAndSpaceHonorPreviewForBothLiveConversionSettings() {
        for live in [false, true] {
            let manager = manager()
            manager.insertAtCursorPosition("main", inputStyle: .roman2kana)
            manager.previewCharacterType(.halfWidthRoman)
            guard case .commitMarkedText = action(key("\r", code: 36), type: manager.characterType, live: live).0 else {
                Issue.record("Enter must commit the preview"); continue
            }
            guard case .clearCharacterType = action(key("\u{1b}", code: 53), type: manager.characterType, live: live).0 else {
                Issue.record("Escape must clear the preview without deleting input"); continue
            }
            manager.clearCharacterType()
            #expect(!manager.isEmpty && manager.characterType == nil)
            guard case .stopComposition = action(key("\u{1b}", code: 53), live: live).0 else {
                Issue.record("The second Escape must remove the complete composition"); continue
            }
            manager.stopComposition()
            #expect(manager.isEmpty)
            manager.insertAtCursorPosition("main", inputStyle: .roman2kana)
            manager.previewCharacterType(.halfWidthRoman)
            let (space, callback) = action(key(" ", code: 49), type: manager.characterType, live: live)
            if live {
                guard case .enterCandidateSelectionMode = space, case .transition(.selecting) = callback else {
                    Issue.record("Live Space must reopen candidates"); continue
                }
            } else {
                guard case .enterFirstCandidatePreviewMode = space, case .transition(.previewing) = callback else {
                    Issue.record("Space must return to normal conversion"); continue
                }
            }
            manager.insertCompositionSeparator(inputStyle: .roman2kana)
            #expect(manager.characterType == nil)
        }
    }

    @Test func emptyingPreviewClearsItsTypeAndReadingUsesPinnedTable() {
        let manager = manager()
        manager.insertAtCursorPosition("shi", inputStyle: .roman2kana)
        manager.previewCharacterType(.halfWidthRoman)
        manager.deleteBackwardFromCursorPosition(count: 3)
        #expect(manager.isEmpty && manager.characterType == nil)
        #expect(CompositionCharacterType.hiragana.text(raw: "main") == "まいn")
        #expect(CompositionCharacterType.katakana.text(raw: "gakkou") == "ガッコウ")
        #expect(CompositionCharacterType.halfWidthKatakana.text(raw: "gakkou") == "ｶﾞｯｺｳ")
        #expect(CompositionCharacterType.halfWidthRoman.text(raw: "Main_API?! 👩‍💻") == "Main_API?! 👩‍💻")
    }
}
