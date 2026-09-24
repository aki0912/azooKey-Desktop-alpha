@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@Suite @MainActor struct ZenzaiSpanBridgeTests {
    private func bridge() throws -> (ZenzaiSpanBridge, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-test-\(UUID())")
        return (try ZenzaiSpanBridge(converter: .withDefaultDictionary(), applicationDirectory: directory,
                                    useZenzai: false, learningEnabled: false), directory)
    }

    private func request(_ raw: String, session: UUID = UUID(), composition: UUID = UUID(), span: UUID = UUID(),
                         revision: UInt64 = 1, left: String? = nil, right: String? = nil,
                         settings: UInt64 = 0) throws -> JapaneseSpanRequest {
        try JapaneseSpanRequest(identity: .init(sessionID: session, compositionID: composition, spanID: span, revision: revision),
                                sourceRange: ScalarRange(5, 5 + raw.unicodeScalars.count), raw: raw,
                                leftContext: left, rightContext: right, settingsVersion: settings, isAtBufferEnd: true)
    }

    @Test func standardRomanBoundariesAndPendingSuffix() throws {
        for (raw, prefix, suffix, reading) in [
            ("shi", "shi", "", "し"), ("si", "si", "", "し"),
            ("tsu", "tsu", "", "つ"), ("tu", "tu", "", "つ"),
            ("n", "", "n", ""), ("nn", "nn", "", "ん"),
            ("kan", "ka", "n", "か"), ("kansh", "ka", "nsh", "か"),
            ("gakk", "ga", "kk", "が"), ("konnichiha", "konnichiha", "", "こんいちは"),
            ("konnnichiha", "konnnichiha", "", "こんにちは")
        ] {
            let parsed = try #require(RomanSpanReading.parse(raw))
            #expect(parsed.prefix == prefix, "raw fixture: \(raw)")
            #expect(parsed.suffix == suffix)
            #expect(parsed.reading == reading)
            #expect(parsed.prefix + parsed.suffix == raw)
        }
        for raw in ["Sushi", "abcai", "sushibx", "sushiqz", "👩‍💻", "e\u{301}", "https://example.com"] {
            #expect(RomanSpanReading.parse(raw) == nil)
        }
    }

    @Test func actualDictionaryFullCandidatesPreserveUnfinishedN() throws {
        let (bridge, directory) = try bridge()
        defer { bridge.releaseAll() }
        let request = try request("kyoun")
        let result = try bridge.candidates(for: request)
        #expect(result.fallback == nil)
        #expect(result.convertedRange == (try ScalarRange(5, 9)))
        #expect(result.suffixRange == (try ScalarRange(9, 10)))
        #expect(result.candidates.contains { $0.text == "今日n" })
        #expect(result.candidates.allSatisfy { $0.text.hasSuffix("n") })
        #expect(bridge.candidateRequestCount == 1)
        let internalSpan = JapaneseSpanRequest(identity: request.identity, sourceRange: request.sourceRange,
                                               raw: request.raw, isAtBufferEnd: false)
        #expect(try bridge.candidates(for: internalSpan).fallback == .incompleteInternalSpan)
        #expect(bridge.activeChildCount == 0)
        #expect(bridge.candidateRequestCount == 1)
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        let empty = try bridge.candidates(for: self.request("n"))
        #expect(empty.fallback == .noCompletePrefix)
        #expect(empty.candidates.isEmpty)
        #expect(empty.suffixRange.count == 1)
        #expect(bridge.candidateRequestCount == 1)
    }

    @Test func bulkPreviewRejectsPartialCandidatesUsingActualComposingCount() throws {
        let manager = SegmentsManager(kanaKanjiConverter: .withDefaultDictionary(),
                                     applicationDirectoryURL: FileManager.default.temporaryDirectory,
                                     containerURL: nil, context: .init(useZenzai: false, learningEnabled: false))
        let raw = "kyouhasushiwotaberu"
        let candidates = manager.replaceCompositionFromRaw(raw, leftContext: nil, rightContext: nil, rich: false)
        #expect(!candidates.isEmpty)
        var composing = ComposingText()
        composing.insertAtCursorPosition(raw, inputStyle: .roman2kana)
        for candidate in candidates {
            var remaining = composing
            remaining.prefixComplete(composingCount: candidate.composingCount)
            #expect(remaining.isEmpty)
        }
        #expect(manager.convertTarget == "きょうはすしをたべる")
        _ = manager.replaceCompositionFromRaw("neko", leftContext: nil, rightContext: nil, rich: false)
        #expect(manager.convertTarget == "ねこ")
    }

    @Test func twoSessionsAndTwoSpansStayIndependentAndRelease() throws {
        let (bridge, _) = try bridge()
        defer { bridge.releaseAll() }
        let sessionA = UUID(), sessionB = UUID(), composition = UUID()
        let a1 = try request("kyou", session: sessionA, composition: composition)
        let b1 = try request("neko", session: sessionB, composition: composition)
        let a2 = try request("sushi", session: sessionA, composition: composition)
        let b2 = try request("ashita", session: sessionB, composition: composition)
        let requests = [a1, b1, a2, b2]
        let first = try requests.map { try bridge.candidates(for: $0) }
        #expect(bridge.activeChildCount == 4)
        for index in requests.indices.reversed() {
            let result = try bridge.candidates(for: requests[index])
            #expect(result.candidates == first[index].candidates)
        }
        #expect(bridge.candidateRequestCount == 4)
        #expect(first[0].candidates.contains { $0.text == "今日" })
        #expect(first[1].candidates.contains { $0.text == "猫" })
        #expect(first[2].candidates.contains { $0.text == "寿司" })
        #expect(first[3].candidates.contains { $0.text == "明日" })
        let token = try #require(first[0].candidates.first?.token)
        #expect(throws: JapaneseSpanBridgeError.self) {
            try bridge.recordCommittedSelection(token, identity: b1.identity)
        }
        bridge.retain(sessionID: sessionA, compositionID: composition, spanIDs: [a2.identity.spanID])
        #expect(bridge.activeChildCount == 3)
        #expect(throws: JapaneseSpanBridgeError.self) { try bridge.recordCommittedSelection(token, identity: a1.identity) }
        bridge.release(sessionID: sessionB)
        #expect(bridge.activeChildCount == 1)
        bridge.releaseAll()
        #expect(bridge.activeChildCount == 0)
    }

    @Test func contextSettingsAndRawInvalidateCacheAndOldTokens() throws {
        let (bridge, _) = try bridge()
        defer { bridge.releaseAll() }
        let session = UUID(), composition = UUID(), span = UUID()
        let firstRequest = try request("kyou", session: session, composition: composition, span: span)
        let first = try bridge.candidates(for: firstRequest)
        for (raw, left, right, settings) in [
            ("kyou", "会議は", "", UInt64(0)), ("kyou", "会議は", "です", 0),
            ("kyou", "会議は", "です", 1), ("ashita", "会議は", "です", 1)
        ] {
            _ = try bridge.candidates(for: request(raw, session: session, composition: composition, span: span,
                                                  left: left, right: right, settings: settings))
        }
        #expect(bridge.candidateRequestCount == 5)
        #expect(throws: JapaneseSpanBridgeError.self) {
            try bridge.recordCommittedSelection(try #require(first.candidates.first?.token), identity: firstRequest.identity)
        }
    }

    @Test func childLimitAndAcknowledgementAreBounded() throws {
        let (bridge, directory) = try bridge()
        defer { bridge.releaseAll() }
        let firstRequest = try request("neko")
        let first = try bridge.candidates(for: firstRequest)
        for _ in 1..<32 { _ = try bridge.candidates(for: request("neko")) }
        let overflow = try bridge.candidates(for: request("neko"))
        #expect(bridge.activeChildCount == 32)
        #expect(overflow.fallback == .sessionLimit)
        #expect(bridge.sessionLimitHitCount == 1)
        let token = try #require(first.candidates.first?.token)
        try bridge.recordCommittedSelection(token, identity: firstRequest.identity)
        #expect(bridge.activeChildCount == 31)
        #expect(throws: JapaneseSpanBridgeError.self) { try bridge.recordCommittedSelection(token, identity: firstRequest.identity) }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func contextsAreLimitedAndMissingModelCannotSilentlyEnableZenzai() throws {
        let request = try request("kyou", left: String(repeating: "あ", count: 100), right: String(repeating: "い", count: 100))
        #expect(request.leftContext?.count == 30)
        #expect(request.rightContext?.count == 30)
        #expect(String(reflecting: request) == "JapaneseSpanRequest(<redacted>)")
        #expect(throws: JapaneseSpanBridgeError.self) {
            try ZenzaiSpanBridge(converter: .withDefaultDictionary(), applicationDirectory: .temporaryDirectory, useZenzai: true)
        }
    }

    @Test(.enabled(if: Config.Learning().value != .nothing, "Checks the existing learning-on setting without changing preferences"))
    func previewsDoNotLearnButExplicitAcknowledgementDoes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-learning-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let bridge = try ZenzaiSpanBridge(converter: converter, applicationDirectory: directory, useZenzai: false)
        defer { bridge.releaseAll() }
        func snapshot() throws -> [String: Data] {
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            var result: [String: Data] = [:]
            while let url = files?.nextObject() as? URL {
                if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    result[url.lastPathComponent] = try Data(contentsOf: url)
                }
            }
            return result
        }
        let baseline = try snapshot()
        let cancelled = try request("kyou")
        _ = try bridge.candidates(for: cancelled)
        bridge.release(sessionID: cancelled.identity.sessionID)
        let request = try request("nekon")
        let result = try bridge.candidates(for: request)
        _ = try bridge.candidates(for: request)
        converter.commitUpdateLearningData()
        #expect(try snapshot() == baseline)
        let token = try #require(result.candidates.first { $0.text == "猫n" }?.token)
        try bridge.recordCommittedSelection(token, identity: request.identity)
        converter.commitUpdateLearningData()
        let learned = try snapshot()
        #expect(learned != baseline)
        #expect(throws: JapaneseSpanBridgeError.self) { try bridge.recordCommittedSelection(token, identity: request.identity) }
        converter.commitUpdateLearningData()
        #expect(try snapshot() == learned)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"] != nil,
                   "Requires the explicitly selected trained v2 artifact"))
    func trainedModelDrivesRealConversionAndRawRecovery() throws {
        let path = try #require(ProcessInfo.processInfo.environment["AUTO_MIXED_RUNTIME_MODEL"])
        let model = try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(model.enterJapaneseThreshold == 0.9)
        #expect(model.contextualThresholds?.enterWithoutContext == 0.98)
        let (bridge, _) = try bridge()
        defer { bridge.releaseAll() }
        let session = UUID()
        let engine = try MixedCompositionEngine(segmenter: TrainedMixedSegmenter(model: model, focus: session),
                                                 converter: MixedSessionConverter(bridge: bridge, sessionID: session))
        // Retain the initially attempted sample as an explicit hold regression, not an accuracy claim.
        let held = "watashiha sushi wotaberu API 👩‍💻 https://example.com"
        try engine.replaceRaw(held)
        #expect(try engine.markedText().text == held)
        #expect(bridge.activeChildCount == 0)
        let raw = "kyouha sushi wotaberu API 👩‍💻 https://example.com"
        try engine.replaceRaw(raw)
        let displayed = try engine.markedText().text
        #expect(displayed != raw)
        #expect(displayed.contains(" API 👩‍💻 https://example.com"))
        #expect(!engine.usedRawFallback)
        #expect(bridge.activeChildCount > 0)
        try engine.handle(.escape)
        #expect(try engine.markedText().text == raw)
        let commit = try engine.handle(.enter).commit
        #expect(commit?.text == raw)
        #expect(bridge.activeChildCount == 0)
        try engine.replaceRaw("watashiha sushi wotaberu")
        engine.cancel()
        #expect(bridge.activeChildCount == 0)
        #expect(engine.buffer.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"] != nil,
                   "Requires the real pinned GGUF runtime resource"))
    func realZenzaiInterleavesChildrenWithoutReloadOrCandidateLeakage() throws {
        let path = try #require(ProcessInfo.processInfo.environment["AUTO_MIXED_ZENZAI_RESOURCES"])
        let resources = URL(fileURLWithPath: path, isDirectory: true)
        let converter = KanaKanjiConverter.withDefaultDictionary()
        let bridge = try ZenzaiSpanBridge(converter: converter,
                                         applicationDirectory: .temporaryDirectory.appendingPathComponent("zenz-test-\(UUID())"),
                                         useZenzai: true, resources: resources, learningEnabled: false)
        defer { bridge.releaseAll() }
        let sessionA = UUID(), sessionB = UUID(), composition = UUID()
        let requests = try [
            request("kyoun", session: sessionA, composition: composition, left: "今日は"),
            request("neko", session: sessionB, composition: composition, left: "動物の"),
            request("sushi", session: sessionA, composition: composition, left: "お昼は"),
            request("ashita", session: sessionB, composition: composition, left: "次の予定は")
        ]
        let results = try requests.map { try bridge.candidates(for: $0) }
        #expect(bridge.backend == .zenzaiReady)
        #expect(bridge.activeChildCount == 4)
        #expect(results.allSatisfy { $0.fallback == nil && !$0.candidates.isEmpty })
        #expect(results[0].candidates.allSatisfy { $0.text.hasSuffix("n") })
        #expect(results[0].suffixRange.count == 1)
        // Force real recomputation in another order, without the bridge or dependency memo cache.
        converter.purgeZenzaiMemoizationCache()
        for index in requests.indices.reversed() {
            let previous = requests[index]
            let fresh = JapaneseSpanRequest(identity: previous.identity, sourceRange: previous.sourceRange, raw: previous.raw,
                                            leftContext: previous.leftContext, settingsVersion: 1, isAtBufferEnd: true)
            let result = try bridge.candidates(for: fresh)
            #expect(result.candidates.map(\.text) == results[index].candidates.map(\.text))
            #expect(bridge.backend == .zenzaiReady)
        }
        #expect(bridge.candidateRequestCount == 8)
        bridge.release(sessionID: sessionA)
        #expect(bridge.activeChildCount == 2)
        bridge.release(sessionID: sessionB)
        #expect(bridge.activeChildCount == 0)
    }
}
