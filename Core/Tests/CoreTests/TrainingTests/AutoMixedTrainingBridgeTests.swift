@testable import Core
import Crypto
import Foundation
import KanaKanjiConverterModule
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Offline training validation only; never instantiated by the application or ConverterServer.
@Suite struct AutoMixedTrainingBridgeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_TRAINING_REQUEST"] != nil,
                   "Invoked by the offline dataset builder"))
    @MainActor func validateDatasetInputs() throws {
        let environment = ProcessInfo.processInfo.environment
        let input = try #require(environment["AUTO_MIXED_TRAINING_REQUEST"])
        let output = try #require(environment["AUTO_MIXED_TRAINING_RESPONSE"])
        let data = try Data(contentsOf: URL(fileURLWithPath: input))
        let request = try JSONDecoder().decode(Request.self, from: data)
        // The dependency's DEBUG conversion helpers print composition state. This offline-only
        // suite runs in a dedicated process; silence both descriptors before handling corpus data.
        let savedOutput = dup(STDOUT_FILENO)
        let savedError = dup(STDERR_FILENO)
        let null = open("/dev/null", O_WRONLY)
        guard savedOutput >= 0, savedError >= 0, null >= 0 else { throw ValidationError.outputRedirection }
        fflush(nil)
        defer {
            fflush(nil)
            dup2(savedOutput, STDOUT_FILENO)
            dup2(savedError, STDERR_FILENO)
            close(savedOutput)
            close(savedError)
            close(null)
        }
        guard dup2(null, STDOUT_FILENO) >= 0, dup2(null, STDERR_FILENO) >= 0 else { throw ValidationError.outputRedirection }
        var masks: [[String]] = []
        for row in request.rows {
            for pair in row.roman_pairs {
                var original = ComposingText()
                original.insertAtCursorPosition(pair.original, inputStyle: .roman2kana)
                var variant = ComposingText()
                variant.insertAtCursorPosition(pair.variant, inputStyle: .roman2kana)
                guard original.convertTarget == variant.convertTarget,
                      !original.convertTarget.isEmpty,
                      original.convertTarget.unicodeScalars.allSatisfy({ (0x3041...0x3096).contains($0.value) }) else {
                    // Do not put corpus text or expected/actual readings into failure logs.
                    throw ValidationError.romanMismatch
                }
            }
            masks.append(ProtectedSpanDetector.detect(row.raw).scalars.map {
                switch $0 {
                case .inferred: "inferred"
                case .raw: "raw"
                case .literal: "literal"
                case .gap: "gap"
                }
            })
        }
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let response = Response(request_sha256: checksum, protections: masks)
        try JSONEncoder().encode(response).write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
    }
}

private enum ValidationError: Error { case romanMismatch, outputRedirection }
private struct Request: Decodable {
    let rows: [Row]
    struct Row: Decodable {
        let raw: String
        let roman_pairs: [Pair]
    }
    struct Pair: Decodable {
        let original: String
        let variant: String
    }
}
private struct Response: Encodable {
    let request_sha256: String
    let protections: [[String]]
}
