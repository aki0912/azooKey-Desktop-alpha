import Foundation

public enum BinaryLanguageLabel: String, Codable, Sendable, CaseIterable {
    case raw = "RAW"
    case japaneseRoman = "JA_ROMAN"
}

public enum LanguageDecoderError: Error, Equatable {
    case invalidProbability, invalidPenalty, invalidMask, numericOverflow
}

public enum ViterbiLanguageDecoder {
    /// Decode one block. Equal transition costs prefer staying; the final tie prefers RAW.
    public static func decode(
        _ probabilities: [Double], switchPenalty: Double = 1.2, forced: [BinaryLanguageLabel?]? = nil
    ) throws -> [BinaryLanguageLabel] {
        guard switchPenalty.isFinite, switchPenalty >= 0 else {
            throw LanguageDecoderError.invalidPenalty
        }
        guard probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw LanguageDecoderError.invalidProbability
        }
        let mask = forced ?? Array(repeating: nil, count: probabilities.count)
        guard mask.count == probabilities.count else {
            throw LanguageDecoderError.invalidMask
        }
        guard !probabilities.isEmpty else {
            return []
        }
        let labels = BinaryLanguageLabel.allCases
        var previous = [Double.infinity, Double.infinity]
        var back: [[Int]] = []
        for (index, probability) in probabilities.enumerated() {
            let clipped = min(max(probability, 1e-7), 1 - 1e-7)
            let emission = [-log1p(-clipped), -log(clipped)]
            var current = [Double.infinity, Double.infinity]
            var parents = [0, 0]
            for state in 0...1 where mask[index] == nil || mask[index] == labels[state] {
                if index == 0 {
                    current[state] = emission[state]
                    parents[state] = state
                } else {
                    let other = 1 - state
                    let stay = previous[state]
                    let change = previous[other] + switchPenalty
                    let parent = change < stay ? other : state
                    current[state] = min(stay, change) + emission[state]
                    parents[state] = parent
                }
            }
            guard current.contains(where: \.isFinite) else {
                throw LanguageDecoderError.numericOverflow
            }
            previous = current
            back.append(parents)
        }
        var state = previous[0] <= previous[1] ? 0 : 1
        var path = [labels[state]]
        for index in stride(from: probabilities.count - 1, through: 1, by: -1) {
            state = back[index][state]
            path.append(labels[state])
        }
        return path.reversed()
    }

    /// Literal/gap positions split independent blocks. RAW protection stays inside a block
    /// as a hard mask, never as an artificial probability or a deleted character.
    public static func decodeBlocks(
        _ probabilities: [Double], protections: [ScalarProtection], switchPenalty: Double
    ) throws -> [SpanKind] {
        guard protections.count == probabilities.count else {
            throw LanguageDecoderError.invalidMask
        }
        // Validate even an empty or entirely protected input.
        _ = try decode([], switchPenalty: switchPenalty)
        guard probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw LanguageDecoderError.invalidProbability
        }
        var result: [SpanKind] = []
        var start = 0
        while start < protections.count {
            switch protections[start] {
            case .literal, .gap:
                result.append(protections[start] == .gap ? .gap : .literal)
                start += 1
            case .inferred, .raw:
                var end = start + 1
                while end < protections.count, protections[end] == .inferred || protections[end] == .raw { end += 1 }
                let forced: [BinaryLanguageLabel?] = protections[start..<end].map { $0 == .raw ? .raw : nil }
                let path = try decode(Array(probabilities[start..<end]), switchPenalty: switchPenalty, forced: forced)
                result += path.map { $0 == .raw ? .raw : .japaneseRoman }
                start = end
            }
        }
        return result
    }
}
