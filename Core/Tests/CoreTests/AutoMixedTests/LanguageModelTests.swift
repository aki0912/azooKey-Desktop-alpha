@testable import Core
import Foundation
import Testing

func autoMixedRepositoryFile(_ relativePath: String) throws -> URL {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while directory.path != "/" {
        let file = directory.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: file.path) {
            return file
        }
        directory.deleteLastPathComponent()
    }
    throw CocoaError(.fileReadNoSuchFile)
}

func languageFixtureData() throws -> Data {
    try Data(contentsOf: autoMixedRepositoryFile("docs/auto-mixed-old/fixtures/language_model_fixture.json"))
}

/// Test-only JSON mutations, never an exported or trained production model.
func syntheticModelData(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
    var object = try #require(JSONSerialization.jsonObject(with: languageFixtureData()) as? [String: Any])
    object["kind"] = "production"
    change(&object)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

// Mirror the external Python fixture schema without renaming its fields.
// swiftlint:disable identifier_name
struct ScoreVector: Decodable {
    let raw: String
    let index: Int
    let features: [String]
    let active_indices: [Int]
    let logit: Double
    let p_ja: Double
}
// swiftlint:enable identifier_name

func checkScore(_ vector: ScoreVector, model: LogisticLanguageModel) throws {
    let features = AnchoredCharacterFeatures(vector.raw)
    #expect(try features.keys(at: vector.index) == vector.features)
    let score = try model.score(features, at: vector.index)
    #expect(score.activeIndices == vector.active_indices)
    #expect(abs(score.logit - vector.logit) < 1e-12)
    #expect(abs(score.japaneseProbability - vector.p_ja) < 1e-12)
}

@Suite struct LanguageModelTests {
    @Test func all128GoldenFeaturesAndScores() throws {
        struct Golden: Decodable { let vectors: [ScoreVector] }
        let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf:
            autoMixedRepositoryFile("docs/auto-mixed-old/fixtures/feature_golden.json")))
        #expect(golden.vectors.count == 128)
        let model = try LogisticLanguageModel(testFixture: languageFixtureData())
        for vector in golden.vectors { try checkScore(vector, model: model) }
    }

    @Test func canonicalEscapesShapesAndPrefixContext() throws {
        let text = "A/\"\\\u{0}\u{8}\t\n\u{c}\r\u{1f}\u{7f}é😀"
        let features = AnchoredCharacterFeatures(text)
        let expectedSymbols = ["a", "/", "\\\"", "\\\\", "\\u0000", "\\b", "\\t", "\\n", "\\f", "\\r", "\\u001f", "\\u007f", "\\u00e9", "\\ud83d\\ude00"]
        for (index, symbol) in expectedSymbols.enumerated() {
            let keys = try features.keys(at: index)
            #expect(keys.count == 61)
            #expect(keys.contains("[\"char\",0,[\"CHAR\",\"\(symbol)\"]]"))
        }
        let upper = try AnchoredCharacterFeatures("Swift").keys(at: 0)
        let lower = try AnchoredCharacterFeatures("swift").keys(at: 0)
        #expect(upper.filter { !$0.hasPrefix("[\"shape\"") } == lower.filter { !$0.hasPrefix("[\"shape\"") })
        #expect(upper != lower)
        #expect(try AnchoredCharacterFeatures("BOS").keys(at: 0).contains("[\"char\",-1,[\"BOS\"]]"))
        #expect(try AnchoredCharacterFeatures("ky").keys(at: 1).contains("[\"char\",1,[\"EOS\"]]"))
        #expect(try !AnchoredCharacterFeatures("kyou").keys(at: 1).contains("[\"char\",1,[\"EOS\"]]"))
        #expect(throws: AutoMixedError.invalidRange) { try AnchoredCharacterFeatures("").keys(at: 0) }
        #expect(throws: AutoMixedError.invalidRange) { try features.keys(at: -1) }
        #expect(throws: AutoMixedError.invalidRange) { try features.keys(at: features.scalarCount) }
    }

    @Test func productionLoaderRejectsFixtureAndMalformedSchema() throws {
        #expect(throws: LanguageModelError.fixtureNotAllowed) { try LogisticLanguageModel(data: languageFixtureData()) }
        #expect(throws: (any Error).self) { try LogisticLanguageModel(data: Data()) }
        #expect(throws: LanguageModelError.oversizedModel) {
            try LogisticLanguageModel(data: Data(repeating: 32, count: LogisticLanguageModel.maximumByteCount + 1))
        }
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["schema_version"] = 2 }, { $0["feature_spec_version"] = "unknown" },
            { $0["kind"] = "unknown" }, { $0["positive_label"] = "RAW" },
            { $0["model_version"] = "" }, { $0.removeValue(forKey: "model_version") },
            { $0["training_manifest_sha256"] = "not-a-hash" },
            { $0["training_manifest_sha256"] = String(repeating: "A", count: 64) },
            { $0["unknown"] = 1 }, { $0["calibration"] = ["a": 1, "c": 0, "unknown": 1] },
            { $0["decoder"] = ["switch_penalty": 1, "unknown": 0] },
            { $0["thresholds"] = ["enter_ja": 1, "hold_ja": 0, "unknown": 0] },
            { $0["calibration"] = ["a": 1] }, { $0["intercept"] = true },
            { $0["coefficients"] = [true] }, { $0["decoder"] = ["switch_penalty": true] },
            { $0["schema_version"] = true }, { $0["calibration"] = ["a": "NaN", "c": 0] },
            { $0["intercept"] = "Infinity" }
        ]
        for mutate in mutations {
            let data = try syntheticModelData(mutate)
            #expect(throws: (any Error).self) { try LogisticLanguageModel(data: data) }
        }
        // JSONDecoder must also reject a numeric exponent that exceeds finite Double.
        let base = try #require(String(data: syntheticModelData(), encoding: .utf8))
        let overflowing = base.replacingOccurrences(of: "\"intercept\":-0.1875", with: "\"intercept\":1e999")
        #expect(overflowing != base)
        #expect(throws: (any Error).self) { try LogisticLanguageModel(data: Data(overflowing.utf8)) }
    }

    @Test func vocabularyOrderingAndNumericConstraintsAreValidated() throws {
        let mutations: [(inout [String: Any]) -> Void] = [
            {
                $0["vocabulary"] = ["a", "a"]
                $0["coefficients"] = [1, 2]
            },
            {
                $0["vocabulary"] = ["b", "a"]
                $0["coefficients"] = [1, 2]
            },
            { $0["coefficients"] = [] },
            {
                $0["vocabulary"] = (0..<32769).map { String(format: "%05d", $0) }
                $0["coefficients"] = Array(repeating: 1, count: 32769)
            },
            { $0["decoder"] = ["switch_penalty": -1] },
            { $0["thresholds"] = ["enter_ja": 0.6, "hold_ja": 0.9] },
            { $0["thresholds"] = ["enter_ja": 1.1, "hold_ja": 0.9] },
            { $0["thresholds"] = ["enter_ja": 0.9, "hold_ja": -0.1] }
        ]
        for mutate in mutations {
            #expect(throws: (any Error).self) { try LogisticLanguageModel(data: syntheticModelData(mutate)) }
        }
        // Python treats these as distinct, ordered UTF-8 strings; Swift String equality does not.
        let bytesModel = try LogisticLanguageModel(data: syntheticModelData {
            $0["vocabulary"] = ["e\u{301}", "é"]
            $0["coefficients"] = [1, 2]
        })
        #expect(try bytesModel.score(AnchoredCharacterFeatures("unknown"), at: 0).activeIndices.isEmpty)
    }

    @Test func positiveLabelCalibrationOOVAndStableSigmoid() throws {
        let model = try LogisticLanguageModel(data: syntheticModelData {
            $0["vocabulary"] = ["[\"char\",0,[\"CHAR\",\"a\"]]"]
            $0["coefficients"] = [2.0]
            $0["intercept"] = -1.0
            $0["calibration"] = ["a": 2.0, "c": 0.5]
        })
        let positive = try model.score(AnchoredCharacterFeatures("a"), at: 0)
        let negative = try model.score(AnchoredCharacterFeatures("z"), at: 0)
        #expect(positive.activeIndices == [0])
        #expect(negative.activeIndices.isEmpty)
        #expect(positive.logit == 1)
        #expect(negative.logit == -1)
        #expect(abs(positive.japaneseProbability - 1 / (1 + exp(-2.5))) < 1e-12)
        #expect(negative.japaneseProbability < 0.5)
        #expect(try LogisticLanguageModel.sigmoid(1000) == 1)
        #expect(try LogisticLanguageModel.sigmoid(-1000) == 0)
        #expect(try LogisticLanguageModel.sigmoid(0) == 0.5)
        for value in [Double.nan, .infinity, -.infinity] {
            #expect(throws: LanguageModelError.numericOverflow) { try LogisticLanguageModel.sigmoid(value) }
        }
        let overflowing = try LogisticLanguageModel(data: syntheticModelData {
            $0["intercept"] = Double.greatestFiniteMagnitude
            $0["calibration"] = ["a": 2, "c": 0]
        })
        #expect(throws: LanguageModelError.numericOverflow) { try overflowing.score(AnchoredCharacterFeatures("a"), at: 0) }
    }
}
