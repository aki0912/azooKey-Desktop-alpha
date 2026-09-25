import Foundation

public enum LanguageModelError: Error, Equatable {
    case oversizedModel, invalidSchema, unsupportedVersion, fixtureNotAllowed
    case invalidVocabulary, invalidNumbers, numericOverflow
}

public struct LanguageScore: Sendable {
    public let activeIndices: [Int]
    public let logit: Double
    public let japaneseProbability: Double
}

/// Development-data parameters, not calibrated span probabilities or release defaults.
public struct ContextualDecisionThresholds: Sendable {
    public let enterWithoutContext: Double
    public let minimumJapanese: Double
    public let minimumPathMargin: Double
}

/// Immutable float64 scorer. Loading Data performs no file access and enables no IME mode.
public struct LogisticLanguageModel: Sendable {
    public static let maximumByteCount = 5 * 1024 * 1024
    public let modelVersion: String
    public let featureSpecVersion: String
    public let trainingManifestSHA256: String
    public let switchPenalty: Double
    public let enterJapaneseThreshold: Double
    public let holdJapaneseThreshold: Double
    public let contextualThresholds: ContextualDecisionThresholds?
    private let indices: [Data: Int]
    private let weights: [Double]
    private let intercept: Double
    private let calibrationA: Double
    private let calibrationC: Double

    /// Production entry point: fixture weights are unconditionally rejected.
    public init(data: Data) throws {
        try self.init(data: data, permitsFixture: false)
    }

    /// Internal, accessible to @testable tests, never exposed as a runtime configuration.
    init(testFixture data: Data) throws {
        try self.init(data: data, permitsFixture: true)
    }

    private init(data: Data, permitsFixture: Bool) throws {
        guard data.count <= Self.maximumByteCount else {
            throw LanguageModelError.oversizedModel
        }
        let file = try JSONDecoder().decode(ModelFile.self, from: data)
        let isV1 = file.schemaVersion == 1 && file.featureSpecVersion == AnchoredCharacterFeatures.version
        let isV2 = file.schemaVersion == 2 && file.featureSpecVersion == ContextualCharacterFeatures.version
        guard isV1 || isV2 else {
            throw LanguageModelError.unsupportedVersion
        }
        guard isV1 == (file.thresholds.contextual == nil) else { throw LanguageModelError.invalidSchema }
        guard file.positiveLabel == "JA_ROMAN", !file.modelVersion.isEmpty,
              file.trainingManifestSHA256.utf8.count == 64,
              file.trainingManifestSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              file.kind == "production" || file.kind == "fixture" else {
            throw LanguageModelError.invalidSchema
        }
        guard file.kind == "production" || permitsFixture else {
            throw LanguageModelError.fixtureNotAllowed
        }
        guard file.vocabulary.count <= 32768, file.coefficients.count == file.vocabulary.count else {
            throw LanguageModelError.invalidVocabulary
        }
        // Compare bytes, not Swift's canonically-equivalent String equality. Never reorder weights.
        let vocabulary = file.vocabulary.map { Data($0.utf8) }
        for index in vocabulary.indices.dropFirst() {
            guard vocabulary[index - 1].lexicographicallyPrecedes(vocabulary[index]) else {
                throw LanguageModelError.invalidVocabulary
            }
        }
        try file.validateNumbers()
        indices = Dictionary(uniqueKeysWithValues: vocabulary.enumerated().map { ($0.element, $0.offset) })
        weights = file.coefficients
        intercept = file.intercept
        calibrationA = file.calibration.a
        calibrationC = file.calibration.c
        switchPenalty = file.decoder.switchPenalty
        enterJapaneseThreshold = file.thresholds.enterJA
        holdJapaneseThreshold = file.thresholds.holdJA
        modelVersion = file.modelVersion
        featureSpecVersion = file.featureSpecVersion
        contextualThresholds = file.thresholds.contextual
        trainingManifestSHA256 = file.trainingManifestSHA256
    }

    public func score(_ features: AnchoredCharacterFeatures, at index: Int) throws -> LanguageScore {
        guard featureSpecVersion == AnchoredCharacterFeatures.version else { throw LanguageModelError.unsupportedVersion }
        return try score(keys: features.unsortedKeys(at: index))
    }

    public func score(_ features: ContextualCharacterFeatures, at index: Int) throws -> LanguageScore {
        guard featureSpecVersion == ContextualCharacterFeatures.version else { throw LanguageModelError.unsupportedVersion }
        return try score(keys: features.unsortedKeys(at: index))
    }

    private func score(keys: [String]) throws -> LanguageScore {
        let active = keys.compactMap { indices[Data($0.utf8)] }.sorted()
        var logit = intercept
        for index in active { logit += weights[index] }
        guard logit.isFinite else {
            throw LanguageModelError.numericOverflow
        }
        let probability = try Self.sigmoid(calibrationA * logit + calibrationC)
        return LanguageScore(activeIndices: active, logit: logit, japaneseProbability: probability)
    }

    static func sigmoid(_ value: Double) throws -> Double {
        guard value.isFinite else {
            throw LanguageModelError.numericOverflow
        }
        if value >= 0 {
            return 1 / (1 + exp(-value))
        }
        let exponential = exp(value)
        return exponential / (1 + exponential)
    }
}

private struct ModelFile: Decodable {
    let schemaVersion: Int
    let featureSpecVersion: String
    let kind: String
    let modelVersion: String
    let positiveLabel: String
    let vocabulary: [String]
    let coefficients: [Double]
    let intercept: Double
    let calibration: Calibration
    let decoder: DecoderSettings
    let thresholds: Thresholds
    let trainingManifestSHA256: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version", featureSpecVersion = "feature_spec_version"
        case kind, modelVersion = "model_version", positiveLabel = "positive_label"
        case vocabulary, coefficients, intercept, calibration, decoder, thresholds
        case trainingManifestSHA256 = "training_manifest_sha256"
    }

    init(from decoder: any Decoder) throws {
        let values = try strictContainer(decoder, CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        featureSpecVersion = try values.decode(String.self, forKey: .featureSpecVersion)
        kind = try values.decode(String.self, forKey: .kind)
        modelVersion = try values.decode(String.self, forKey: .modelVersion)
        positiveLabel = try values.decode(String.self, forKey: .positiveLabel)
        vocabulary = try values.decode([String].self, forKey: .vocabulary)
        coefficients = try values.decode([Double].self, forKey: .coefficients)
        intercept = try values.decode(Double.self, forKey: .intercept)
        calibration = try values.decode(Calibration.self, forKey: .calibration)
        self.decoder = try values.decode(DecoderSettings.self, forKey: .decoder)
        thresholds = try values.decode(Thresholds.self, forKey: .thresholds)
        trainingManifestSHA256 = try values.decode(String.self, forKey: .trainingManifestSHA256)
    }

    func validateNumbers() throws {
        let numbers = coefficients + [intercept, calibration.a, calibration.c,
                                          decoder.switchPenalty, thresholds.enterJA, thresholds.holdJA]
        guard numbers.allSatisfy(\.isFinite), decoder.switchPenalty >= 0,
              0 <= thresholds.holdJA, thresholds.holdJA <= thresholds.enterJA,
              thresholds.enterJA <= 1 else { throw LanguageModelError.invalidNumbers }
        if let policy = thresholds.contextual {
            guard policy.enterWithoutContext.isFinite, policy.minimumJapanese.isFinite,
                  policy.minimumPathMargin.isFinite,
                  (thresholds.enterJA...1).contains(policy.enterWithoutContext),
                  (0...1).contains(policy.minimumJapanese), policy.minimumPathMargin >= 0 else {
                throw LanguageModelError.invalidNumbers
            }
        }
    }

    struct Calibration: Decodable {
        let a: Double
        let c: Double
        enum CodingKeys: String, CodingKey, CaseIterable { case a, c }
        init(from decoder: any Decoder) throws {
            let values = try strictContainer(decoder, CodingKeys.self)
            a = try values.decode(Double.self, forKey: .a)
            c = try values.decode(Double.self, forKey: .c)
        }
    }

    struct DecoderSettings: Decodable {
        let switchPenalty: Double
        enum CodingKeys: String, CodingKey, CaseIterable { case switchPenalty = "switch_penalty" }
        init(from decoder: any Decoder) throws {
            switchPenalty = try strictContainer(decoder, CodingKeys.self).decode(Double.self, forKey: .switchPenalty)
        }
    }

    struct Thresholds: Decodable {
        let enterJA: Double
        let holdJA: Double
        let contextual: ContextualDecisionThresholds?
        enum CodingKeys: String, CodingKey, CaseIterable {
            case enterJA = "enter_ja", holdJA = "hold_ja"
            case enterWithoutContext = "enter_ja_without_context", minimumJapanese = "minimum_ja"
            case minimumPathMargin = "minimum_path_margin"
        }
        init(from decoder: any Decoder) throws {
            let fields = Set(try decoder.container(keyedBy: ModelField.self).allKeys.map(\.stringValue))
            let isV1 = fields == Set(["enter_ja", "hold_ja"])
            let values = try isV1 ? decoder.container(keyedBy: CodingKeys.self) : strictContainer(decoder, CodingKeys.self)
            enterJA = try values.decode(Double.self, forKey: .enterJA)
            holdJA = try values.decode(Double.self, forKey: .holdJA)
            contextual = try isV1 ? nil : ContextualDecisionThresholds(
                enterWithoutContext: values.decode(Double.self, forKey: .enterWithoutContext),
                minimumJapanese: values.decode(Double.self, forKey: .minimumJapanese),
                minimumPathMargin: values.decode(Double.self, forKey: .minimumPathMargin)
            )
        }
    }
}

private struct ModelField: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Enforce required fields and additionalProperties=false at every schema object.
private func strictContainer<Key: CodingKey & CaseIterable>(
    _ decoder: any Decoder, _ keyType: Key.Type
) throws -> KeyedDecodingContainer<Key> {
    let actual = try decoder.container(keyedBy: ModelField.self).allKeys.map(\.stringValue)
    guard Set(actual) == Set(Key.allCases.map(\.stringValue)) else {
        throw LanguageModelError.invalidSchema
    }
    return try decoder.container(keyedBy: keyType)
}
