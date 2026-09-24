import Foundation

// Compile with the real Core detector source. No IME, XPC, context, or input-history access.
do {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard data.count <= 4_194_304 else { throw CocoaError(.fileReadTooLarge) }
    let inputs = try JSONDecoder().decode([String].self, from: data)
    guard inputs.count <= 10_000,
          inputs.allSatisfy({ $0.unicodeScalars.count <= 256 }) else {
        throw CocoaError(.coderInvalidValue)
    }
    let masks = inputs.map { raw in
        ProtectedSpanDetector.detect(raw).scalars.map { policy in
            switch policy {
            case .inferred: "inferred"
            case .raw: "raw"
            case .literal: "literal"
            case .gap: "gap"
            }
        }
    }
    FileHandle.standardOutput.write(try JSONEncoder().encode(masks))
} catch {
    FileHandle.standardError.write(Data("Protection input validation failed\n".utf8))
    exit(1)
}
