import Core
import Foundation
import Testing

@Suite struct RawCompositionBufferTests {
    @Test func editsRebuildOffsetsWithoutChangingEarlierSnapshotsOrCopies() throws {
        var buffer = RawCompositionBuffer("a👩‍💻e\u{301}")
        let snapshot = buffer.offsets
        var copy = buffer
        try buffer.deleteBackward()
        try copy.moveCursor(toScalar: 1)
        try copy.insert("漢")
        #expect(snapshot.text == "a👩‍💻e\u{301}")
        #expect(snapshot.graphemeBoundaries == [0, 1, 4, 6])
        #expect(buffer.offsets.text == "a👩‍💻")
        #expect(buffer.offsets.graphemeBoundaries == [0, 1, 4])
        #expect(copy.offsets.text == "a漢👩‍💻e\u{301}")
        #expect(copy.offsets.graphemeBoundaries == [0, 1, 2, 5, 7])
        #expect(try snapshot.slice(ScalarRange(4, 6)) == "e\u{301}")
        #expect(try buffer.offsets.slice(ScalarRange(1, 4)) == "👩‍💻")
    }

    @Test func unicodeOffsetsAndIndicesRoundTrip() throws {
        let map = TextOffsetMap("Aかな漢👩‍💻e\u{301}")
        #expect(map.scalarCount == 9)
        #expect(map.utf16Count == 11)
        #expect(map.graphemeBoundaries == [0, 1, 2, 3, 4, 7, 9])
        #expect(try map.slice(ScalarRange(4, 7)) == "👩‍💻")
        for scalar in 0...map.scalarCount {
            #expect(try map.scalarOffset(at: map.index(atScalar: scalar)) == scalar)
            #expect(try map.scalarOffset(atUTF16: map.utf16Offset(atScalar: scalar)) == scalar)
        }
        #expect(map.scalarOffset(atUTF16: 5) == nil)
        #expect(map.scalarOffset(atUTF16: 8) == nil)
        #expect(throws: AutoMixedError.invalidRange) { try map.index(atScalar: -1) }
        #expect(throws: AutoMixedError.invalidRange) { try map.slice(ScalarRange(0, 10)) }
    }

    @Test func deletesGraphemesWithoutNormalizingSource() throws {
        let original = "Hello  👩‍💻e\u{301}🇯🇵"
        var buffer = RawCompositionBuffer(original)
        #expect(Array(buffer.text.unicodeScalars) == Array(original.unicodeScalars))
        try buffer.deleteBackward()
        #expect(buffer.text == "Hello  👩‍💻e\u{301}")
        try buffer.deleteBackward()
        #expect(buffer.text == "Hello  👩‍💻")
        try buffer.deleteBackward()
        #expect(buffer.text == "Hello  ")
        try buffer.insert("API?q=1")
        #expect(buffer.text == "Hello  API?q=1")
    }

    @Test func centralEditsValidateBoundariesAtomically() throws {
        var buffer = RawCompositionBuffer("a👩‍💻e\u{301}Z")
        #expect(throws: AutoMixedError.notGraphemeBoundary) { try buffer.moveCursor(toScalar: 2) }
        #expect(throws: AutoMixedError.notGraphemeBoundary) { try buffer.replace(ScalarRange(1, 2), with: "x") }
        #expect(throws: AutoMixedError.invalidRange) { try buffer.replace(ScalarRange(0, 99), with: "x") }
        #expect(buffer.text == "a👩‍💻e\u{301}Z")
        #expect(buffer.cursorScalarOffset == 7)
        try buffer.moveCursor(toScalar: 4)
        try buffer.deleteBackward()
        #expect(buffer.text == "ae\u{301}Z")
        #expect(buffer.cursorScalarOffset == 1)
        try buffer.insert("XY")
        #expect(buffer.text == "aXYe\u{301}Z")
        try buffer.replace(ScalarRange(1, 5), with: "漢")
        #expect(buffer.text == "a漢Z")
        try buffer.moveCursor(toScalar: 0)
        #expect(try !buffer.deleteBackward())
    }

    @Test func insertingAcrossGraphemeBoundariesKeepsCaretValid() throws {
        var buffer = RawCompositionBuffer("👩💻")
        try buffer.moveCursor(toScalar: 1)
        try buffer.insert("\u{200D}")
        #expect(buffer.text == "👩‍💻")
        #expect(buffer.cursorScalarOffset == 3)
        try buffer.deleteBackward()
        #expect(buffer.isEmpty)

        try buffer.insert("e")
        try buffer.insert("\u{301}")
        #expect(Array(buffer.text.unicodeScalars).map(\.value) == [0x65, 0x301])
        #expect(buffer.cursorScalarOffset == 2)
        try buffer.deleteBackward()
        #expect(buffer.isEmpty)
    }

    @Test func invalidRangesCannotBeDecoded() throws {
        #expect(throws: AutoMixedError.invalidRange) { try ScalarRange(-1, 2) }
        #expect(throws: AutoMixedError.invalidRange) { try ScalarRange(2, 1) }
        #expect(throws: AutoMixedError.invalidRange) { try UTF16Range(location: Int.max, length: 1) }
        let decoder = JSONDecoder()
        #expect(throws: AutoMixedError.invalidRange) {
            try decoder.decode(ScalarRange.self, from: Data(#"{"lowerBound":3,"upperBound":1}"#.utf8))
        }
        #expect(throws: AutoMixedError.invalidRange) {
            try decoder.decode(UTF16Range.self, from: Data(#"{"location":-1,"length":1}"#.utf8))
        }
        let range = try ScalarRange(4, 7)
        #expect(try decoder.decode(ScalarRange.self, from: JSONEncoder().encode(range)) == range)
        let display = try UTF16Range(location: 3, length: 5)
        #expect(try decoder.decode(UTF16Range.self, from: JSONEncoder().encode(display)) == display)
    }
}
