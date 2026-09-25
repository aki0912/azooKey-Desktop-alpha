@testable import Core
import Crypto
import Foundation
import Testing

/// Opt-in real-engine replay of authored input. Arrival deadlines model a serial
/// client at the requested typing rate; this is not an IMK or XPC latency test.
@Suite(.serialized) @MainActor struct MixedLatencyBenchmarkTests {
    struct Sample: Codable {
        let length: Int
        let rate: Int
        let index: Int
        let deleting: Bool
        let queueUS: UInt64
        let serviceUS: UInt64
        let responseUS: UInt64
        let pending: Int
        let metrics: MixedPerformance.Snapshot
        let displaySHA256: String
    }
    struct Report: Codable {
        let schema: Int
        let coldUS: UInt64
        let samples: [Sample]
        let drainUS: [String: UInt64]
        let activeChildrenAfterCommit: Int
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AUTO_MIXED_LATENCY_OUTPUT"] != nil))
    func pacedRealZenzai() async throws {
        let env = ProcessInfo.processInfo.environment
        let output = try #require(env["AUTO_MIXED_LATENCY_OUTPUT"])
        let model = try LogisticLanguageModel(data: Data(contentsOf: URL(fileURLWithPath: #require(env["AUTO_MIXED_RUNTIME_MODEL"]))))
        let start = DispatchTime.now().uptimeNanoseconds
        let bridge = try ZenzaiSpanBridge(converter: .withDefaultDictionary(),
            applicationDirectory: .temporaryDirectory.appendingPathComponent("mixed-latency-\(UUID())"),
            useZenzai: true, resources: URL(fileURLWithPath: #require(env["AUTO_MIXED_ZENZAI_RESOURCES"])), learningEnabled: false)
        defer { bridge.releaseAll() }
        let segmenter = try JapanesePreferredSegmenter(model: model, lexicon: .bundled(), policy: .bundled(), focus: UUID())
        let engine = MixedCompositionEngine(segmenter: segmenter,
            converter: MixedSessionConverter(bridge: bridge, sessionID: UUID(), allowJapaneseReadingFallback: true), punctuation: .init())
        try engine.replaceRaw("asita")
        _ = try engine.handle(.enter)
        #expect(bridge.backend == .zenzaiReady)
        let cold = (DispatchTime.now().uptimeNanoseconds - start) / 1000
        var samples: [Sample] = [], drains: [String: UInt64] = [:]
        let lengths = (env["AUTO_MIXED_LATENCY_LENGTHS"] ?? "20,60,120,240").split(separator: ",").compactMap { Int($0) }
        let rates = (env["AUTO_MIXED_LATENCY_RATES"] ?? "5,10,15").split(separator: ",").compactMap { Int($0) }
        for length in lengths {
            // One continuous uncommitted sentence, deliberately without spaces or punctuation.
            let raw = String(String(repeating: "asitanotennkiwoosietekudasai", count: 12).prefix(length))
            let keys = raw.map { MixedInputEvent.insert(String($0)) }
            let edits = Array(repeating: MixedInputEvent.backspace, count: 10) + raw.suffix(10).map { .insert(String($0)) }
            let events = keys + edits
            for rate in rates {
                engine.cancel()
                let origin = DispatchTime.now().uptimeNanoseconds
                let interval = UInt64(1_000_000_000 / rate)
                for (index, event) in events.enumerated() {
                    let arrival = origin + UInt64(index) * interval
                    let now = DispatchTime.now().uptimeNanoseconds
                    if now < arrival { try await Task.sleep(nanoseconds: arrival - now) }
                    let began = DispatchTime.now().uptimeNanoseconds
                    let trace = MixedPerformance.Trace()
                    let display = try MixedPerformance.$trace.withValue(trace) {
                        _ = try engine.handle(event)
                        return try MixedPerformance.measure(.render) { try engine.markedText().text }
                    }
                    let end = DispatchTime.now().uptimeNanoseconds
                    #expect(!engine.usedRawFallback)
                    let digest = SHA256.hash(data: Data(display.utf8)).map { String(format: "%02x", $0) }.joined()
                    samples.append(Sample(length: length, rate: rate, index: index,
                        deleting: index >= length && index < length + 10,
                        queueUS: (began - arrival) / 1000, serviceUS: (end - began) / 1000,
                        responseUS: (end - arrival) / 1000,
                        pending: min(events.count - index - 1, Int((began - arrival) / interval)),
                        metrics: trace.snapshot(), displaySHA256: digest))
                }
                drains["\(length)-\(rate)"] = samples.last!.responseUS
                #expect(engine.buffer.text == raw)
                _ = try engine.handle(.enter)
                #expect(bridge.activeChildCount == 0)
                // Checkpoint each completed series, so interrupted runs are explicit partial reports.
                let report = Report(schema: 1, coldUS: cold, samples: samples, drainUS: drains,
                                    activeChildrenAfterCommit: bridge.activeChildCount)
                try JSONEncoder().encode(report).write(to: URL(fileURLWithPath: output), options: .atomic)
                print("Latency series complete: length=\(length) rate=\(rate) samples=\(events.count)")
            }
        }
    }
}
