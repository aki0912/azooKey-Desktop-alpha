/// A verified replacement for one Japanese run after deleting its final reading unit.
/// This is edited input, not a reconstruction of the original keystroke history.
public struct JapaneseBackspaceEdit: Sendable {
    public let raw: String
    public let reading: String
    public init(raw: String, reading: String) { self.raw = raw; self.reading = reading }
}

/// Optional injection keeps the pure engine and legacy callers independent of a roman table.
public protocol JapaneseBackspaceEditing {
    func deletingLastUnit(in raw: String) -> JapaneseBackspaceEdit?
}
