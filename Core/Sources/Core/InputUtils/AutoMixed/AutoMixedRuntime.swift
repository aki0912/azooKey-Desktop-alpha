import Foundation
import Crypto
import KanaKanjiConverterModuleWithDefaultDictionary

/// Bundle-only opt-in. Missing/invalid configuration leaves the normal IME manual.
/// The marker is deliberately not shipped in the default app resources.
public enum AutoMixedExperiment {
    public struct Configuration: Codable, Sendable {
        public let enabled: Bool
        public let modelSHA256: String
    }
    public static func configuration(in directory: URL) -> Configuration? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("auto-mixed-experiment.json")),
              data.count <= 4096,
              let result = try? JSONDecoder().decode(Configuration.self, from: data), result.enabled else { return nil }
        return result
    }
}

@MainActor public final class AutoMixedRuntime {
    private let model: LogisticLanguageModel
    private let lexicon: EnglishLexicon
    private let policy: EnglishDecisionPolicy
    private let bridge: ZenzaiSpanBridge

    public init(resources: URL, converter: KanaKanjiConverter, applicationDirectory: URL) throws {
        guard let config = AutoMixedExperiment.configuration(in: resources) else { throw EnglishLexiconError.missingResource }
        let data = try Data(contentsOf: resources.appendingPathComponent("auto-mixed-model.json"))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == config.modelSHA256 else { throw EnglishLexiconError.invalidData }
        MixedDiagnostics.record(.runtimeStage, [.stage: .token(.model)])
        model = try LogisticLanguageModel(data: data)
        MixedDiagnostics.record(.runtimeStage, [.stage: .token(.lexicon)])
        lexicon = try .bundled()
        MixedDiagnostics.record(.runtimeStage, [.stage: .token(.policy)])
        policy = try .bundled()
        // Experimental IME preview and commit both keep learning disabled. Enabling
        // ack-driven candidate learning requires the later pending-token integration.
        MixedDiagnostics.record(.runtimeStage, [.stage: .token(.bridge)])
        bridge = try ZenzaiSpanBridge(converter: converter, applicationDirectory: applicationDirectory,
                                      useZenzai: true, resources: resources, learningEnabled: false)
    }

    public func makeSession(epoch: UUID) -> AutoMixedServerSession {
        AutoMixedServerSession(epoch: epoch) { [self] context in
            let sessionID = UUID()
            return try MixedCompositionEngine(
                segmenter: JapanesePreferredSegmenter(model: model, lexicon: lexicon, policy: policy,
                    context: context.leftSideContext.map(CommittedLeftContext.available) ?? .unavailable, focus: sessionID),
                converter: MixedSessionConverter(bridge: bridge, sessionID: sessionID,
                    leftContext: context.leftSideContext, rightContext: context.rightSideContext, allowJapaneseReadingFallback: true))
        }
    }
}
