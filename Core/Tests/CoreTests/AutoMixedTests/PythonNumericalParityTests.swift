@testable import Core
import Foundation
import Testing

@Suite struct PythonNumericalParityTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_PARITY_PATH"] != nil,
                   "Run sh Tools/test_auto_mixed_parity.sh to generate fresh Python reference results"))
    func freshPythonFeaturesScoresAndPaths() throws {
        let path = try #require(ProcessInfo.processInfo.environment["AUTO_MIXED_PARITY_PATH"])
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(reference.feature_spec_version == AnchoredCharacterFeatures.version)
        #expect(reference.scores.count >= 256)
        #expect(reference.decoders.count >= 256)
        let model = try LogisticLanguageModel(testFixture: languageFixtureData())
        for vector in reference.scores { try checkScore(vector, model: model) }
        for vector in reference.decoders {
            #expect(try ViterbiLanguageDecoder.decode(vector.probabilities, switchPenalty: vector.switch_penalty,
                                                       forced: vector.forced) == vector.path)
        }
    }
}

// Mirror the external Python fixture schema without renaming its fields.
// swiftlint:disable identifier_name
private struct Reference: Decodable {
    let feature_spec_version: String
    let scores: [ScoreVector]
    let decoders: [DecoderVector]
    struct DecoderVector: Decodable {
        let probabilities: [Double]
        let switch_penalty: Double
        let forced: [BinaryLanguageLabel?]
        let path: [BinaryLanguageLabel]
    }
}
// swiftlint:enable identifier_name
