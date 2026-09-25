import Foundation

/// An explicit presentation of the original composition, independent of language prediction.
public enum CompositionCharacterType: Sendable, Equatable, CaseIterable {
    case hiragana, katakana, halfWidthKatakana, fullWidthRoman, halfWidthRoman

    public var isRoman: Bool { self == .fullWidthRoman || self == .halfWidthRoman }

    public func text(raw: String, reading: @autoclosure () -> String) -> String {
        switch self {
        case .hiragana:
            reading().applyingTransform(.hiraganaToKatakana, reverse: true) ?? reading()
        case .katakana:
            reading().applyingTransform(.hiraganaToKatakana, reverse: false) ?? reading()
        case .halfWidthKatakana:
            Self.katakana.text(raw: raw, reading: reading()).applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? reading()
        case .fullWidthRoman:
            raw.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? raw
        case .halfWidthRoman:
            raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw
        }
    }
}
