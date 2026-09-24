import AppKit
import Core
import Darwin
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import SwiftUI

@main
enum PlaygroundLauncher {
    @MainActor static func main() {
        // Upstream conversion can print input even outside DEBUG. This isolated process has
        // no runtime console sink; errors are shown in the window. Never log user context.
        let null = open("/dev/null", O_WRONLY)
        guard null >= 0, dup2(null, STDOUT_FILENO) >= 0, dup2(null, STDERR_FILENO) >= 0 else { exit(1) }
        close(null)
        PlaygroundApp.main()
    }
}

private struct PlaygroundApp: App {
    @StateObject private var state = PlaygroundState()

    var body: some Scene {
        WindowGroup("日英混在入力 · 試用版") {
            PlaygroundView(state: state)
                .frame(minWidth: 780, minHeight: 600)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
    }
}

@MainActor
private final class PlaygroundState: ObservableObject {
    @Published var raw = ""
    @Published var display = ""
    @Published var committed = ""
    @Published var useContext = false
    @Published var selection: [MixedCandidate] = []
    @Published var selectionIndex: Int?
    @Published var error: String?
    @Published var status = "モデルを読み込み中"
    @Published var rawPreview = false
    private var model: LogisticLanguageModel?
    private var englishLexicon: EnglishLexicon?
    private var englishPolicy: EnglishDecisionPolicy?
    private var bridge: ZenzaiSpanBridge?
    private var engine: MixedCompositionEngine?
    private let focus = UUID()
    var isReady: Bool { engine != nil }

    init() {
        do {
            let args = CommandLine.arguments
            func option(_ name: String) -> String? {
                guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
                return args[index + 1]
            }
            guard let modelURL = option("--model").map({ URL(fileURLWithPath: $0) }) ??
                    Bundle.main.url(forResource: "language-model", withExtension: "json") else {
                error = "Tools/run_auto_mixed_playground.sh から学習済みモデルを指定して起動してください。"
                return
            }
            let model = try LogisticLanguageModel(data: Data(contentsOf: modelURL))
            let bundledResources = Bundle.main.url(forResource: "ggml-model-Q5_K_M", withExtension: "gguf")?.deletingLastPathComponent()
            let resources = option("--resources").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? bundledResources
            // No AppGroup, installed IME directory, user dictionary export or settings writes.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutoMixedPlayground-\(UUID())")
            self.bridge = try ZenzaiSpanBridge(converter: .withDefaultDictionary(), applicationDirectory: directory,
                                              useZenzai: resources != nil, resources: resources, learningEnabled: false)
            self.model = model
            self.englishLexicon = try EnglishLexicon.bundled()
            self.englishPolicy = try EnglishDecisionPolicy.bundled()
            try resetEngine()
            try refresh()
        } catch {
            self.error = "起動できません。v2学習済みモデル、英単語辞書、変換資源を確認してください。"
        }
    }

    private func resetEngine() throws {
        engine?.cancel()
        guard let model, let bridge, let englishLexicon, let englishPolicy else { return }
        let context: CommittedLeftContext = useContext ? .available(committed) : .unavailable
        engine = try MixedCompositionEngine(
            segmenter: JapanesePreferredSegmenter(model: model, lexicon: englishLexicon, policy: englishPolicy,
                                                 context: context, focus: focus),
            converter: MixedSessionConverter(bridge: bridge, sessionID: focus,
                                             leftContext: useContext ? String(committed.suffix(30)) : nil,
                                             allowJapaneseReadingFallback: true)
        )
    }

    func edit(_ value: String) {
        guard value != engine?.buffer.text else { return }
        // Bound synchronous work in the playground. The full IME's limits belong to T5/T7.
        guard value.unicodeScalars.count <= 256 else {
            raw = engine?.buffer.text ?? ""
            error = "入力できる長さを超えました。確定してから続きを入力してください。"
            return
        }
        do {
            try engine?.replaceRaw(value)
            error = nil
            try refresh()
        } catch { self.error = "変換できませんでした。原文は入力欄に残っています。" }
    }

    func contextChanged() {
        do { try resetEngine(); try engine?.replaceRaw(raw); try refresh() }
        catch { self.error = "文脈設定を反映できませんでした。" }
    }

    func event(_ event: MixedInputEvent) {
        do {
            if let result = try engine?.handle(event), let commit = result.commit {
                committed += commit.text
                raw = ""
                // The transcript is in-memory only. Playground commits never train the converter.
                try resetEngine()
            }
            try refresh()
        } catch { self.error = "操作できませんでした。原文は入力欄に残っています。" }
    }

    func choose(_ index: Int) {
        guard selection.indices.contains(index) else { return }
        for _ in selection.indices where engine?.selectionIndex != index { event(.tab()) }
        event(.enter)
    }

    func clear() {
        engine?.cancel()
        raw = ""
        display = ""
        selection = []
        selectionIndex = nil
        rawPreview = false
    }

    func clearCommitted() {
        committed = ""
        contextChanged()
    }

    private func refresh() throws {
        display = try engine?.markedText().text ?? raw
        selection = engine?.selectionOptions ?? []
        selectionIndex = engine?.selectionIndex
        rawPreview = engine?.state == .rawPreview
        let backend: String
        switch bridge?.backend {
        case .dictionary: backend = "かな漢字辞書"
        case .zenzaiPending: backend = "Zenzai · 初回変換待ち"
        case .zenzaiReady: backend = "Zenzai · モデル読込済み"
        case .zenzaiUnavailable: backend = "Zenzai · 読込失敗（原文を表示）"
        case nil: backend = "変換資源なし"
        }
        status = "日本語優先・英単語判定あり · \(backend) · \(model?.modelVersion ?? "モデル未読込")"
    }
}

private struct PlaygroundView: View {
    @ObservedObject var state: PlaygroundState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("日英混在入力").font(.largeTitle.bold())
                Text("試用版").font(.caption.bold()).padding(6).background(.orange.opacity(0.15)).cornerRadius(6)
                Spacer()
            }
            Text("日本語を優先して変換し、英単語の根拠が強い区間はアルファベットで残します。")
            Text(state.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .accessibilityIdentifier("mixed-model-status").id(state.status)
            Toggle("この画面で確定した文章を左文脈に使う（末尾30文字）", isOn: $state.useContext)
                .disabled(!state.raw.isEmpty)
                .onChange(of: state.useContext) { _ in state.contextChanged() }
            VStack(alignment: .leading, spacing: 6) {
                Text("入力原文").font(.headline)
                TextField("例: APIwotukau", text: $state.raw)
                    .textFieldStyle(.roundedBorder).font(.title3.monospaced())
                    .accessibilityIdentifier("mixed-raw-input")
                    .onChange(of: state.raw) { state.edit($0) }
                    .onSubmit { state.event(.enter) }
                    .onExitCommand { state.event(.escape) }
                    .disabled(!state.isReady)
                Text("空白はそのまま残ります。Enterで確定、Escapeで原文表示。候補選択中のEnterは候補を採用します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(state.rawPreview ? "原文表示" : "変換プレビュー").font(.headline)
                Text(state.display.isEmpty ? "ここに変換結果が表示されます" : state.display)
                    .font(.title2).textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                    .accessibilityIdentifier("mixed-preview").id(state.display)
                HStack {
                    Button("候補 / 次へ") { state.event(.tab()) }.disabled(state.raw.isEmpty)
                    Button("前の候補") { state.event(.tab(reverse: true)) }.disabled(state.selection.isEmpty)
                    Button(state.selection.isEmpty ? "確定" : "候補を採用") { state.event(.enter) }.disabled(state.raw.isEmpty)
                    Button("原文に戻す") { state.event(.escape) }.disabled(state.raw.isEmpty)
                    Spacer()
                    Button("入力を消去") { state.clear() }
                }
                if !state.selection.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(Array(state.selection.enumerated()), id: \.element.token) { index, candidate in
                                Button(candidate.text) { state.choose(index) }
                                    .tint(index == state.selectionIndex ? .accentColor : .secondary)
                            }
                        }
                    }
                }
            }.padding(16).background(.quaternary.opacity(0.5)).cornerRadius(12)
            HStack {
                Text("確定した文章").font(.headline)
                Spacer()
                Button("文章を消去") { state.clearCommitted() }.disabled(!state.raw.isEmpty)
            }
            ScrollView {
                Text(state.committed.isEmpty ? "確定するとここにつながります" : state.committed)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("mixed-committed").id(state.committed)
            }.frame(minHeight: 70)
            if let error = state.error { Text(error).foregroundStyle(.red) }
            Text("このウィンドウ内で試せます。判定精度は評価中です。入力と文脈は保存せず、終了すると消えます。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24)
    }
}
