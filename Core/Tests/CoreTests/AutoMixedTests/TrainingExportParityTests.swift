@testable import Core
import Foundation
import Testing

@Suite struct TrainingExportParityTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_TRAINING_EXPORTS"] != nil,
                   "Run the offline fixture training smoke to export v1 and v2 models"))
    func trainedFixtureExportsMatchPython() throws {
        try verifyExports(variable: "AUTO_MIXED_TRAINING_EXPORTS", fixture: true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_APPROVED_EXPORTS"] != nil,
                   "Explicitly validate calibrated approved exports without installing an IME"))
    func trainedApprovedExportsMatchPython() throws {
        try verifyExports(variable: "AUTO_MIXED_APPROVED_EXPORTS", fixture: false)
    }

    private func verifyExports(variable: String, fixture: Bool) throws {
        let paths = try #require(ProcessInfo.processInfo.environment[variable])
        var versions = Set<String>()
        for path in paths.split(separator: ":") {
            let directory = URL(fileURLWithPath: String(path))
            let data = try Data(contentsOf: directory.appendingPathComponent("model.json"))
            if fixture {
                // Keep the fixture rejection contract even when approved exports are tested too.
                #expect(throws: LanguageModelError.fixtureNotAllowed) { try LogisticLanguageModel(data: data) }
            }
            let model = try fixture ? LogisticLanguageModel(testFixture: data) : LogisticLanguageModel(data: data)
            let parity = try JSONDecoder().decode(ExportParity.self, from: Data(contentsOf: directory.appendingPathComponent("parity.json")))
            #expect(parity.feature_spec_version == model.featureSpecVersion)
            versions.insert(model.featureSpecVersion)
            #expect(parity.vectors.count == 128)
            for vector in parity.vectors {
                let actual: LanguageScore
                if model.featureSpecVersion == AnchoredCharacterFeatures.version {
                    let features = AnchoredCharacterFeatures(vector.raw)
                    #expect(try features.keys(at: vector.index) == vector.features)
                    actual = try model.score(features, at: vector.index)
                } else {
                    let context = vector.left_context.map(CommittedLeftContext.available) ?? .unavailable
                    let features = ContextualCharacterFeatures(vector.raw, leftContext: context)
                    #expect(try features.keys(at: vector.index) == vector.features)
                    actual = try model.score(features, at: vector.index)
                }
                #expect(actual.activeIndices == vector.active_indices)
                #expect(abs(actual.logit - vector.logit) < 1e-12)
                #expect(abs(actual.japaneseProbability - vector.p_ja) < 1e-12)
            }
            for vector in parity.decoders {
                #expect(try ViterbiLanguageDecoder.decode(vector.probabilities, switchPenalty: vector.switch_penalty) == vector.path)
            }
            if model.featureSpecVersion == ContextualCharacterFeatures.version {
                #expect(parity.segment_cases.count == 21)
                let segmenter = try ContextualLanguageSegmenter(model: model)
                for vector in parity.segment_cases {
                    let masks = ProtectedSpanDetector.detect(vector.raw).scalars.map { String(describing: $0) }
                    #expect(masks == vector.protections)
                    let input = LanguageJudgmentInput(raw: vector.raw,
                        leftCommittedContext: vector.left_context.map(CommittedLeftContext.available) ?? .unavailable,
                        focusIdentity: UUID(), revision: 0)
                    let spans = try segmenter.judge(input).hypotheses
                    let labels = spans.flatMap { span -> [String] in
                        let label: String
                        switch span.kind {
                        case .japaneseRoman: label = "JA_ROMAN"
                        case .raw: label = "RAW"
                        case .gap: label = "GAP"
                        case .literal: label = "LITERAL"
                        case .unresolved: label = "UNRESOLVED"
                        }
                        return Array(repeating: label, count: span.sourceRange.count)
                    }
                    #expect(labels == vector.labels)
                }
            }
        }
        #expect(versions == [AnchoredCharacterFeatures.version, ContextualCharacterFeatures.version])
    }
}

private struct ExportParity: Decodable {
    let feature_spec_version: String
    let vectors: [Vector]
    let decoders: [Decoder]
    let segment_cases: [SegmentCase]
    struct SegmentCase: Decodable {
        let raw: String
        let left_context: String?
        let protections: [String]
        let labels: [String]
    }
    struct Vector: Decodable {
        let raw: String
        let index: Int
        let left_context: String?
        let features: [String]
        let active_indices: [Int]
        let logit: Double
        let p_ja: Double
    }
    struct Decoder: Decodable {
        let probabilities: [Double]
        let switch_penalty: Double
        let path: [BinaryLanguageLabel]
    }
}
