import Foundation
import KanaKanjiConverterModule

extension CompositionCharacterType {
    var function: UserAction.Function {
        switch self {
        case .hiragana: .six
        case .katakana: .seven
        case .halfWidthKatakana: .eight
        case .fullWidthRoman: .nine
        case .halfWidthRoman: .ten
        }
    }

    /// Mixed input uses the same pinned roman table as manual input, including pending consonants.
    public func text(raw: String) -> String {
        if isRoman {
            return text(raw: raw, reading: raw)
        }
        var composition = ComposingText()
        let pieces = raw.map { character in
            InputPiece.key(intention: KeyMap.h2zMap(character), input: character, modifiers: [])
        }
        composition.insertAtCursorPosition(pieces.map { .init(piece: $0, inputStyle: .roman2kana) })
        return text(raw: raw, reading: composition.convertTarget)
    }
}

/// Only character-type shortcuts are resolved here; mode switches and app shortcuts are separate.
public enum CharacterTypeShortcut {
    private static let optionKeys: [String: CompositionCharacterType] = [
        "z": .hiragana, "x": .katakana, "a": .halfWidthRoman, "s": .halfWidthRoman, "c": .fullWidthRoman
    ]
    private static let controlKeys: [String: CompositionCharacterType] = [
        "j": .hiragana, "k": .katakana, "l": .fullWidthRoman,
        ";": .halfWidthRoman, ":": .halfWidthRoman, "'": .halfWidthRoman
    ]
    private static let functionKeys: [UInt16: CompositionCharacterType] = [
        97: .hiragana, 98: .katakana, 100: .halfWidthKatakana, 101: .fullWidthRoman, 109: .halfWidthRoman
    ]

    public static func resolve(_ event: KeyEventCore) -> CompositionCharacterType? {
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch event.modifierFlags {
        case [.option]: return key.flatMap { optionKeys[$0] }
        case [.control]: return key.flatMap { controlKeys[$0] }
        case [.control, .shift]:
            // On ANSI layouts ':' requires Shift. Other Shift shortcuts remain untouched.
            return key == ":" ? .halfWidthRoman : nil
        case []: return functionKeys[event.keyCode]
        default: return nil
        }
    }
}

public extension UserAction.Function {
    var characterType: CompositionCharacterType {
        switch self {
        case .six: .hiragana
        case .seven: .katakana
        case .eight: .halfWidthKatakana
        case .nine: .fullWidthRoman
        case .ten: .halfWidthRoman
        }
    }
}
