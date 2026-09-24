import Foundation

public enum EnglishLexiconError: Error { case missingResource, invalidData, invalidPolicy }

/// Immutable local lookup. No spelling service, user dictionary, network, or input logging.
public struct EnglishLexicon: Sendable {
    private let words: [String: Int]
    private let levels: [(Int, [String])]
    public var count: Int { words.count }

    public init(data: Data) throws {
        guard data.count <= 2_000_000, let text = String(data: data, encoding: .utf8) else {
            throw EnglishLexiconError.invalidData
        }
        var words: [String: Int] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2, let level = Int(fields[1]), [10, 20, 35].contains(level),
                  let word = Self.key(String(fields[0])), word == fields[0],
                  words.updateValue(level, forKey: word) == nil else { throw EnglishLexiconError.invalidData }
        }
        guard !words.isEmpty else { throw EnglishLexiconError.invalidData }
        self.words = words
        levels = [10, 20, 35].map { level in (level, words.filter { $0.value == level }.keys.sorted()) }
    }

    public static func bundled() throws -> Self {
        try Self(data: Data(contentsOf: resource("english", extension: "tsv")))
    }

    static func resource(_ name: String, extension ext: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "EnglishLexiconResources") else {
            throw EnglishLexiconError.missingResource
        }
        return url
    }

    func exactLevel(_ raw: String) -> Int? {
        Self.key(raw).flatMap { words[$0] }
    }

    func prefixLevel(_ raw: String) -> Int? {
        guard let key = Self.key(raw) else { return nil }
        for (level, entries) in levels {
            var low = 0, high = entries.count
            while low < high {
                let middle = (low + high) / 2
                if entries[middle] < key { low = middle + 1 } else { high = middle }
            }
            if low < entries.count, entries[low].hasPrefix(key) { return level }
        }
        return nil
    }

    private static func key(_ raw: String) -> String? {
        let bytes = Array(raw.utf8)
        guard (1...32).contains(bytes.count), bytes.first != 39, bytes.last != 39,
              bytes.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || $0 == 39 }),
              bytes.filter({ $0 == 39 }).count <= 1 else { return nil }
        return String(decoding: bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
    }
}

/// Explicit trial heuristics; these values are not calibrated English probabilities.
public struct EnglishDecisionPolicy: Decodable, Sendable {
    let version: Int
    let commonEntryMaximumJapaneseMean: Double
    let otherEntryMaximumJapaneseMean: Double
    let holdMeanAllowance: Double
    let prefixMaximumJapaneseMean: Double
    let shortWordMaximumJapaneseMean: Double
    let minimumRawFraction: Double
    let minimumPrefixLength: Int

    public init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
        let probabilities = [commonEntryMaximumJapaneseMean, otherEntryMaximumJapaneseMean, holdMeanAllowance,
                             prefixMaximumJapaneseMean, shortWordMaximumJapaneseMean, minimumRawFraction]
        guard version == 1, probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              (3...32).contains(minimumPrefixLength), minimumRawFraction >= 0.5,
              otherEntryMaximumJapaneseMean <= commonEntryMaximumJapaneseMean,
              prefixMaximumJapaneseMean <= otherEntryMaximumJapaneseMean,
              shortWordMaximumJapaneseMean <= otherEntryMaximumJapaneseMean,
              commonEntryMaximumJapaneseMean + holdMeanAllowance <= 1 else { throw EnglishLexiconError.invalidPolicy }
    }

    public static func bundled() throws -> Self {
        try Self(data: Data(contentsOf: EnglishLexicon.resource("english-policy", extension: "json")))
    }
}
