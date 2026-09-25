import Core
import Foundation
import Testing

@Suite struct ViterbiLanguageDecoderTests {
    @Test func emptyTieClippingMaskAndPenalty() throws {
        #expect(try ViterbiLanguageDecoder.decode([]).isEmpty)
        #expect(try ViterbiLanguageDecoder.decode([0.5, 0.5, 0.5], switchPenalty: 0) == [.raw, .raw, .raw])
        #expect(try ViterbiLanguageDecoder.decode([0, 1], switchPenalty: 0) == [.raw, .japaneseRoman])
        #expect(try ViterbiLanguageDecoder.decode([0.1, 0.6, 0.1]) == [.raw, .raw, .raw])
        #expect(try ViterbiLanguageDecoder.decode([0.1, 0.6, 0.1], switchPenalty: 0) == [.raw, .japaneseRoman, .raw])
        #expect(try ViterbiLanguageDecoder.decode([1, 1], forced: [.raw, .raw]) == [.raw, .raw])
        #expect(try ViterbiLanguageDecoder.decode([0, 0], forced: [.japaneseRoman, .japaneseRoman]) == [.japaneseRoman, .japaneseRoman])
        // A tied transition stays in the current state, so the masked last JA propagates backwards.
        #expect(try ViterbiLanguageDecoder.decode([0.5, 0.5], switchPenalty: 0, forced: [nil, .japaneseRoman]) == [.japaneseRoman, .japaneseRoman])
    }

    @Test func invalidInputsAndCostOverflowFailClosed() throws {
        for value in [Double.nan, .infinity, -.infinity, -0.1, 1.1] {
            #expect(throws: LanguageDecoderError.invalidProbability) { try ViterbiLanguageDecoder.decode([value]) }
        }
        for penalty in [Double.nan, .infinity, -0.1] {
            #expect(throws: LanguageDecoderError.invalidPenalty) { try ViterbiLanguageDecoder.decode([], switchPenalty: penalty) }
        }
        #expect(throws: LanguageDecoderError.invalidMask) { try ViterbiLanguageDecoder.decode([0.5], forced: []) }
        #expect(throws: LanguageDecoderError.numericOverflow) {
            try ViterbiLanguageDecoder.decode([0.5, 0.5, 0.5], switchPenalty: .greatestFiniteMagnitude,
                                               forced: [.raw, .japaneseRoman, .raw])
        }
        #expect(throws: LanguageDecoderError.invalidMask) {
            try ViterbiLanguageDecoder.decodeBlocks([0.5], protections: [], switchPenalty: 0)
        }
        #expect(throws: LanguageDecoderError.invalidProbability) {
            try ViterbiLanguageDecoder.decodeBlocks([.nan], protections: [.literal], switchPenalty: 0)
        }
    }

    @Test func gapsAndLiteralsResetWhileRawMasksRemainInTheBlock() throws {
        for separator: ScalarProtection in [.gap, .literal] {
            let result = try ViterbiLanguageDecoder.decodeBlocks(
                [0.01, 0.5, 0.9], protections: [.inferred, separator, .inferred], switchPenalty: 100
            )
            #expect(result == [.raw, separator == .gap ? .gap : .literal, .japaneseRoman])
        }
        #expect(try ViterbiLanguageDecoder.decodeBlocks([0.01, 1, 0.9], protections: [.inferred, .raw, .inferred], switchPenalty: 100) == [.raw, .raw, .raw])
    }

    @Test func matchesBruteForceMinimumCost() throws {
        let choices = [0.0, 0.05, 0.3, 0.5, 0.7, 0.95, 1.0]
        // Fixed deterministic inputs, all 2^n possible label paths, with several hard masks.
        for count in 1...7 {
            for seed in 0..<20 {
                let probabilities = (0..<count).map { choices[($0 * 3 + seed) % choices.count] }
                let forced: [BinaryLanguageLabel?] = (0..<count).map { index in
                    switch (index + seed) % 5 {
                    case 0: .raw
                    case 1: .japaneseRoman
                    default: nil
                    }
                }
                for penalty in [0.0, 0.4, 1.2, 2.0] {
                    let path = try ViterbiLanguageDecoder.decode(probabilities, switchPenalty: penalty, forced: forced)
                    let best = (0..<(1 << count)).map { bits -> Double in
                        let candidate: [BinaryLanguageLabel] = (0..<count).map { bits & (1 << $0) == 0 ? .raw : .japaneseRoman }
                        return pathCost(candidate, probabilities: probabilities, penalty: penalty, forced: forced)
                    }.min()!
                    #expect((pathCost(path, probabilities: probabilities, penalty: penalty, forced: forced) - best).magnitude < 1e-10)
                }
            }
        }
    }
}

private func pathCost(_ path: [BinaryLanguageLabel], probabilities: [Double], penalty: Double, forced: [BinaryLanguageLabel?]) -> Double {
    var cost = 0.0
    for index in path.indices {
        if let mask = forced[index], mask != path[index] {
            return .infinity
        }
        let probability = min(max(probabilities[index], 1e-7), 1 - 1e-7)
        cost += -log(path[index] == .japaneseRoman ? probability : 1 - probability)
        if index > 0, path[index] != path[index - 1] { cost += penalty }
    }
    return cost
}
