# Auto Mixed Input 実装状況

2026-09-24時点。**長音の前後で日本語の単語が分かれる不具合を修正し、Mixedへ反映済み。`harike-n`／`harike-nn` から「ハリケーン」を一語の候補として取得・確定できることを導入済み実サーバーで確認した。Core回帰・IMK境界・既存記号／apple回帰も成功。今回の修正後の物理打鍵は未確認。** 最新記録は末尾の「長音を含む語の変換修正」を参照。

計700原文（増強後3,907行）でv1/v2のLR学習・校正・exportは実施済みだが、品質基準未達のためT3全体は未完了、候補モデルはrelease_ready=false。追加650件の人手確認も未実施。fixtureと候補モデルのPython／Swift数値一致を確認したことと、実入力での判別性能・v2の優位性を区別する。T6全体・T7/T8は未完了。以下の各stageは当時の資料パス・実行結果を含む履歴である。

## T0：参照commitと現状の確認を完了

以下は2026-09-23のT0調査記録。T2開始時のHEADと確認結果は後述する。

| 項目 | 確認結果 |
|---|---|
| 作業開始HEAD | `b7ec0e4f27cf19d6a3aefa77d4b5ea7f2ebe5376` |
| 参照commitとの差分 | 同一SHA。開始時のtracked差分なし。HEADは変更していない |
| コミット | `2026-09-05T17:11:43+09:00`、`feat(input): 予測候補の受理にConverterの新APIを利用する (#373)` |
| 既存ユーザー変更 | `git status --short`は`?? docs/`。提供された仕様一式をそのまま保持 |
| AGENTS | リポジトリ・親ディレクトリに実ファイルの`AGENTS.md`は見つからなかった。依頼に添付された指示を適用。`docs/auto-mixed/AGENTS.addendum.md`は追記案として確認し、上書きや統合はしていない |
| 読んだ仕様 | `docs/auto-mixed/README.md`、`CODEX_START.md`、`docs/01_REQUIREMENTS_UX.md`、`02_UPSTREAM_MAP.md`、`03_ARCHITECTURE.md`、`05_TEST_AND_EVALUATION.md`、`06_IMPLEMENTATION_PLAN.md`、`07_SECURITY_RELEASE.md` |
| OS・ツール | arm64、macOS 27.0（26A428）、Xcode 27.0（27A266a）、Apple Swift 6.4（swiftlang-6.4.0.34.1）、Python 3.11.9 |
| 隔離先 | `build/auto-mixed/`。既存`.gitignore`の`build/`対象。baselineソース、ビルド、キャッシュ、ログを配置。`DerivedData/`もこの中に作成 |

`Core/Package.swift`はtools-version 6.1、macOS 13指定。macOSではConverterの`Zenzai` traitを有効にする。アプリtargetはmacOS 13、project共通設定は12。これらは実機動作保証ではない。READMEの要件とも区別する。

CIはmacOS 15＋Xcode 16.3で`swift build/test`、Ubuntu 22.04＋Swift 6.2、署名なしのXcode Releaseビルド、`swiftlint --quiet --strict`を定義している。共有scheme `azooKeyMac`はプロジェクト内のXMLで確認した。今回のXcode 27はCIと異なる。

### 依存と資源

| 依存 | 実際に解決したrevision／version |
|---|---|
| AzooKeyKanaKanjiConverter | `ad714fea8cb2fe113aea86ba5c42563cdaf77cfb`（仕様と一致。checkoutのHEADも確認） |
| swift-crypto | 3.15.1、`95ba0316a9b733e92bb6b071255ff46263bbe7dc` |
| ZIPFoundation | 0.9.20、`22787ffb59de99e5dc1fbfe80b19c97a904ad48d` |
| その他 | swift-algorithms 1.2.1、swift-asn1 1.7.3、swift-collections 1.7.0、swift-numerics 1.1.1、swift-tokenizers 0.0.1、SwiftyMarisa 0.0.1、Jinja 1.1.2 |
| llama.cpp binary | 依存manifestの`b4846/signed-llama.xcframework.zip`。checksum `db3b13169df8870375f212e6ac21194225f1c85f7911d595ab64c8c790068e0a` |

解決結果は`Core/Package.resolved`とbaselineコピー内に残る（既存ルールでgit管理外）。開始時には解決済みlockも`Core/.build`もなかった。依存checkoutは`build/auto-mixed/core/checkouts/`に取得した。依存manifest・固定revisionは変更していない。

`.gitmodules`とgitlinkの確認結果：

- `azooKeyMac/Resources/gguf` → `Miwa-Keita/zenz-v3.2-small-gguf`、`c67e03e07d215c869f591b274c1631170d3e11fe`。未初期化。
- `azooKeyMac/Resources/base_n5_lm` → `Miwa-Keita/base_n5_lm`、`160a305a89c033ac53a674baeac4470cf531a71b`。未初期化。

XcodeのResources phaseはGGUFと4個のmarisaファイルをアプリ資源へコピーする。`ConverterServer+Snapshot.appResourcesDirectoryURL()`はHelperから上位の`Contents/Resources`を探し、`SegmentsManager`はそこから`ggml-model-Q5_K_M.gguf`と`lm_*`を読む。`Tools/embed_converter_server.sh`は別にConverterServerをSwiftPMでビルドし、HelperとSwiftPM resource bundleを埋め込む。このscriptは`Core/.build`を使うため、将来の完全隔離XcodeビルドではDerivedDataの指定だけでは足りない。

### APIは固定依存の定義まで確認

以下の依存内パスは`build/auto-mixed/core/checkouts/AzooKeyKanaKanjiConverter/`からの相対パス。

- `Sources/KanaKanjiConverterModule/InputManagement/InputStyle.swift`には`.direct`、`.roman2kana`、`.mapped(id:)`が実在する。標準表IDは`.defaultRomanToKana`。既存サーバーの`resolveInputStyle`も確認した。
- 同ディレクトリの`ComposingText.swift`には`insertAtCursorPosition(_:inputStyle:)`、`insertAtCursorPosition(_ elements:)`、`prefixComplete(composingCount:)`、`inputIndexToSurfaceIndexMap()`がある。最後の対応表はInputElementと表示Characterの境界であり、新規原文バッファのscalar範囲と同じ単位ではない。
- `Sources/KanaKanjiConverterModule/ConverterAPI/KanaKanjiConverter.swift`の`createSession`は変換状態を追加する。辞書・Zenzai・学習・Converter単位のキャッシュは共有する。`withSession`は存在確認後にactive sessionを交換し、`defer`で元へ戻す同期API。ネスト時の復元も実装で確認。スレッド安全ではなく、既存サーバー同様の逐次実行が必要。
- `removeSession`は状態を除去する。`stopComposition`は共有Zenzaiの`endSession`も呼ぶため、child sessionを実運用で混線なく使えるかはT4の実試験が必要。
- 全文消費判定は`Core/Sources/Core/InputUtils/SegmentsManager.swift`のprivate拡張`isWholeComposingText(composingCount:)`で確認した。compositionのコピーに`prefixComplete`を適用し、空になったかを調べる。`ComposingCount`は`.inputCount`、`.surfaceCount`、`.composite`であり、整数の文字数比較に置き換えない。
- `prefixCandidateCommited`は`setCompletedData`、`updateLearningData`、原文の部分確定を行う。プレビューには使えない。既存挿入APIも毎回候補更新を行うため、T4で一括置換と候補更新の分離が必要。

`ZenzaiSpanBridge`、`replaceCompositionFromRaw`は現行APIとして存在しない。今回の`LanguageSegmenter`、`JapaneseSpanConverting`、`MixedCandidate`などは新設したT1用境界。仕様03章のsession／identity／suffix／学習契約を完成させたAPIではなく、T4で拡張する暫定インターフェースである。

### XPC構造と現在のキー契約

`azooKeyMacInputController.handle` → 同期`ConverterClientEventRouter` → `ConverterKeyEventRequest` → `ConverterServerClient` → Data上のJSON/Codable → MainActor上の`ConverterServer` → `withConverterSession` → `UserAction`／`InputState`／`SegmentsManager` → snapshotとeffects → クライアントのmarked text／候補描画、という経路を確認した。

サーバーは共有Converterを1個持ち、入力sessionごとにmanagerとconversion sessionを持つ。同じeventIDには直前の応答を返し、古いeventIDは拒否する。クライアントはpending件数とactivationGenerationを持つ。Commandは同期的にアプリへ通し、pending中は他のキーを保守的にconsumeする。snapshotはmanagerが空なら原則`.empty`となるため、混在表示の接続時には専用分岐が必要。

| 操作 | 既存manualの主な契約 | T1で別実装した混在契約 |
|---|---|---|
| Space | 日本語composingではライブ変換ONなら候補選択、OFFならpreview。英語composingでは空白追加 | 常にU+0020を挿入。連続空白も保持 |
| Tab | composingで予測候補を受理 | 候補を開く／循環。Shift+Tabは逆順 |
| Enter | 状態に応じてmarked text／候補を確定 | 選択中は内部採用のみ。次のEnterで全体の確定値を1個返す |
| Escape | composingではstopComposition | 選択中は候補を閉じる。それ以外は原文表示へ戻す |
| Backspace | 既存managerへ削除操作 | 原文の1書記素を削除 |

既存の入力処理、設定、XPC wire型、InputController、Package.swiftには変更を加えていない。機能の有効化UIも追加していない。

## T1：原文・範囲・モック状態機械を完了

| 追加ファイル | 責務 |
|---|---|
| `Core/Sources/Core/AutoMixed/AutoMixedTypes.swift` | scalar／UTF-16範囲とdecode時検証、span、候補、provider protocol、イベントと確定値 |
| `Core/Sources/Core/AutoMixed/RawCompositionBuffer.swift` | 原文を保持し、書記素境界で挿入・削除・中央置換。ZWJや結合文字で編集後に境界が変わる場合もカーソルを補正 |
| `Core/Sources/Core/AutoMixed/TextOffsetMap.swift` | 原文scalar、String.Index、書記素境界、UTF-16の対応 |
| `Core/Sources/Core/AutoMixed/MixedMarkedTextRenderer.swift` | spanの全被覆、重複・空・範囲外を検証。変換runはatomic対応とし、内部位置の推測を拒否 |
| `Core/Sources/Core/AutoMixed/MixedCompositionEngine.swift` | idle／composing／selecting／rawPreview。providerを注入し、障害時は原文へ退避。プレビューに学習やOS操作を含めない |
| `Core/Tests/CoreTests/AutoMixedTests/`の3ファイル | Unicode、編集、範囲、混在表示、候補採用と確定の分離、失敗時の原文保持、同梱fixtureの基礎ケース |
| `Tools/test_auto_mixed_core.sh` | 同じソースとテストを参照する依存なしの隔離SwiftPMハーネス |
| `implementation_status.md` | この記録 |

`fixtures/event_cases.json`から実行するT1基礎ケースは`space-literal`、`double-space`、`candidate-then-commit`、`enter-pass-empty`、`escape-raw`、`backspace-prefix`、`backspace-grapheme`の7件。fixtureを複製・改変せず読み込む。残り9件はテスト内で後続stageとして列挙し、fixtureの追加を見落とさないよう全ID集合も検証する。

### 段階実装上の境界

- scalar範囲型は任意の妥当なscalar範囲を表せるが、表示spanの分割は書記素境界に限定した。結合文字やZWJの途中に候補を入れないための検証であり、T2のラベル集約時にもこの条件を守る。
- 変換run内の対応不明位置は`nil`を返す。左右移動でその区間だけを原文へ展開する操作はT6。RawCompositionBuffer自体の中央編集は実装・テスト済みだが、engineの公開イベントは末尾編集まで。
- 原文表示は再描画や候補を閉じる操作では再変換しない。通常編集で推定を再開する。候補採用後、末尾に隣接区間を追加しても、範囲と原文が同じspanの選択を保持する。中央編集を含むロックの移動・解除はT6。
- T1の候補は要求span全体を覆う固定文字列。未完ローマ字の解釈・変換可能prefixとsuffixの分離・dirty区間の候補再利用はT4以降。
- T1の全英語Tabは原文保持候補を開く。日本語強制・区間選択UI、`explicit-raw`、`buffer-capacity`はT6として未実装。256scalarを超えた自動確定はまだ行わない。
- `MixedCommit`はローカルな戻り値。実OSへのinsert、commitID、ack、学習、再送・重複防止を実装したものではない。`escape-raw`の表示・確定文字列は確認したが、fixture中の`learned_ja_candidate_count`を実学習系へ接続する検証はT4/T5に残る。

## T2：特徴量・モデル読込・系列復号を完了

開始HEADは`8226975355e3ef645899020245b4a2c38f37722b`。作業ツリーはクリーンだった。T0の依存API調査・baseline記録とT1の完了条件を読み直し、T1単独テスト16件を再実行して通過を確認してから着手した。実ファイルのAGENTS.mdは引き続き見つからず、依頼に添付された指示を適用した。

T2では`docs/auto-mixed/docs/04_MODEL_AND_DATA.md`、モデルschema、Python参照実装・テスト、03章の保護規則を確認した。既存のmanual入力、XPC、InputController、依存manifestは変更していない。

### 変更ファイルと検証内容

| 追加ファイル | 内容 |
|---|---|
| `Core/Sources/Core/AutoMixed/AnchoredCharacterFeatures.swift` | scalar位置のwindow・shape・anchored n-gram。ASCIIだけを小文字化し、Pythonと同じASCII-escaped JSONキーを生成 |
| `Core/Sources/Core/AutoMixed/LogisticLanguageModel.swift` | immutableなDoubleスコアラ。5MiB制限、schema全必須項目・未知項目拒否、version・正例ラベル・manifest hash形式・語彙・数値・閾値を検証 |
| `Core/Sources/Core/AutoMixed/ViterbiLanguageDecoder.swift` | RAW／JAの2状態復号。同点では状態継続、最終同点ではRAW。hard maskとgap／literalでの独立復号 |
| `Core/Sources/Core/AutoMixed/ProtectedSpanDetector.swift` | URL・メール・パス・明確な識別子・ファイル名、数値・記号・既存Unicode文字を保護。大文字runだけをRAW固定 |
| `Core/Sources/Core/AutoMixed/StatisticalLanguageSegmenter.swift` | 特徴抽出→LR→保護付き復号→span全被覆検証を接続。JA仮説と、原文保持用の未解決spanを区別 |
| `Core/Tests/CoreTests/AutoMixedTests/LanguageModelTests.swift` | 128 golden、エスケープ、正例方向、校正、OOV、schema・語彙・数値異常、fixture拒否 |
| `Core/Tests/CoreTests/AutoMixedTests/ViterbiLanguageDecoderTests.swift` | 同点、mask、clamp、異常値、gap reset、560条件の全経路探索との最小コスト比較 |
| `Core/Tests/CoreTests/AutoMixedTests/ProtectedSpanDetectorTests.swift` | 50 fixture内のliteral／gap範囲、Unicode書記素、URL末尾・大文字直後の保護範囲、T1 engineとの安全な接続 |
| `Core/Tests/CoreTests/AutoMixedTests/PythonNumericalParityTests.swift` | 実行時にPythonから生成した期待値とSwiftを比較。入力がない通常のSwiftテストでは明示的にskip |
| `Tools/generate_auto_mixed_parity.py`、`Tools/test_auto_mixed_parity.sh` | 変更していないPython参照から325件の特徴量・スコアと372件の復号経路を生成し、Swiftテストを実行 |

`implementation_status.md`も更新した。既存golden・schema・reference・イベントfixtureの期待値は変更していない。

通常の`LogisticLanguageModel(data:)`は`kind=fixture`を必ず拒否する。fixture用initはinternalであり、`@testable`テストだけが利用する。公開APIに許可フラグや設定スイッチは設けていない。テスト内で作る`kind=production`のJSONも形式検証用の人工値で、配布資源や学習済みモデルとして保存していない。

語彙と特徴キーの対応にはUTF-8バイトを使い、Swift Stringの正規等価比較による語彙の合流を避けた。推論時に語彙を並べ直さず、active indexの昇順で係数を加算する。全128 goldenで特徴キー・active indexが完全一致し、logitとJA確率は絶対誤差`1e-12`未満だった。追加parityでは全ASCII制御文字、補助平面、結合文字、入力途中のprefixも比較した。

### T2の判断記録：理由と影響

1. **JA仮説はT4まで原文保持する。** 04章はViterbi後に標準ローマ字表で妥当性を検査する契約だが、そのadapterはT4に属する。`hypotheses(_:)`は推定JAを返し、T1が使う`segment(_:)`はJAを`unresolved`へ置き換える。実Converter未確認のrunを変換候補要求へ渡さないための段階的な境界である。T4では実検査を通ったrunだけ変換へ渡す。T2だけでは自動かな漢字表示にならない。
2. **保護tokenの境界を保守的に定めた。** 空白・山括弧・ダブルクォートでtokenを区切り、URLやパス等の構造があるtokenは全体をliteralにする。空白なしのファイル拡張子後やURL後のローマ字も保護され得る。これは仕様に記載された過剰保護の限界であり、`readme.mdwohiraku`の意図ラベルを自動成功の期待値へ変更していない。詳細な境界操作はT6。
3. **Swiftのヒントはhard maskにしない。** `Swift`の開始・終了位置を境界候補として返すが、`Swiftde`全体をRAW固定せず、Viterbiのresetにも使わない。camelCaseも一律に保護しない。ヒントを使った表示安定化や曖昧語の保留はT6に残る。
4. **有限入力からの算術overflowも拒否する。** schema上の各数値がfiniteでも、内積・校正・遷移コストの計算中にoverflowする場合はエラーを返す。参照実装が有限範囲で定める数値仕様は変えず、到達可能な復号経路のコストがすべて無限大になった場合の安全処理を追加した。T1 engineはエラー時に原文へ戻す。
5. **schema読込はDataの検証まで。** ファイル取得・bundle署名・モデル全体の外部SHA照合は実装していない。`training_manifest_sha256`は形式を検証するが、学習内容や品質の証明には使わない。配布時のモデルとmanifestの整合性確認はT3以降の資源統合で必要になる。

JSON schemaの制約とPythonの追加検証（語彙UTF-8順、`hold_ja <= enter_ja`）を両方適用した。ロジスティック回帰・特徴量・Viterbiの数式、tie規則、既存テストの期待値に仕様変更はない。

### T2の実行結果・環境制約

| 実行 | 結果 |
|---|---|
| 開始前`sh Tools/test_auto_mixed_core.sh` | T1の16件／3 suite通過。`build/auto-mixed/t2-baseline.log` |
| T2 source追加後、既存テスト | コンパイルと16件通過。`build/auto-mixed/t2-compile.log` |
| `sh Tools/test_auto_mixed_parity.sh` | T1＋T2の30件／7 suite通過。128 golden、325 fresh score、372 fresh path、560条件のbrute-force比較を含む |
| Core全体、native方式、parity有効 | **100件／9 suite通過**。ConverterServerもコンパイル・リンク成功。起動・登録は未実施 |
| Python reference unittest | 22件通過 |
| `reference/validate_bundle.py` | 50 span、128 golden、16 eventに加え、今回はJSON Schema Draft 2020-12検証も通過。環境に`jsonschema 4.26.0`が存在することを確認 |
| `shasum -c SHA256SUMS.txt` | 既存23エントリー一致。仕様一式・fixture・Python参照は未変更 |
| 静的確認 | 既存差分と追加11ファイルの空白検査、shell構文、Python ASTを確認。追加Coreにログ・ネットワーク・UserDefaults参照なし |
| 文書lint | natural-japaneseの`lint.py`は今回も`sudachipy`不足で失敗。手動チェックリストで通読した。実装テストとは別に残る環境制約 |

T2で実行したSwift・Pythonテストに失敗はなかった。モデル拒否や数値異常は、エラーになることを期待したテストとして通過している。`validate_bundle.py`が出す「Swift parity未実行」はそのPythonスクリプト単体の検証範囲を示す固定メッセージであり、上記の別ハーネスによるparity結果とは分けて記録した。

最終ログは`build/auto-mixed/t2-tests-final.log`と`build/auto-mixed/t2-core-final.log`。fresh parityの生成物は`build/auto-mixed/reference-parity.json`にあり、git管理には含めない。`event_cases.json`の`fixture-rejected`に相当する読込拒否はT2で検証したが、アプリの実効policyをmanualへ戻す接続試験はT5に残る。

Swift 6.4／Xcode 27／Python 3.11.9で検証した。既定SwiftPM方式のllama署名問題はT0のまま未解決で、Core全体はnative方式を継続した。ユーザー領域cacheへの書き込み警告、既存設定の非推奨警告、llamaの最低macOS version差は残る。SwiftLintは未導入で未実行。ユーザー設定を変更する`testOptionPunctuationMappings`1件も引き続き除外した。

このstageでは学習、精度・遅延・メモリ測定、実Zenzai、macOSアプリ全体のビルド、GUI、インストールを実行していない。RAW保護のテスト成功は英語破壊率やJA recallの達成を意味しない。

## T0・T1で実行した検証と失敗（2026-09-23）

| 検証 | 結果 |
|---|---|
| `git status --short`、`git rev-parse HEAD`、参照SHAとの`git diff`、`git submodule status` | 上記の現状を確認。追跡済みファイルへの差分なし |
| 初回`swift test --package-path Core`相当（隔離scratch/cache指定） | clang module cacheへの書き込み権限でmanifestコンパイル失敗。プロジェクト内へcacheを指定して解消 |
| 依存解決の初回再試行 | repository cache取得に失敗。ネットワーク取得を許可された実行で、固定依存を隔離領域へ解決できた |
| baselineのSwiftPM既定ビルド | `llama.xcframework`の署名を検証できず失敗。signature検証無効化、署名変更、依存の変更はしていない |
| baselineの`--build-system native` | **既存70テスト通過**。HEADのCoreを`git archive`で隔離コピーして実行 |
| T1単独の初回実行 | 16件中1件失敗。テストの期待UTF-16長を17と誤記していた。`今日は`3＋`Swift`5＋`で`1＋`API`3＋`を叩く`3＝15を確認して修正。表示期待文字列やfixtureは変更していない |
| T1単独の再実行 | **16件／3 suite通過**（SwiftPM既定方式）。ソース確認で見つけた、隣接編集後の再選択時に候補一覧が1件になる問題も修正し、2件を再選択できるテストを追加 |
| 変更後Core全体、native方式 | **86件／5 suite通過**。ConverterServerもコンパイル・リンク成功。起動・登録はしていない |
| Python reference unittest | **22件通過** |
| `reference/validate_bundle.py` | 50 span、128 golden、16 eventの意味・構造検証成功。`jsonschema`未導入のためJSON Schema検証は未実行 |
| `shasum -c SHA256SUMS.txt`（仕様ディレクトリ） | 全23エントリー一致。既存資料とfixtureを保持 |
| 差分・scriptの静的確認 | `git diff --check`、追加10ファイルの`git diff --no-index --check`、`sh -n Tools/test_auto_mixed_core.sh`を確認。空白エラーなし。新規Core内にログ出力・ネットワーク・UserDefaults参照なし |
| `xcodebuild -version` | Xcode 27.0を確認 |
| `xcodebuild -list -project azooKeyMac.xcodeproj` | 通常DerivedData／SourcePackagesへの書き込み権限で依存解決失敗。CoreSimulator接続警告も出た。schemeはXMLで確認 |
| 作業報告の文書lint | natural-japaneseの`lint.py`を試したが、`sudachipy`未導入で失敗。手動チェックリストによる通読で補った。Swift検証とは別の制約 |

既存テストの`testOptionPunctuationMappings`はAppGroup UserDefaultsを書き換えるため、baseline・変更後とも`--skip testOptionPunctuationMappings`で除外した。元へ戻すdeferはあるが、通常使用中の設定への一時変更も避けた。この1件は未確認であり、全既存テスト通過とは表記しない。

baseline・変更後とも、依存の辞書読込で任意のLOUDSファイル不足メッセージが出た。追加テストの出力ではない。既存のdeprecated設定警告、macOS 13指定とllama.frameworkの13.3最低versionの差も残る。native方式はSwift 6.4では非推奨であり、既定方式の署名問題を解決したことにはならない。

### T0〜T2時点の再実行コマンド

リポジトリルートから順に実行する。Core全体は依存解決済み環境を前提とし、T1/T2単独テストは外部Swiftパッケージに依存しない。fresh parityにはPython 3が必要で、後続のCoreコマンドもその生成物を使う。

```sh
sh Tools/test_auto_mixed_core.sh

# T2: fresh Python parityも含め、T1/T2を検証する。
sh Tools/test_auto_mixed_parity.sh

CLANG_MODULE_CACHE_PATH="$PWD/build/auto-mixed/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/auto-mixed/swift-cache" \
AUTO_MIXED_PARITY_PATH="$PWD/build/auto-mixed/reference-parity.json" \
swift test --package-path Core \
  --scratch-path "$PWD/build/auto-mixed/core" \
  --cache-path "$PWD/build/auto-mixed/cache" \
  --disable-sandbox --build-system native --skip testOptionPunctuationMappings

python3 -m unittest discover -s docs/auto-mixed/reference -p 'test_*.py' -v
python3 docs/auto-mixed/reference/validate_bundle.py
git diff --check
```

T0のbaseline用コピーは`mkdir -p build/auto-mixed/baseline`後、`git archive HEAD Core | tar -x -C build/auto-mixed/baseline`で作成した。当時のHEADは`b7ec0e4f27cf19d6a3aefa77d4b5ea7f2ebe5376`であり、再作成する場合はHEADの代わりにこのSHAを使う。`Core/Package.resolved`もコピーし、`--package-path`を`build/auto-mixed/baseline/Core`へ変更して実行した。T0のテストにT2 parityの環境変数は不要。

初回依存解決は、同じcache環境変数を付けて`swift package --package-path Core --scratch-path "$PWD/build/auto-mixed/core" --cache-path "$PWD/build/auto-mixed/cache" --disable-sandbox resolve`を実行した。ビルド・失敗のログは`build/auto-mixed/`の`baseline.log`、`baseline-retry.log`、`resolve.log`、`baseline-resolved.log`、`baseline-native.log`、`pure-tests.log`、`pure-tests-final.log`、`core-after.log`に残る。

## T2完了時点の未実行事項と次stageの前提

次はT3。`docs/auto-mixed/docs/04_MODEL_AND_DATA.md`、span schema、training config例を読み、権利を確認できるデータだけを使う学習・校正・評価パイプラインを作る。T2の特徴仕様とモデルschemaを固定契約として使い、元文章group単位のsplitとexport後のSwift parityを守る。学習用データの準備・権利確認・品質gateを満たさない限り、productionモデルや自動モード完成を宣言しない。

| stage／検証 | 残る作業 |
|---|---|
| T3 | 学習用データ・権利確認、学習CLI、独立test／calibration、productionモデル、精度評価・model card。T2の人工係数parityは学習完了を意味しない |
| T4 | 実Zenzai bridge、bulk composition置換、候補全文消費・suffix確認、previewと学習の分離。2入力session×複数JA spanで混線・解放・モデルロード数を実測する |
| T5 | policy／capability／mixed snapshot、event再送、commitIDとack、旧JSON互換、フォーカス拘束、ThinClientInputPipelineTests。今回のCore既存XPCテストだけで混在XPC統合済みとはしない |
| T6 | 区間指定・中央編集UI・256scalar上限・曖昧語保留・非標準入力表の退避、残るmock_core fixture |
| macOSアプリ | モデルsubmodule未取得。アプリ全体のbuild/test、実Zenzai、署名、GUI、入力欄・キーボード回帰は未実行。IMEを導入せずにできる隔離ビルド準備から再開する |
| CI差分 | Ubuntu未実行。SwiftLint実行ファイルが環境にないため、`swiftlint --quiet --strict`は未実行。後続CIで必要 |
| T7・T8 | 実測性能・精度・障害注入・配布ライセンス・識別子・署名と導入。今回の範囲外 |

通常使用中のIMEのインストール・削除・登録変更、LaunchAgent操作、プロセス終了、ユーザー辞書・学習データの変更は行っていない。追加Coreの実行時処理にはファイルI/O、ネットワーク通信、入力ログ保存を含めない。モデルは呼出側から渡されたDataを解析し、GGUFのロードは行わない。Python実行・fixtureの読込はテストハーネス内に限る。

## T3初回差分：任意の確定済み左文脈と特徴量v2

### 着手時の実物確認と資料との差分

| 項目 | 2026-09-24の確認結果 |
|---|---|
| HEAD | `bafcadc0f45aa0f869a9ea907bbc3d5c411d0ac7`。直前はT1の `8226975`、その前は参照commit `b7ec0e4f27cf19d6a3aefa77d4b5ea7f2ebe5376`。HEADは変更していない |
| T2実装 | HEADに特徴量、LR、Viterbi、保護検出、statistical segmenter、数値・brute-forceテスト、parity生成scriptが存在。コミット名だけで完了判定していない |
| 参照commitとの差分 | T1/T2の独立Coreとテスト・検証script・資料が追加されている。着手時まで既存manual／XPC／依存manifestは参照commitと同じ |
| 開始時のユーザー変更 | `git status --short` は `docs/auto-mixed/` の25ファイルが削除、`docs/auto-mixed-old/` と `docs/azookey_auto_mixed_codex/` が未追跡。ソースのユーザー変更はなし。移動を戻したり上書きしたりしていない |
| AGENTS | リポジトリと親階層に実ファイルは見つからず、依頼のAGENTS指示を適用。更新資料の `AGENTS.addendum.md` も読んだ。追記案を既存指示と誤認して新規AGENTSを生成していない |
| 読んだ資料 | `implementation_status.md` と更新資料の README、CODEX_START、CODEX_CONTINUE_AFTER_T2、02・04・05・06・09章。指定された `docs/auto-mixed/` 自体は存在しないため、対応する `docs/azookey_auto_mixed_codex/` を参照 |
| 旧資料の保存 | `docs/auto-mixed-old/` の25ファイルがHEADの旧パスとbyte一致。旧bundleの23 checksum、更新bundleの27 checksumも一致。両方の提供資料に変更なし |
| v1 schema | 新旧資料ともモデルは `schema_version=1`、`feature_spec_version=anchored-char-v1`、fixtureモデルは `kind=fixture`。更新版にもv2の実装・schema・学習済みモデルは含まれていなかった |
| v1 fixture | feature golden、model fixture、span cases、event casesは新旧でbyte一致。golden SHA-256は `d2d9f12b9b870dd744df9ae75ac09085b6a98c0e552c58f4771cb4d55da6b057` |
| v1実装と旧仕様 | T2コードにはmade/no/to/nameの無条件保留リストは存在しない。JA仮説を一律unresolvedへ戻すのはT4ローマ字検証が未実装なため。新仕様でもこの安全策とv1比較経路を保持 |
| 依存／環境 | Converter checkoutは `ad714fea8cb2fe113aea86ba5c42563cdaf77cfb`。manifest変更なし。GGUF・base_n5_lmのgitlinkはT0記載SHAのまま未初期化。arm64、macOS 27.0（26A428）、Xcode 27.0（27A266a）、Swift 6.4、Python 3.11.9を再確認 |

既存テストの資料パスだけを `docs/auto-mixed-old/` へ変更し、T2回帰を先に実行した。特徴量v1の生成規則、係数、golden、Viterbi、保護規則、期待値は変更していない。v1のcanonical escape関数はv2でも使うためprivateからinternalへ変更したが、出力は同じ。

### 変更したファイルと仕様の具体化

| ファイル | 変更内容 |
|---|---|
| `Core/Sources/Core/AutoMixed/LanguageJudgment.swift` | 新設の判定protocol、任意の文脈入力、明示的availability、30 scalar制限、不変request ID、結果の鮮度確認、raw表示用safeSpans。contextをCodableにせずdebug表示を伏せる |
| `Core/Sources/Core/AutoMixed/ContextualCharacterFeatures.swift` | v1キー＋文脈v2キー。rawとcontextを連結せず、末尾の文字・shape・空白／句読点／日本語文字・短n-gram・ASCII末尾語を追加 |
| `Core/Sources/Core/AutoMixed/LogisticLanguageModel.swift` | schema 2／v2の明示的な受理と型別score。v1/v2取り違えと不正な閾値を拒否。既存の内積・校正計算を共用。fixtureのproduction拒否も維持 |
| `Core/Sources/Core/AutoMixed/ContextualLanguageSegmenter.swift` | 既存LR／Viterbi／保護検出を利用。文脈なし・低信頼時のJA保留をartifactの閾値で指定。単語別のhard maskや保留分岐は追加しない |
| `Core/Tests/CoreTests/AutoMixedTests/ContextualLanguageTests.swift` | 新規10テスト。v1特徴包含、128 golden、788 fresh parity、文脈対照、空と欠損、Unicode、version拒否、閾値変更、保護、古いrequest識別 |
| `Tools/AutoMixedTraining/` | v2のPython参照、schema、人工fixture、固定golden、生成器、5テスト、正確なキー／境界／保留契約を記したREADME。学習CLIではない |
| 既存テスト3ファイル、`Tools/generate_auto_mixed_parity.py` | 利用者による旧資料の移動に合わせた参照パス修正のみ |
| `Tools/test_auto_mixed_parity.sh` | 従来のv1生成・検証を維持し、v2のfresh生成・検証を追加 |
| `azooKeyMac/InputController/azooKeyMacInputController.swift` | 左右の文脈本文をNSLogへ出す2行だけを除去。取得、manual変換、キー処理、XPC payloadは変更なし |

09章で未固定だったv2キーと境界を `Tools/AutoMixedTraining/README.md` に定義した。モデルschemaを2に分けた理由は、追加特徴と保留閾値をv1 artifactから明確に区別するため。v1はschema 1のまま読める。

保留の指標はrun内の平均p・最小pと、当該JA runだけをRAWへ置換した系列コスト差。文脈取得不可時には別の平均p閾値を用いる。値はモデルJSONから変えられ、単語名は判定条件に含めない。コスト差は隣接RAWとの切替罰則を含むが、系列全体の最良次点pathを求めるものではない。平均pもコスト差もspanの校正済み正解確率とは呼ばない。この限定は小さな差分で線形時間の比較を導入するためで、devでの採用可否は未評価。

新APIの `userOverrides` はT6、候補cacheと非同期XPC適用はT4〜T5に残した。今回の判定器はstatelessかつ同期で、文脈cacheを持たない。文脈のみの変化でも新requestを作れば旧結果を識別できることを単体試験したが、実アプリの遅延応答破棄を検証したことにはならない。採用済み候補を更新する処理も接続していない。

### 既存アプリの文脈取得経路

実在する経路は `currentConverterTextContext()` → `getLeftSideContext()`／`getRightSideContext()` → `ConverterKeyEventRequest.context` → `ConverterServer+KeyEvent` の `session.setContext(request.context)`。`ConverterTextContext` は左右それぞれoptional String、transport上限は200。サーバーの `ConverterSession.getLeftSideContext(maxCount:)` は `String.suffix` によりCharacter単位で切る。新仕様の30 Unicode scalarとは単位が違う。

クライアントはmarkedRangeを優先し、なければselectedRangeを使って `client().string(from:actualRange:)` を呼ぶ。activationGenerationによる応答の世代確認は存在する。一方、次の条件は現コードから安全と確認できなかった。

- 選択範囲が非空の場合のunavailable化。現在はその手前の本文も取得する。
- markedRange／selectedRangeが得られない場合の欠損表現。現在は位置0へ代替するため、成功した空文字と区別できない可能性がある。
- 取得actualRangeの検証、UTF-16境界、同一入力欄・現在の文脈であることの確認。
- セキュア入力時の明示的な取得抑止。既存OS経路が保護するとの推測だけでは新契約の保証にしない。

そのため、取得APIがあることだけを理由にv2へ渡す配線は追加しなかった。既存の文脈本文ログ2行は削除した。新APIは欠損が既定で、v1のraw-only経路も残る。実際のIMK取得許可・フォーカス・選択・セキュア入力の確認は未実行。新判定器に文脈保存・外部送信・本文hash記録はない。保存したgoldenは固定の自作テスト文字列であり、利用者の入力欄から採取したものではない。既存アプリ全体の動的なログ監査はT7に残る。

### 実行した検証と失敗

| 検証 | 結果 |
|---|---|
| 修正前のparity script | 失敗。資料移動でPythonが旧 `docs/auto-mixed/reference` をimportできなかった。`t3-baseline.log` に記録 |
| 参照パス修正後のT0〜T2回帰 | **30件／7 suite通過**。v2変更前のbaselineを `t3-v1-baseline.log` に保存 |
| v2実装後、既存テストだけのコンパイル・回帰 | **30件通過**。`t3-compile.log` |
| 新規Swiftテスト初回 | コンパイル失敗。throwするキー生成とScalarRange初期化に `try` が不足していた2か所を修正。期待値と許容誤差は変更していない。`t3-tests-first.log` |
| `sh Tools/test_auto_mixed_parity.sh` 再実行 | **40件／8 suite通過**。v1 128 golden・325 fresh score・372 decoder pathを維持。v2 128 golden・788 freshでキー／active index一致、logit／p差は1e-12未満。`t3-tests-second.log` |
| 変更後Core全体、native方式 | **110件／10 suite通過**。ConverterServerもビルド対象としてコンパイル・リンク。サーバー起動・登録なし。`t3-core.log` |
| Python旧reference | **22件通過**。`t3-reference-v1.log` |
| Python移行資料reference | **24件通過**。`t3-reference-migration.log` |
| Python新規v2検証 | **5件通過**。固定golden再現、対照group・prefix split漏洩拒否、欠損契約、不正context拒否、v2 schemaを検証。`t3-python.log` |
| bundle validators | 新旧とも意味検証とDraft 2020-12 schema検証成功（jsonschema 4.26.0）。旧50 span／128 golden／16 event、更新版は追加のcontext対照5件 |
| 資料保全 | 旧資料25ファイルのHEAD一致、旧23・更新27のSHA-256一致。v1 fixtureを再生成・上書きしていない |
| 静的確認 | `git diff --check`、shell syntax、変更アプリSwiftのfrontend parseを確認。新CoreにファイルI/O・ログ・ネットワーク・UserDefaultsの追加なし。アプリ文脈本文ログ2行の消失とmixed呼び出し未接続を確認 |
| 報告文のlint | natural-japaneseのlintを再試行したが、`sudachipy`未導入で実行失敗。報告は手動で通読した。コードテストの結果とは別の制約 |

検証ログはすべて `build/auto-mixed/` に保存した。Core全体では引き続き `testOptionPunctuationMappings` を除外した。この既存テストは使用中のAppGroup設定を書き換えるためで、期待値を弱めたり成功扱いにしたりしていない。

SwiftPM既定方式のllama署名問題はT0/T2から未解決で、今回もnative方式を使用した。署名検証の無効化や依存変更はない。SwiftLintは実行ファイルがないため未実行。アプリSwiftのparseは完全なXcodeビルドや実機試験ではない。

### T3初回差分時点の再実行手順

```sh
sh Tools/test_auto_mixed_parity.sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tools/AutoMixedTraining -p 'test_*.py' -v
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s docs/auto-mixed-old/reference -p 'test_*.py' -v
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s docs/azookey_auto_mixed_codex/reference -p 'test_*.py' -v
python3 docs/auto-mixed-old/reference/validate_bundle.py
python3 docs/azookey_auto_mixed_codex/reference/validate_bundle.py

CLANG_MODULE_CACHE_PATH="$PWD/build/auto-mixed/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/auto-mixed/swift-cache" \
AUTO_MIXED_PARITY_PATH="$PWD/build/auto-mixed/reference-parity.json" \
AUTO_MIXED_CONTEXT_PARITY_PATH="$PWD/build/auto-mixed/context-parity.json" \
swift test --package-path Core \
  --scratch-path "$PWD/build/auto-mixed/core" \
  --cache-path "$PWD/build/auto-mixed/cache" \
  --disable-sandbox --build-system native --skip testOptionPunctuationMappings
```

### 次に進める範囲と未実行事項

次はT3内のデータ・学習・校正・独立評価。今回のv1/v2契約を固定し、権利確認済みデータをgroup単位で分割して同条件で比較する。学習CLI、学習manifest／依存lock、productionモデル、model card、文脈有無・曖昧語・英語in日本語別の精度／保留率／反転回数／p95計測は未実装・未実行。fixtureの人工係数だけではT3完了にできない。

実Zenzai、複数入力session、IMK／XPC文脈取得、古い非同期応答、候補cache、表示ヒステリシス、実機GUI、セキュア入力、対象アプリ試験、署名／配布、Linux CIも未実行。未学習モデルをproductionとして同梱していない。既存アプリに混在モードの生成・dispatch・設定UIはなく、機能OFFを維持する。IMEのインストール・削除・登録変更、LaunchAgent操作、ユーザー設定・辞書・学習履歴変更は行っていない。

## T3準備差分：権利確認済みローカルデータ向け学習パイプライン

### 着手時の確認と範囲

開始HEADは `998fccdceb6cb22b6d14830bf5adafc76a2d0072`、作業ツリーはクリーンだった。以前のT3初回差分と資料移動はコミット済み。指定の `docs/auto-mixed/` は引き続き存在せず、対応する `docs/azookey_auto_mixed_codex/docs/04_MODEL_AND_DATA.md`、span/model schema、training config例と現在のv2 schemaを読んだ。AGENTS実ファイルは見つからず、依頼に添付された指示を継続適用した。

v1/v2の既存特徴量・モデルschema・golden・Core実行時処理は変更していない。変更対象は `Tools/AutoMixedTraining/` の学習ツール・文書、Swiftのオフライン検証テスト2ファイル、本記録。アプリ、manual入力、XPC、依存Swift manifest、IME登録は変更なし。新旧提供資料のchecksumも一致した。

### 実装した内容

| ファイル | 内容 |
|---|---|
| `Tools/AutoMixedTraining/pipeline.py` | validate-data、build-dataset、train、calibrate、export、evaluate。非ゼロ終了、出力上書き拒否、内容を含まない診断 |
| `pipeline_io.py` | JSON重複キー・NaN/Inf拒否、checksum、相対ローカル入力、依存lock確認、実行環境・実装SHA記録 |
| `dataset.py` | 原本と権利資料のhash／承認情報検証、元文groupと近重複の統合、分割固定、variant/prefix増強、派生データのsplit保持 |
| `swift_bridge.py` | 既存Coreを専用test processで呼び、生成したvariantの読み一致と全行の実保護maskを検証。本文処理中の依存DEBUG出力を抑止し、一時入力を削除 |
| `learning.py` | train限定語彙、float64疎行列LR、devでC選択、calibration限定sigmoid、devでdecoder／採用閾値選択、test評価とprefix再計算 |
| `fixture_manifest.json`、`training_config.json` | 提供fixtureのhashと検証用設定。fixtureとapprovedの経路を分離 |
| `approval_manifest.example.json` | 実データの承認記録の雛形。pending_review・未記入のままでは実行不可 |
| `requirements.lock` | 隔離Python環境の依存版を固定。配布物hash付きlockではない |
| `fixture_smoke.py`、`test_pipeline.py` | 全6 CLIのfixture動作確認、権利・漏洩・重み・収束・出力保護の回帰試験 |
| `Core/Tests/CoreTests/TrainingTests/AutoMixedTrainingBridgeTests.swift` | 固定Converterの実 `ComposingText` と `ProtectedSpanDetector` によるオフライン入力検証。Zenzaiは呼ばない |
| `Core/Tests/CoreTests/AutoMixedTests/TrainingExportParityTests.swift` | fitしたfixtureモデルのv1/v2各128ベクトル、Viterbi path、v2保護・保留21ケースのPython／Swift一致 |
| `Tools/AutoMixedTraining/TRAINING.md`、同README | CLI、承認manifest、分割・増強契約、環境、評価範囲、未実装部分を記載 |

学習用依存はプロジェクト内の `build/auto-mixed/training-env/` に導入した。Python 3.11.9、scikit-learn 1.9.1、NumPy 2.4.6、SciPy 1.17.1、jsonschema 4.26.0ほかをlockに保存した。取得したのはライブラリだけで、公開コーパス、入力履歴、追加モデルのダウンロードは行っていない。

### 権利・漏洩防止と仕様の具体化

approvedモードは、source_id、license_id、取得日、出典、用途、確認者・確認日、加工／group規則、プライバシー確認、原本と確認資料のSHA-256を要求する。レコードのprovenanceとの照合も行う。承認の記載と証拠の一致を検証する実装であり、ライセンス適合性を自動審査するものではない。実コーパスへの承認をこの作業で代行していない。

fixtureは原本からcheckpoint、export、評価までfixture扱いを維持し、productionへ昇格するオプションを設けていない。fit済みfixtureのSwift production読込も拒否される。実コーパスがないため、approvedモードの実学習は未実行。approved manifest検証の単体試験では、一時ディレクトリのテスト用承認記録を使い、実コーパス承認とは区別した。

分割は元文groupと近重複をまとめてから70/10/10/10で固定し、その後にvariantとprefixを生成する。同じrawの文脈対照、元文の表記違い・prefixは同じ分割を継承する。別splitの文と重複する増強文は除外して件数を記録する。語彙はtrainのみ、Cはdev、sigmoidはcalibration、decoder設定はdev、最終評価はtestだけを使う。位置sample weightは元レコードごとの合計を1にする。

原本用の `split=unassigned` は今回の入力契約の拡張。既存span schemaには追加せず、学習原本の入口だけで扱う。既にsplit指定された原本を黙って振り直さない。固定dataset/checkpointはhashで対応を確認する。これらは誤操作・改変検知用であり、署名による信頼保証ではない。

初期のvariant生成は標準表の母音終端・かな出力tokenの同義表記に限定した。理由はnや促音の内部規則をPythonへ複製しないため。shi/si、chi/ti、tsu/tu等を生成し、実Converterで変更run全体の読みが一致することを検証する。n・未完入力などは原本を保持し、増強を省く。prefixはASCII間の境界だけを使い、結合文字やZWJを途中で切らない。全Unicode書記素への増強は未対応。

`evaluate --traces` は今回、実打鍵ログの読込ではなくASCII原本の全prefix再生を行うフラグとした。各prefixの特徴と保護maskを再計算し、完成文の未来情報を流用しない。実アプリの打鍵ログを取得していないため、この限定を設けた。IMK・Zenzai・表示ヒステリシス・p95/RSSは未評価。v1/v2の保留条件も異なるため、smoke結果を同条件の品質比較とは扱わない。

### 実行した検証

最終の一連の成果物とログは `build/auto-mixed/training-final/`。内容はfixture由来で、権利確認済み本番モデルではない。

| 検証 | 結果 |
|---|---|
| 変更前のfixture形式・既存parity | 50 span＋5 context対照をschema検証。pure Core **40件通過**。`training-baseline.log` |
| 初回の依存導入 | sandbox内の名前解決でpip取得失敗。許可されたネットワーク実行で隔離venvへ導入成功。`training-install.log` と `training-install-network.log` |
| validate-data／build-dataset | 提供55原本を受理。48 groupを45成分へ統合し、成分はtrain32/dev5/calibration4/test4へ分割。55原本＋27 variant＋213 prefixの計295行、cross-split衝突の増強57行を除外 |
| 実Swiftによる増強検証 | 全variantの変更runが元runと同じ読みになること、全行の保護maskを実コードで確認。専用bridgeテスト **1件通過**。Zenzai推論・学習は未実行 |
| train／calibrate／export／evaluate | v1とv2で全CLI完走。train896位置、dev36位置、calibration16位置、test26位置の**fixture動作確認**。出力kindは両方fixture、評価区分はfixture_smoke_only、release_ready=false |
| test prefix replay | fixtureのASCII原本5件について各prefixを再計算。IMK打鍵や速度の実測ではない。反転数を品質改善の根拠には使っていない |
| Python全テスト | **16件通過**（既存5＋今回11）。test/calibrationのlabel変更がfit結果へ影響しないこと、testを除いても校正結果が変わらないこと、未承認・fixture昇格・group漏洩・非収束・既存出力上書きの拒否を検証 |
| fit済みfixtureのSwift parityを含むpure Core | **41件／9 suite通過**。各versionで128件のfeature/active index/logit/p、9 decoder path、追加のv2保護・保留21ケースを検証。logit/pの許容誤差は従来どおり1e-12未満 |
| 既存Coreを含むnative回帰 | **112件中111件成功、offline bridge 1件は専用環境変数なしでskip**。bridge自体は上記の別実行で成功。ユーザー設定を書き換える `testOptionPunctuationMappings` は従来どおり別途除外。`training-core-final.log` |
| 旧reference／移行資料reference | **22件／24件通過**。移行資料のvalidatorはschemaを含め成功。`training-reference-v1.log`、`training-reference-migration.log` |
| 静的確認 | Python全ソースのparse、tracked／新規ファイルの空白検査、新旧提供資料checksum一致。既存goldenやテスト期待値は変更していない |
| 報告文lint | natural-japaneseのlintは `sudachipy` 不足で失敗。報告を手動で通読した。学習・コード検証とは別の制約 |

学習経路の単体・結合テストに失敗はなかった。非収束は意図した負例としてエラーを確認した。Swift検証中に依存のDEBUG出力を確認したため、最終版では専用processの本文処理中にstdout/stderrを抑止した。最終ログにそのcomposition出力がないことも確認した。

SwiftPMの既定ビルド方式でのllama署名問題は未解決で、native方式を使った。通常のmacOSアプリbuild／GUI、Linux、SwiftLintは今回未実行。実学習データ、学習品質、モデルの配布適合性、実Zenzai、実入力欄の文脈取得、T7の性能・プライバシーgateも未検証。

### 次の作業

[学習手順](Tools/AutoMixedTraining/TRAINING.md) の承認manifestに、責任者が確認した実データと確認記録を指定すれば、fixtureと別の経路で準備を開始できる。少数fixtureのfit結果を本番モデルへ流用しない。十分な元文group、校正用の両class、独立testを揃え、注釈・権利・近重複を確認する必要がある。

次は実コーパスの用意とレビュー、その後の学習・校正・独立評価・失敗例分析。同条件のv1/v2比較とT4以降の統合が揃うまでT3完了や判別性能を宣言しない。機能OFFを維持し、通常使用中のIMEのインストール・削除・登録変更は行っていない。

## T3データ準備：人手確認用のAI作成サンプル50件（2026-09-24）

開始HEADは `1fff8acc5dedd96be8eb612075c9781a04cc982d`、作業ツリーはクリーン。依頼に沿って `Tools/AutoMixedTraining/review_samples/samples_50.jsonl` と [確認表](Tools/AutoMixedTraining/review_samples/REVIEW.md) を追加した。学習ツール・Core・アプリ・既存fixture・golden・schema・期待値は変更していない。

50件は日英混在16件、日本語7件、通常の英文6件、保護文字列4件、Unicodeを含む3件、文脈対照・取得不可・空文脈13件、日本語文脈中の英語1件。全件がAI作成の注釈案で、人手の確認結果やモデルの予測ではない。読み候補・意図表記・確認点を記載した。外部コーパスの取得、第三者の入力履歴の収集はしていない。文脈は自作の設定だけで、Swift検証へは渡していない。

`kind=authored` は未承認の作成原稿という扱いで、AIによる生成であることを各行のnoteと確認表に明記した。`rights_status=pending_review`、`split=unassigned` を維持し、承認manifestは作成していない。生成サービスの用途適合性・権利・プライバシーの人手確認は未実施。同梱fixtureから分離し、fixtureや本番モデルを作る経路へ混ぜていない。

同じrawの文脈対照と関連する英文は同じgroupへまとめ、全36 groupとした。035〜047のrawは既存fixtureと重複するため、既存fixtureから独立したtestには使えない旨を記載した。分割・ローマ字variant・prefix増強は未実施。後続で承認済み原本をgroup単位で分割してから増強する。

### 検証結果と修正

実行環境は既存のmacOS arm64、隔離Python 3.11.9環境と依存lock、固定Converter revision `ad714fea8cb2fe113aea86ba5c42563cdaf77cfb`。検証ログは `build/auto-mixed/review-samples-50/` に保存した。

| 検証 | 結果 |
|---|---|
| 原本の構造・範囲 | 50件を検査。既存原本専用拡張unassignedを検査用メモリ上のコピーでのみtrainに置換し、既存schema・連続被覆・scalar範囲・ID・文脈契約のvalidatorを通過。実際のsplit割当や権利承認ではない |
| group・文脈・Unicode | 同一rawのgroup一致、36 group、取得不可4対照と取得成功した空文脈の区別、絵文字の3 scalar・分解形アクセントの保持を確認 |
| 固定Converterとの読み照合・初回 | 既存 `AutoMixedTrainingBridgeTests` にJ区間のrawと期待かなを渡したところromanMismatchで失敗。切り分けで020・021・029・049の4件を特定 |
| 読み不一致への対応 | 期待かなは変更せず、020をsatsukisannniaimashita、021をkonnnyakuwokaimasu、029のJ区間をwokakuninn、049をhonnyakusuruへ修正。固定表のnn・ny・終端nの扱いに合わせた。初稿との差を確認表へ記載 |
| 修正後の実Swift検証 | 46 J区間すべてでrawのconvertTargetと期待かなが一致、全50行の保護mask生成も完了。専用bridgeテスト1件通過。かなを比較対象にした一括入力検証であり、漢字や言語判定の性能試験ではない |
| 未承認データの拒否 | CLIの直接入力はfixture schemaと不一致で拒否。チェック用の一時pending manifestではapproval/privacy review requiredで拒否。いずれも期待した非ゼロ終了で、本番学習は未実行 |
| 最終整合性 | JSONLと確認表の50 ID・全区間が一致し、全行未確認のままであることを確認。新規ファイルの末尾空白検査とgit diff --checkも通過 |
| 文書lint | natural-japaneseのlintはsudachipy不足で失敗。確認手順と表を手動で通読。追加の依存ダウンロードは行っていない |

SwiftPMは既存と同じnative方式を使用。user-level cacheへの書込不可とnative方式廃止予定の警告が出たが、修正後の専用テストは成功した。アプリコード変更がないためCore全体・実GUI・IME打鍵試験は再実行していない。人手による例文・読み・意図・権利の確認、学習・校正・独立評価は未実行。自動混在入力はOFFのままで、通常使用中のIMEのインストール・削除・登録変更は行っていない。

次は確認表の全50行を採用・修正・判断不可・除外に分け、特に固有名詞・日付・助詞、曖昧語と左文脈、保護する範囲を確認する。表の修正をJSONLへ反映して再検証した後、権利と注釈が確認済みの原本を増やす。この50件の作成や読み一致をもってT3完了・判別精度の達成とはしない。

## T3データ準備：ローマ字の別表記を増強（2026-09-24）

HEADは引き続き `1fff8acc5dedd96be8eb612075c9781a04cc982d`。開始時に残っていた50件の原本・確認表・TRAINING.md・本記録の変更を保持した。固定Converterは既にshi/si・tsu/tu等を受理しており、今回の対象は学習データの増強。Converter本体、既存manual入力、アプリ、v1/v2特徴量・LR・Viterbi・golden・schemaは変更していない。

### 増強方式と理由

`dataset.py` の候補生成を拡張した。以前は完全な母音終端tokenだけで分解できないJ区間を丸ごと省いていたため、wohozonshiteやsatsukisannniaimashita中のshi/tsuも取りこぼしていた。現在は固定表のnn/xnを境界として認識し、未解釈の途中子音をそのまま保つ。途中子音の直後で置換先の先頭子音が変わる候補は省く。生成後は従来と同じ実Swiftの厳密な読み比較を必須とし、不一致を無視する経路は追加していない。

置換はJA_ROMAN区間のみ。shi/si、chi/ti、tsu/tu、fu/hu、ji/zi、拗音・小書きx/lの代表的な表記群を候補にし、実際に固定表で同じかなになるものだけを使う。複数の区間・箇所を変えた代表例を先に、その後に一部だけ変えた例を作る。既定は元文あたり最大2件、設定上限は既存どおり8件。組み合わせの全列挙を避け、重複と256 scalar超過を除く。英語・literal・gap・曖昧区間、文脈、意図表記、group・split・provenanceは保持し、offsetを再計算する。

仕様の具体化として、固定表にある全同義キーを採用する従来方式から、代表的な表記群に限定した。少数データへca/ci/whu等の例が偏ることを避けるためで、実用頻度を測定した結果ではない。これらの入力をConverterから削除したわけでもない。増強データと選択順は変わるため、旧fixture学習結果との直接比較は行わない。表記別の実データ量・精度は今後検証する。アポストロフィ、大文字、未完末尾のJ区間は引き続き省く。

元文groupを分割してから増強し、派生行はsplitを継承する。別splitと衝突した派生行を除く処理は共通関数へ切り出し、確認用プレビューでも同じ処理を使う。元文ごとの合計sample weight 1、train限定の語彙、dev/calibration/testの役割は変更していない。

### 50件への適用結果と確認方法

`preview_roman_variants.py` を追加し、pending_review・unassignedの原本からだけ確認用プレビューを作れるようにした。groupを仮分割してから生成し、実Swift検証に通った後に、新規ディレクトリへpreview.jsonと確認表を保存する。本文・左文脈を診断ログへ出さず、文脈はSwiftへ渡さない。出力済みディレクトリは上書きしない。

[派生一覧](Tools/AutoMixedTraining/review_samples/roman_variants/REVIEW.md) は元の50件＋別表記13件の計63件、cross-split衝突除外は0件。全件pending_reviewを維持した。原本JSONLは変更していない。preview.jsonは `kind=review_preview`、`training_eligible=false` であり、学習用sealed datasetとして受け入れられない。仮分割を本番の分割と見なさず、学習時は承認済み原本全体から再構築する。プレビューを原本へ連結して二重増強しない。

### 検証結果・制約

| 検証 | 結果 |
|---|---|
| 50件の増強プレビュー | 実Converterで13派生行の変更区間が元区間と同じ読みになることを確認。63行の保護mask、schema・scalar範囲、原本hash・preview checksum、group継承を検証 |
| Python最終回帰 | **25件すべて通過、skipなし**。別表記の双方向性、複数箇所の代表例、n・促音、Unicode offset、非J区間と文脈の保持、件数制限、split前生成の防止、漏洩除外、未承認・既存出力の拒否、元文重みを検証。`roman-augmentation-tests-final.log` |
| 別表記群の実Swift照合 | 78入力ケースから作った**106派生ペア**が実Converterで同じ読みになることを確認。小書きx/l、拗音、n・促音を含む。既存の厳密比較を使用し、期待値・誤差許容は変更なし |
| fixture全CLI smoke | validate-data、build-dataset、v1/v2のtrain・calibrate・export・evaluateが通過。55原本＋10 variant＋232 prefix＝297行、別splitと衝突した派生55行を除外。全出力はfixture、release_ready=false。`build/auto-mixed/roman-augmentation-smoke/` |
| Swift parityを含むpure Core | **41件／9 suite通過**。既存v1/v2 golden、fit済みfixtureの数値・decoder・保護／保留の一致を維持。`roman-augmentation-smoke/swift-parity.log` |
| 文書lint | natural-japaneseのlintを試行したがsudachipy不足で失敗。追加部分と確認表を手動で通読。依存追加や外部データ取得は行っていない |

学習・増強に関する検証の失敗はなかった。最初のPython実行ではfit用の3件を専用環境変数なしでskipしたが、最終実行では新しいSwift照合を含め全25件を実行した。テスト用の出力上書き拒否は期待どおりのエラーである。

Swiftは既存のnative方式を使用し、既定方式の署名問題は未解決。通常使用中のIME、アプリ設定、辞書、登録は変更していない。実入力欄、キーイベントの逐次入力、実Zenzai、本番コーパスでの学習・校正・独立評価、実用頻度や品質向上の測定は未実行。自動混在入力はOFF、T3全体は未完了。次は元の50件と派生13件の人手確認、権利承認、その後の確認済み原本の拡充となる。

## サンプル63件の内容確認完了（2026-09-24）

利用者から「サンプルデータは全件オッケーです。」という返答を受け、原本50件とローマ字別表記13件を全件採用として記録した。確認表の判定を更新し、`Tools/AutoMixedTraining/review_samples/annotation_review.json` に確認者（この会話の利用者）、日付、返答、対象ID、対象ファイルのSHA-256を保存した。個別の修正指示はなかったため、raw・ラベル・読み候補・文脈・group・splitを含む原本JSONLとpreview.jsonの内容は変更していない。

AMBIGUOUSの5件は、意図を固定しない評価用例として採用した。JA/RAWへ強制変更せず、binary学習から除外する契約を維持する。原本noteは作成時の記録として残し、現在の内容確認状態はhash付きの確認記録を正とする。将来内容を変えた場合に、今回の採用を自動継承しない。

今回の返答は内容・注釈の確認として記録し、生成サービスの利用条件や権利確認の証拠を補ったことにはしない。provenanceのrights_statusはpending_review、previewのtraining_eligibleはfalseを維持した。学習用の権利確認manifestは未作成で、次は利用条件と許可用途の記録を整える。学習・校正・品質評価、IMEの変更は実行していない。

確認記録の63 ID、2ファイルのSHA-256、確認表の50＋13件の採用判定、preview checksum、AMBIGUOUS 5件と権利statusの維持を検証し、git diff --checkも通過した。データ本文・実行コードの変更はないため、モデル学習やCoreテストは再実行していない。文書lintはsudachipy不足で失敗し、更新箇所は手動で通読した。

## 承認済み50原文の学習と確認UI（2026-09-24）

**v1/v2のLRを学習し、自由入力と正解例を比較するローカルUIを作成した。校正はデータ不足で停止しており、実用モデルの完成・T3完了とはしない。** 起動手順と結果は [REVIEW_UI.md](Tools/AutoMixedTraining/REVIEW_UI.md) に記載した。

開始時のHEADは `52715a39ffcb1c709332e701bb3fc61bf7074146`、git statusはclean。ファイルとしてのAGENTS.mdは見つからず、会話の指示を適用した。T0〜T2、v1/v2特徴量、LR、Viterbi、golden、学習・モデルschema、依存revisionを変更していない。アプリからMixedCompositionEngineを構築する経路も追加していない。

### 権利承認を反映し、fixtureと分けて学習

利用者の「データの権利は大丈夫なので、学習して。学習した結果を確認するUIツールを作って欲しい。」を [RIGHTS_REVIEW.md](Tools/AutoMixedTraining/approved_samples/RIGHTS_REVIEW.md) に記録した。これは利用者による承認であり、第三者の法的審査を代行したという記録ではない。確認用原本とannotation_review.jsonのhashを保持し、provenanceだけを変更した承認済みコピーを作った。raw・ラベル・読み・架空の文脈・group・splitは元の50件と一致する。

同梱fixtureで形式・parityを確認した既存パイプラインに、承認済み原本50件だけを渡した。確認用の派生13件を原本へ連結していない。外部コーパス・入力履歴を取得せず、既存の隔離venvを使用した。

seed=20260924で36 groupをtrain/dev/calibration/testへ25/4/4/3 groupに分割した。原文数は31/7/9/3件。分割後の増強で原文50＋variant 13＋prefix 246＝309行となり、別splitと衝突した派生53行を除外した。元文単位の合計sample weight 1、train限定の語彙、devでのC選択、独立したcalibration/testという役割を維持している。

両モデルともC=10を選択し、1,875位置でfitが完了した。v1の語彙は10,066、v2は10,176特徴。校正原文の採点対象はJA 45位置・RAW 36位置で、既存のapproved条件「各100位置以上」に届かず、両方とも `calibration partition has insufficient examples of both labels` で停止した。最低件数や期待値は変更していない。sigmoid校正、devでのdecoder・閾値選択、runtime exportは未実施。checkpointは `phase=fitted` / `release_ready=false`。既存schemaの `kind=production` は承認済み候補の識別名として残るが、本番品質を表すとは扱わない。

初回成果物は `build/auto-mixed/approved-50-20260924/` のdataset、v1/v2のconfig・fitted checkpoint・calibration_status、report.json。新しい `train_review.py` でも同じ手順を実行し、`build/auto-mixed/approved-50-review-20260924/` に別保存した。dataset、語彙、係数、初期設定、fit指標は初回と完全一致。ソースの追加・修正に伴う環境manifestの実装hashとmodel_versionの差はある。出力済みのモデル・評価は上書きしていない。

### 未校正の結果を診断用として表示

test原文3件・56採点位置では、JA再現率はv1が22/41（53.7%）、v2が0/41（0%）。保留率はv1が21/56（37.5%）、v2が43/56（76.8%）。英語span破壊は両方0/4だが、Wilson 95%区間の上限は49.0%と広い。Brierはv1が0.09119、v2が0.09152だった。v2は保留が多く、このtestで日本語を採用していない。少数の自作例、未校正スコア、v1/v2の条件差を含むため、曖昧語の実用性能・文脈による改善・安全性を主張しない。

仕様上の追加は、未校正checkpointにも限定的な確認UIを用意したこと。理由は、校正不足を隠さず、次に必要なデータや失敗例を確認できるようにするため。公式のexport/evaluateは引き続きcalibrated checkpointを要求する。UI用reportは `approved_small_sample_diagnostic` とし、校正の成否、分母、保留、信頼区間、非リリース状態を明示する。testを人が閲覧済みになる影響があるため、今後の調整後に独立した新しいtestが必要になる。

UIは例文選択、自由入力、短い左文脈、文脈取得不可と空文字の区別、書記素単位のprefix、v1/v2の区間と文字スコア、区画別の診断値・不一致例を表示する。既存Python scorer・decoderを利用し、保護範囲は実 `ProtectedSpanDetector` をコンパイルした専用Swift bridgeで取得する。Zenzai・XPC・IMEは呼ばない。自由入力の未来suffix、正解・意図表記を判定へ渡さない。

任意入力のraw・左文脈はPOSTで受け、サーバーログ・ファイル・ブラウザー保存領域へ記録しない。応答にも本文・文脈・特徴キーを含めない。Swift bridgeへ文脈を渡さず、rawだけをstdin経由で渡す。サーバーは127.0.0.1限定、Host/Origin検査、固定assetの配信、no-store。外部通信・CDN・テレメトリは使わない。承認済み学習例と架空の文脈は、明示的に渡された学習データ・静的レポートとして保存する。

### 実行した検証、失敗、環境制約

| 検証 | 結果 |
|---|---|
| 権利・原本・分割・増強 | 承認manifestの原本／証拠hashとschema検証を通過。原本50件のprovenance以外が不変。309行のgroup／split・近重複キーの漏洩なし、元文重み1を確認。build-datasetの実Swift読み照合も通過 |
| 初回fitと再実行CLI | v1/v2のfit成功。新CLIでもdataset・語彙・係数・設定・fit指標が完全一致。既存出力とfixture入力の拒否も検証 |
| 校正 | v1/v2とも各class 100位置条件で停止。失敗理由と45/36位置を保存。未校正checkpointの公式export/evaluate拒否も確認 |
| Python最終回帰 | **34件すべて通過、skipなし**。既存25件＋新規9件。ログは `build/auto-mixed/approved-50-review-tests.log` |
| UI推論の一致・Core連携 | 全50原文のライブ予測が静的reportと一致。全309行で実Core保護maskがdatasetと一致。URLの途中prefix、絵文字・結合文字、v1の文脈非依存、入力・文脈の非保存を検証 |
| HTTP | 127.0.0.1の一時ポートでreport／推論応答、Host/Origin拒否、asset範囲、JSON・入力長エラー、no-store、入力とアクセスログの非出力を確認 |
| 実ブラウザー | Codex内ブラウザーで例文切替、madeの左文脈変更／未取得、自由入力、空文脈、31 scalarのエラー、ZWJ・結合文字を切らないprefix、校正区画9件の表示を確認。検査時のconsole error/warnは0件。表示幅557pxの画面を目視確認 |
| テスト作成中の失敗 | 新規テストのクラス属性runがunittest.runと衝突し、実行前にTypeError。review_runへ改名。次に原本比較テストでloaderによる検証用split=trainと保存済みunassignedを混同して1件失敗。保存済み原本同士を比較するよう修正し、provenance以外の完全一致という期待値は維持。最終34件は通過 |
| その他の実行エラー | report作成後の一時集計コマンドに括弧不足がありSyntaxError。修正して集計を取得し、学習成果物は影響なし。ブラウザー操作ツールの空文字fillで入力が消えず待機が失敗したため、実欄を確認して全選択・削除で空文脈を再検証 |
| 実行環境 | macOS 27.0 arm64、Swift 6.4、Python 3.11.9。既存requirements.lockのscikit-learn 1.9.1／numpy 2.4.6等を使用。sandbox内の初回サーバーbindはPermissionErrorで停止し、ローカル待受けを許可した実行で起動・HTTP検証が成功。プロセス確認用psもsandboxで拒否されたが、作成したサーバーの起動セッションで停止・再起動を確認 |
| 文書・静的検査 | node --check、git diff --checkを通過。natural-japaneseのlintはsudachipy不足で失敗したため、追加文書を手動で通読。依存ダウンロードは行っていない |

最終回帰のコマンドは次のとおり。fixtureのfitテスト用datasetと、承認済みモデルのUIテスト用runを別々に指定する。

```sh
PYTHONDONTWRITEBYTECODE=1 \
AUTO_MIXED_TRAINING_DATASET=build/auto-mixed/roman-augmentation-smoke/dataset.json \
AUTO_MIXED_REVIEW_RUN=build/auto-mixed/approved-50-20260924 \
build/auto-mixed/training-env/bin/python -m unittest discover \
  -s Tools/AutoMixedTraining -p 'test_*.py' -v
```

承認済みモデルのSwiftスコアexport parityは校正未完了のため未実行。既存Coreの変更がないためpure Core全41件は今回は再実行せず、前回の通過記録を維持する。今回の309行の保護maskと別表記の読みは実Swiftで検証した。実機IME打鍵、実Zenzai、XPC/IMK、表示ヒステリシス、実入力欄の文脈取得、p95・メモリ、十分な独立品質評価は未実行。通常使用中のIMEのインストール・削除・登録・設定変更は行っていない。機能はアプリ未接続でOFF、T3全体は未完了。

次は承認済みの独立元文groupと文脈対照を増やし、新しいデータ版で分割・学習・校正へ進める。最低100位置を満たすための校正例複製やtestからの移動は行わない。今回閲覧したtestに合わせた閾値調整も避ける。十分な独立testと条件を揃えたv1/v2比較、その後のT4以降の実機評価が残る。

## 700原文への拡充とデータ量の診断（2026-09-24）

**Codex作成650件を追加し、旧50件を保持して700原文で学習・校正した。実用十分な量・品質とはしない。** 仕様04章の最初の500〜1,000件という計画値に沿って拡充したが、追加分の人手確認は未実施。作成方針・次の件数目標・確認箇所は [DATA_PLAN.md](Tools/AutoMixedTraining/synthetic_expansion/DATA_PLAN.md)、全追加例は [確認表](Tools/AutoMixedTraining/synthetic_expansion/generated/REVIEW.md) に記載した。

開始HEADは `899fca42ec64c5da5ab5e24ade190c709d48fcda`、git statusはclean。AGENTS.mdの実ファイルは見つからず、会話の指示を適用した。既存04/05章、学習パイプライン、固定Converterの実APIを確認。T0〜T2、v1/v2特徴量、LR、Viterbi、golden、span/model schema、依存revision、manual入力は変更していない。機能フラグはOFF。IMEのインストール・削除・登録・設定変更は行っていない。

### 作成した例と仕様への追加

`author_expansion.py` と明示した原稿から650件を作った。混在250、日本語100、英語140、短い検索語30、保護・Unicode30、20曖昧語×5条件100件。一般文を単語の直積で複製せず、各文章を原稿へ記述した。文脈はこのタスクで作った架空のものだけ。実入力や実アプリの文脈を収集・記録せず、外部コーパスもダウンロードしていない。用途の許可は今回の追加作成指示に基づき、旧50件の全件承認を新650件の人手確認へ拡張解釈していない。

同一rawの文脈対照は一つのgroupにまとめる。取得不可／取得した空文字の40件はAMBIGUOUSとしてbinary学習から除外する。made/no/to/name等の無条件保留は追加していない。人には文脈100件と保護範囲30件を優先して確認してもらい、残りも用途別に点検する。

既存testをtrainへ動かさないため、dataset builderと `train_review.py` に任意のbaselineを追加した。旧原文・mode・seedを検証し、旧groupのsplitを固定。異なる旧splitをつなぐ追加例は拒否し、新規成分だけを配分する。sealed datasetの任意metadata `baseline_dataset_sha256` / `frozen_group_splits` が増えるが、span/model schemaは変更しない。baselineを渡さない既存経路も維持する。

その後、既存のローマ字variantとprefixを増強する。trainだけで語彙を作り、元文単位の合計sample weight 1を維持した。UIの「人が承認した例」と誤読し得る表示を「用途承認済みの原文」「収録されている例文」へ修正した。権利承認と注釈確認を区別するための変更で、判定処理は同じ。

### 分割・学習・校正の結果

最終出力は `build/auto-mixed/expanded-700-se-20260924/`。dataset SHA-256は `b5bd29bbf48da0b2f57f3152be2eb85bb8b2e7df1c501fd8248d5009754a707e`。606のsource groupを同一raw・近重複で602成分へまとめた。旧50原文と旧splitは完全一致。

| 区画 | 成分 | 原文 | 増強後 | 原文のJA位置 | 原文のRAW位置 |
|---|---:|---:|---:|---:|---:|
| train | 421 | 481 | 2,728 | 6,900 | 4,560 |
| dev | 61 | 77 | 393 | 1,033 | 545 |
| calibration | 61 | 79 | 411 | 953 | 628 |
| test | 59 | 63 | 375 | 960 | 748 |

700原文＋405 variant＋2,802 prefix＝3,907行。別splitと衝突する派生1,345行を除外した。両モデルはdevでC=10を選択、語彙32,768。校正の最低条件JA/RAW各100位置を変更せず満たし、sigmoid校正・devでの採用条件選択・runtime exportを完了。phase=calibratedだがrelease_ready=false。

| testの指標 | v1 | v2 | 仕様の目標 |
|---|---:|---:|---:|
| JA再現率（保留は見逃し） | 648/960 = 67.5% | 4/960 = 0.4% | 90%以上 |
| JA適合率 | 100% | 100%（採用4位置のみ） | 98%以上 |
| 英語span破壊率 | 0/158 | 0/158 | 0.5%以下 |
| 破壊率Wilson 95%上限 | 2.37% | 2.37% | 標本数・区間も評価 |
| 境界F1 | 0.702 | 0.000 | 0.90以上 |
| 保留率 | 307/1,708 = 18.0% | 959/1,708 = 56.1% | 全raw維持を成功としない |
| Brier | 0.02100 | 0.01790 | 参考診断 |

v2は既存のdev探索でenter_ja=0.95、enter_ja_without_context=1.0、minimum_ja=0.55、minimum_path_margin=1.2が選ばれた。文脈なしの再現率は0。既存の `min(1, enter_ja + 0.07)` という候補生成が保留を増やす条件になっている。文脈ありのtestはJAわずか4位置・1語族であり、そこでの正答を文脈性能の証明にしない。スコアが改善しても採用条件が実用性を制限し得るため、追加データだけで解決したとは扱わない。

旧50件とはtestの母集団・校正状態が異なるので、旧診断値との単純な精度向上比較はしない。今回のtestも閲覧済み。係数・閾値・期待値をこの結果に合わせて変更していない。次の開発はdevを使い、改善後の判定には未閲覧の独立testを用意する。現在158英語spanで、仕様の評価開始目安2,000spanには不足している。

### データ量の診断と実測時間

v2・C=1.0を固定した別の診断では、入れ子のtrain成分だけを使って語彙・LRを作り直し、固定dev原文でlog lossを測った。校正・復号閾値・test採点は行わず、学習曲線用のJSONだけを保存した。

| train成分 | train原文 | dev log loss |
|---:|---:|---:|
| 100 | 124 | 0.23735 |
| 250 | 298 | 0.17195 |
| 421 | 481 | 0.14620 |

この範囲ではデータ追加に伴いdev誤差が下がった。ただし単一seedの自作分布であり、1万件ならどの精度になるかは未確認。次の拡充計画は1万原文を目安にし、先にv2の採用条件と注釈を点検する。実用判定は件数でなく05章の品質・安全・性能基準で行う。

今回から `perf_counter` の実測を各runのtimings.jsonへ保存する。最終実行は前処理・dataset保存6.42秒、v1 fit・保存15.55秒、v2 fit・保存15.16秒、校正・export・確認report27.23秒、合計64.48秒。後続の公式評価、size診断、parity、UI検証、手作業のデータ作成時間は含めない。同時に実行したsize診断などの負荷もあるため、一般的な所要時間の保証には使わない。旧50件へこの時間を遡及して記録しない。

### 実行した検証、修正、残る制約

| 検証 | 結果 |
|---|---|
| 原本検証 | 新650件のschema・区間・hash検証、553か所の日本語を実Converterで読み照合。生成物と原稿の一致、旧50件の不変、分割後の漏洩検査を通過 |
| Python回帰 | 既存34＋追加8の **42件すべて通過、skipなし**（11.208秒）。旧50件のUI・HTTP・非保存回帰も維持。`build/auto-mixed/expanded-700-se-tests.log` |
| Swift回帰・export parity | **42件／9 suite通過**（1.409秒）。既存fixtureのproduction読込拒否を維持し、今回の校正済みv1/v2を通常loaderで読んでキー・active index・logit・p・復号を照合。数値許容誤差1e-12は不変。`build/auto-mixed/expanded-700-se-swift-parity.log` |
| 公式評価 | v1/v2とも `pipeline.py evaluate --traces` 成功。各evaluation.jsonへ用途別・文脈別診断を保存。ASCII原文62件・連続prefix 1,771step、過去位置反転数v1=1,702／v2=226。Unicode原文1件は未replay。IMKの打鍵試験ではない |
| 表記修正 | 最初の新規テストで「こんにちは」がconnnichihaとなり失敗。期待値を変えず生成側をka/ki/ku/ke/koへ修正。後のUI確認でせ→ceを発見し、seを優先する回帰を追加。実Converterでは両方有効だが、一般的な打鍵例を作る目的に合わせて修正した |
| 修正前の保存 | 最初のrun `expanded-700-20260924/` と、ceを含むrun `expanded-700-canonical-20260924/` をbuild配下に保持。ce版はv1再現率75.1%・61.79秒だったが最終結果へ採用しない。se修正後も全606 source groupのsplitは同一。閲覧後の表記修正なので、独立した新testでの再評価とは扱わない |
| 一時集計エラー | 学習終了前にtimings.jsonを読むコマンドがFileNotFoundError。学習自体は継続・完了し、終了後に実測値を取得した |
| 最新UI | 127.0.0.1:8766で700原文・3,907行・校正済み表示を確認。calibrationのmade対照で、v2は日本語文脈ならJA 4位置、英語文脈ならRAW 4位置。これは収録例の配線確認であり性能評価とは別。console error/warn 0件、幅557pxで表示を目視確認 |
| 静的検証 | git diff --check、node --check、Python AST、manifest／原稿hash／sealed datasetの照合を通過 |
| 文書lint | natural-japaneseのlintはsudachipy不足で失敗。依存を追加取得せず、手動チェックリストで追加文書を通読 |

回帰再現用のPython環境変数は、既存の `AUTO_MIXED_TRAINING_DATASET=build/auto-mixed/roman-augmentation-smoke/dataset.json` と `AUTO_MIXED_REVIEW_RUN=build/auto-mixed/approved-50-20260924` に、新たに `AUTO_MIXED_EXPANSION_RUN=build/auto-mixed/expanded-700-se-20260924` を加える。unittest discoverのコマンドは前節と同じ。Swift parityにはfixtureのv1/v2 exportを従来どおり指定し、追加の `AUTO_MIXED_APPROVED_EXPORTS` に今回の `v1/export:v2/export` のパスを指定する。

環境はmacOS 27.0 arm64、Swift 6.4、Python 3.11.9、既存のrequirements.lock。SwiftPMは既存のnative方式を使用し、既定方式の署名問題を解消したわけではない。ローカルHTTPテスト・UIはsandbox外の127.0.0.1待受けを許可して実行した。パイプラインと本タスクで外部コーパスや追加依存は取得していない。

未実行：新650件の人手確認、実ユーザー分布の独立評価、2,000英語span以上の新test、複数seedによる量の検証、条件を揃えたv1/v2 ablation、実Zenzai、実機IME、XPC/IMK接続、実アプリからの文脈取得、表示ヒステリシス、p95・RSS測定、アプリ全体のビルド。T3全体の完了・本番性能は主張しない。

次は文脈なしv2の閾値候補とdevの選択目的を点検し、人手確認済みの文脈対照・用途別原文を増やす。v1/v2・旧golden・凍結splitを保持し、閾値や特徴量を変える場合は理由と影響を別の小差分に記録する。実Zenzai統合はT4として分離する。

## 文脈別の閾値を独立探索（2026-09-24）

**独立探索を実装し、文脈あり0.90・文脈なし0.98の試験用候補を保存した。devの保留率は65.8%から21.9%へ改善したが、品質目標を満たす候補はなかった。** 条件・結果・再現コマンドは [THRESHOLD_SEARCH.md](Tools/AutoMixedTraining/THRESHOLD_SEARCH.md) に記録した。今回の値は同じdev上の比較であり、前節のtest値とは比較しない。

開始HEADは `58a115d345d1c24e17382b48786f880fdefeca00`、git statusはclean。会話のAGENTS指示、実装状況、06章のT3/T4/T6境界、前ターンで確認した05章の品質目標を適用した。変更はToolsの学習処理・設定・CLI・新規テストと文書のみ。Core、モデルschema、v1/v2特徴量、LRの学習式、Viterbi、golden、原文・分割・権利資料、依存、manual入力は変更していない。

### 実装と仕様差分

`learning.py` に文脈別の閾値候補生成と共通探索を追加した。学習設定のschema_versionを2へ進め、`missing_context_increment` に代えて `enter_ja_without_context_grid` を要求する。`enter_ja_grid` との組み合わせから `enter_ja <= enter_ja_without_context < 1` を満たす組だけを使う。新設定は1.0や無効な組み合わせを拒否する。旧設定version 1の加算方式は凍結済みcheckpointの再現用に残し、黙って新方式へ変更しない。

理由は、旧方式でenter_ja=0.95を選ぶと文脈なしの閾値が1.0となり、日本語をほとんど採用できなくなるため。影響は新設定で生成する候補の範囲とfitted checkpointの初期閾値。runtimeに必要な2閾値は既存のモデルschema 2にあるため、モデルschema・Swift読込・判定器に変更はない。取得した空文字と文脈未取得の区別も維持する。

`pipeline.py tune-thresholds` は校正済みモデルと同じsealed datasetを要求し、係数・語彙・切片・sigmoidを固定してdevだけで探索する。変更可能な設定を閾値グリッドに限定し、seed、fit設定、最低文字スコア、path margin、hold値、切替ペナルティ候補の変更を拒否する。元のfit・校正manifestは履歴として残し、親checkpoint SHAと新探索の設定・実装hash・選択結果を別項目へ保存。新しいモデルIDとmanifest hashでexportする。

選択の優先順は従来の英語破壊率0.5%制約とJA再現率最大化を維持した。全候補の指標と、仕様のJA再現率90%・適合率98%・境界F1 0.90・英語破壊率0.5%への未達項目を追加保存する。合格候補数とrelease_readyを区別し、0件のときは診断用候補として明示する。判定スコアをプロセス内だけで再利用し、キャッシュ有無の数値一致も検証。入力本文・左文脈を探索ログや集計へ追加記録しない。

### 同じdevでの比較

700原文版のdataset SHA `b5bd29bbf48da0b2f57f3152be2eb85bb8b2e7df1c501fd8248d5009754a707e` を固定した。語彙・係数・校正値の完全一致を確認。devは77原文・61成分・JA 1,033位置・RAW 545位置・英語115区間。

最初は文脈あり[0.90, 0.95, 0.99]、文脈なし[0.90, 0.95, 0.97, 0.99]の有効8組と、既存の切替ペナルティ5通りを比較した。40候補から0.90／0.99・切替0を選び、JA再現率48.1%、保留34.9%、英語破壊0/115。全4目標の合格候補は0だった。

次にdevだけで文脈なし候補を[0.90, 0.95, 0.97, 0.98, 0.982, 0.984, 0.986, 0.988, 0.99, 0.995]へ増やし、21組×5＝105候補を比較した。先の候補との重複を含む。同じdevを使った詳細探索であり、独立した確認評価ではない。

| devの指標 | 旧v2 | 詳細探索の候補 | 仕様目標 |
|---|---:|---:|---:|
| 文脈あり／なし閾値 | 0.95／1.00 | 0.90／0.98 | devで選ぶ |
| JA再現率 | 10/1,033 = 1.0% | 702/1,033 = 68.0% | 90%以上 |
| JA適合率 | 100% | 100% | 98%以上 |
| 英語span破壊 | 0/115 | 0/115 | 0.5%以下 |
| 境界F1 | 0.000 | 0.652 | 0.90以上 |
| 保留率 | 1,038/1,578 = 65.8% | 346/1,578 = 21.9% | 全保留を成功としない |

英語制約内は80/105候補、全4目標の合格候補は0。最低文字スコア0.55、path margin 1.2、hold_ja 0.65は不変。文脈なし再現率は692/1,023 = 67.6%。文脈ありは14原文中JA 10位置・RAW 18位置だけで、0.90と0.95は同点だったため0.90を選んだ。文脈あり閾値の最適性を裏づける十分なデータはない。

0/115の英語破壊率のWilson 95%上限は3.23%。既存v1の同じdevではJA再現率72.2%・境界F1 0.769・英語破壊0/115で、今回のv2の優位性も示していない。さらに閾値を下げた0.90／0.97はJA再現率81.4%だが英語破壊3/115となる。品質目標を緩めて採用していない。

成果物は `build/auto-mixed/independent-thresholds-20260924/` と `build/auto-mixed/independent-thresholds-refined-20260924/`。各config・checkpoint・exportと、後者のcomparison.jsonを保存した。既定training_config.jsonは最初の40候補を維持し、詳細探索の設定は再現手順とrun内に保存。既存UIは元の700原文runを表示したままで、今回の候補を既存testと一緒に再採点する更新は行っていない。

### 検証と未実行事項

| 検証 | 結果 |
|---|---|
| 同梱fixture | 固定fixture datasetでv1/v2をfit・校正・export。v1は旧fixture成果物の語彙・係数・切片・校正・decoder・閾値と完全一致。両versionともfixture属性を維持 |
| Python全回帰 | 既存42＋新規7の **49件通過、skipなし**（14.792秒）。独立した組の選択、旧設定互換、1.0・NaN・不正設定の拒否、空文脈、合格候補なし、スコア再利用の一致、test・calibration・train・dev派生行の探索除外を検証 |
| 固定モデルの再探索 | 係数・校正の完全一致と元checkpoint不変を検証。fit・matrixを呼ぶと失敗するテスト、dev以外を除いたデータでも同一checkpointになるテストが通過。詳細105候補でもdev-only再実行の完全一致を別途確認 |
| 旧設定の回帰 | 元のv2設定で再探索し、元の閾値・decoder・selected_dev_metricsと完全一致。既存の校正最低件数100位置を変えず、旧50件の校正不足拒否も通過 |
| Swift数値一致 | **42件／9 suite通過**（1.435秒）。新fixture v1/v2、旧承認済みv1、新40候補・105候補の両v2 exportを検証。許容誤差1e-12、fixtureの通常loader拒否、既存goldenを維持 |
| 実行上の制約・失敗 | 新規テストの最初の実行では成果物依存2件をskipし、成果物作成後の最終49件では全件実行。実装テストの失敗はなし。文書patchは一致行不足で一度失敗したが、変更せず停止したことを確認して正しい行へ再適用 |
| 静的・文書検査 | git diff --check、Python AST、新規ファイルの空白・相対パス、既定configの検証を通過。natural-japaneseのlintはsudachipy不足で失敗し、追加箇所は手動チェックリストで通読した |

ログは `build/auto-mixed/independent-threshold-tests-20260924.log`、`independent-threshold-fixture-20260924.log`、`independent-threshold-swift-parity-20260924.log`。Python全回帰は前節の3環境変数に `AUTO_MIXED_THRESHOLD_RUN=build/auto-mixed/independent-thresholds-20260924` を追加して実行する。Swift parityには新fixture両exportと、旧承認済みv1・今回のv2両exportを指定した。

環境は既存のmacOS 27.0 arm64／Swift 6.4／Python 3.11.9と固定requirements.lock。HTTP回帰のためローカル待受けを許可して実行。外部データ・追加依存は取得していない。testの新規採点、prefix replay、実機IME、Zenzai、XPC/IMK、速度・RSS、アプリ全体のビルドは未実行。探索での文脈性能は小標本のまま。機能フラグOFF、release_ready=false、T3全体は未完了。IMEのインストール・削除・登録・設定変更は行っていない。

次は、混在境界での英語誤分類と日本語の見逃しをdevで分析し、人手確認済みの原文・文脈対照を補う。今回の候補は比較用として保存し、品質評価には十分な未閲覧testを別途準備する。実Zenzai統合はT4として分離する。

## 現在の学習済み候補を使ったT4接続と試用アプリ（2026-09-24）

利用者の「精度改善は動くようになってから」という方針に従い、追加学習・データ拡充・閾値変更を止め、T4へ進んだ。T3の品質gateを合格扱いにしたわけではない。通常IMEの機能フラグはOFFのまま。開始HEADは `c64a6fea8fa562a8ff0154be6df8aa7cd2f66c9a`、開始時git statusはcleanだった。

### 使用モデルと実API

判定器は `build/auto-mixed/independent-thresholds-refined-20260924/export/model.json`、schema 2／anchored-context-v2／`offline-retuned-302c6220b7f569e5`。SHA-256は `2c9ae52f24a1855a11ecc95d4e2ed80ff88fa5e79325a36102d247cfc0ad7581`。文脈あり0.90／なし0.98、minimum_ja 0.55、margin 1.2、hold 0.65、switch 0を維持した。v1/v2の特徴量、LR、Viterbi、golden、元データ、split、学習済み重みは変更していない。

固定依存のcheckout HEADは `ad714fea8cb2fe113aea86ba5c42563cdaf77cfb` で仕様と一致。`createSession`、`removeSession`、同期的な `withSession`、`requestCandidates`、`ComposingText.insertAtCursorPosition`、`inputIndexToSurfaceIndexMap`、`prefixComplete` の定義を再確認した。index mapの単位は入力要素とsurfaceのCharacterであり、汎用scalar mapではない。

`ZenzaiSpanBridge`、`JapaneseSpanRequest/Result`、`SegmentsManager.replaceCompositionFromRaw` は今回の新設API。既存APIとは区別する。XPCのwire型、dispatch、IMKクライアント、manualのキー経路は変更していない。

### 実装した範囲と仕様差分

- 共有Converterに対して、入力session／composition／spanごとにchild sessionを管理するbridgeを追加した。全操作はMainActor上の同期処理。最大32 child、消えたspan・取消・確定・session終了で解放し、上限超過は原文保持する。bridge内部で巨大モデルを作り直さない。
- `SegmentsManager` に原文prefixを一括置換し、候補要求を1回だけ行う入口を追加した。既存のoptions・動的辞書・資源解決を同じmanager内部で利用する。manual側の既定引数と設定値は維持し、mixedだけ予測候補を無効にした。候補はコピーしたComposingTextへ実際の `ComposingCount` を適用し、全量を消費するものに絞る。
- 標準 `.roman2kana` の実ComposingTextで妥当性を確認する。ASCIIローマ字に限定したときだけ入力要素数とscalar数を対応させる。独立した変換境界までをprefixとし、`n`、`nsh`、`kk` など依存の残る末尾は元のrawで残す。内部区間に未完suffixが残ればrun全体をunresolvedへ戻す。
- **公開APIの制約**：依存は未完prefixの一覧を公開していない。末尾に未変換文字が残るときは、実ComposingTextに英字またはapostropheを1キー足して全量かなになるかを最大27通りで確認する。確認できないケースは原文へ退避する。独自ローマ字表、特徴量への未来情報、Zenzaiによるsubstring探索は使わない。この保守的な検査が将来の入力表で拾えないケースは、依存の公開API追加として扱う。
- キャッシュはraw・左右文脈・range・設定version・richを含むメモリ内だけ。設定version変更でuser dictionary／personalization設定を読み直す。前方の表示を後方の文脈へ渡し、採用済み候補を維持する。標準入力表と資源はbridge生成時に固定するため、それらの変更時はbridgeを作り直す。
- previewでは学習APIを呼ばない。サーバー側のopaque tokenだけで実Candidateを参照する明示的な学習入口を別に設け、取消後・更新後・他sessionのtoken・重複ackを拒否する。T5のOS commit ack／pending領域は未接続。試用アプリは確定しても学習OFFで、全childを解放する。
- **段階的なUI**：登録不要で試せる `AutoMixedPlayground` をmacOS専用productとして追加した。T1エンジンへ現在の判定器とT4 bridgeを注入し、原文欄、混在表示、候補ボタン、Enter確定、Escape原文化、任意の左文脈を動かす。通常IMEへの接続はT5に残す。Tabはこのウィンドウではフォーカス移動で、候補操作はボタンを使う。漢字表示上の編集mappingもT6に残し、現在の変換runはsuffix込みでatomicに扱う。
- 左文脈はこの画面で確定した文章から明示的に有効にした場合だけ利用する。判定は末尾30 scalar、既存Converterは30 Character上限。rawは最大256 scalar。入力・候補・文脈は永続化しない。依存に入力をprintする経路があるため、試用プロセスのstdout／stderrを起動直後に破棄し、問題は画面に表示する。

### 依頼に基づく資源の取得

当初GGUF／base_n5_lmのsubmoduleは空だった。追加依頼「辞書はさがしてダウンロードして」に従い、`.gitmodules` とHEADのgitlinkに対応するHugging Faceの配布元を確認し、固定revisionのGGUFと4個のmarisaを取得した。計 **118,509,944 bytes**。5ファイルとも配布APIのLFS SHA-256と一致する。

取得先は `build/auto-mixed/runtime-resources/`。URL・revision・サイズ・checksumは `receipt.json` に保存した。取得・再検証スクリプトは `Tools/fetch_auto_mixed_resources.py`。既存ファイルが不一致なら上書きせず停止する。submoduleや利用中のIMEの配置は変更していない。

GGUFは [Miwa-Keita/zenz-v3.2-small-gguf](https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf/tree/c67e03e07d215c869f591b274c1631170d3e11fe) のQ5_K_M、配布ページはApache-2.0を表示。補助ngramは [base_n5_lm](https://huggingface.co/Miwa-Keita/base_n5_lm/tree/160a305a89c033ac53a674baeac4470cf531a71b)。後者の固定revisionにはLICENSE／モデルカードがなく、再配布権利は未確認。今回のローカル検証用取得と、T8の再配布判断は分ける。学習コーパスへの追加や追加学習は行っていない。補助ngramは取得とchecksum確認のみで、個人ngramを使ったパーソナライズ推論は未実行。

### 実行した検証と失敗

| 検証 | 結果 |
|---|---|
| Core全体、native方式 | **124件中120件成功、4件skip、13 suite**。既存manualの候補／編集／XPC契約を含む。実行4.501秒。`t4-core-final.log` |
| pure Core＋fresh Python v1/v2＋学習済み／fixture export parity | **43件／9 suite成功、skipなし**。旧goldenを維持、数値許容差1e-12を維持。1.921秒。`t4-parity-final.log` |
| 実Zenzai、ホストGPU | **専用1件成功、0.571秒**。2入力session×2JA spanを交互に扱い、キャッシュを明示的に無効化して逆順に再計算しても候補一致。未完nのsource範囲と原文suffixも確認。`t4-zenzai-final.log` |
| モデル共有 | 上記専用プロセスの8回の実候補要求で `Loaded model` は **1回**。重み読込の増加なし。同時childは4、session単位の解放後は0 |
| previewと学習 | 学習ONの既存設定を変更せず一時ディレクトリで試験。preview・取消・flushでは学習ファイルが不変。明示ackで更新されるpositive controlと、重複ack拒否後に不変なことを確認 |
| 子session・cache | 32上限、解放、他session／古いtoken拒否、raw・左右文脈・設定変更、未完内部区間のraw退避を実辞書で確認 |
| 試用アプリ | Release build、開発用.app生成、Info.plist検証、起動成功。`t4-playground-final.log`。UIの実操作も確認（下記） |
| 資源／静的確認 | 5ファイルのサイズ・SHA-256再検証成功。shell構文と `git diff --check` 成功 |

Core全体のskip 4件はoffline dataset bridge、fixture export、approved export、実Zenzaiの環境指定テスト。export 2件は別のpure parity実行、実ZenzaiはホストGPUの専用実行で成功した。offline dataset bridgeは学習データ変更がないため今回は未実行。従来どおりユーザー設定を書き換える `testOptionPunctuationMappings` は別途除外した。

途中の失敗も残した。

- 初回コンパイルはSwiftUIのcatch内で `error` がshadowされる2か所で失敗。`self.error` に修正した。`t4-bridge-first.log`。
- 最初の実テストは3 assertion失敗。固定依存では `konnichiha` が `こんいちは`、`konnnichiha` が `こんにちは` になることを実APIで確認し、両方を回帰例にした。独自のかな変換へ差し替えていない。また `watashiha sushi wotaberu ...` は現在のモデルが全JA候補を保留し、変換されない。これを原文保持の回帰例として残し、変換接続のpositive例には現在のモデルがJAとする `kyouha ...` を追加した。閾値・goldenの期待値を緩めていない。`t4-bridge-second.log`。
- sandbox内の実Zenzai試験はMetalが0MiBと報告され、GGUF読込に失敗した。辞書fallbackを成功扱いせず、backend失敗／raw保持として扱う。ホストGPUへ実行範囲を広げた専用テストは成功した。初回ホスト実行11.921秒はMetal kernel初期化を含む。`t4-bridge-third.log`、`t4-zenzai-host.log`。
- ネットワーク制限内では配布元の名前解決に失敗したため、依頼された固定資源取得だけを外側で実行し、checksum確認まで完了した。
- 当初MacがロックされていたためUI操作を中断。利用者の解除後に再開した。実行ファイル単体は画面操作ツールがアプリとして認識しなかったため、独立bundle IDの開発用.appを生成する形にした。通常IMEの識別子・登録は変えていない。
- SwiftUIの動的な表示文字列がAX情報では古いままになる問題を実画面で発見し、表示のidentityを更新して修正した。修正後のAXにも `APIを使う` とモデル読込済みが反映されることを確認した。
- LaunchServices経由の再起動でdyldのopen待ちが発生した。入力前の専用プロセスのstackを確認して終了した。`open -n` で成功した試行もあったが、最終ビルドで再発したため、起動スクリプトは.app内の実行ファイルを直接起動する方式に変更した。直接起動した最終ビルドで、Zenzai読込と `APIwotukau` → `APIを使う` を再確認した。LaunchServices経路の原因は未特定で、解消済みとは扱わない。`t4-playground-startup-sample.txt`。実行中バイナリを上書きしないよう、packagingはatomic置換にした。

実画面では `APIwotukau` → `APIを使う`、別候補 `をつかう` の採用、Enterで1回だけ確定欄へ追加、任意文脈の切替、Escape原文化、連続空白・絵文字・URLを含む原文確定、保留例の原文表示、257 scalarの入力拒否時に前の原文を保持することを確認した。toolのtypeTextで絵文字が入らなかった試行は成功に含めず、pasteで原文欄に絵文字が入ったことを確認してから確定を検証した。テスト入力はこのタスクで用意した例文だけ。実際のユーザー文脈は収集していない。

### 残る作業

T4のbridgeに必要な実Converter、複数child、共有モデル、preview非学習の検証は通過した。次は **T5のXPC／IMK統合**。auto専用dispatch、capability、mixed snapshot、commitID／ack、未ack候補の保持上限、重複effect防止、フォーカス拘束、OSのcommit／stop／deactivateの順序を実装する。試用ウィンドウの確定はローカルな表示更新で、他アプリへのIME入力ではない。

T3の精度改善と独立test、T6の編集／表示安定化、T7の入力追従・ログ監査・アプリ別試験、T8の権利／署名／配布確認は未完了。今回のGPUテスト時間を入力レイテンシとして報告しない。通常IMEの完全なXcode build、Linux、SwiftLint（未導入）は未実行。既存のSwiftPM署名問題を解消したわけではなく、native方式を継続した。macOS 13指定とllamaの13.3最低version差などの既存警告は残る。

起動・操作手順は [Tools/AUTO_MIXED_PLAYGROUND.md](Tools/AUTO_MIXED_PLAYGROUND.md)。既存のIMEのインストール・削除・登録変更、LaunchAgent変更、ユーザー設定変更は行っていない。

## 未完ローマ字の末尾表示を維持する小差分（2026-09-24）

利用者が報告した `asita → 明日`、`asitan → asitan`、`asitano → 明日の` の揺れに対応した。希望例中の `assitan` は最初の説明にある `asitan` と同じ意図と解釈し、その前提を伝えた。余分なsを消して `assitan` を明日にする綴り修正は実装していない。

開始HEADは引き続き `c64a6fea8fa562a8ff0154be6df8aa7cd2f66c9a`。git statusには前節T4の未コミット変更があり、すべて保持した。今回の実装変更は `Core/Sources/Core/InputUtils/AutoMixed/TrainedMixedInput.swift`、新規回帰は `Core/Tests/CoreTests/InputUtilsTests/PendingRomanTailTests.swift`。操作説明と `docs/azookey_auto_mixed_codex/docs/04_MODEL_AND_DATA.md` §3.2にも追記した。

### 原因と採用条件

現在のモデルでは `asita` の全位置平均は約0.9962、`asitan` は約0.9735。末尾nのpは約0.8610で、文脈なし採用閾値0.98に全体平均が届かなくなる。標準ローマ字APIとbridgeは既に `asita` ＋ `n` を扱えたが、判定器で全体を保留するためbridgeに届かなかった。これらの値は文字位置の指標であり、単語の正解確率ではない。

試用adapterで、末尾のunresolved runに限って次を確認する。

1. 実ComposingTextから非空の完成prefix＋有効な未完suffixを得られる。
2. 現在のrawの当該run全位置で `p >= max(hold_ja, minimum_ja)`。現在のモデルでは0.65。RAWと保護済みの位置はこの経路へ入れない。
3. suffixを除いたraw全体を、同じ左文脈で1回だけ再判定し、完成prefixと完全に同じ範囲が既存の採用閾値・最小値・marginを通る。

この条件を満たせば元runをbridgeへ渡し、prefixだけを変換して元のsuffixを付ける。rawの文字・Unicode scalar範囲は変えない。貼り付けでも同じ判定を行い、前の漢字表示を無条件で引き継がない。`made/no/to/name` などの語別ルールは追加していない。

**仕様差分と影響**：T6のうち末尾表示だけを先に実装した。一般的な表示履歴を使うhysteresisではなく、現在のrawで確認する限定的なprefix再判定である。既存のhold値を全位置の下限として使い、係数・閾値・schema・v1/v2特徴量・Viterbi・goldenは変更していない。判定器単体の評価指標と最終表示の採用規則は異なるため、前節までの精度を今回の表示規則の精度としては報告しない。追加LR再判定は最大1回で、Zenzaiのsubstring探索は追加していない。

### 検証結果

| 検証 | 結果 |
|---|---|
| Core回帰、native方式 | **130件中125件成功、5件skip、14 suite、5.278秒**。既存manual・固定v1/v2 golden・Python parityを含む。`build/auto-mixed/pending-tail-core.log` |
| 追加した人工スコアの条件試験 | 未完n/k/sh/kk/nx、低信頼、hold値・minimum値・margin・文脈別採用閾値の変更、RAW境界、内部の未完子音、URL・email・識別子・ファイル名、絵文字・結合文字前方のscalar範囲を確認。fixtureは学習済み品質の根拠にしない |
| 現在の学習済み判定器＋実辞書 | `明日 → 明日n → 明日の`、backspaceでの逆遷移、貼り付け、未完n込み確定、Escape原文復元、`asian` への置換時の子session解放を確認。`asian/ash/shin/names/making/design/tomorrow` 等の有限例でJA化しない回帰も通過 |
| 実Zenzai、ホストGPU | 専用 **1件成功、0.545秒**。上記と同じ入力・編集・確定列を実GGUFで実行し、backendはzenzaiReady。未完nのsource範囲と全候補末尾nを確認。モデル読込は1回。`build/auto-mixed/pending-tail-zenzai.log` |
| Release試用アプリ | build成功（12.88秒）、.appを再生成して直接起動。実画面で `asita` 入力後にn、oを1文字ずつ足し、`明日 → 明日n → 明日の` と原文欄の不変を確認。左文脈OFF。`build/auto-mixed/pending-tail-playground.log` |
| 不変・静的検査 | モデルSHA-256は `2c9ae52f24a1855a11ecc95d4e2ed80ff88fa5e79325a36102d247cfc0ad7581` のまま。`git diff --check` 成功 |

全体試験のskipは既存offline dataset bridge、fixture export、approved export、既存Zenzai共有試験、今回のZenzai試験。今回のZenzai試験だけ別途ホストGPUで成功した。他4件は今回再実行しておらず、前節の結果と区別する。従来どおり設定を書き換える `testOptionPunctuationMappings` は明示的に除外した。

途中の失敗は、最初のテストコンパイルでfixtureパス取得のtryが不足した1件（修正済み、`pending-tail-first.log`）、次の実行で新規テストの期待値が不正だった3 assertion（`pending-tail-second.log`）。後者は① `nx` が実入力表では次のa等で完成する有効な未完suffix、②末尾apostropheが既存保護器で別literalになる、③人工モデルでnをRAWにすると既存経路でasitaだけJAになる、という事実を確認した。①はprefix/suffixの正確な期待値を持つpositive例へ移し、②③は既存の正確なspan種別と③の範囲をassertする形にした。現在の学習済みモデルで `asitanx` を保留する期待値は維持し、既存テスト・採用閾値は弱めていない。

環境はmacOS 27.0 arm64／Swift 6.4／Xcode 27。ホストGPUの専用実行は一時領域・学習OFF。試用アプリは入力／文脈を記録せず、テストログの入力はタスクで明示した例と人工fixtureだけ。通常IMEの機能フラグOFF、manual経路・XPC／IMKは今回変更していない。IMEのインストール・削除・登録・ユーザー設定変更、追加学習、外部データ取得は行っていない。

未実行は広範な英語誤変換率・typing trace・入力遅延・実機IME／他アプリ・署名付きXcode全体build・SwiftLint。追加した有限の回帰例から一般的な判別精度は主張しない。LaunchServices起動問題の再調査も未実行で、既存の直接起動を継続した。T5接続を進める前提は維持し、T6全体とT7の品質・性能評価は未完了のまま。

## 完成した末尾をひらがなで表示する小差分（2026-09-24）

依頼された `asitanote → 明日のて` を試用adapterに追加した。開始HEADは `616db3f6467d3cdf2e5a1a21208f5a244874e5b1`、git statusはclean。前節までの変更がコミット済みであることを確認した。今回の開始時にもリポジトリ内にAGENTS.mdはなく、会話で指定された指示を適用した。

### 原因・変更・仕様差分

現在の学習済みモデルは `asitanote` 全体をunresolvedとする。末尾teの文字位置pは約0.5881／0.7024で、強い日本語判定ではない。一方、現在のrawにおける前方 `asitano` の平均は約0.9833で、末尾を除いた `asitano` 自体も従来の採用基準を通る。このため、全体を漢字候補へ渡す以外に、末尾だけ読みを表示する段階を加えた。これらのpは単語や言語全体の正解確率ではない。

- `RomanSpanReading.splitFinalKana` を新設。既存の `ComposingText.inputIndexToSurfaceIndexMap()` の定義を確認し、最後の独立入力単位でだけ分ける。両側が完全なかなになり、連結読みが元の読みと一致することを確認する。ASCII入力に限定してこのmapを使い、`kya/きゃ`、`tte/って`、`nki/んき` の内部で分断しない。
- `TrainedMixedSegmenter` は末尾unresolvedの完全なローマ字runに限り、全位置がminimum_ja以上、前方prefixの平均が文脈別採用閾値以上、末尾単位のlog odds合計がminimum_path_margin以上という条件を要求する。さらに、末尾を除いたraw全体を同じ文脈で1回だけ再判定し、同じ前方範囲が従来の採用基準を通ることを確認する。RAW、URL等の保護範囲、内部区間は昇格させない。
- 新設の表示専用span `japaneseKana` を追加し、エンジンとrendererが原文範囲を持つatomicな読み表示を扱う。前半は既存 `japaneseRoman`。候補操作は前半に作用し、かな末尾はそのまま残る。`MixedSessionConverter` はかな末尾を標準ローマ字表だけで描画し、Converter childや学習可能なCandidateを作らない。bridge本体は変更していない。
- **採用規則の拡張**：前節の未完英字suffixに使うhold条件は維持した。今回は完成した末尾のかな表示専用に、既存minimum_ja=0.55と局所margin=1.2を使う。漢字採用の平均閾値（文脈あり0.90／なし0.98）を全体で下げる変更ではない。局所marginはViterbiの全path marginとは別の用途で、値の最適性は未検証。理由と影響を仕様04章§3.2に追記した。
- モデルschema 2、特徴量v1/v2、係数・閾値値・LR・Viterbi・goldenは不変。学習ラベルやXPC wire型へjapaneseKanaを追加していない。export parityの網羅switchには、この表示専用値が判定器から出たら失敗するassertionを追加した。追加LR再判定は最大1回、分割候補は最後の1か所だけで、Zenzaiのsubstring探索は行わない。

変更ファイルは `Core/Sources/Core/AutoMixed/{AutoMixedTypes,MixedCompositionEngine,MixedMarkedTextRenderer}.swift` と `Core/Sources/Core/InputUtils/AutoMixed/{RomanSpanReading,TrainedMixedInput}.swift`。テストは新規 `Core/Tests/CoreTests/InputUtilsTests/KanaTailTests.swift`、既存renderer／export parityテストへの追記。操作説明も `Tools/AUTO_MIXED_PLAYGROUND.md` に反映した。

### 実行した検証

| 検証 | 結果 |
|---|---|
| 初回の対象テスト | **11件中10件成功、実Zenzaiの1件skip、0.848秒**。コンパイル・assertion失敗なし。`build/auto-mixed/kana-tail-first.log` |
| Core全体、native方式 | **137件中133件成功、4件skip、15 suite、6.035秒**。既存manual、v1/v2固定golden、Python parity、両版のfixture exportと学習済みexport一致を含む。`build/auto-mixed/kana-tail-core.log` |
| 実Zenzai、ホストGPU | **2件成功、skipなし、1.047秒**。今回のかな末尾と前節の未完nの入力・編集・確定列を実GGUFで再検証。backendはzenzaiReady、当該専用プロセスのモデル読込は1回。`build/auto-mixed/kana-tail-zenzai.log` |
| Release試用アプリ | build成功（14.38秒）、.app更新、直接起動成功。実画面でasitano入力後にt、eを1文字ずつ追加し、`明日の → 明日のt → 明日のて` を確認。原文欄はasitanote、左文脈OFF。`build/auto-mixed/kana-tail-playground.log` |
| 静的・モデル不変確認 | `git diff --check` 成功。モデルSHA-256は `2c9ae52f24a1855a11ecc95d4e2ed80ff88fa5e79325a36102d247cfc0ad7581` のまま |

追加テストは、独立ローマ字単位の実API、人工係数によるminimum・margin・前方採用閾値・文脈有無・切り詰め後の再判定の拒否条件、Unicode scalar／UTF-16境界と原文復元、RAW／URL／email／識別子／内部末尾、かな表示だけなら辞書要求・子session・学習可能tokenがないことを検証した。人工fixtureを判別精度の根拠にはしていない。

現在の学習済みモデルでは `asitanote/ashitanote/asitanome` の前方漢字＋かな末尾を確認し、`note/notes/notebook/asianote` 等に今回のかな表示を適用しないことを確認した。辞書・Zenzaiの両方で、削除による `明日のt` への復帰、前半候補 `あしたの` の選択と `あしたのて` の確定、貼り付け、Escapeと原文確定、noteへの置換時の子session解放を確認した。既存テストの期待値は弱めていない。

全体試験のskip 4件はoffline dataset bridgeと実Zenzai 3件。そのうち今回と前節のZenzai 2件だけ別途実行済みで、既存の複数session共有試験は今回は再実行していない。設定を書き換える `testOptionPunctuationMappings` は従来どおり別途除外した。今回の実行にコンパイル／assertion失敗はなく、既存のnative方式の非推奨警告・macOS最低version差等は残る。

### 制約・次に進む前提

適用は最後の独立入力単位に限る。たとえば現在のモデルでは `asitanoten` にRAW判定が混ざり、`asitanotenki` は切り詰めた前方自体が保留となるため、今回のかな末尾表示は適用しない。複数単位の弱い末尾を連続して維持する機能まで完成したとは扱わない。

広範な英語誤変換率・typing trace・入力遅延・実機IME／他アプリ・Xcode全体build・SwiftLintは未実行。今回の有限例の通過から一般的な精度や速度を主張しない。環境は引き続きmacOS 27.0 arm64／Swift 6.4／Xcode 27。実Zenzaiテストは一時領域・学習OFF・ホストGPUで実行し、LaunchServices経路の再検証は行っていない。ユーザーの入力・文脈は永続化せず、ログ中の入力は明示した試験例と人工fixtureだけ。

通常IMEの機能フラグはOFF、manual／XPC／IMKの入力経路は未変更。IMEのインストール・削除・登録・ユーザー設定変更、追加学習やデータ取得は行っていない。T5接続へ進む前提は維持し、T6全体・T7の品質評価は引き続き未完了。

## 日本語優先とローカル英単語判定を試用アプリへ追加（2026-09-24）

利用者の「基本は日本語、高い確率で英語と判断した場合に英語を維持したい」という希望と、その方針でのコード変更依頼に対応した。開始HEADは `fd9fd0639d12d1e1eacefdbb2bf399bc21962fd8`、開始時のgit statusはclean。前節までの末尾表示がコミット済みであることを確認した。リポジトリ内にAGENTS.mdはなく、会話で指定された指示を適用した。

### 変更と仕様差分

- 新設 `JapanesePreferredSegmenter` を試用アプリの既定にした。従来の `TrainedMixedSegmenter` とT2/T3判定器は回帰基準として維持する。従来の保留表示は日本語を取り逃しやすいため、英語の根拠が十分でない有効なローマ字を日本語表示へ進める。これは**表示方針の変更**であり、学習済みモデルの精度改善や再学習ではない。
- 英語には辞書一致と現在のrawに対するモデルスコアを併用する。半数以上の位置がpJA<0.5であることに加え、SCOWL level 10/20の完全一致ではpJA平均0.60以下、level 35では0.35以下、3文字未満では0.15以下を要求する。末尾prefixは3文字以上・level 10/20の単語prefix・平均0.20以下に限定する。これらは試用のための初期値であり、校正された英語確率・devで最適化した閾値とは扱わない。`english-policy.json` で独立して調整できる。
- 同じ英語区間の追加入力・末尾削除には平均上限を0.10緩める維持条件を設けた。前方の原文不変、同じ開始位置、辞書／prefix条件とRAW寄り位置の割合は引き続き必要。関係のない置換・前方編集へ維持条件を引き継がない。確定・取消・空入力・provider失敗時には `LanguageSegmenter.reset()` を呼ぶ。既存のstateless判定器にはdefault no-opを提供する。原文と英語判定の履歴はメモリ上の現compositionだけで、保存・送信しない。
- 英語条件を満たさず標準ローマ字表で成立する部分は、pJA平均が既存hold値0.65以上ならかな漢字候補、それ未満なら読みを表示する。未完子音は末尾だけ元の英字で残す。従来の `asitano + te` の漢字／かな境界は、読みの独立性を維持できる場合に残す。全体が有効なローマ字なら内部の任意substringを辞書検索しないため、`asitanote` のnoteを英語として切り出さない。
- 全体がローマ字として不成立の場合は既存判定器の境界だけを利用し、`meeting + desu` 等を扱う。URL・メール・コード・略語・Unicode literal・空白の既存保護を先に適用する。不成立入力や境界の見逃しでは原文保持が残る。made/no/to/nameの無条件保留リストは導入していない。
- 読み表示の拡張は `MixedSessionConverter(allowJapaneseReadingFallback: true)` で明示的に有効化する。既定falseは従来の「完成した末尾だけ」という契約を維持する。読み表示にはConverter childや学習可能tokenを作らない。既存テストの期待値を弱めず、新方針を別のテストで確認する。

詳細な理由・条件・影響は `docs/azookey_auto_mixed_codex/docs/04_MODEL_AND_DATA.md` §3.3、試用手順は `Tools/AUTO_MIXED_PLAYGROUND.md` に追記した。主な実装は `Core/Sources/Core/InputUtils/AutoMixed/{EnglishLexicon,JapanesePreferredSegmenter}.swift`。モデルschema 2、特徴量v1/v2、係数・モデル閾値・LR・Viterbi・goldenは変更していない。モデルversionは `offline-retuned-302c6220b7f569e5`、SHA-256は `2c9ae52f24a1855a11ecc95d4e2ed80ff88fa5e79325a36102d247cfc0ad7581` のまま。

### 辞書の取得・権利・用途

[SCOWL 2020.12.07の公式配布](https://sourceforge.net/projects/wordlist/files/SCOWL/2020.12.07/)を取得した。対応するupstream revisionは `5ef55f9c42730ebe4394a78b77855468a6f15dd2`。archiveは2,569,810 bytes、SHA-256は `5587667caa20c4891390c2d42dbb4d5c4c3f41bee77af1457ece3ba23fb859cc`。[公式Copyright](https://raw.githubusercontent.com/en-wl/wordlist/rel-2020.12.07/scowl/Copyright)にある利用・複製・改変・配布の許諾と、構成データごとの表示条件を確認し、原文Copyrightをそのまま同梱した。

`Tools/build_auto_mixed_english_lexicon.py` は固定checksumを照合してから、米英のword/contraction表のlevel 10/20/35だけを読み、ASCII小文字の正確な綴り（内部apostrophe可、32文字以下）を保持する。重複は最小levelで統合する。archiveの一括展開や外部コードの実行は行わない。派生表は **50,957語・622,063 bytes**。`EnglishLexiconResources` に取得元、入力ファイル別checksum、出力checksum、加工説明、原文Copyrightを保存し、Coreのresource bundleへ追加した。levelは語の一般性の分類であり、実測頻度ではない。

**辞書はローカル実行時照合専用**。train/dev/calibration/test、学習manifest、学習済み成果物には混ぜていない。権利未確認コーパスの取得や追加学習は行っていない。名前・製品名・新語などの網羅性はない。ネットワーク制限内の取得は名前解決に失敗したため、依頼された公式archiveの取得だけを実行範囲の外側で行い、固定checksumを確認した。

### 実行した検証・失敗と修正

| 検証 | 結果 |
|---|---|
| 既存末尾テストの初回実行 | **12件中1 assertion失敗、2件skip、1.553秒**。初期実装が内部の読み表示を既定でも許可し、従来の拒否条件に違反した。明示的opt-inへ修正し、既存の期待値を維持。`build/auto-mixed/japanese-preferred-first.log` |
| 修正後の新規・既存対象テスト | **19件中16件成功、3件skip、3 suite、3.036秒**。新規日本語優先・旧かな末尾・旧未完末尾。`build/auto-mixed/japanese-preferred-second.log` |
| Core全体、native方式 | **144件中139件成功、5件skip、16 suite、7.690秒**。既存manual、v1/v2固定golden、Python数値parity、両版fixture exportと承認済み学習データのexport parityを含む。`build/auto-mixed/japanese-preferred-core.log` |
| 追加した英文対照テスト | **1件成功、0.355秒**。全体実行の後に追加した `englishSentencesPreserveAmbiguousWordsUsingCurrentRawContext` を単独実行。`I made a note`、`go to the meeting`、`my name is Tom` を英字保持し、単独made/toをかな表示する。全体実行件数には含めない。`build/auto-mixed/japanese-preferred-english-context.log` |
| 実Zenzai、ホストGPU | **3件成功、skipなし、2.112秒**。新方針と従来のかな末尾・未完末尾を実GGUFで再生し、backend=zenzaiReady。専用プロセスのモデル読込は1回。`build/auto-mixed/japanese-preferred-zenzai.log` |
| 辞書再現性 | builderの `--check` で派生表・Copyright・provenanceの3点がbyte単位で一致。外部取得物のchecksumとローカル照合の形式・長さ・重複拒否も確認 |
| Release試用アプリ | build成功 **14.28秒**、.appを更新し、`Core_Core.bundle` の同梱リンクを確認。直接起動して新方針の表示とZenzai読込済みを確認。`build/auto-mixed/japanese-preferred-playground.log` |
| 静的検査 | `git diff --check` 成功、モデルchecksum不変、通常IMEへの混在入力の生成・dispatchが未接続（機能OFF）であることを確認 |

新規の人工スコア試験は、辞書の一般性別条件、短語、prefix、JSONによる条件変更、維持条件とreset、無関係な編集、保護範囲との交差、Unicode scalar範囲、空入力・上限超過、かな＋未完suffix、原文復元を確認する。人工fixtureは判別性能の根拠にしない。実際のモデルでは `sushi → 寿司`、`made → まで`、`to → と`、既存の `明日 → 明日n → 明日の → 明日のt → 明日のて` を確認した。note/notes/meeting/hello/design/menu/camera/file/tomorrowの英字保持、meetingdesu等の混在、候補選択、原文確定とchild解放も通過した。

実画面では左文脈OFFで `sushi → 寿司`、`made → まで`、`I made a note → I made a note`、入力途中の `mee → meeting` の英字維持、`asitanote → 明日のて`、Escapeによる `asitanote` 復元、`sushi meeting → すし meeting` を確認した。単独sushiと英文を含むrawではモデルスコアが異なり、漢字候補／かな表示が変わることも確認できた。画面には最後の混在例を残した。テスト入力はこのタスクの例文だけで、ユーザーの実際の入力・文脈を収集していない。

全体試験のskip 5件はoffline dataset bridgeと実Zenzai 4件。そのうち新方針・かな末尾・未完末尾の3件だけ別途ホストGPUで実行済み。既存の複数session共有GPU試験とoffline dataset bridgeは今回再実行していない。設定を書き換える `testOptionPunctuationMappings` は従来どおり別途除外した。学習データ・モデルの変更はなく、test splitでの閾値調整は行っていない。

### 制約と次の作業

環境はmacOS 27.0 arm64／Swift 6.4／Xcode 27／Python 3.11.9。native方式の非推奨警告、macOS 13指定とllamaの13.3最低version差などの既存警告は残る。実Zenzai試験は一時領域・学習OFF・ホストGPUで実施した。既知のsandbox GPU制約とLaunchServicesの起動待ち問題は解消扱いにせず、今回も直接起動を使用した。

広範な英語誤変換率、辞書にない語・人名・製品名の評価、実際のtyping trace、入力遅延・RSS、実機IME／他アプリ、署名付きXcode全体build、Linux、SwiftLintは未実行。辞書と表示規則の追加で有限の例は改善したが、実用精度や閾値の最適性は主張しない。日本語を優先する分、ローマ字としても成立する未知の英単語を日本語表示にする場合がある。Escapeで原文を取り戻せる。

適用先は独立した試用アプリで、通常IMEは未接続のため機能OFF、manual／XPC／IMKは未変更。IMEのインストール・削除・登録変更、LaunchAgent・ユーザー設定変更は行っていない。次はT5接続を進められる状態だが、T3品質gate・T6全体の編集安定化・T7評価は未完了のまま。今回の英語維持条件をT6全体の完了とは扱わない。

## 空白なしの日本語間でmeetingを保持する修正（2026-09-24）

利用者の `asitahameetinggaarimasu` からmeetingを抽出したいという依頼に対応した。開始HEADは `9eb99f1c9e051ab4268bc2a331392b038898a4c8`、git statusはclean。前節までがコミット済みであることと、リポジトリ内にAGENTS.mdがないことを確認した。会話の指示を適用し、通常IMEやユーザー設定は変更していない。

### 原因・仕様差分・影響

現在のモデルはUnicode scalar範囲 `[7,14)` のmeetingをすべてRAW寄り（pJA<0.5、平均約0.21）と判定していた。一方、`meeting + ga` の文字列が標準入力表でかなとして成立するため、日本語優先の全体表示がその英語判定を上書きしていた。旧試用画面で `明日はメエチンッがあります` となることも確認した。

`JapanesePreferredSegmenter` に、全体を日本語表示へ進める前の英語区間保持を追加した。候補は**モデルのRAW run開始・終了境界だけ**で作り、辞書完全一致、既存の英語スコア条件、最小3文字・最大32文字を要求する。単語内の弱い日本語判定をまたいで複数runをまとめることは認める。これにより `asitahameeting` のeだけが日本語寄りになる場合もmeeting全体で判断できる。左右の日本語は独立に標準ローマ字として成立し、それぞれの平均pJAが既存hold値以上であることを要求する。適格候補の最長1語を保護後の連続区間ごとに採用する。

末尾が `meetingg` のように未完子音だけなら、その子音は原文のまま表示する。この側は日本語への表示変更がないためhold条件を要求しない。日本語の読みを含む側のhold条件と内部の未完子音拒否は維持する。meeting固有の文字列分岐、任意の文字位置での全substring探索、Zenzaiのsubstring探索は追加していない。`asitanote` 等の従来の日本語表示は回帰試験で維持した。仕様04章§3.3と試用手順にも理由と適用条件を追記した。

変更は試用adapterとそのテスト・文書だけ。T2/T3判定器、原文バッファ、Unicode範囲定義、辞書データ、モデルschema・v1/v2特徴量・係数・閾値値・LR・Viterbi・goldenは不変。モデルSHA-256は引き続き `2c9ae52f24a1855a11ecc95d4e2ed80ff88fa5e79325a36102d247cfc0ad7581`。追加データ取得・学習・test splitでの閾値調整は行っていない。

### 検証結果と途中の失敗

| 検証 | 結果 |
|---|---|
| 修正前の再現 | 新規回帰1件で3 assertion失敗（区間範囲・種別・表示）、0.525秒。`build/auto-mixed/embedded-english-before.log` |
| 最初の修正後 | 日本語優先9件中8件成功、実Zenzaiの1件skip、2.392秒。提示例が `明日はmeetingがあります` となることを確認。`build/auto-mixed/embedded-english-first.log` |
| 拡張した編集・保護試験 | 22件中5 assertion失敗。4件は追加入力／削除の `asitahameetingg` で右のgのpJA約0.5486がhold条件を満たさず、meetingまで日本語へ戻る実装不備。未完子音だけは原文保持するよう修正した。残る1件は新規テストがURL保護をrawと仮定していた誤りで、既存 `ProtectedSpanDetector` の定義どおりliteralの正確な期待値へ修正。`build/auto-mixed/embedded-english-targeted.log` |
| 上記修正中のコンパイル | throwing式を短絡演算子の右側へ置いた際のtry不足1件。slice取得を分離して修正。`build/auto-mixed/embedded-english-targeted-fixed.log` |
| 最終の対象試験 | **22件中19件成功、3件skip、3 suite、5.037秒**。元の期待値と未完gの保持条件を維持して再実行。`build/auto-mixed/embedded-english-targeted-final.log` |
| Core全体、native方式 | **147件中142件成功、5件skip、16 suite、9.529秒**。既存manual、固定v1/v2 golden、新しく生成したPython数値parity、v1/v2のfixture exportと承認済みモデルexport parityを含む。`build/auto-mixed/embedded-english-core.log` |
| 実Zenzai、ホストGPU | **3件成功、skipなし、2.276秒**。日本語優先の実GGUF再生へ提示例の完全一致を追加し、旧かな末尾・旧未完末尾も再実行。backend=zenzaiReady、専用プロセスのモデル読込1回。`build/auto-mixed/embedded-english-zenzai.log` |
| Release試用アプリ | build成功 **14.45秒**、.appを更新して直接起動。実画面で `明日はmeeting → 明日はmeetingg → 明日はmeetingがあります` を確認。原文は提示例へ戻し、左文脈OFF。`build/auto-mixed/embedded-english-playground.log` |
| 静的検査 | `git diff --check` 成功、モデルchecksum不変 |

新規試験は `[0,7)` 日本語・`[7,14)` 英字・`[14,23)` 日本語の厳密な範囲・種別、`明日はmeetingがあります` の完全一致、meeting完成後の全prefixでの追加入力と逆順の削除、貼り付け、先頭の `meetinggaarimasu → meetingがあります`、Escape原文化・原文確定・child解放を確認した。人工スコアでは短語・辞書prefix・弱い日本語側の拒否、内部の未完ローマ字、Unicode前方のscalar範囲、URL保護を確認した。人工例は精度の根拠にしない。既存テストの期待値やモデルの閾値を弱めていない。

全体試験のskipはoffline dataset bridgeと実Zenzai4件。そのうち3件だけ別途ホストGPUで成功し、既存の複数session共有GPU試験とoffline dataset bridgeは今回は未実行。設定を書き換える `testOptionPunctuationMappings` は従来どおり別途除外した。環境はmacOS 27.0 arm64／Swift 6.4／Xcode 27。native方式・user-level cache・macOS最低version差などの既存警告は残る。ホストGPU試験は一時領域・学習OFF。LaunchServicesの再検証はせず、既存の直接起動を継続した。

今回の表示保持はモデルが示した境界と辞書の範囲に限る。複数の英単語を含む長い連結入力の一般的な分割、未知語・語形変化の網羅、meeting完成前のすべての打鍵遷移、広範な誤変換率・入力遅延・RSS、実機IME／他アプリ、Xcode全体build・Linux・SwiftLintは未実行。有限の例から一般的な抽出精度は主張しない。通常IMEは未接続で機能OFF、manual／XPC／IMK・インストール・削除・登録・LaunchAgent・ユーザー設定は未変更。ユーザー入力・文脈の記録を追加していない。T5へ進む前提を維持し、T3品質gate・T6全体・T7は未完了のまま。

## T5：IME接続を実装、実機確認待ち（2026-09-24）

利用者の「現在の完成状況を確認し、IMEとして使うための残作業を進める」という依頼に対応した。開始HEADは `b1b155e4b525ebb87448012ff210832fa854e3bb`、git statusはclean。既存のT0〜T2・T4・試用アプリ・meeting抽出を作り直さず、次のT5接続を実装した。仕様の現行位置は `docs/azookey_auto_mixed_codex/`。README、CODEX_START、03/06/07章と本記録を確認し、AGENTSは実ファイルがないため会話の指示を適用した。依存revision、モデル、辞書、学習データは変更していない。

### 実装内容

- `Core/Sources/Core/XPC/AutoMixedTransport.swift`：実定義としてCompositionPolicy、capability version 1、epoch/focus/operation/composition/revision、scalar/UTF-16 span、commitID/ack、クライアントledger、同期キーrouterを追加。旧 `ConverterServerResponse` の新フィールドはoptionalで、欠損JSONをdecodeできる。
- `AutoMixedServerSession.swift`：専用逐次adapter。legacyの `withSession` の外側で混在engineとchildを操作する。Space・Tab/Shift-Tab・候補採用Enter・全体確定Enter・Escape・末尾削除・候補世代・上限256を接続。候補対象の区間は既存marked textのfocused属性で表示する。stopはlegacy managerが空でも原文を保持する。
- `AutoMixedRuntime.swift` とConverterServer：bundleマーカーのopt-in、モデルSHA-256照合、fixture拒否、既存学習済みv2＋日本語優先adapter＋実GGUF bridge。通常ビルドにはマーカーを置かずOFF。旧サーバーへ新enumを送る前に既存 `.composition(.snapshot)` でcapabilityを確認する。既定manual経路は既存のまま。
- `azooKeyMac/InputController/AutoMixedIMEClient.swift` と既存controller：XPC接続、元クライアントへの確定、候補UI、フォーカス世代、古い応答と二重commitの除外、切断時の原文回復、非標準入力表のmanual退避を追加。実験マーカーのあるappだけ切替メニューを表示する。有効中は既存ライブ変換設定／AI変換メニューを使わない。ユーザー設定への保存は追加しない。
- 短い文脈は既存 `getLeftSideContext/getRightSideContext(maxCount: 30)` から取得する。取得要求はUTF-16範囲で、request/factoryでも30文字以下に限定する。nilなら文脈なし。ackやstopで次compositionの空文脈を固定せず、空入力後の次の打鍵で取り直す。文脈・raw・journalはメモリ内だけで、ログや学習データへ保存しない。
- `Tools/prepare_auto_mixed_ime_build.py`：このcheckoutの `build/` 内にあるビルド済みappだけへ、取得済み資源と学習済みモデルを配置する。5資源のreceipt/size/SHA-256、モデルschema、非fixture条件を照合してから最後にマーカーを作る。自動取得・学習・起動・登録・インストールはしない。手順と未対応点は `Tools/AUTO_MIXED_IME.md`。

モデルはschema 2、`anchored-context-v2`、`offline-retuned-302c6220b7f569e5`、SHA-256 `2c9ae52f24a1855a11ecc95d4e2ed80ff88fa5e79325a36102d247cfc0ad7581` のまま。v1/v2の特徴量・係数・閾値・LR・Viterbi・goldenは変更していない。`kind=production` はruntime形式であり、品質gate合格を意味しない。今回も `release_ready=false` として扱う。

### 仕様差分・理由・影響

1. **確定学習はOFF**。preview/commitで学習させない。未ack確定文字列は最大8件保持し、超過時は原文を維持して追加確定を止める。ackは文字列の退去だけを行う。候補childは確定時に解放するため、仕様03章§7の「ack後にpending candidateを一度だけ学習」は未実装。重複挿入防止を先に検証するための分離であり、候補選択から学習するIMEとしては未完成。
2. **OSの確定は同期処理**。SDKのIMKInputController宣言にある、`commitComposition` の復帰前に確定を終える契約を確認した。XPCの遅い返答を別の入力欄へ適用しないよう、元のクライアントへ最後の表示を同期確定して旧focusを失効する。未応答キーがある場合はack済みraw＋未応答打鍵から原文を確定する。影響としてフォーカス移動時に漢字表示を失う場合がある。通常Enterはserver commitID/ack方式。
3. **auto要求の失敗時は原文回復してmanualへ戻す**。旧キー要求の継続再送をそのまま使うと別server epochへ不明な確定を再送し得るため、autoは再送しない。manual再送は変更しない。未応答Enterを含むjournalは入力を消さず保持するため、障害時に複数composition相当のrawが連結される場合がある。プロセスクラッシュをまたぐexactly-onceは保証しない。
4. **実験プロセスのstdout/stderrを破棄**。依存Converterのdebug出力に入力が含まれるため、マーカーのあるConverterServerは受付前に両出力を破棄する設定にする。通常manualプロセスは変更しない。T7の全ログ経路・analytics・実機動的監査を済ませたという意味ではない。

上記の差分を03章と06章にも記録した。既存テストの期待値は弱めていない。

### 実行した検証

環境はmacOS 27.0 arm64／Swift 6.4／Xcode 27（27A266a）／Python 3.11.9。Coreはnative方式、cache/scratchは `build/auto-mixed/`。Xcodeはscheme `azooKeyMac`、Debug、`platform=macOS,arch=arm64`、署名OFF、分離DerivedData/SourcePackages。通常IMEのプロセスは起動していない。

| 検証 | 結果 |
|---|---|
| ConverterServer native build | 成功、5.51秒。`build/auto-mixed/t5-server-first.log`。最終Core test buildでも更新済みhelperを生成し、Xcodeへ埋め込み |
| 初期transportテスト | 7件成功、0.003秒。続くモデル付き試験は9件中8件成功・実GGUF1件skip、0.521秒。`t5-core-second.log` / `t5-core-third.log` |
| 最終Core全体 | **158件中152件成功、6件skip、17 suite、9.819秒**。新transport11件、既存manual、v1/v2 golden、新規生成Python parity、fixture exportと承認済みモデルexport parityを含む。`build/auto-mixed/t5-core-final.log` |
| 実Zenzai、ホストGPU | **5件成功、skipなし、5 suite、3.548秒**。新wire sessionの `asitahameetinggaarimasu → 明日はmeetingがあります` 完全一致と確定、既存の日本語優先・かな末尾・未完末尾、複数session/複数childの混線・モデル再読込防止。backend=zenzaiReadyを検証。`build/auto-mixed/t5-zenzai.log` |
| ThinClientInputPipelineTests | **4件成功、失敗なし、0.003秒**。遅延応答の順序とキー所有権、Command通過、autoのSpace/Tab、OS即時確定用raw復元とfocus失効。build-only SwiftPM harnessで元のテストファイルを直接使用。通常IMEのtest hostは起動しない。`build/auto-mixed/t5-thin-client-second.log` |
| アプリ全体 | **Xcode Debug build成功**。新IMKクライアント、候補区間表示、メニュー、Core、embedded ConverterServerを含む。`build/auto-mixed/t5-xcode-build-fourth.log` / `t5-xcode-build-final.log`。署名・起動・実機入力の成功とは区別 |
| 開発app資源配置 | prepare CLI成功。モデル・GGUF・4 marisa資源のchecksum、helper/別添bundleを確認。fixture拒否、build外出力拒否も確認。`build/auto-mixed/t5-prepare-ime.log`。appは起動しない |
| 静的確認 | `git diff --check` 成功、モデルchecksum不変、source resourcesに実験マーカーなし、一時資源リンク除去、tracked lock/依存manifest不変 |

新規テストは旧JSON互換、未知capability拒否、Unicode範囲、request診断のredaction、二重確定と古いsnapshotの分離、ack再送、epoch/focus拘束、候補世代、stop、256上限、未ack上限、非標準表拒否、文脈のcomposition単位取得、マーカーOFF・不正hash・fixture拒否を確認する。wire試験は**同一プロセス内のcodec roundtrip＋server adapter**であり、実Mach XPC通信やIMK操作の代用として完了扱いしない。

Coreのskip6件のうちGPU5件は別途すべて成功。offline dataset builder専用試験1件は今回は未実行。ユーザー設定を変更する `testOptionPunctuationMappings` は従来どおり `--skip` で除外した。これらを成功件数へ入れない。

再現用のCore環境変数は `AUTO_MIXED_RUNTIME_MODEL`、`AUTO_MIXED_PARITY_PATH`、`AUTO_MIXED_CONTEXT_PARITY_PATH`、`AUTO_MIXED_TRAINING_EXPORTS`、`AUTO_MIXED_APPROVED_EXPORTS` に、前節と同じ候補モデル／新規生成parity／v1/v2 fixture・承認済みexportを指定した。GPU5件はさらに `AUTO_MIXED_ZENZAI_RESOURCES=build/auto-mixed/runtime-resources` 相当のresource URLを指定し、学習OFF・一時領域で実行した。学習・新規データ取得・test splitでの調整はしていない。

### 途中の失敗と修正

- 初期Swift Testingコンパイルで、mutating ledgerメソッドを `#expect` へ直接渡すと生成closureの引数がimmutableになり失敗。3箇所を一度local変数へ評価する形に修正した。assertionの期待値は維持。`t5-core-first.log`。
- Xcode一覧の初回は通常のDerivedData/cacheへのsandbox書込み制限で失敗。分離先とホスト実行へ変更して解決した。`t5-xcode-list.log` / `t5-xcode-isolated-list.log` / `t5-xcode-host-list.log`。依存の固定GitHubパッケージを解決したが、学習コーパスは取得していない。
- 全体buildの初回は未初期化submoduleの4 marisa、2回目はGGUFが欠けて失敗。以前取得済みの5資源をreceipt照合後、一時symlinkでsourceの欠損場所へ置いて検証した。既存ファイルは上書きせず、最終build後に今回作った5リンクだけを削除した。`t5-xcode-build-first.log` / `t5-xcode-build-second.log`。
- 3回目は新クライアントのMainActor initializer、menu、候補delegate呼出しがnonisolated contextから行われてコンパイル失敗。actor付きlazy property、既存Task、IMK menuのmain actor境界へ移して修正。4回目・最終buildは成功。`t5-xcode-build-third.log`。
- 独立harness初回は固定依存の辞書submodule取得でsandboxのDNS制限により失敗。ホスト実行で固定依存を解決し、4件通過。`t5-thin-client-first.log` / `t5-thin-client-second.log`。
- コード確認中に、確定直後のackが空文脈で次engineを作る不具合を修正した。ack/stopではengineを作らず、bufferが空になったら破棄する。新規回帰で、確定→ack→新規入力と全削除→新規入力の両方を検証した。

native方式の非推奨、既存weak capture、macOS 13とllama最低13.3の差、署名OFFビルドでのinstall_name_toolによる署名無効化、AppIntents metadata未使用などの警告は残る。SwiftLintはコマンドが存在せず未実行。

### 未実行事項・次に必要な作業

**T5は接続コード・自動試験・ビルドまで。実機確認待ちとする。** 今回のappは `build/auto-mixed/xcode-derived/Build/Products/Debug/azooKeyMac.app` にある検証生成物で、インストール用完成品ではない。通常版と同じ識別子を持つため起動しなかった。AppDelegate起動時に既存IMEサーバー・辞書同期へ進むことを確認し、Xcodeのhosted testも実行していない。

次は、通常版と識別できる試験版のbundle/Mach service/LaunchAgent/AppGroup・データ領域を準備してから、別途ユーザー操作による導入と他アプリでのIME試験へ進む。TextEdit・Chromium系・secure field・選択置換、OS commit/stop/deactivate順序、実XPC切断と再起動、Command操作、候補click、入力取りこぼしを確認する必要がある。現時点ではこれらを未実行とする。

T6の中央編集・任意区間の原文／JA強制、複数spanでの対象選択、長時間のjournal/commit ledger上限・遅延、T7の広範な精度・性能・RSS・全ログ監査、T8の署名・配布権利表示・戻し方も残る。auto中の未対応キーはconsumeされ得る。追加650原文の人手確認とT3品質gateも未解決。実際の学習モデルの判別性能、日常使用の安定性は主張しない。

通常IMEのインストール・削除・登録、LaunchAgent、ユーザー設定は変更していない。既存ユーザー変更の破棄はない。機能マーカーは分離した開発appの中だけに作成した。ユーザーの実入力・文脈は収集せず、試験ログはタスクで提示された例文と人工fixtureだけを使った。

## 通常版と併用するazooKey Mixed（2026-09-24）

利用者の「おすすめの方法で進め、アプリも通常版と併用できるよう変更する」という依頼に対応した。開始HEADは `e1f7d30f0016d5792c5e9c68d12d2b816ecc82d9`、git statusはclean。会話のAGENTS指示と現行仕様03/06/07章、前節のT5記録、試用手順を確認した。T0〜T2・T4を作り直さず、モデル・辞書・学習データ・依存revision・v1/v2特徴量・LR・Viterbi・goldenは維持した。

### 変更と仕様差分

- `IMEIdentity` を追加し、アプリと埋め込みhelperのbundleからidentityを解決する。通常版のbundle/Mach service/AppGroup/保存先は従来値を維持。試験版は `azooKeyMixed.app`、表示名 `azooKey Mixed`、bundle ID `dev.azookey.inputmethod.azooKeyMixed` とした。Mach serviceとLaunchAgentも同prefixの `.ConverterServer` に分離した。
- MixedのUserDefaults、ユーザー辞書、学習領域、カスタム入力表、APIキーのKeychain accountを独立させた。通常版から自動コピーせず、設定の欠損を通常UserDefaultsから補うこともしない。helperの副作用なし `--identity` を導入前に照合する。
- 以前の実験用チェックメニューを、Mixed専用の **自動・日本語・英数の3入力モード**へ変更した。日本語／英数は既存manual経路。自動への切替時にmanual compositionがあれば確定後から有効にする。英数／かなキーは各manualモードへ戻る。通常版に自動モードは追加しない。
- 起動直後にmanualへ流れて混在入力を逃すことを防ぐため、capability交渉中の打鍵をメモリ内で保持し、旧commandで対応を確認後に順番に送る。失敗時は元の欄へrawを一度だけ回復する。GGUF/Metal初期化を考慮しauto要求のみ5秒、従来manualの1秒設定は維持した。待ち時間を延ばしたことで障害時の復旧が遅くなるが、無制限再送はしない。性能要件を満たしたという意味ではない。
- 証明書照会では有効なcodesigning identityが0件だった。**このMac用のad-hoc署名・App Sandbox/App Groupなし**のprofileを追加し、専用 `Library/Application Support/azooKeyMixed` 以下へ保存する。正式配布のAppGroup/Developer ID署名・公証とは分離した仕様差分で、通常版のsandboxやOSのセキュリティ設定は変更しない。
- `Tools/build_mixed_ime.py` は分離ビルド、既存receiptの5資源を検証、学習済みexportの配置、ローカル署名、strict検証、制御CLIの生成を行う。欠損source資源への一時リンクは自分で作ったものだけfinallyで削除する。`Tools/install_mixed_ime.py` は専用アプリとLaunchAgentだけを対象にし、異なるidentity・symlinkを拒否。失敗時は旧Mixedファイルとjobへ復旧する。削除でも辞書・設定・APIキーは残す。通常版用 `install.sh` は実行していない。
- Mixedのアプリdebug入力記録を止め、helperとLaunchAgentのstdout/stderrも破棄する。raw・文脈・journalをログや学習データへ保存する処理は追加していない。確定学習OFF、T3品質未達、全ログ監査未完了は維持する。

runtime modelはschema 2、`anchored-context-v2`、`offline-retuned-302c6220b7f569e5`、SHA-256 `2c9ae52f24a1855a11ecc95d4e2ed80ff88fa5e79325a36102d247cfc0ad7581`。引き続き `release_ready=false`。`kind=production` を品質合格とは扱わない。学習・コーパス取得・閾値調整は行っていない。

### 実施した検証

macOS 27.0 arm64、Xcode 27、Swift 6.4、Python 3.11.9。キャッシュと生成物は `build/auto-mixed/`。Coreはnative方式。IMK boundaryの独立harnessは実アプリに合わせてSwift 5言語モード、依存CoreはSwift 6のまま。

| 検証 | 結果・ログ |
|---|---|
| identity追加後のCore回帰 | 161件中155件成功・6件skip、18 suite、10.144秒。`mixed-profile-core-final.log` |
| 最終Core＋実GPU＋専用Mach XPC | **162件中161件成功・1件skip、19 suite、25.815秒**。`mixed-core-installed-final.log`。既存manual、v1/v2 golden・Python/export parity、実Zenzai5件、導入済み専用helperへの新規Mach XPC試験を含む |
| 実Mach XPC単独の初回 | **1件成功、3.050秒**。`mixed-installed-xpc-first.log`。capability → `asitahameetinggaarimasu` → `明日はmeetingがあります` 完全一致 → commit重複除外 → ackを検証。最終版はcloseSession応答も待って接続を閉じる |
| クライアントboundary | **8件成功、失敗なし**。`mixed-client-second.log` と再現用スクリプトの `mixed-client-final.log`。交渉前のキー順序、manual既定、未対応serverでのraw復元、Unicode削除、OS確定・旧focus、Command通過。模擬IMK欄を使い、実IMK打鍵とは区別 |
| インストーラー障害注入 | **9件成功**。`mixed-installer-tests-final.log`。一時homeと模擬OS呼出しで通常app・辞書の保全、コピー失敗、起動／登録失敗時の旧版復旧、別identity・symlink拒否、launchdの一時EIO限定再試行を確認。実削除・実障害を全網羅したという意味ではない |
| app＋helperビルド | Xcode Debug arm64 build成功。`mixed-profile-build-third.log` / `mixed-profile-build-final.log`。3モード、専用資源、ad-hoc署名、codesign deep/strict確認 |
| 導入前検査 | ホスト実行でstrict署名・helper identity一致。`mixed-install-host-dry-run.log` |
| 実際の専用導入・更新 | `mixed-install.log` / `mixed-install-retry.log`。ユーザーの `Library/Input Methods/azooKeyMixed.app` と専用LaunchAgentを導入。アプリと専用helperのプロセス起動を確認。通常IMEのインストール・削除・登録・jobは変更していない |
| 入力ソース有効化・実打鍵 | **未完了**。登録APIは成功するが、親sourceはenabled=false、3モードだけenabled=true。選択APIはOSStatus -50。システム設定の追加画面にもMixedは出ず、実IMEとしての文字入力は未実行 |

Coreのskip1件はoffline dataset builder専用試験。ユーザー設定を書き換える既存 `testOptionPunctuationMappings` は従来どおり除外した。GPU試験で一時学習fixtureの不存在ログが出るが、対応assertionは成功している。既存のnative方式非推奨・weak capture・macOS最低version差などの警告は残る。SwiftLint・Linux・Intel・正式署名／公証は未実行。既存テストの期待値を弱めていない。

### 途中の失敗と制約

1. 初期Core/buildでPropertyListSerializationのoptions指定漏れ、次にこのSDKのReadOptionsへ配列を渡した型不一致で失敗。API定義に合わせて `options: 0` に修正。`mixed-profile-core-first.log` / `mixed-profile-build-first.log` / `mixed-profile-build-second.log`。
2. クライアントharnessの初回はSwift 6モードになり、既存XPC callbackの非Sendable captureでコンパイル失敗。アプリprojectの `SWIFT_VERSION=5.0` と一致させて再実行し8件成功。productionの型検査設定やassertionは変更していない。`mixed-client-first.log` / `mixed-client-second.log`。
3. sandbox内のstrict codesign確認はApple互換dylibのtrust検証でCSSMERR_TP_NOT_TRUSTEDとなった。同じstrict条件をホスト実行して成功。検証を緩めて回避していない。`mixed-install-dry-run.log` / `mixed-install-host-dry-run.log`。
4. 実更新の初回はlaunchctl bootstrapがEIO=5で失敗し、旧Mixed app/jobへ復旧した。停止直後のendpoint解放との競合を疑い、専用jobが存在しない場合だけ0.2秒間隔・最大2秒再試行するよう修正。障害注入と実更新はその後成功した。正確なOS内部原因は未確定。`mixed-install-final.log` / `mixed-install-retry.log`。
5. 登録直後のAPI一覧に古い重複エントリーが一時的に見えた。別プロセスでの最終確認では親＋3モードに収束した。しかし親が無効のままなので、APIが成功したことだけで利用可能とは判定しないよう制御CLIと案内を修正した。SDKのTextInputSources.hでは「mode選択には親IMEがenabledであること」を要求している。親から順に有効化するAPIも成功を返すが、このログイン中には反映されなかった。
6. バックグラウンドアプリを画面ツールで取得すると約25分でtimeout、システム設定の取得にも約8分を要した。後続の既存ウインドウ操作は成功。Mixedプロセスは別途確認できたため、画面ツールのtimeoutだけを起動失敗とは判定しない。UIの実打鍵成功とも扱わない。

### 現在の状態と次の作業

**試験版のファイル配置・専用サーバー・実Mach XPC変換まで確認済み。macOSでの入力ソース有効化と実IMK打鍵は未確認のため、T5とT8を完了扱いしない。** 元の入力ソース `com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese` は前後で一致し、通常の登録内容・ユーザー設定を変更していない。確認用TextEdit新規書類は空のまま閉じ、既存文書を変更していない。OSログアウト・再起動・通常IMEの停止は行っていない。

次は利用者が書類を保存して再ログインし、システム設定 → キーボード → テキスト入力「編集」→「＋」からMixedが追加できるか確認する。再ログインで解消するかは未検証なので保証しない。続いて自動／日本語／英数、提示例の逐次打鍵、Tab/Enter、Escape、末尾削除、フォーカス移動・Command操作をTextEditとChromium系で確認する。secure field・候補click・選択置換・server切断／再起動・長時間入力も残る。

T3品質gate・追加650件の人手確認、T6中央編集、T7精度／遅延／RSS／ログ監査、T8正式配布の署名・権利表示は引き続き未完了。導入・更新・削除と未対応点は `Tools/AUTO_MIXED_IME.md`。今回の差分は未コミット。

最終静的確認：`git diff --check` 成功、モデルchecksum不変、source resourcesの実験マーカー・一時リンクなし、lock/依存manifest不変。最終導入dry-runもstrict署名・identity検査に成功した（`mixed-final-dry-run.log`）。登録状態は `mixed-registration-final.json`、選択中IDの前後比較は一致。クライアント8件は0.006秒、導入試験9件は0.037秒で再実行成功した。


## 日本語確定後のapple入力（2026-09-24）

利用者の「自動モードでappleが日本語に変換される」という報告を調査した。開始HEADは `fa73fcc1cd4289671d9f7279012b97cf10242549`、git statusはclean。会話のAGENTS指示、implementation_status、現行README・04/06章・IME手順を確認。前回の隔離導入がコミット済みであることを確認した。通常IMEとmanual経路、モデル・辞書・依存・学習データは変更していない。

### 再現した原因と修正範囲

短い確定済み左文脈があると、v2モデルが現在の英単語の綴りまで日本語寄りにする。人工の対照例で、`apple` のpJAは文脈なしで約0.002〜0.081、左文脈「明日」で約0.956〜0.999となった。これは表示する英語確率ではない。文脈を取得できた空文字列でも強く日本語寄りになるケースがあった。

現在の導入済みhelperへ専用試験sessionで「asita確定 → ack → appleを1文字ずつ」を送ると、`app` 時点の表示が英字のままにならず、英字spanの判定も外れることを実Mach XPCで再現した。今回確認した「明日」文脈では、完成した `apple` はunresolvedとして原文表示に戻る。この結果と、利用者の環境で完成語が日本語化する全ケースを同一視しない。実IMK欄での症状全体の再現は未実行。

`JapanesePreferredSegmenter` に次の狭い補助判定を追加した。

- 文脈付きの英語条件に届かず、文脈が取得できている場合だけ使う。
- 対象は保護後の区間全体で、辞書完全一致または入力末尾の辞書prefix、3文字以上に限る。任意substringを探さない。
- 標準ローマ字として未完／不成立の場合だけ、同じraw全体を文脈なしでも採点する。既存の英語平均値・RAW比率・level・prefix・hold条件を満たすことを要求する。
- `made/name/note/no/to` など完成したローマ字にはこの補助判定を使わない。辞書にあるだけで無条件に英語にしない。現在rawだけでも日本語の根拠が強ければ採用しない。
- 追加採点は1回のsegment呼出しにつき最大1回。文脈や入力を保存する処理は追加しない。

これにより修正後は `app → appl → apple` の順方向・削除・再入力と、日本語確定後の繰返しで英字を保持した。1〜2文字段階の日本語優先は維持する。これはモデルの学習改善ではなく表示条件の補助であり、一般的な精度・入力遅延改善を主張しない。仕様04章§3.3へ理由と影響を追記した。v1/v2特徴量・LR・Viterbi・golden・schema・閾値値は不変。候補モデルは引き続きrelease_ready=false。

### 検証と途中の失敗

環境は前回と同じmacOS 27 arm64／Xcode 27／Swift 6.4／Python 3.11.9。scratch/cache/logは `build/auto-mixed/`、Coreはnative方式。ログへ出した入力・文脈はこのタスクの人工例だけで、実際の利用者の入力欄から採取していない。

| 検証 | 結果 |
|---|---|
| 修正前の初期対照 | 4文脈中2 assertion失敗、1.107秒。`apple-before.log` / `apple-diagnostic.log`。文脈なしならraw、短い日本語文脈ではunresolvedになる条件を確認 |
| 修正前の21文脈 | 完成語の英語span期待で18 assertion失敗、5.498秒。`apple-contexts-before.log`。診断用printは最終テストから除去 |
| 修正前の入力途中を含む回帰 | 同じテストをHEAD実装で実行し76 assertion失敗、5.550秒。`apple-prefix-before.log`。検証後、作業中の修正をfinallyで戻した |
| 最初の修正 | 11件中10件成功・実GPU1件skip、6.005秒。`apple-first-fix.log` |
| 拡張した対象試験 | 13件中12件成功・実GPU1件skip、12.837秒。`apple-regression.log`。21文脈、7英単語、日本語対照、URL等、同じsessionで日本語確定→apple確定を3回確認 |
| Core全体 | **166件中159件成功・7件skip、20 suite、19.536秒**。`apple-core-final.log`。既存manual、v1/v2 golden、Python/export parity、辞書だけで英語採用しない人工スコア対照を含む |
| 実GGUF/GPU | 最終 **2件成功、skipなし、3.131秒**。`apple-zenzai-final.log`。日本語確定→apple逐次入力→確定/ackを3回、既存meeting/asitan/asitanote等も再生しzenzaiReadyを確認 |
| GPU試験初回の失敗 | 新テストが遅延ロード前にzenzaiReadyを要求し1件失敗。実定義のzenzaiPendingを確認し、検査を変換実行後へ移した。期待値はzenzaiReadyのまま。`apple-zenzai.log` |
| appビルド・署名 | 成功。`apple-build.log`。通常版とは分離した `build/auto-mixed/mixed-ime/azooKeyMixed.app`、strict署名検証済み |
| 更新ツール | **11件成功、0.046秒**。`apple-installer-tests.log`。`update` 操作を追加し、既存Mixedのファイルだけ更新して入力ソースの登録・各モードの有効/無効を保つ。初回導入への誤使用は拒否。通常版と辞書の保全・障害復旧試験も再実行 |
| 導入済み旧版での実Mach XPC | **意図した回帰失敗4件、0.185秒**。`apple-installed-before.log`。上記日本語確定後の逐次入力を旧helperで再現。利用者sessionには接続しない |

Core全体のskipは当時の実GPU5件、導入済みhelper1件、offline dataset builder1件。設定を書き換える既存 `testOptionPunctuationMappings` は別途除外した。その後に追加したGPU専用1件は別実行で成功し、導入済みhelperの新回帰は旧版で失敗を確認した。全件成功の報告には含めない。既存の警告、SwiftLint未導入、Linux/Intel未実行は継続する。

### 更新前の状況と未確認事項

APIでMixedの親sourceと自動モードがenabled=true、自動モードがselected=trueと確認できた。日本語／英数モードは利用者側の選択でdisabledなので、その設定を変えないため再登録しない専用update経路を用意した。

修正版のビルドと検証は済んだが、Mixedが現在使用中のためまだ置き換えていない。未確定の入力を消さず更新するため、利用者へ入力確定とABC／標準日本語への一時切替を依頼した。実機IMKの修正後打鍵、修正版を導入した後の実Mach XPC、Chromium／secure field／長時間入力はこの時点では未実行。通常版のインストール・削除・登録・起動設定には触れていない。

モデルSHA-256は `2c9ae52f24a1855a11ecc95d4e2ed80ff88fa5e79325a36102d247cfc0ad7581`。T3品質gate、T6中央編集、T7の広範な精度・性能・ログ監査、T8一般配布の残作業は完了扱いしない。今回の差分は未コミット。

最終確認：`git diff --check` 成功、モデルchecksum不変。更新dry-runはstrict署名・helper identity検証に成功した（`apple-update-dry-run.log`）。source resourcesに実験マーカーと一時リンクがないことを確認した。


### 修正版の反映完了（2026-09-24追記）

利用者の「切り替えた。修正版を反映して」を受け、選択中の入力ソースがMixed以外であることを再確認して更新した。HEADは引き続き `fa73fcc1cd4289671d9f7279012b97cf10242549`。前節の未コミット差分は保持した。

最初の更新は専用LaunchAgentのbootstrapがEIO=5となり、旧Mixedアプリとjobへ自動復旧した（`build/auto-mixed/apple-update.log`）。停止要求の完了後にもlaunchdに専用jobが残っている場合があるため、`stop_server` がそのラベルの消失を最大8秒待つよう修正した。単純にbootstrapを既存jobへ重ねる処理にはしない。停止待ちの間は旧ファイルを置換しない試験と、8秒の上限試験を追加。導入ツールの**13件が成功、0.049秒**（`apple-installer-stop-tests.log`）。従来の復旧・通常版保全の期待値は維持した。

その後の `python3 Tools/install_mixed_ime.py update` は成功した（`apple-update-final.log`）。登録・有効化をやり直さず、専用アプリとhelperを更新した。導入先のapp実行ファイル・helper・モデルが検証済みbuildとSHA-256で一致すること、入力モードごとのenabled/selected状態と現在の入力ソースが更新前後で一致することを確認した（`apple-update-status-before.json` / `apple-update-status-after.json`）。通常IME・辞書・設定・Keychainには変更を加えていない。

更新済みhelperに対する実Mach XPC試験は**2件成功、skipなし、0.653秒**（`build/auto-mixed/apple-installed-final.log`）。日本語確定とack後の `app → appl → apple` の表示・raw span・apple確定、および `asitahameetinggaarimasu → 明日はmeetingがあります` と二重確定防止を確認した。旧版で4 assertion失敗していた新回帰が修正版で通った。

実IMK欄の手操作・Chromium・secure field・長時間入力は今回も未実行で、実XPC試験の成功と区別する。現在の入力ソースは利用者が切り替えた状態のまま。入力メニューで `azooKey Mixed（自動）` へ戻せる。今回の変更は未コミット。

### 再ログイン後の反映確認（2026-09-24追記）

利用者から「ログアウトしたが更新が反映されていないように見える」と報告されたため再調査した。HEADは `fa73fcc1cd4289671d9f7279012b97cf10242549` のまま、前回の未コミット差分を保持した。今回、新しい変換ロジックの修正・ビルド・再インストールは行っていない。

- 起動中のMixedアプリと専用helperの実行元が、ユーザー用の導入先 `Library/Input Methods/azooKeyMixed.app` であることを確認。専用LaunchAgentも同じhelperを参照している。
- 検証済みbuildと導入先のSHA-256を再照合し、アプリは `c57007c13f642a87571fc76d33996086c51ef5fd5b38740f1de0118df20f5929`、helperは `e38d59877217aec1121bd01f8618edccd7833508de4bea00ca36ea4f0f546b6a` で一致。モデルも従来の `2c9ae52f24a1855a11ecc95d4e2ed80ff88fa5e79325a36102d247cfc0ad7581` で一致した。表示versionは引き続き1.0、bundle versionは1なので、表示だけではこの修正前後を区別できない。
- 再ログイン後の実Mach XPC試験は **2件成功、0.280秒**（`build/auto-mixed/apple-after-login-xpc.log`）。専用の試験sessionで日本語確定後の `app → appl → apple` とmeeting混在を確認。利用者のsession・実入力文脈は取得していない。
- クライアントboundaryの既存回帰は **8件成功、失敗なし、0.004秒**（`build/auto-mixed/apple-after-login-client.log`）。模擬IMK欄の試験であり、実機の状態遷移を全て再現するものではない。
- TextEditの新規書類で画面操作ツールによる逐次キー入力を試みたが、Mixed自動・macOS標準日本語の両方で `asita` が英字のまま入力され、標準日本語での対照も成立しなかった。画面操作がIMEを経由する実打鍵であると確認できないため、appleが表示されたことをIMEの成功とは数えない。実IMK打鍵の検証は未完了。
- 検証のため既に有効な入力ソースを一時選択し、終了時は開始時のABCへ戻した。登録・有効化・通常IMEのファイルや設定は変更していない。検証用書類は自分が入力した文字だけを消し、空の状態で一時領域へ保存して閉じた。既存文書は編集していない。

現時点ではファイルの反映漏れは確認されず、利用者の症状は未解決。対象アプリ、入力・確定の順番、完成したappleが実際にどう表示されるかを利用者へ確認中。次はその操作列を固定し、自動モードの有効状態と実IMK経路を切り分ける。根拠のない閾値変更・テスト期待値の緩和・再登録は行わない。通常manual、学習モデル、v1/v2 golden、依存revisionは不変。

利用者の追加報告「モード切り替えたよ」の後に再確認すると、選択中は `dev.azookey.inputmethod.azooKeyMixed.Automatic` だった。自動モードの選択を確認したが、未確定入力の有無は不明なのでアプリ終了・再起動は行っていない。この利用者による切替を、検証終了時にこちらがABCへ戻した操作と区別する。

## 自動選択とcontroller初期モードの同期（2026-09-24）

利用者から `asita` を確定した後の `apple` が「明日あっpぇ」となり、Codexの入力欄とメモの両方で再現するとの報告を受けた。前回確認したファイル一致・実Mach XPC成功だけでは、このアプリ側の症状を説明できていなかった。開始HEADは引き続き `fa73fcc1cd4289671d9f7279012b97cf10242549`、既存未コミット差分は保持した。会話のAGENTS、現状記録、現行README・03/06章・SDKのIMKStateSetting/TIS定義を確認した。

### 調査結果と変更

表示結果からmanualのローマ字入力へ流れている可能性を調査。実装には、`selectedInputMode` の初期値が日本語で、`setValue` 通知を受けるまでOSの選択状態を読まない欠落があった。ただし利用者の実controllerで通知欠落を観測したわけではなく、これが報告された症状の原因だとまだ断定しない。専用UserDefaultsの正式なinput_styleキーは未設定で、コード上の既定値は標準ローマ字。設定は書き換えていない。

- `MixedInputModeResolver` を新設。通知未受信の場合だけactivation時と最初のkeyDownでOSの選択中sourceを確認し、Mixed自身の3入力ソースIDだけを受け入れる。通知が来ればその入力欄の指定を優先する。通常版や他IMEのsourceから自動を有効にしない。
- controllerの既存モード同期処理を共有し、初期状態の補完からもcapability交渉を開始する。senderが取得できない場合は既存のclientを使用。activateServer内から候補位置を同期問い合わせしない制約は維持する。
- 入力メニューの補助表示がmanualでも自動の説明を出していたため、実際のcontrollerの日本語／英数／自動状態を表示するよう修正。
- 仕様03章§7.3に理由・影響・未確認範囲を記載。TIS参照はactivation当たり最大2回、入力・文脈を記録しない。モデル・特徴量・閾値・辞書・学習データ・依存・通常manualの変換処理は変更しない。

### 検証

macOS 27 arm64／Xcode 27／Swift 6.4。独立クライアントharnessは実アプリと同じSwift 5言語モード。

- 最初の境界試験は14件成功（`build/auto-mixed/apple-mode-client-first.log`）。通知なしの開始・次の入力欄、activation後に選択情報が得られる場合、通知が前後どちらに来ても明示指定を優先すること、manualと他IMEの保全、通常版がTISを読まないことを検証。
- 追加後は **15件成功、失敗なし、0.004秒**（`apple-mode-client-final.log`）。実 `AutoMixedIMEClient` と `AutoMixedServerSession`、模擬IMK欄・模擬segmenter/converterで、モード通知なし→asita→明日→Enter→apple→OS確定→別の欄で繰返しを検証。文字キーは実際のキーコードを使用。新テストはアプリの初期モードと確定後の配送を対象にし、学習モデル精度や実IMK成功を意味しない。以前の8件も成功。
- インストーラーの既存障害注入試験は **13件成功、0.046秒**（`apple-mode-installer-tests.log`）。一時homeと模擬OS呼出しだけを使用。
- 初回のアプリ全体ビルドとstrict署名検証は成功（`apple-mode-build.log`）。レビューでactivation時の候補位置問い合わせを避ける条件を明示した後、最終ビルド・strict署名検証も成功（`apple-mode-build-final.log`）。

今回の境界テスト・初回ビルドに失敗はない。既存のweak capture・native build非推奨・最低macOS版差などの警告は残る。Core変換ロジックは今回変更していないため全Core/GPU試験は再実行していない。モデルSHA-256は `2c9ae52f24a1855a11ecc95d4e2ed80ff88fa5e79325a36102d247cfc0ad7581` のまま。以前のテスト期待値は緩めていない。

この時点では新しいモード初期化の修正は未導入。実際のOS通知順序、Codex／メモでの修正後の物理打鍵、secure field、長時間利用は未確認。前回の画面操作ツールは標準日本語の対照も成立しなかったため、今回その操作を実打鍵試験の代用にしていない。通常IMEの登録・インストール・設定には触れていない。

最終の更新dry-runはstrict署名・Mixed専用identity検証に成功（`apple-mode-update-dry-run.log`）。`git diff --check` も成功。選択中がMixed自動のため未導入のままとし、利用者に入力確定とABCへの切替を依頼した。追加修正版の実機確認は、この更新後に行う必要がある。

### 追加修正版の導入完了

利用者が「ABCに切り替えた」と回答した後、APIでもABCを確認し、`python3 Tools/install_mixed_ime.py update` を実行して成功した（`build/auto-mixed/apple-mode-update.log`）。今回は停止・起動失敗や再試行による復旧はなかった。登録はやり直していない。

導入先のapp実行ファイルSHA-256は `c5f0110d7a883e63539a380a601e917057aca248fa304f31ac101630b989c6b6` で最終buildと一致。helperとモデルも一致し、前回から不変。更新前後のMixed各モードのenabled/selected状態は同じで、選択中はABCのまま（`apple-mode-status-before.json` / `apple-mode-status-after.json`）。通常版やユーザー辞書・設定を変更していない。

更新後の実Mach XPC回帰は **2件成功、skipなし、0.654秒**（`apple-mode-installed-final.log`）。これはhelperの回帰確認であり、今回変更したOS→controllerのモード通知経路の実機合格とは区別する。次は利用者がMixed自動を選び、Codex／メモでasita確定→appleを入力して表示を確認する。未解消なら入力メニューの新しい補助表示から、manual初期化とcapability失敗をさらに切り分ける。現段階では実機の症状解消は未確認。差分は未コミット。

## 実機経路の診断ログ（2026-09-24）

利用者から初期モード補完後も未解消との報告があり、「IME／サーバーにログを付け、不要なworkaroundを重ねず原因を調べる」と指示された。前回のモード通知欠落は仮説であり、実機の原因として確認できていなかった。今回、新しい自動復帰・閾値変更などは加えず、現状の実行経路を観測する。

`MixedDiagnostics` を追加。値型はbool／数値／UUID／固定enumのみで、入力文字列や文脈、キーコード、候補、エラー説明を受け取らない。IME controllerのmode通知・開始条件・配送経路、AutoMixedIMEClientのcapability／client同一性／停止／応答採否、XPC送受信・失敗・timeout／切断、サーバーの受付と結果・runtime初期化段階を記録する。sessionとownerはランダムUUIDで対応づける。利用者の入力をログや学習データへ追加していない。

診断は `Tools/build_mixed_ime.py --diagnostics` でMixed専用bundleの期限付きマーカーを生成した場合だけON。通常版と既定ビルドはOFF。24時間またはプロセス当たり10,000記録で新規出力を停止する。Unified Loggingを利用するためhelperのstdout/stderr抑制は維持。ログ回収用 `Tools/collect_mixed_diagnostics.py` は専用subsystem/categoryだけを読み、timestamp/pid/event/fieldsのみを作業用JSONLへ取り出す。07章の入力非保存方針を確認した。

実施：境界試験15件成功（初回0.007秒、`build/auto-mixed/diagnostics-client-first.log`）、診断の入力・文脈非出力／UUID対応／未指定OFF試験3件成功・0.003秒（`diagnostics-core.log`）、アプリ全体buildとstrict署名検証成功（`diagnostics-build.log`）、更新dry-run成功（`diagnostics-update-dry-run.log`）。モデルと判定条件は変更していない。既存の警告は残る。この時点では診断版の導入と実機再現は未実行。Mixed自動が選択中なので、未確定入力を失わず更新するためABCへの切替を依頼した。通常IMEのインストール・削除・登録は行っていない。

### 診断版の導入・記録確認

利用者の切替完了後、APIでもABCを確認して更新成功（`diagnostics-update.log`）。導入先とbuildのアプリ・helper・モデル・診断マーカーのSHA一致を確認した。アプリは `e6b120cfad4ccf11f954b303530391a4c0675f201a5a741bc300d8b3c373d07a`、helperは `1ef32a7cbddeb117bd4e9c9dbd2ec68a044054335ad928e62977aca4a24dd19a`。各モードの有効／選択状態は保持し、選択中はABCのまま。

最終境界試験も15件成功・0.007秒（`diagnostics-client-final.log`）。導入済みhelperへの人工例の実Mach XPC回帰は2件成功・0.649秒（`diagnostics-installed-test.log`）。専用Unified Logから38件（runtimeStage6、serverReceive16、serverReply16）の状態記録を取得し、marker→model→lexicon→policy→bridge→readyと、送受信を確認（`diagnostics-before-repro.jsonl`）。この試験は人工例であり、利用者の問題再現はこれから行う。利用者へMixed自動を選び、メモの新しい行でasita→Enter→appleを一度入力するよう依頼した。

## かなキーによる自動モード解除の特定と修正（2026-09-24）

利用者の診断版での再現結果は「明日あっpぇ」。専用ログを回収し、193件の状態記録を `build/auto-mixed/diagnostics-user-repro.jsonl` に保存した。入力本文・確定文脈は記録していない。開始HEADは `fa73fcc1cd4289671d9f7279012b97cf10242549` のまま、既存の未コミット差分を保持した。

### 観測と原因

メモでの操作に対応するcontrollerでは、20:24:32に自動モード通知とcapability確認（allowed/success/capabilityがすべてtrue）が完了。20:24:34に自動要求の最初のactionとしてdeactivateが送られ、同じイベントがmanualKeyへ配送された。その後controllerはjapaneseになり、文字・Enterはすべてmanual経路へ送られた。XPCの失敗・timeout・client不一致はなく、helperも各要求へ正常応答している。Codex側のcontrollerにも同型の遷移があった。症状発生時には英語のsegmenterまでキーが届いていなかった。

`AutoMixedIMEClient.handle` はkey code 102（英数）と104（かな）の両方で `leaveForManual()` を呼び、nilを返してcontrollerの手動処理へ渡していた。手動かな処理の `switchInputLanguage(.japanese)` が自動を解除する。初回診断ではモードキーをinsertに分類していたためキー自体はログから断定できなかったが、利用者から「かなキーを押した」と回答を得た。標準ローマ字styleはログでも前後一貫してtrue。追加したかなキー回帰は修正前に5 assertion失敗し、この経路を再現した。

### 変更と仕様差分

- 自動が有効またはcapability確認中なら、標準ローマ字styleのかなキーをclient内で消費する。自動の状態・表示・pending rawを維持し、文脈取得やXPC送信を行わない。日本語優先の自動入力でかなキーを押す習慣により英語判定が失われることを防ぐ。
- 旧仕様の「かなキーで手動日本語へ切替・即時確定」は自動モード内だけ廃止する。手動日本語への明示切替は入力メニューを使う。英数キーと非標準styleの手動復帰、manualモードのキー処理は変更しない。仕様03章§11.1と `Tools/AUTO_MIXED_IME.md` を更新した。
- 通知欠落を補う仮説実装 `MixedInputModeResolver` を撤去。実機では通知が成功しており今回の原因ではなかったため。activation時／最初のkeyDownのTIS参照、関連refactor、補完専用の6テストを撤去し、既存の通知処理へ戻した。補完を前提にした結合テストは、明示的自動モードにかなキーを加える実際の再現操作へ置き換え、明日・apple・確定・別欄の期待値は維持した。以前からの8テストも保持した。
- 状態診断に固定分類kanaKey／romanKeyと、英数キー／非標準styleによるmanualExit理由を追加。文字列・キーコードは保存しない。マーカーなしOFF、24時間／10,000件上限は維持した。

### 実行済み検証と未確認事項

macOS 27 arm64／Xcode 27／Swift 6.4。クライアントharnessはアプリと同じSwift 5言語モード。

- 修正前：境界16テスト中、新規かなキー回帰の5 assertionが失敗（`build/auto-mixed/kana-client-before-fix.log`、0.099秒）。失敗は意図した自動解除の再現で、期待値は緩めていない。
- 修正後：境界11件成功、0.007秒（`kana-client-after-fix.log`）。capability待機／開始後、未応答打鍵中、表示中、日本語確定後、別欄でかなキーを繰り返しても自動を維持すること、明日→appleの表示と確定、英数／非標準styleへの復帰時のpending raw一度だけ回復、manualでかなキーを従来経路へ渡すことを確認。模擬IMK欄・segmenter/converter・transportを用いた検証で、実機の表示合格とはしない。
- 診断試験3件成功、0.003秒（`kana-diagnostics-test.log`）。入力・文脈がpayloadに含まれないこと、モード操作分類、相関ID、未指定OFFを確認。

アプリビルド・導入・修正後の実IMK物理打鍵はこの記録時点では未完了。全Core／学習／モデル評価は今回の変更対象外で再実行していない。secure field・長時間入力・広範なアプリ互換性も未実行。既存のweak capture、native build非推奨、依存最低macOS版差の警告は残る。モデル、v1/v2 golden、学習データ、依存revisionは変更していない。通常IMEへのインストール・削除・登録変更は行わない。

アプリ全体のビルドとstrict署名検証は成功（`build/auto-mixed/kana-build.log`）。モデルSHA-256は従来どおり `2c9ae52f24a1855a11ecc95d4e2ed80ff88fa5e79325a36102d247cfc0ad7581`。更新dry-runもMixed専用identity・署名検証に成功（`kana-update-dry-run.log`）、`git diff --check` 成功。現在Mixed自動が選択中なので、この時点では未導入。利用者へ入力確定とABCへの切替を依頼した。修正後の物理打鍵・新しい診断ログによる経路確認は更新後に行う。

### 修正版の反映完了

利用者の「ABCへ切り替えた」回答後にAPIでもABCを再確認し、Mixed専用updateが成功（`build/auto-mixed/kana-update.log`）。入力ソース登録・有効化はやり直していない。更新前後の入力ソース状態は一致し、ABCのまま（`kana-update-status-before.json` / `kana-update-status-after.json`）。導入先とbuildのapp、helper、モデル、診断マーカーはSHA-256一致（`kana-installed-hashes.json`）。appは `fcd59b07acf255616aa2194945079971a50a7fbf6239b23ba468526a6ec7f244`、helperは `dc580a3a9a9ec50a314c2765e47afc6a5d199f359036ea5560a99a5d8e4c3040`。通常版や利用者の辞書・設定は変更していない。

CIのSwiftLintはこの環境にコマンドがないため未実行（未導入）。コンパイル・関連テスト・差分空白検査の成功と区別する。

更新済みhelperへの実Mach XPC回帰は2件成功、skipなし、0.648秒（`build/auto-mixed/kana-installed-tests.log`）。日本語確定後のappleとmeeting混在・二重確定防止を人工例で確認した。この試験はIMKのかなキー経路を通らないため、実機の解消確認とは区別する。利用者へMixed自動を選び「かな → asita → Enter → apple」を物理打鍵するよう依頼した。修正後の表示結果とログ照合は返答待ち。変更は未コミット。

### 利用者の物理打鍵と修正後ログの照合

利用者は再現操作への回答で「明日appleになった」と確認した。更新後の状態ログ364件を `build/auto-mixed/kana-post-update-events.jsonl` に回収（更新前の終了処理・人工XPC回帰・フォーカス遷移も含む）。新appプロセスの対象controllerでは、20:37:40にautomatic通知とcapability確認成功、20:37:41のkanaKeyは `kind=automatic, accepted=true`。その後の文字・Enterはautomaticへ配送され、同じsessionのhelper応答はready、client側の採否もaccepted=trueだった。この入力中にmanualKey、manualExit、XPC失敗・timeoutはなく、20:37:52のフォーカス離脱までモードはautomaticを維持していた。

入力本文はログにないため、表示文字列の確認は利用者報告に基づく。状態ログはキーの配送・応答・モード維持を裏づける。今回のかなキーを含む再現手順は解消を確認した。Codex／メモの両方で修正後の全操作を網羅したこと、モデル精度の改善、T6以降全体の完了は主張しない。引き続きsecure field・長時間利用・広範なアプリの操作は未確認。

既定ビルドの診断はOFF。導入済み診断版はビルド後24時間の期限またはプロセス当たり10,000件で新規記録を停止する。今回も通常IMEの登録・ファイル・設定は変更せず、既存ユーザー差分を保持した。修正は未コミット。次は通常利用での確認を進められる状態。

## 自動モードの日本語優先記号（2026-09-24）

利用者の要望は「自動の記号がすべて半角になるため、英語直後以外で `- . , [ ]` を `ー 。 、 「 」` にしたい」。開始HEADは `1507f97f43133fb17edc8b7896ea48b1e5e62279`、git statusはclean。前回作業はこのHEADに含まれている。会話AGENTS、現状記録、仕様01/03章、実際のengine／renderer／protection／runtime／XPC定義を確認した。

### 変更と仕様差分

従来は仕様01章§4.2に従いASCII句読点をすべて原文表示していた。今回の利用者指示に合わせ、この方針をMixed自動で変更する。新設した `MixedPunctuationPolicy` をengineへ任意注入し、試用runtimeとplaygroundだけで有効にする。指定なしの既定engine／renderer、manual、学習モデル、特徴量、LR/Viterbiは変更しない。

- 対象の5記号は表示・確定時に変換し、rawはASCIIのまま。英語判定raw span直後と連続ASCII記号は半角を保つ。空白・日本語を挟めば日本語優先へ戻る。未判定rawを無条件に英語とはしない。
- 閉じ括弧は同じbufferまたは取得できた短い左文脈内の開き括弧に合わせる。`[apple]` は `「apple」`、`apple[asita]` は `apple[明日]`。日本語文中で引用する英単語のために開閉形式が混ざらないようにする。
- 確定後に記号だけを入力する場合、既存の左文脈の末尾がASCII英字なら半角、日本語／空白／取得不可なら日本語優先。文脈はメモリ内だけで記録しない。
- URL・メール・パス・ファイル名・コード識別子などの既存保護tokenは変換しない。数値に接する記号も小数・桁区切り・負号・添字・入力途中の保全を優先して半角を維持する。対象外の記号は従来どおり。この例外と5記号の範囲を仕様01/03章と `Tools/AUTO_MIXED_IME.md` に記載した。
- 保護判定に追加したbool配列は既存tokenの原文維持範囲を示すだけで、scalar分類・境界ヒントは不変。記号置換は1 scalar／1 UTF-16単位同士に限定し、結合文字を含む書記素は変換しない。SpanKind、XPC capability version 1、モデルschemaは変更しない。
- 後続JA変換へ渡すleftDisplay、marked text、Tabの記号候補、Enter／OS確定が同じ表示規則を使う。Backspaceはrawを削除し、Escapeとprovider失敗時は原文を維持する。既存テストの期待値は変更していない。

### 実行済み検証

macOS 27 arm64／Xcode 27／Swift 6.4。

- 初回の関連Core試験24件成功、1.026秒（`build/auto-mixed/punctuation-core-first.log`）。新しい7試験はモック分割による日本語／英語／未判定境界、記号単独・確定左文脈、括弧対応、保護token・数値、Unicode双方向範囲、削除・再入力・Escape、候補表示、失敗時原文、既定OFF、XPC codec／確定／新composition文脈を検証。学習済み候補モデル＋通常辞書による逐次入力も含み、`asita.` → `明日。`、`apple.` → `apple.`、`[apple]` → `「apple」` を確認した。モデルの一般精度向上を意味しない。
- Core回帰はrunner集計179件・22 suiteで成功、21.185秒（`punctuation-core-regression.log`）。v1/v2 Python数値parity、学習export parity、保護・Unicode・状態・輸送・既存apple／meeting回帰を含む。GGUFを指定する実Zenzai専用試験6件、導入済みhelper試験3件、データビルダーから呼ぶ専用試験1件はこの実行ではskip。導入試験は更新後に別途実行する。ユーザー設定を書き換える既存 `testOptionPunctuationMappings` は明示除外し、今回の記号試験は設定に触れない専用試験で行った。
- IMKクライアント境界11件成功、0.007秒（`punctuation-client.log`）。かなキー維持と日本語確定後の英語入力の回帰を保持。

この時点までコンパイル／テスト失敗はなし。依存の警告、native build非推奨、weak capture、テスト用一時学習ファイル不在の診断出力は残る。SwiftLintはこの環境にないため未実行。アプリbuild、導入、実物理打鍵、secure field、長時間利用はこの記録時点では未完了。通常IMEの登録・ファイル・設定へ変更を加えず、通常資源に実験マーカーを追加しない。学習／辞書／依存revisionの更新は行っていない。

### ビルド・導入・実サーバー検証

アプリ全体buildとstrict署名検証は成功（`build/auto-mixed/punctuation-build.log`）。更新dry-run成功（`punctuation-update-dry-run.log`）。現在の入力ソースをAPIで読むとABCだったため、使用中のMixed入力を中断することなく専用updateを実行して成功（`punctuation-update.log`）。入力ソースの再登録・有効化は行っていない。更新前後のモード状態は一致しABCを保持（`punctuation-status-before.json` / `punctuation-status-after.json`）。

導入先と検証済みbuildのapp／helper／モデルのSHA-256一致を確認（`punctuation-installed-hashes.json`）。appは `f97b3a90a25a93cb996765537393cb7a331d1ae00a9440e76e0bb7a8489fed76`、helperは `338d8e8b4f0fd550e081e4f88dd29c4a516afc89a524858574c73734fac1e46f`。モデルは `2c9ae52f24a1855a11ecc95d4e2ed80ff88fa5e79325a36102d247cfc0ad7581` のまま。診断マーカーなしの既定buildに戻し、導入先にも診断マーカーがないことを確認した。通常IMEやユーザー設定・辞書は変更していない。

導入済みhelperへの実Mach XPC試験は3件成功、skipなし、1.573秒（`punctuation-installed-tests.log`）。新規試験で `asita.` → `明日。`、`asita,` → `明日、`、`asita-` → `明日ー`、`[apple]` → `「apple」`、日本語確定後の `apple-.,` の原文維持、確定左文脈ごとの単独period、小数・URL保持、Escape後の原文確定を確認した。旧apple確定後回帰とmeeting混在・二重確定防止の2件も成功。

`git diff --check` 成功。現時点のテスト／ビルド失敗はなし。これは実サーバーの人工入力試験であり、Codex／メモでの修正後の物理打鍵を確認したとはしない。次はMixed自動を選んで通常利用で確認できる状態。secure field・長時間入力・記号周辺の広範なモデル精度評価は未実行。変更は未コミット。

## 長音を含む語の変換修正（2026-09-24）

利用者から「ーを含む単語、はりけーん等が変換できない」と報告され、入力列は `harike-n` と確認した。HEADは `1507f97f43133fb17edc8b7896ea48b1e5e62279`。前回の記号修正は未コミットで、その差分を保持して今回の修正を追加した。会話AGENTS、実装記録、実際のparser／segmenter／bridge／SegmentsManagerと固定依存のComposingText・標準ローマ字表を確認した。

### 原因と変更

記号policyは `-` の表示だけを `ー` にしており、segmenterとRomanSpanReadingは単語全体を日本語候補へ渡していなかった。`harike-nn` はharike／ハイフン／nnに分かれ、候補選択では末尾「ん」の候補だけが出ていた。さらに依存の `.roman2kana` はハイフンを長音へ正規化せず、元のテキストをそのまま渡すだけでは解決しなかった。

- 日本語と判断した先頭runの後に長音がある場合、標準ローマ字として成立する一続きの範囲をjapaneseRomanとして変換器へ渡す。先頭が英語ならこの結合を行わない。保護token・数値・空白・句読点・結合文字の書記素境界は越えない。`su-pa-` のpa／`ra-men` のmenを途中で別英単語として扱わず、一語全体で読む。
- RomanSpanReadingとbridgeの変換用コピーだけでハイフンを長音へ変換。rawとsourceRange、モデル特徴量は元のまま。候補は既存辞書／Zenzaiから取り、特定の単語や候補をハードコードしない。
- 長音を含む語の終端nが依存のcompositionSeparatorでかなになる場合のみ、その公開APIで「ん」としてpreviewする。合成終端はconverter内だけで、sourceRangeや原文に追加しない。`harike-no`／`harike-nya`への継続、Backspace、Escapeで原文復帰できる。既存の `asitan` → `明日n` の期待値は維持した。
- SegmentsManagerのmixed専用bulk previewに終端処理の任意引数（既定false）を追加し、bridgeだけから指定する。通常manualのキー入力・確定・候補処理は変更しない。仕様03章§11.3と利用手順を更新した。モデル・辞書・学習データ・依存revision・XPC/schemaは不変、学習OFF。

### 検証・失敗と修正理由

macOS 27 arm64／Xcode 27／Swift 6.4。試験入力は人工例で、利用者の本文や文脈を収集していない。

1. 修正前の2試験で6 assertion／require失敗（`build/auto-mixed/long-vowel-before.log`）。spanの分割、全語候補の欠如、parser拒否を再現した。初期試験では依存自体が `-` を長音へ変えると誤って期待していたが、実際は「はりけ-ん」。依存定義を確認し、試験を「依存はhyphenを保持／新adapterだけが正規化」の契約へ修正した。読みや候補の期待値は維持した。
2. 初回修正後の関連25件で6失敗（`long-vowel-first-fix.log`）。ハリケーンとコーヒーは通ったが、su-pa-／ra-menがpa／menの英語判定で分割された。日本語の長音単語内の断片を独立判定しない形に修正し、スーパー／ラーメンの期待値を維持した。
3. 次の実行ではmeeting-roomを完全な英語で保持する新テスト1件が失敗（`long-vowel-final-unit.log`）。HEADの変更前segmenterを一時harnessに読み込んで比較すると、旧実装／修正後の双方が `meeting-ろおm`（`long-vowel-baseline-comparison.log`、比較1件成功・0.586秒）。これは既存モデルのroom判定であり今回の長音変更で起きた差ではない。新テストの対象を英語直後のハイフン保持・raw保持へ限定し、未解決のモデル判定として記録した。既存テストの期待値は変更していない。一時比較ソースへのリンクは削除済みで、成果物はbuild内だけ。
4. 最終Core回帰はrunner集計182件・23 suite成功、22.962秒（`long-vowel-core-regression.log`）。長音を含む5例の逐次入力・一語span・実辞書候補・候補採用／確定、n/nn/no/nya、削除・再入力、Unicode双方向範囲・結合文字、Escape、URL／ファイル／英語／数値の保全を確認。v1/v2 parity・既存記号・apple／meeting・pending n回帰も成功。実GGUF専用6件、導入済みhelper4件、データbuilder専用1件はこの実行でskip。ユーザー設定を書き換える既存 `testOptionPunctuationMappings` は明示除外した。
5. 実IMKクライアントの模擬境界11件成功、0.008秒（`long-vowel-client.log`）。かなキー維持・原文保全・フォーカス移動の回帰を確認。`git diff --check` 成功。

この時点ではbuild／導入／実サーバーの新試験は未完了。物理打鍵、secure field、長時間入力も未確認。SwiftLintはコマンドがないため未実行。既存のビルド警告とテスト用一時学習ファイル不在の診断出力は残る。通常IMEへのインストール・削除・登録変更は行わない。

### 反映と実サーバーの最終検証

アプリ全体buildとstrict署名検証成功（`build/auto-mixed/long-vowel-build.log`）、更新dry-run成功（`long-vowel-update-dry-run.log`）。入力ソースを読むとABCだったため、専用updateを実行して成功（`long-vowel-update.log`）。登録・有効化をやり直さず、前後のモード状態とABC選択を保持（`long-vowel-status-before.json` / `long-vowel-status-after.json`）。

導入先とbuildのapp／helper／モデルのSHA-256は一致（`long-vowel-installed-hashes.json`）。appは `88df4351257c12e38725ac5102702bc6b436008f598a1ece1f8cc6a4c06efc2d`、helperは `6a8633650758bba308ae14ffa4465fe024c4a0228547f33c5dfb178db0c5b8d3`。モデルは従来の `2c9ae52f24a1855a11ecc95d4e2ed80ff88fa5e79325a36102d247cfc0ad7581` のまま。診断はOFF、通常IMEのファイル・設定・登録は変更していない。

実Mach XPC試験4件成功、skipなし、2.770秒（`long-vowel-installed-tests.log`）。新試験でharike-n／harike-nn、ko-hi-、su-pa-、ra-menを一文字ずつ入力し、元のrawと範囲を保った一語span、ハリケーン／コーヒー／スーパー／ラーメンの候補選択・確定、Escapeの原文確定を確認した。既存の句読点・英語直後の記号・括弧・URL・数値・apple・meeting・二重確定防止の3試験も成功。実サーバーの人工入力試験であり、実IMKの物理打鍵確認とは区別する。

作業途中、HEADが前回記号修正のcommit `d8cea7bb7c198cc969da605a3e67f84f872b6227` へ進んでいることを確認した。こちらからcommit操作は行わず、今回の長音修正差分と既存変更を保持した。最終 `git diff --check` 成功。今回の長音修正は未コミット。Mixed自動へ戻して通常利用で確認できる状態。物理打鍵・secure field・長時間利用は未確認。

## 句点追加による「教えて」のひらがな化の原因調査（2026-09-24）

利用者から `asitanotennkiwoosiete.` の句点入力で「教えて」が「おしえて」になる理由を質問された。開始HEADは `362fa25b9dc66f5df4e096ced74bffda1747d2db`、git statusはclean。前回の長音修正はこのHEADに含まれる。今回は原因調査であり、製品コード・モデル・設定・導入済みIMEは変更していない。旧資料パス `docs/auto-mixed/README.md` は存在しなかったため、配置済みの `docs/azookey_auto_mixed_codex/README.md` と追記案、実際のsegmenter／特徴量／converter／engineの定義を参照した。

### 観測と原因

導入済みMixed helperに独立したテストセッションから提示された固定例を一文字ずつ送り、確定左文脈が取得不可の条件で利用者報告と同じ変化を確認した。

- 句点前：`明日の天気を教えて`。raw全体 `[0,21)` がjapaneseRoman。
- 句点後：`明日の天気をおしえて。`。`[0,18)`（`asitanotennkiwoosi`）がjapaneseRoman、`[18,21)`（`ete`）がjapaneseKana、`[21,22)` がliteral。
- Backspaceで句点を除くと、一つのjapaneseRomanへ戻り `明日の天気を教えて` になった。
- 取得成功した空の左文脈を渡す対照では、句点後も `[0,21)` がjapaneseRomanで `明日の天気を教えて。` を維持した。利用者の実際の文脈取得状態は収集しておらず、上記は条件を制御した人工入力での比較。

固定モデルを使うローカル調査でも同じ区間変化を確認。文字特徴は前後8文字とn-gram／EOSを参照するため、ASCII period追加で末尾の特徴が変わる。文脈取得不可では末尾eteの日本語スコア平均が句点後0.181となり、baselineがRAWへ分割する。JapanesePreferredSegmenterは前半の日本語区間を維持し、後半eteはhold閾値0.65未満のためjapaneseKanaにする。このスコアは校正済みの語の確率ではない。

MixedSessionConverterはjapaneseKanaを読みだけで表示し、変換bridgeへ渡さない。調査harnessでもeteのbridge結果が存在しないことを確認。Zenzaiへ「おしえて」全体を渡した結果の候補変化ではなく、その手前で `osi` と `ete` に分断されたことが原因。句点表示policyはrawのperiodを「。」として表示するだけで、直接漢字をひらがなへ置換していない。通常辞書だけの対照は「押しえて。」となり、同じ分断でも前半の候補がZenzaiと異なる点を区別した。

### 検証と未実施事項

- macOS／Swift環境は前回と同じ。ローカルモデル・通常辞書の診断1件成功、5.551秒（`build/auto-mixed/period-diagnosis/local.log`）。文脈取得不可／空文脈取得成功、逐次入力／全体置換、句点削除を比較。入力保持・非fallbackを確認した診断の成功であり、症状が修正された意味ではない。
- 実Mach XPCの導入済みhelper診断1件成功、skipなし、2.784秒（`build/auto-mixed/period-diagnosis/installed.log`）。独立セッションを終了し、ユーザーの入力セッション・入力ソース・登録には触れていない。調査用Swiftソースはbuild内に保存し、Coreテストへの一時リンクは削除した。
- テスト／ビルド失敗なし。ユーザーcacheアクセス不可とnative build非推奨の既存警告あり。差分空白検査は成功。本文や文脈をアプリから取得する診断・常時ログは追加せず、記録は提示された固定テスト例のみ。

修正・再学習・アプリbuild／更新・修正後の物理打鍵・全回帰は未実施。次に修正する場合は、句読点追加で日本語の語中に境界が生じる問題を対象にし、逐次入力だけの表示固定で隠さず、全体置換・削除・文脈可否・既存英語／保護tokenを対照にする。閾値の一律緩和や当該文字列の特例は今回追加していない。

## 句点問題の根本原因と修正方針の調査（2026-09-24）

利用者の「時々再現する根本原因と適切な修正方法を考える」依頼に対応。HEADは `362fa25b9dc66f5df4e096ced74bffda1747d2db` のまま、前回の本記録だけが未コミットで、その内容を保持した。実装・導入ではなく調査と設計を行い、[原因・対照実験・修正の責任範囲](docs/azookey_auto_mixed_codex/docs/10_PUNCTUATION_STABILITY_REVIEW.md) を追加した。

実際のexport manifestを照合するとモデルの元datasetは `expanded-700-se-20260924` だった。初回は別のcanonical版を集計したが、SHA不一致に気づき、正しいdatasetで再集計してassertを追加。最終成果物は一致するdataset SHA `b5bd29bbf48da0b2f57f3152be2eb85bb8b2e7df1c501fd8248d5009754a707e` のtrainだけを対象とする。モデルSHAは従来どおり。凍結testの再採点・パラメータ選択はしていない。

原因は三層。train原文481件でperiod直前8文字のASCII英字はRAW680位置／JA0位置で、日本語の句読点rawが欠けている。空文脈13原文には学習対象のRAW／JA英字位置がなく、v2の反復BOS特徴が空文脈を日本語側へ過大に加点する（取得不可との差は校正後logitで約+7.883）。さらに現モデルの切替ペナルティ0と、英語として採用しなかった部分をかなへ戻した後も古い区間境界を残す処理が、語全体のZenzai入力を阻害する。全体の平均スコアは既存hold値以上の約0.8705であり、単なる採用閾値の調整だけでは境界の問題を解消しない。

実施した検証：

- train集計・特徴量寄与・切替ペナルティの対照計算を `build/auto-mixed/period-root-cause/audit.py` で実施し、`audit.json` に保存。係数・特徴量・閾値は製品へ反映していない。
- 現行segmenterの21入力×8終端×6文脈＝1,008条件で範囲検証と全体入力／逐次入力の最終spanを比較。差0件、診断1テスト成功・155.228秒（`matrix.log`）。これは予測が全件正解という意味ではない。追加対照で `osiete.` の全体かな化と `asitanote.` のnote英語化も確認し、単純な隣接span結合だけでは全症状を直せないことを記録した。
- 導入済みhelperで、最初の文脈nil／空と後続文脈nil／空の4組を各3回再現。最初がnilなら3回とも「おしえて」、空なら3回とも「教えて」。途中の取得状態変更は影響せず、composition開始時に文脈を保持する実装と一致した。独立セッションを終了し、利用者の入力セッションは操作していない。
- 実Zenzaiへ本文全体の読みを内部spanとして直接渡すと「明日の天気を教えて」を返した。上記実サーバー対照と合わせ2テスト成功・16.390秒、skipなし（`server-and-zenzai.log`）。モデルを強制変更した精度実験ではなく、変換呼出しの因果を確認する対照。

一時テストソースはbuild内に保存し、Coreからのリンクを削除。SwiftPMの既存cache権限警告とnative build非推奨は残る。並行確認のためtest bundleの本体を直接起動しようとした試行はexec format errorで実行不可だったため、正式な `swift test` 経路で上記2テストを実行した。診断テストのassertion失敗はなし。差分空白検査成功。

推奨は、現行回帰を保持して、判定後の日本語の変換単位と入力中かなpreviewを整理する差分と、実際の句読点raw・空文脈を含むデータ／モデル改善を分けて評価すること。モデル改善ではまず既存v2のデータ補完を比較し、文脈特徴を変更する場合は別versionにする。前表示の固定、nilを空へ置換、句点だけ推論前に差し替え、閾値の一律緩和は採らない。

製品コード・学習モデル・IMEの更新は未実施。通常IMEのファイル・設定・登録は不変。利用者の実機で文脈の取得状態が実際に変動したかは未確認で、本文／文脈を取得・保存していない。新しい修正の実装・再学習・全回帰・物理打鍵・品質評価は次の作業として残る。

## 記号コーパスの拡充と再学習・再現確認（2026-09-24）

利用者の「記号類を考えてコーパスを増やし、再学習後に今回の問題を確認する」依頼に対応した。開始HEADは `362fa25b9dc66f5df4e096ced74bffda1747d2db`。前回からの本記録と調査メモを保持し、旧700原文・旧モデル・v1/v2 goldenを上書きしていない。会話AGENTS、既存の資料、権利記録、実際のデータ分割・学習・校正・export・Swift bridgeの定義を確認した。

### データとパイプライン

`Tools/AutoMixedTraining/punctuation_expansion/` に原文230件と権利記録、生成済みJSONL、確認表を追加。日本語75、混在45、英語60、URL・メール・path・数値等40、Unicode記号10件。本文はCodexの創作で、外部コーパスの取得やアプリ入力の収集はなし。利用者による今回の作成・学習指示を利用許可として記録し、注釈の全件人手確認は未実施と明記した。固定Converterで日本語の読み211か所を照合した。今回の再現文とshi版は学習原文に追加していない。

source manifestに任意の `augmentation.boundary_policy` を追加し、指定時だけgroup分割後に句読点・括弧・空文脈対照を生成する。元文あたりの合計sample weight 1、prefix最大8、ローマ字variantの実Swift照合を保持。非空文脈で意図を与えた曖昧語を空文脈へ複製せず、AMBIGUOUSや構造保護tokenも自動増強から除外する。未指定の既存manifest経路、span/model schema、特徴量v1/v2、LR/ViterbiのSwift実装、manual、IMEの判定ロジックは変更しない。

元のsealed dataset SHA `b5bd29bbf48da0b2f57f3152be2eb85bb8b2e7df1c501fd8248d5009754a707e` と原文・分割を照合して固定。新datasetは930原文、8,663行（原文930、ローマ字596、記号1,473、文脈1,876、prefix3,788）。別splitと衝突した派生行1,816件を除外し、元文を移さなかった。原文はtrain642／dev100／calibration102／test86。SHAは `ec912fd6d4731d141604f5b7012a0ccb5cd5cc8d58b32a40dd5f09fc2a80e2e3`。

trainの派生行を含む集計では、periodの前8文字にJA_ROMAN9,587位置／RAW1,243位置、空文脈にJA36,449位置／RAW10,210位置がある。以前の欠落を埋めたことの確認であり、位置数を独立した原文数や学習重みと同一視しない。

### 一括再学習の結果

`build/auto-mixed/punctuation-930-20260924/` に独立したv2候補を学習・校正・exportした。基準モデルと同じ詳細グリッドを使い、語彙・係数はtrain、正則化と閾値はdev、sigmoidはcalibrationから選んだ。モデル形式・特徴量を変更せず、最低件数や品質目標を緩めていない。選択された閾値は文脈あり／なしとも0.99、hold0.65、切替ペナルティ0。

データ構築とSwift検証9.378秒、LR学習とdev選択53.317秒、校正とdev閾値選択2.101秒、export0.804秒、全体65.603秒。時間は `perf_counter` の実測値を `timings.json` に保存。候補モデルSHA-256は `2cef9e0443d6ca5f54caf9c999959aa78d0ad7f8b030e0462a1749a091b1e02b`、`release_ready=false`。

新規 `PunctuationModelRegressionTests` は、モデルを差し替えて同じ期待値を検証する。旧モデルでは1試験・8 assertion失敗・11.899秒（`build/auto-mixed/punctuation-model-before.log`）。再学習候補は通常辞書と実Zenzaiの両試験が成功、2件・skipなし・20.240秒（`punctuation-retrained-zenzai.log`）。文脈取得不可／取得成功空、si／shi、句点・読点の追加／削除／再入力、全体入力、確定、Escapeの原文回復を検証した。`asitanotennkiwoosiete.` → `明日の天気を教えて。` を、本文全体の日本語spanを維持した状態で確認した。実IMKの物理打鍵ではなく、同じCoreと実GGUFを使う隔離試験。

ただし、関連Core回帰はrunner集計34件・5件skipで12 assertion失敗、29.231秒（`punctuation-model-after.log`）。失敗は `asitan`／`asitano` の判定とpending n表示、`asitanote` のかな末尾、孤立made、日本語対照のnote、`asitahameetingg` の入力途中の英語保持。apple確定後、長音、基本記号、Python／Swiftの新export parityは成功した。既存テストの期待値は変更していない。この候補で今回の症状は解消したが、既存動作の維持は未達なのでIMEへは反映しない。

### 退行を避けるための比較実験

記号を含むchar/ngramの係数のみを再学習する制約付きLRも別artifactで比較。非記号係数・文脈・基準校正・decoder・閾値を固定し、devでL2正則化、calibrationで残差倍率を選ぶ。独自optimizerの勾配は有限差分と照合した。特定語や今回の例の係数を手で指定する処理、実行時のモデル切替、語別workaroundは追加していない。

- 既存の記号486特徴を使う `punctuation-symbol-refit-20260924` は24.544秒。既存入力の回帰は通るが、今回の句点試験8 assertion失敗（`punctuation-symbol-regression.log`、34件・5skip、28.527秒）。
- 記号486枠をtrain由来の特徴へ置き換え、語彙数32,768と非記号の係数・キーを保持する `punctuation-symbol-refresh-20260924` は41.565秒。今回の句点試験4 assertion失敗（`punctuation-symbol-refresh-regression.log`、34件・5skip、28.107秒）。

両方とも未採用で、制約付き学習が問題を解決したとは報告しない。これらの実験はv2特徴量定義やSwift scorerを変更しないが、一括再学習と学習可能なパラメータ範囲・校正方式が異なるため、記録と成果物を分離した。

### 凍結後の評価・検証と未実施事項

一括再学習候補を固定した後、test原文86件を一度評価し、同じ行で旧モデルと比較した（`evaluation.json` / `comparison.json`）。新規原文は23件で、旧testは以前に閲覧済み。全86件を未閲覧の独立testとはしない。testを見た後の追加学習・モデル選択はなし。

旧→候補はJA precision99.20%→100%、JA recall74.25%→54.55%、英語破壊1/208→0/208、境界F1 0.700→0.627、保留率15.76%→26.60%。保留が増えており、全体精度向上や実用品質の達成は主張しない。これはLR＋Viterbi＋保留までの評価で、IME最終表示の精度とは異なる。prefix評価はASCII85原文・2,465遷移、既存位置のラベル変更2,095、Unicode1原文は未replay。各prefixで実Swift保護maskと特徴量を再計算し、実IMK打鍵とは区別した。

Python最終試験は60件中46件実行成功・14skip、4.196秒（`punctuation-python-final.log`）。原文930／旧700の完全一致・旧group固定・派生行漏洩なし・periodと空文脈の両ラベル・権利／fixture隔離・数値勾配を含む。途中、新規unittestの属性名runが基底クラスのメソッドと衝突しTypeErrorになった。directoryへ修正し、同じ3検証を再実行して成功（`punctuation-dataset-tests.log`、1.961秒）。ログ中のpreview既存出力エラーは既存の拒否動作を検証する負例であり、学習失敗ではない。

macOS 27 arm64／Xcode 27／Swift 6.4／Python 3.11.9と固定requirements.lockを使用。SwiftPM cache権限・native build非推奨など既存の警告は残る。`git diff --check` 成功。SwiftLintは未導入のため未実行。今回の既存IMEクライアント、通常manual、インストール・削除・登録・ユーザー設定への変更なし。新候補のアプリbuild／導入／実Mach XPC／物理打鍵／長時間運用は未実施。

今回の依頼に対するデータ追加・再学習・特定症状の解消確認は完了した。新モデルの採用は既存回帰の失敗で見送った。[データ・学習方法・時間・失敗を含む結果](Tools/AutoMixedTraining/punctuation_expansion/README.md) を参照。次は、既存の入力途中の契約を保つ変換区間の設計と文脈特徴を見直し、今回のモデル改善と両立させる必要がある。通常IMEと導入済みMixedは従来のまま利用できる。

## 再学習モデルの退行原因の調査（2026-09-24）

利用者の「リグレッションの原因を調査して」に対応。HEADは `362fa25b9dc66f5df4e096ced74bffda1747d2db`。会話AGENTS・既存AGENTS・実装記録・仕様04/05章・前回の調査と学習成果物・実際の学習／Swift判定／表示処理を確認した。既存の未コミット差分は保持。今回は調査のみで、製品コード・採用閾値・既存テストの期待値・導入済みIMEは変更していない。

詳細は [再学習後の退行調査](docs/azookey_auto_mixed_codex/docs/11_RETRAINING_REGRESSION_REVIEW.md)。診断ソースと生結果は `build/auto-mixed/regression-root-cause/` に保存した。利用者の本文・文脈は取得せず、既知の人工回帰例と権利確認済みtrain/devのみを分析した。

### 確認できた原因

- 記号・空文脈を含む完成文の増強は、原文ごとの総重み1を維持しても、入力途中の比率を維持しない。同じ既存train481原文でprefixの重み合計が241.0788→146.5375、約39.2%減少。元のprefix生成は記号／文脈variantに適用されない。新規原文と増強を別々にON/OFFする比較学習でも、句点改善と同時に未完n・te・英語後続gのスコアが変わることを確認した。
- 閾値選定は完成したdev原文のLR＋Viterbi＋保留だけを評価し、実際の入力途中や日本語優先表示を評価しない。新dev155英語span中backupの1件が旧閾値で破壊され、1/155＝0.645%が0.5%制約を超えるため0.99／0.99へ厳しくなる。同じ新devでJA recallは旧閾値68.33%→新閾値52.25%。105候補中、全品質目標を満たすものは0だった。
- `asitahameetingg` は末尾gのpJAが0.548635→0.273869となり、meetingとgが同じRAW runに入る。辞書照合がRAW runの端だけを候補にするため、meetingの末尾が失われ、既知の英単語を照合できなくなる。旧閾値／校正へ戻すだけでは解消しない。
- `asitanote` は日本語の採用済み区間が失われると、後段の全体平均による日本語優先処理が全体を漢字変換する。旧係数のまま閾値だけ厳しくした対照でも通常辞書表示が「明日のて」→「明日の手」となる。低信頼化によって変換範囲が広がる逆転がある。madeも日英のスコアを漢字／かな表示へ流用するため通常辞書の表記が変わる。
- 空文脈の日本語加点は校正後logitで+7.882789→+0.282207へ減り、空文脈noteが英語表示になった。「明日」「これは」の非空文脈は日本語を維持。これは旧空文脈の偏りへの依存を含む期待値であり、空文字だけで日本語意図を仮定してよいか仕様の整理が必要。テストを通すための過大加点の復元や語別例外は行わない。

### 前回の失敗報告の精密化

既存の12 assertion失敗は再現したが、すべてが自動モードの画面上の退行ではない。asitanは下位adapterの全位置0.65条件に届かず失敗する一方、日本語優先runtimeは「明日n」を保持する。asitanoは内部区間が変わるが表示は「明日の」のまま。

さらに固定GGUFで実Zenzaiを比較すると、新旧ともasitanoteは「明日のて」、madeは「まで」を返した。通常辞書では表記が変わるが、実Zenzaiのこの人工例では変わらない。内部の変換範囲の退行は残るため、既存テスト失敗を無視してよいとはしない。

実Zenzaiでも新規に表記が崩れたのは、文脈取得不可の `asitahameetingg`。「明日はmeetingg」→「あしたはめえちngg」を確認した。空文脈では現行モデルでもmeeting途中の英語保持ができていなかった。句点の報告例は今回も旧「明日の天気をおしえて。」→候補「明日の天気を教えて。」を確認した。実IMKの物理打鍵による確認ではない。

### 実行した検証・失敗・制約

- 既存6テストの再実行：旧モデル6件成功・4.787秒、新候補6件・12 assertion失敗・4.716秒。前回と同じ失敗で、期待値不変。ログは `regression-independent-thresholds-refined-20260924.log` と `regression-punctuation-930-20260924.log`。
- 旧／新と閾値のみ／校正のみ交換の6条件×4人工文脈×14入力＝336条件。診断1テスト成功・81.791秒。Python／Swiftのlogitと確率3,816位置で最大絶対誤差0、保留後ラベルも336条件一致。全体入力／逐次入力の最終span差0。正解精度336件合格ではない。`swift-matrix.json` / `parity.json`。
- trainだけを使う2×2の比較学習は34.996秒。新train語彙・C=10・optimizer・新校正値を固定し、新規原文と記号／文脈増強の寄与を分けた。両方ONは新モデルの全係数・切片を誤差0で再現。旧prefixの26行除外はすべての対照で維持し、校正し直していない診断実験である。新たな採用候補のexportやtestによるモデル選択はなし。`ablation.json`。
- 実Zenzaiは旧／新×取得不可／空×7入力＝28条件。初回sandbox内ではMetalが0 MiBとされ、モデル読込が `error loading model: vector` で失敗。backend検証1 assertion失敗・2.097秒を `zenzai-matrix.log` / `zenzai-sandbox-failed.json` に保存し、成功結果に含めていない。ホスト側の隔離試験で同じテストを再実行し、実GGUF・backend ready・学習OFFで1件成功・1.872秒。`zenzai-host.log` / `zenzai-matrix.json`。

macOS 27 arm64／Xcode 27／Swift 6.4／Python 3.11.9。SwiftPM cache警告・native build非推奨等は残る。SwiftLintは未導入のため未実行。一時診断テストのCore内リンクは削除し、診断ソースはbuild内に保存した。新候補のアプリbuild・導入・実Mach XPC・実機打鍵・長時間利用は未実施。独立testの再採点は行っていない。

次に進む際は、入力途中の表示評価と用途別の学習重みを選定へ含め、英単語候補の境界を単一Viterbi runから切り離す小さな差分を優先する。漢字／かな変換範囲の設計と空文脈の期待も別途整理する。今回それらの修正は未実装。通常IMEおよびMixedのインストール・削除・登録・利用者設定は不変。

## 英単語候補の境界独立化と入力途中評価（2026-09-25）

利用者の「英単語抽出をモデルの区切りだけに依存させない修正と、入力途中の評価追加」に対応。HEADは `362fa25b9dc66f5df4e096ced74bffda1747d2db`。既存AGENTS、本記録、仕様04/05章、前回の退行調査、実際の判定・学習・テスト定義を確認し、既存の未コミット変更を保持した。モデル再学習やIMEへの導入は今回の作業に含めていない。

### 実装と仕様差分

`JapanesePreferredSegmenter` の埋込み英単語候補を、Viterbiが提案したRAW runの端だけから作る方式から、保護後の区間内の辞書完全一致を調べる方式へ変更した。候補数は区間長×辞書の最大長32以内。最長の適格語を優先し、同長なら開始位置の早いものを採る。現在の英語スコア・RAW比率・辞書level・hysteresis、前後の独立したローマ字成立とhold条件は保持する。末尾の未完子音だけは従来どおりraw表示を許す。区間全体が辞書語ならその全体判定を優先し、短い別単語への切り分けを防ぐ。

これにより、`asitahameetingg` のmeetingとgが一つのRAW runになってもmeetingを照合できる。候補増加による日本語中の誤抽出が影響として考えられるため、前後比較と負例を追加した。特定語の例外・閾値緩和・前表示の固定・探索中のZenzai呼出しは追加していない。モデル係数・特徴量v1/v2・LR/Viterbi・schema・golden・manual入力・辞書データは不変。仕様差分の理由と範囲は04章、評価方法は05章に追記した。

`pipeline.py evaluate-typing` と専用Swiftテストを追加。approvedなsealed datasetのdev原文だけを、書記素単位の追加・末尾削除・各prefixの新規入力で再生する。実Swiftの特徴量、保護、ローマ字妥当性、辞書、日本語優先処理、hysteresisを毎回実行する。完成した英語正解spanの日本語化、JA precision/recall、既存位置のkind変更、追加と削除／貼り付けのspan差、segment時間を文脈取得不可／空／非空別に集計する。本文・文脈はreportやログへ出さず、一時要求・応答は終了時に削除する。依存ライブラリのDEBUG出力もcorpus処理中は抑制する。

`train_punctuation.py` はexport後に同じdev評価と実測時間を保存するよう変更した。このhookを含む一括再学習は今回は未実行。同じ評価関数自体は下記4構成で実行済み。閾値の自動順位付けや学習重みは変更せず、候補レビュー資料として扱い、`release_ready=false` を維持する。

### 変更前後の比較

930原文datasetのdev100原文を固定し、HEADの旧segmenterと今回のsegmenterを同じSwift評価器で比較した。旧／新候補のモデルSHAはそれぞれ `2c9ae52f24a1855a11ecc95d4e2ed80ff88fa5e79325a36102d247cfc0ad7581`、`2cef9e0443d6ca5f54caf9c999959aa78d0ad7f8b030e0462a1749a091b1e02b` のまま。dataset SHAは `ec912fd6d4731d141604f5b7012a0ccb5cd5cc8d58b32a40dd5f09fc2a80e2e3`。

- 現行モデル：追加時の完成した英語spanの日本語化が229/2,596（8.82%）から162/2,596（6.24%）へ減った。JA recall 95.71%→97.01%、precision 94.24%→94.96%。
- 再学習候補：同193/2,596（7.43%）から139/2,596（5.35%）へ減った。JA recall 95.66%→96.36%、precision 94.67%→95.47%。
- 削除時も現行216/2,441→154/2,441、候補183/2,441→132/2,441。追加／貼り付けのspan差は現行7件・候補3件、追加／削除は現行8件・候補6件で、修正前後で増えていない。
- segment時間p95は現行36.946→37.073 ms、候補40.764→42.102 ms。このMacのDebugビルド各1回の値であり、IME全体の応答時間や性能目標への合格ではない。

1構成8,024 snapshot、4構成合計32,096 snapshot。同じ100原文の相関した観測で、独立した32,096件の精度試験ではない。正解は完成文の意図ラベルなので、短い入力だけから意図を確定できるとも主張しない。一般corpusの最終漢字表記はこの評価の対象外。testの再採点やモデル選択は行っていない。[比較結果と実行手順](Tools/AutoMixedTraining/TYPING_EVALUATION.md) を参照。生reportと診断ソースは `build/auto-mixed/embedded-prefix-20260925/` に保存した。

### 検証・途中の失敗

以下のログ名は上記buildディレクトリからの相対名。

- 新fixture試験は修正前に10 assertion失敗・0.218秒（`before.log`）。モデルが単語の両端を提案しない対照、Unicode範囲、保護token、弱い日本語根拠、不成立な前後区間を検証する。
- 初回実装は関連runner集計25件で4 assertion失敗・15.199秒（`first-old.log`）。2件はmadeからmad＋eを誤抽出する新規退行で、全体の辞書語判定を優先する一般規則と回帰試験を追加して修正した。新規負例も見直した。`kyanotexha` は不成立なxhaの前に、変更前から存在するRAW境界を引き継ぐため、新しい候補探索だけの負例になっていなかった。`kyanotegqzha` へ変更し、gqzhaのparse不成立とnoteの非抽出を明示的に検証する。既存テストの期待値は変更していない。
- この負例変更の追加監査では、xhaのparse不成立と、2種類の人工スコアで旧／新segmenterの範囲・kind一致を確認した（`invalid-flank-audit-final.log`、1件成功・0.045秒）。監査初回は両スコアともnoteの全範囲を持つという仮定で1 assertion失敗（`invalid-flank-audit.log`）。境界一致の確認は初回から成功し、全範囲を持つ条件を正しく限定して再実行した。製品コードへの追加変更はない。
- 関連runner集計34件では、旧モデルの既知の句点問題8 assertionが残る（`second-independent-thresholds-refined-20260924.log`、26.275秒）。新候補も34件で8 assertion失敗（`second-punctuation-930-20260924.log`、26.757秒）。前回12件のうちmeetingの4件は解消し、残りは下位adapterのasitan／asitano、通常辞書のasitanote／made、空文脈noteの既知の退行。全回帰成功とは扱わない。
- 旧モデルでの広いCore回帰はrunner集計186件・24 suite成功、23.346秒（`core-old-final.log`）。ユーザー設定を書き換える `testOptionPunctuationMappings` と、別途失敗を確認した旧モデルの `PunctuationModelRegressionTests` を明示的に除外。実Zenzai・導入済みhelper・環境変数を要するデータ／export parity等の条件skipが17件あり、186件すべてを実行済みとはしない。既存manualを含む通常の検証と、実際のinsert／backspaceを使うmeeting回帰を実行した。
- Pythonは65件中51件成功・14skip、4.088秒（`python-all.log`）。追加5試験で、完成前の英語を完成語の破壊率へ数えないこと、方向間の差、Unicode scalar範囲、漢字／かなkindの区別、壊れたtraceの拒否、dev原文以外の除外を確認した。既存のpreview出力拒否エラー表示は負例の期待動作。
- devの実Swift評価は変更前旧110.914秒／変更後旧111.296秒／変更前新115.297秒／変更後新120.649秒で各専用テスト成功。reportに個別ログ位置とfingerprintを記録した。
- 実Zenzaiはホスト側の隔離テストで旧モデル1件成功・2.895秒（`zenzai-independent-thresholds-refined-20260924.log`）、新候補3件成功・11.862秒（`zenzai-punctuation-930-20260924.log`）、いずれもskipなし・backend ready・学習OFF。meetingの逐次追加／削除／全体入力・原文回復を両モデルで確認。新候補では既存の日本語表示回帰と `asitanotennkiwoosiete.` → `明日の天気を教えて。` も確認した。実IMKの物理打鍵とは区別する。

macOS 27 arm64／Xcode 27／Swift 6.4／Python 3.11.9。SwiftPM cache権限・native build非推奨等の既存警告あり。SwiftLintは未導入のため未実行。比較用のCore内一時リンクは削除し、ソースとログはbuild内に保存した。最終 `git diff --check` 成功、モデルSHA不変と資料の参照先を確認した。

今回依頼された境界修正と入力途中評価は実装・検証済み。新候補は残る8 assertion失敗の整理が必要で、採用済みとはしない。用途別の学習重み、漢字／かな変換区間、空文脈の仕様、複数の埋込み英単語の同時探索は未変更。アプリbuild・IME反映・実Mach XPC・実機打鍵・長時間利用・独立test品質評価は未実施。通常IMEおよびMixedのインストール・削除・登録・利用者設定を変更せず、実際の入力本文／文脈も取得していない。

## 作業ブランチの保存とprefix重みの比較（2026-09-25）

利用者の「別のブランチを作って未コミットの変更をコミットして、次の作業を進めて」に対応。`codex/t0t1` のHEAD `362fa25b9dc66f5df4e096ced74bffda1747d2db` から `codex/mixed-prefix-regressions` を作成した。既存の未コミット変更31ファイル（記号コーパス・調査・英単語抽出・入力途中評価を含む）を、差分検査後 `60ac059` にコミットした。元ブランチや既存モデルを巻き戻していない。AGENTS・実装記録・04/06章・退行調査・実際の学習処理とテストを確認した。

次の小さな作業は、前回調査で判明した「記号・文脈variantの追加でprefixの学習重みが薄まる」問題への任意設定と比較学習とした。漢字／かなの表示規則を同時変更せず、重みの影響を分けて評価した。

### 変更と互換性

`Tools/AutoMixedTraining/sample_weighting.py` を追加し、学習configのoptional `sample_weighting={"policy":"prefix-mass-v1","prefix_fraction":0.5}` を `learning.py` から扱う。各train原文の総重み1をprefix群と非prefix群へ配分し、各群の対象位置へ均等に割り当てる。一方に対象位置がなければ残る群へ全重みを配り、両群とも対象なしなら学習から除く。未知policy・増強種別、0/1・非有限比率、train以外への指定を拒否する。監査集計と規則を学習manifestに保存する。

設定省略時は従来式を維持。既定config、dev・calibrationの原文のみの重み、test、元文group、原文・variant・prefix生成、モデルschema、特徴量v1/v2・LR/Viterbi・goldenは変更しない。比較用の `prefix_weighted_config.json` は前候補と同じ探索条件に配分だけを追加した。用途間の配分が変わるため記号の寄与が減ること、0.5は最適値ではないこと、文脈variant由来のprefixは今回増やしていないことを04章に記録した。同章に残っていた「ローマ字として成立すればsubstring探索しない」という旧記述も、前回実装済みの条件付き辞書探索と一致させた。

旧設定を修正後のコードで再学習すると、930原文候補の語彙・全係数・切片・fit reportを完全一致で再現した。デフォルト経路の数値差は0。候補は別artifactとして保存し、既存モデルやIMEへ反映していない。

### 実学習とdev比較

同じsealed dataset SHA `ec912fd6d4731d141604f5b7012a0ccb5cd5cc8d58b32a40dd5f09fc2a80e2e3` を使用。train642原文中、両群に対象位置あり586件・非prefixのみ28件・対象なし28件。総重み614を維持し、prefixの重みは234.2676→293。新データの収集・ダウンロードやtestの再採点はしていない。

候補SHAは `471a88a65739d72386d57fef1531c0a3aa0a031f9c4a709a0fcb4eca728baa22`。Cはdevで10、校正は独立calibration、文脈別閾値はdevでともに0.99、hold0.65・切替ペナルティ0。品質基準と既存テストの期待値は維持した。`release_ready=false`。

前候補と同じdev100原文で、完成文の判定器JA recallは52.25%→54.54%、precision100%・英語破壊0/155は不変、保留率33.33%→31.71%。実Swiftの日本語優先を含む入力途中評価では、完成した英語spanの日本語化が139/2,596（5.35%）→135/2,596（5.20%）、既存位置のkind変化924→834。ただしJA recallは96.36%→96.25%、precision95.47%→95.41%、追加と貼り付けの差3→6件、追加と削除の差6→8件となった。改善は一様ではない。同じ100原文の相関した8,024 snapshotであり、独立した精度試験ではない。

関連回帰では既存8 assertion失敗のうち5件が解消した。内訳は下位adapterのasitan／asitanoとpending n表示の4件、空文脈noteの1件。一方、asitanxの「日本語区間を含めない」負例が新しく失敗した。先頭asitaの平均スコアが採用基準を通り、後続nxと別扱いになるため。通常辞書のasitanote／madeの表記とmadeの区間kindの3件は残り、計4 assertion失敗。失敗数減少だけで合格とはしない。

実測時間は旧設定の再現学習49.075秒、新候補の学習・C選択50.008秒、校正・閾値選択1.773秒、export0.677秒、実Swiftのdev入力途中評価121.367秒、比較全体222.931秒。成果物は `build/auto-mixed/prefix-mass-20260925/`。詳細と再実行CLIは [PREFIX_WEIGHTING.md](Tools/AutoMixedTraining/PREFIX_WEIGHTING.md)。

### 検証・失敗・修正

以下のログ名は上記成果物ディレクトリからの相対名。

- 重み単体5試験成功・0.005秒。記号／文脈variantが増えてもprefix重みが不変、元文総重み、欠けた群・対象なし、旧数値互換、行順・長さ、拒否条件を確認した。
- Python初回は71件・1失敗・8skip・16.104秒（`python-first.log`）。既存40候補用の検証へ誤って105候補の過去artifactを渡したため。40候補の過去artifactに訂正した再実行も、現在のPython実装fingerprintが当時と違うことで完全一致比較1件が失敗（`python-final.log`、11.847秒）。期待値を緩めず、同じ40候補設定で検証用artifactを新しい出力先へ作った。係数・校正を固定したdevだけの閾値再検証で、testや採用モデルは変更していない。
- fixture55原文／297行でv1/v2のCLI学習・校正・export・fixture評価を実行。新しい検証用artifactを使ったPython最終は71件中63件成功・8skip、12.154秒（`fixture-smoke/python-tests.log`）。新規の実fit対照でtest/calibrationのラベル変更が学習へ影響しないこと、test除外が校正へ影響しないこと、fixture隔離を確認。閾値だけの再探索で学習配分を変更できないことも検証した。
- fixture smokeの最後のpure Core検証は、`MixedPunctuationTests.swift` が辞書モジュールをimportしているのにpure用ディレクトリに置かれていたためコンパイル失敗（`fixture-smoke/swift-parity.log`）。本体コードやテスト期待値を変えず、同ファイルを `InputUtilsTests/` へ移した。純粋Core用の対象から分離し、通常Core試験では引き続き全ケースを実行する。最後のparity手順を再実行し44件・9 suite成功、skipなし・1.382秒（`parity-final.log`）。v1/v2特徴量・Viterbi・新fixture exportと承認済みv1／新v2 exportのPython/Swift比較を含む。最初のsmoke一括実行自体を成功と書き換えず、修正後の末尾手順成功として区別する。
- 新候補の関連Core回帰と承認済みexport parityはrunner集計36件・5skip・4 assertion失敗、29.238秒（`core-candidate.log`）。失敗は上記のとおり。exportの数値parity、meeting、通常辞書の句点試験は成功した。
- 新候補の実Zenzaiは4件・3 suite成功、skipなし・12.286秒（`zenzai-candidate.log`）。ホスト側の隔離セッション、実GGUF、backend ready、学習OFFで、meeting追加／削除／全体入力、既存日本語表示、`asitanotennkiwoosiete.` → `明日の天気を教えて。`、下位adapterの未完nを確認した。実IMK打鍵ではない。
- テスト移動後の既存モデルによる広いCore回帰はrunner集計186件・24 suite成功、15件条件skip、23.184秒（`core-current-final.log`）。ユーザー設定を書き換える `testOptionPunctuationMappings` と、既知の旧モデル句点問題 `PunctuationModelRegressionTests` を明示的に除外した。移動した記号試験と新旧exportの数値比較を含む。186件すべてを実行済みとはしない。

環境はmacOS 27 arm64／Xcode 27／Swift 6.4／Python 3.11.9、依存lockは不変。SwiftPM cache権限・native build非推奨の既存警告あり。SwiftLintは未導入で未実行。最終 `git diff --check` 成功、移動したテストの内容がbyte単位で同一であることと、既存2モデルのSHA不変を確認した。評価reportへraw/contextを保存せず、アプリの本文・文脈・入力履歴を収集していない。

配分設定と比較検証は完了したが、新候補は未採用。残る表記・変換区間の問題と新しいasitanxの負例を整理する必要がある。新モデルのアプリbuild・実Mach XPC・IME反映・実機打鍵・長時間利用・独立test品質評価は未実施。通常IMEおよびMixedのインストール・削除・登録・ユーザー設定は変更していない。

## 回帰テストの契約訂正（2026-09-25）

利用者の「明日nxで正解」「テストが変なら修正して」に対応。開始時は `codex/mixed-prefix-regressions`、HEAD `d2554d6ba01fc2287259741c6efc5cf45a5285dc`、working treeはclean。会話とユーザー共通AGENTS、実装記録、05章・06章・退行調査、実際の判定器・reading parser・converter・失敗したテストを照合した。製品の判定器・表示・モデルを変更せず、内部kindを表示仕様と混同した期待値を訂正する。

### 変更理由と影響

- `PendingRomanTailTests` の学習済みモデル負例から `asitanx` を外した。既存の人工スコア試験は元から `asita` とpending suffix `nx` を認めており、「日本語区間を一つも含めない」という条件は旧モデルの結果を固定したものだった。代わりに `JapanesePreferredTests` へ通常辞書／実Zenzaiの2試験を追加。実際のinsertで「明日 → 明日n → 明日nx」、Backspace・再入力・貼り付け・表示確定・Escapeによる原文確定を検証する。raw完全保持、範囲の全被覆、変換対象 `[0,5)`、非fallback、session解放も確認。`nx` の削除・補正は許容せず、一つのspanか複数spanかは固定しない。他の英語・不成立ローマ字・保護tokenの負例と、人工スコアでの採用条件は維持。
- `made`／`to` の言語判定試験を「japaneseKanaのみ」から「全範囲が日本語、読みがまで／と、pending suffixなし」へ変更した。japaneseRomanは既存仕様で許された変換経路であり、日英判定だけで漢字／かなの最終表記を固定すべきではないため。英語文中の曖昧語保持と、人工スコアによるkana／kanji切替試験は不変。
- 通常辞書の2例だけ、`made` は「まで／間で」、`asitanote` は「明日のて／明日の手」を許容した。追加した独立対照は判定器を迂回した `SegmentsManager` で「間で／明日の手」が先頭になり、madeの候補に「まで」もあることを確認する。かなpreviewと全文の辞書変換の両方を許容する理由を明示し、任意の出力を合格にしない。日本語区間、読み全体、raw保持、非fallback、Escapeの原文復元を追加検証する。
- 実Zenzaiの `made → まで`、`asitanote → 明日のて` は従来どおり完全一致を要求。`asitanx → 明日nx` も完全一致とした。句点後の「教えて」、meetingの抽出・途中入力の期待値は変更していない。

理由と適用範囲を [05章](docs/azookey_auto_mixed_codex/docs/05_TEST_AND_EVALUATION.md) に追記し、[prefix重み比較](Tools/AutoMixedTraining/PREFIX_WEIGHTING.md) は比較学習時点の4 assertion失敗を履歴として残したうえで、今回の訂正へ案内した。通常辞書のみでも常に「まで／明日のて」を優先させる場合は別の製品仕様・実装変更になる。学習ラベル、v1/v2特徴量、LR/Viterbi、golden、schema、品質目標は変更なし。

### 実行した検証

ログは `build/auto-mixed/test-contracts-20260925/`。すべて隔離したCoreセッション、学習OFF。今回のテスト／コンパイル失敗なし。

- 最初の新候補・通常辞書関連試験：runner24件、19件実行成功・5件条件skip、17.774秒（`candidate-dictionary.log`）。この後、辞書順位の独立対照と2例のEscape確認を追加して次の試験を実行した。
- 最終の新候補・関連Core回帰：runner40件・7 suite、33件実行成功・7件条件skip、31.667秒（`candidate-core.log`）。従来の4 assertion失敗は訂正後の契約で成功。記号・長音・apple・meeting・pending tail・承認済みv1／候補v2のexport parityを含む。skipは実Zenzai6件とfixture export parity1件で、後者は下記の広い回帰で実行した。
- 新候補・実Zenzai：5件・3 suite成功、skipなし、13.781秒（`candidate-zenzai.log`）。日本語表示・asitanxの追加／削除／復元・meetingの途中入力・句読点追加後の「教えて」・下位adapterのpending nを確認。実GGUFのbackend readyをassertした。
- 従来モデル・広いCore回帰：runner189件・24 suite、ログ上174件実行成功、14件条件skipと導入済みIME試験1 suite skip、25.605秒（`baseline-core.log`）。fresh Python参照のv1/v2特徴量・数値parity、fixture／承認済みexport、既存manualを含む。利用者設定を書き換える `testOptionPunctuationMappings` と、既知の旧モデルの句点問題 `PunctuationModelRegressionTests` は前回同様に明示除外。旧モデルの句点問題が直ったという意味ではない。
- 従来モデル・実Zenzai：4件・2 suite成功、skipなし、5.621秒（`baseline-zenzai.log`）。今回変更した日本語表示・asitanxと、meeting・pending nを確認。旧モデルの句点試験は含めていない。

環境はmacOS 27 arm64／Xcode 27.0（27A266a）／Swift 6.4。SwiftPMのユーザーcache権限、ZIPFoundationの旧watchOS指定、native build非推奨の既存警告あり。SwiftLintはコマンド未導入で未実行。Python参照を再生成したが、学習パイプラインの再学習・単体試験は今回のテスト訂正対象ではなく未実行。`git diff --check` 成功。従来モデルSHA `2c9ae52f24a1855a11ecc95d4e2ed80ff88fa5e79325a36102d247cfc0ad7581` と候補SHA `471a88a65739d72386d57fef1531c0a3aa0a031f9c4a709a0fcb4eca728baa22` は不変。

今回のテスト訂正と新旧モデルでの確認は完了。候補の `release_ready=false` と未採用状態は維持し、4 assertionの訂正を精度改善と扱わない。devの入力途中の英語破壊・方向差など前回の指標はそのまま。新たな独立test品質評価、アプリbuild、実Mach XPC、IME反映、実機打鍵、長時間利用は未実施。モデル採用判断にはこれらを別途確認する。通常IMEおよびMixedのインストール・削除・登録・設定は変更せず、実際の入力本文や文脈を取得・記録していない。

## コミットとMixed試用版の更新（2026-09-25）

利用者の「コミットして。IME本体を更新して欲しい」に対応。テスト訂正と記録の5ファイルを `7b67bd0`（`Align mixed input regressions with display and reading contracts`）として `codex/mixed-prefix-regressions` へコミットした。このHEADからMixed専用アプリをビルドし、前回検証したprefix重み候補SHA `471a88a65739d72386d57fef1531c0a3aa0a031f9c4a709a0fcb4eca728baa22` を明示指定して反映した。`60ac059` の英単語抽出修正も含む。今回、新しい製品ロジックや再学習は追加していない。利用者のローカル試用更新として扱い、モデルの `release_ready=false` と品質未達の記録は維持する。

### 更新と検証

ログ・復旧用コピーは `build/auto-mixed/update-prefix-20260925/`。旧Mixedアプリを `previous-azooKeyMixed.app` として保存した。更新直前・直後ともmacOS標準日本語（`com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese`）が選択中で、Mixedの未確定入力を強制終了する状態ではなかった。

- `Tools/build_mixed_ime.py --model build/auto-mixed/prefix-mass-20260925/export/model.json` によるhelperとアプリ全体のビルド、資源receipt照合、ad-hoc署名・deep strict検証が成功（`build.log`）。診断ログはOFF。既存の通常版と別bundle／service／保存先のprofileを使用した。
- インストーラーの模擬OS試験13件成功・0.052秒（`installer-tests.log`）。一時領域だけの失敗・復旧・更新検証で、実インストール試験と区別する。
- 専用 `update --dry-run` 成功後、`update` でMixedだけを入れ替え、専用LaunchAgentを再起動した（`update-dry-run.log` / `update.log`）。再登録・再有効化・入力ソースの切替は行わず、前後のMixed全モードの有効状態と選択中ソースが一致した（`status-before.json` / `status-after.json`、`current-before.txt` / `current-after.txt`）。
- 導入先とビルドのSHA-256はapp本体・helper・モデルの3点で一致（`hashes-before.json` / `hashes-after.json`）。appは `10f4e5975b996d69d3077354826cd68368a72cb832c460715e9409d499bb8439`、helperは `bb48ba8058b0cfb1207e98db81177cdbeddcdef5afdbbc2cdeec7e9da514dd73`。bundleの有効マーカーも上記モデルSHAを指すことを確認した。
- 更新済みhelperへの実Mach XPC試験5件・2 suite成功、skipなし、10.866秒（`installed-tests.log`）。既存4試験でappleの日本語確定後入力、長音、記号、混在文、commit重複除外を確認。追加の隔離診断1試験では文脈取得不可／空の両方で、`asitanx → 明日nx`、`asitanote → 明日のて`、`made → まで`、meeting混在文、`asitanotennkiwoosiete. → 明日の天気を教えて。` を逐次入力・貼り付け・確定・Escapeで確認した。meetingは完成した時点から英字保持、nxと句点は削除・再入力、句点の前後は「教えて」の保持も確認。

追加診断は `InstalledPrefixModelVerificationTests.swift` としてbuild内に保存し、Coreテストへの一時リンクは終了後に削除した。先行する `probe-compile.log` は実サーバーへの接続フラグなしでコンパイルだけを確認したため1件skipであり、実行成功には数えない。後続の `installed-tests.log` で明示フラグを付けて実行済み。

### 環境制約と残事項

初回のsandbox内ではgit indexへの書込みが拒否されたため、そのcommit試行は失敗。ホスト側の許可された実行で同じ5ファイルをコミットした。入力ソースの初回sandbox内照会もHIServicesの接続エラーと不整合な状態を返したため採用せず、ホスト側で再取得した状態だけを更新判断と前後比較に使用した。自動承認レビューによる拒否はなし。ビルド・更新・実サーバー試験の失敗なし。環境はmacOS 27 arm64／Xcode 27／Swift 6.4、既存のSwiftPM・Xcode依存警告は残る。SwiftLintは未導入で未実行。最終差分空白検査は成功。

コミットとMixed版の反映は完了。利用者は入力メニューでMixed（自動）を選んで試用できる状態で、選択操作はこちらでは行っていない。通常版のファイル・設定・辞書・登録を変更していない。実際のアプリ本文・文脈・入力履歴も取得していない。今回の確認は実サーバーに固定例を送った自動試験であり、更新後の実IMK物理打鍵、secure field、長時間利用、未閲覧データでの品質評価・一般配布は未実施。

## 疑問符・感嘆符の全角表示とMixed更新（2026-09-25）

利用者の「？／！も日本語にくっつく時は全角にして欲しい」に対応。開始HEADは `465ce33`、`codex/mixed-prefix-regressions` のworking treeはclean。共通AGENTS、既存記号仕様、実装記録と実際の表示policy・renderer・保護処理を確認した。

`MixedPunctuationPolicy.japanese` へ `? → ？` と `! → ！` の2対応を追加。既存の日本語優先規則を共用し、未確定の日本語区間、取得可能な確定済み日本語の直後、連続記号を全角表示・確定する。英語直後、URL・識別子などの構造保護、数値に接する記号、結合文字の書記素境界は既存規則を維持。原文バッファとモデル入力はASCIIのまま、Escapeで原文に戻せる。manual、学習モデル・特徴量・LR/Viterbi・schema・goldenは変更していない。対象が5記号から7記号へ増えることを01章と `Tools/AUTO_MIXED_IME.md` へ明記した。

### 検証と反映

ログは `build/auto-mixed/question-exclamation-20260925/`。

- 初回の記号Core試験はrunner9件、8件実行成功・実Zenzai1件skip、13.385秒（`core.log`）。その後、既存の括弧削除ケースも保持したループに整理し、疑問符・感嘆符のTab候補／原文候補とUnicode offsetの検証を追加した。
- 最終の関連Core回帰はrunner38件・6 suite成功、skipなし、47.612秒（`core-final.log`）。実GGUF・backend ready・学習OFFで、`asita? → 明日？`、`asita! → 明日！`、英語・URL・数値・結合文字の原文保持、確定文脈、削除・再入力・Escape・Tabを検証。既存のapple・meeting・pending tail・長音も確認した。句読点安定性試験へ `?`／`!` を追加し、文脈取得不可／空、si／shiの両方で「教えて」が漢字のまま維持されることを通常辞書と実Zenzaiで確認した。
- 現在のモデルを明示してアプリとhelperをビルドし、資源receipt・ad-hoc署名・deep strict検証成功（`build.log`）。更新dry-run成功後、Mixed専用updateで反映した（`update-dry-run.log` / `update.log`）。更新前後ともmacOS標準日本語が選択されており、Mixedの全モード有効状態と選択中ソースが一致。再登録・再有効化・入力ソース切替はなし。
- 導入先とビルドのapp／helper／モデルSHAが一致（`hashes-after.json`）。appは `0a3f93ecfd2e664df51c039c17614d49c616c2dbb378c87e568992e48edb4d6b`、helperは `e188a48f75a15c838190868863019f780806c0e2b77b7f8402585c9bd873daa9`。モデルSHAは `471a88a65739d72386d57fef1531c0a3aa0a031f9c4a709a0fcb4eca728baa22` で更新前と同じ。診断ログはOFF。旧Mixedアプリのコピーは同ディレクトリの `previous-azooKeyMixed.app` に保存した。
- 更新済みhelperの実Mach XPC試験4件成功、skipなし、3.594秒（`installed-tests.log`）。既存試験へ日本語・英語直後の `?`／`!`、`?!`、確定左文脈、URL内の記号を追加し、表示・ASCII原文・確定を確認。既存のapple、長音、混在文、commit重複除外も成功した。

テスト・ビルド・更新の失敗なし。macOS 27 arm64／Xcode 27／Swift 6.4、既存の依存・SwiftPM native build・Xcode警告は残る。SwiftLintは未導入で未実行。最終 `git diff --check` 成功。再学習・新たな品質評価は行っておらず、`release_ready=false` は維持。実IMKの物理打鍵・secure field・長時間入力は今回未確認で、実サーバーの固定例試験とは区別する。通常版のファイル・設定・辞書・登録を変更せず、実際のアプリ本文・文脈を取得・記録していない。今回の差分は未コミット、Mixed版には反映済み。

## 自動モードのA案「あA」アイコン（2026-09-25）

利用者が選択したA案を実装。開始HEADは `e1c29e0`、ブランチは `codex/mixed-prefix-regressions`。開始時の未追跡 `design/` は前の提案素材として保持した。`design/mixed-menu-icons/a-bilingual.tiff` と同一の資源を `Tools/Resources/mixed-auto.tiff` に保存し、Mixed専用ビルドが `auto.tiff` へコピーする。旧「自」のSwift生成スクリプトは廃止した。フォント環境によるビルドごとの字形変化を避け、承認された形を固定する。自動モードの4つのアイコン参照と `TISIconIsTemplate=true` は維持。通常版・manualモード・変換処理・モデルは変更しない。

### 検証

ログと検証用スクリプトは `build/auto-mixed/icon-a-20260925/`。

- 採用TIFFと提案Aのbyte一致を確認。ImageIO／AppKitで2表現（18px、36px）、両方18pt、黒単色・透過背景を確認（`icon-validation.log`）。比較画像も目視した。採用画像SHA-256は `8c81a8d693bf748febfe13f0e890536a56923611042a31116f1d538e80371dad`。
- 現在のprefix重みモデルを明示してアプリ・helperをビルドし、資源receipt照合、ad-hoc署名とdeep strict検証成功（`build.log`）。モデルSHA `471a88a65739d72386d57fef1531c0a3aa0a031f9c4a709a0fcb4eca728baa22` とhelperのSHAは導入済み版と一致。診断ログOFF、通常日本語／英数のアイコン資源も不変（`hashes-before.json`）。品質未達の扱いは維持し、学習や精度評価は実行していない。
- インストーラーの模擬OS試験13件成功、0.051秒（`installer-tests.log`）。実OSへの更新とは区別する。更新dry-runも成功（`update-dry-run.log`）。
- 一時的なbundle検証スクリプトの初回だけ、runtime exportに存在しない `release_ready` を直接参照して `KeyError`。実際のexport定義を確認し、この誤った参照を削除した。製品コード・テスト期待値を変えず、同じモデルSHAと有効マーカーを確認して再実行成功（`bundle-validation-before.log`）。ビルド・既存試験の失敗はなし。

macOS 27 arm64／Xcode 27／Swift 6.4。既存の依存・native build非推奨・署名前のバイナリ修正警告あり、最終署名検証は成功。SwiftLintは未導入で未実行。資源変更だけのため変換器の全回帰・再学習は未実行。OSが実際に表示するメニューバー、ライト／ダークの自動色反転、実IMK打鍵は未確認。

### 反映状況

最初のホスト照会でMixed（自動）が選択中だったため更新を待ち、利用者の切替報告後に `com.apple.keylayout.ABC` を確認した。利用者から今後の英数キーによる切替操作も許可されたが、今回はすでにABCだったためキー操作を行っていない。

- 旧Mixedアプリを同ログディレクトリの `previous-azooKeyMixed.app` に保存後、Mixed専用 `update` で反映成功（`update.log`）。入力ソースの再登録・再有効化・選択操作は行っていない。更新前後ともABCで、Mixed全モードの有効状態・選択状態が一致（`current-pre-update.txt`／`current-after.txt`、`status-pre-update.json`／`status-after.json`）。
- 導入先とビルドのapp／helper／モデル／アイコン／manual用2アイコンのSHAが一致（`hashes-after.json`）。appは `9bae39c6fa939f8bdb9e9c7675a5c7321d52cc40fbea51c1666efa260ae8e416`、自動アイコンは上記A案のSHA。導入先でも4つのアイコン参照・テンプレート指定・モデル有効マーカー・診断OFF・deep strict署名検証が成功。
- 更新済みhelperへの実Mach XPC試験4件成功、skipなし、3.590秒（`installed-tests.log`）。appleの日本語確定後入力、長音、日英に接する記号（？／！を含む）、混在文とcommit重複除外を確認した。固定例を隔離セッションに送り、実際の利用者の本文・文脈は取得していない。
- メニューバーの目視確認を試みたが、画面操作ツールの `TextInputMenuAgent` 取得が `timeoutReached`（-10005）で失敗した。画面状態は取得できず、実際の表示とライト／ダークの色反転は未確認。これをビルド・反映・XPC試験の成功とは区別する。

Mixed版への反映は完了し、利用者が自動モードを選んで試用できる状態。通常版のファイル・設定・辞書・登録は変更していない。最終 `git diff --check` 成功。今回の差分は未コミット。

## 不成立ローマ字による全体英字化の修正（2026-09-25）

開始HEADは `7049be7`、ブランチは `codex/mixed-prefix-regressions`、working treeはclean。利用者が提示した `zuttotukatteirutodanndannnyuuryokugaosokunarukigasurnndakedo`（60 scalar）を、導入中と同じモデルで一文字ずつ再現した。長さ上限ではなく、53文字目の `…sur → …surn` で読みが「…すrn」になり、`RomanSpanReading.parse` が不成立になることが発端だった。日本語優先表示の全体検証を通らず、全範囲がunresolvedとして原文表示された。英語辞書に採用された結果でも、converterの例外による全体fallbackでもない。

この入力の平均日本語スコアは約0.9775で、現在のT3採用閾値0.99には届かない。通常の日本語優先表示は、読みが成立すれば別途かな漢字表示を認めるが、不正な文字を含む場合の独立部分の救済が欠けていた。ローマ字を `…surunn…` に直した対照は全体の読みが成立した。本文の自動補正を解決策にはしない。

### 変更と仕様への影響

- `RomanSpanReading.independentRuns` を新設。依存ライブラリで実際に定義されている `ComposingText.inputIndexToSurfaceIndexMap()` が返す独立境界を使い、かなに読める部分と原文のまま残った部分を分離する。各かな部分を同じ入力APIで読み直して一致を確認し、促音・拗音・nの依存を文字数で推測しない。かなと未変換文字が一つの不可分segmentに混在する場合は救済しない。独自のローマ字表、誤字補完、文字削除は追加していない。
- `JapanesePreferredSegmenter` の保留時だけ、先頭が読める区間に限り部分変換を認める。日本語部分ごとに既存の `hold_ja`（現在0.65）以上の平均スコアを要求する。低信頼部分、英語判定済み範囲、辞書にある単語、URL等の保護は優先する。末尾のpending文字は既存parserで成立する場合だけ直前のかな部分へ付ける。今回の最終入力は `[0,51)` の日本語、`[51,52)` の原文 `r`、`[52,60)` の日本語になる。`rn` の入力途中でも先頭の日本語を保持する。
- 製品変更は上記2ファイル。T0〜T2、`TrainedMixedSegmenter`、特徴量v1/v2、LR/Viterbi、学習済みモデル・閾値、golden、schema、manual、原文バッファは変更していない。01章と試用手順に部分変換の条件を追記した。
- 既存の人工スコア試験にあった `abcai`／`asitaqz`／`sushibx` の「日本語区間を一つも含めない」は、今回修正する全体棄却を固定していたため訂正。読みが成立する正確な部分列（`a + b + cai`、`asita + qz`、`sushi + bx`）を要求し、変換対象には不正な文字が含まれないことを検証する。低信頼時に救済しない対照を追加。URL・メール・識別子、英語の負例、従来baselineの期待値は維持した。失敗数を減らすだけの任意出力許容にはしていない。

### 検証と失敗履歴

ログ・診断スクリプトは `build/auto-mixed/invalid-roman-20260925/`。入力は利用者提示の固定例と試験用に作成した文字列のみで、実際のアプリ本文・確定文脈・入力履歴を採取していない。変換試験は隔離セッション、学習OFF。

- 修正前の逐次診断で52文字目までは日本語表示対象、53〜60文字目は全体unresolvedを確認（`probe-before.log`）。新規回帰試験は修正前に1件・3 assertion失敗、0.355秒（`regression-before.log`）。
- 初回実装は「T3で日本語採用後に読みだけ棄却された場合」に限定し、元の3 assertionが失敗したままだった（`recovery-first.log`）。実スコアと採用閾値を確認して、この実装とbaselineへの一時変更を撤回。日本語優先表示の既存hold閾値で各部分を独立検証する最終形にした。次の実行は今回の例が成功し、上記の旧全体棄却試験3 assertionだけが失敗（`recovery-second.log`）。仕様理由を記して期待値を訂正した。
- 拡張試験の初回は22件・4条件skip・1件失敗、31.521秒（`recovery-tests.log`）。新規テストが `kan'iqzdesu` を独立したかなに分けられると誤認していた。実際の固定依存は `n' → ん'` を不可分segmentとして保持する（`boundary-probe.log`）。製品コードで無理に分割せず、この例を救済不可の明示的な負例として残した。
- 最終の関連Core回帰は43件・7 suite成功、skipなし、91.829秒（`core-final.log`）。通常辞書と実GGUF／Zenzai readyの両方で60文字の逐次入力、文脈取得不可／空、`rn` への遷移、削除・再入力、貼り付け、句点追加、表示確定、Escape原文確定、修正入力、Unicode範囲と表示offset、child解放を検証。既存のapple、meeting、曖昧語、pending nx、長音、記号と「教えて」の維持も成功した。
- 実Zenzaiの最終表示は「ずっと使っていると段々入力が遅くなる気がすrんだけど」。通常辞書の先頭候補は「ずっと使っているとだんだん入力が遅くなる貴ガスrんだけど」で、表記順位の違いを全英字化の問題と混同しない。今回の契約は読みが成立する部分を変換し、`r` のみ原文で残すこと。人工スコア試験と実モデル試験は区別し、一般的な誤字判定精度の改善は主張しない。
- 60文字の入力replay本体は通常辞書7.135／10.105秒、実Zenzai6.155／8.362秒（文脈取得不可／空）。起動・その他のassertionを含むsuite全体とは区別する。長時間利用で遅くなる現象の調査や性能合格を意味せず、その原因・長時間RSS・実IMKの打鍵遅延は未確認。

### Mixed反映

- 現在のモデルを明示してMixedアプリとhelperをビルドし、資源receipt照合・ad-hoc署名・deep strict検証成功（`build.log`）。インストーラーの模擬OS試験13件成功・0.047秒（`installer-tests.log`）。
- ホスト側でABC選択中を確認し、旧Mixedを同ディレクトリの `previous-azooKeyMixed.app` へ保存。更新dry-run後、Mixed専用 `update` 成功（`update-dry-run.log`／`update.log`）。更新前後の選択中ソースは `com.apple.keylayout.ABC` で、Mixed全モードの有効状態も一致。切替操作・再登録・再有効化・通常版の変更はなし。
- ビルドと導入先のapp／helper／モデル／自動・manualアイコンSHAが一致し、導入先の署名検証成功（`hashes-after.json`）。app SHAは `df03a5b549677eb2bb36250d010577d792978c7582166892a4eea0e5bcb7b3f7`、helperは `48740ee33ac968e39724d84ff0f3a0a6a9a6ecc6fb4df7fc286ed66dcdc9df85`。モデルは従来の `471a88a65739d72386d57fef1531c0a3aa0a031f9c4a709a0fcb4eca728baa22`、A「あA」アイコンも不変。診断ログOFF。
- 更新済みhelperへの実Mach XPC試験5件成功、skipなし、4.982秒（`installed-tests.log`）。今回の例で変換済みprefixから1文字ずつ不成立部分を追加し、日本語保持、`r` だけの原文表示、貼り付けとの一致、表示／原文確定を確認。既存の4試験も成功した。

macOS 27 arm64／Xcode 27／Swift 6.4。既存のSwiftPM・依存警告と依存Converterのデバッグ出力あり。SwiftLintは未導入で未実行。ビルド・更新・最終試験の失敗なし。実IMK物理打鍵・長時間利用・独立データでの品質評価・再学習は未実施で、モデルの品質未達という扱いは維持。診断用の一時テストリンクは削除済み。最終 `git diff --check` 成功。修正はMixedへ反映済み、差分は未コミット。

## 長い未確定文の再計算削減とRelease化（2026-09-25）

開始HEADは `7371e62`、ブランチは `codex/mixed-prefix-regressions`、working treeはclean。共通AGENTS、実装記録、実際に存在する `docs/azookey_auto_mixed_codex/` の仕様を確認した。`docs/auto-mixed/` は現ツリーに存在しない。固定依存は引き続き `ad714fea8cb2fe113aea86ba5c42563cdaf77cfb`。実定義の `createSession`／`withSession`／`removeSession` と、そのsessionが保持する入力・lattice・Zenzaiキャッシュを確認した。

### 変更

- `MixedPerformance` は新設の数値専用・TaskLocal計測。期限付きMixed診断でだけ有効化し、queue待ち、server actor待ち、日英判定全体、特徴量/LR/Viterbi、ローマ字解析、候補生成、IMK表示呼出し、child作成/解放、候補要求、未応答キー数を記録する。本文・文脈・候補・入力ハッシュを製品診断に追加しない。既定OFF、24時間/10,000件という既存上限は維持。
- Mixedビルドの既定をReleaseにし、IMEと同梱helperの構成と資源パスを揃えた。`--configuration Debug` も選択可能。`mixed-build.json` に構成名を残す。通常版のビルド設定・登録は変更しない。
- 同じ個数の区間で、前方の区間がすべて不変、最後の日本語区間の開始位置が同じ、rawが末尾追加/削除だけの場合にIDを保持し、辞書変換のchildを再利用する。実Zenzaiは後述の退行を受け、完全な変換入力が同じ場合だけchildを再利用する。分割/結合/言語変更、中央置換、開始位置・文脈・設定変更では該当childを作り直す。確定・取消・フォーカス終了の解放は維持。
- 編集した区間の採用候補は失効。実Candidateはchild内に保持し、complete prefixが同じ `asita → asitan` では候補生成を省いて末尾表示を更新する。編集後のtokenを再発行し、古いtokenとrevisionの組合せを拒否する。確定候補を文字列から再構成しない。
- T3判定の保護・特徴量・スコアを同じraw/文脈/モデルの1回の呼出し内で共有する。短縮prefix、文脈なし対照、次の編集は別計算。編集をまたぐ特徴量キャッシュは追加しない。
- 最初の測定で短文のp95上昇を認めたため、推論途中の重複ソートも除去した。公開特徴量キーのUTF-8順は維持し、推論の有効添字は従来どおりソートしてFloat64で加算する。各キーはfamily/offset/lengthで一意なので内部生成のSetも配列へ変更。特徴量定義、語彙、係数、閾値、Viterbi、schema、goldenは変更せず、v1/v2のPython parityで照合した。表示仕様の変更や期待値の緩和はない。

使用モデルは従来の `prefix-mass-20260925/export/model.json`、SHA `471a88a65739d72386d57fef1531c0a3aa0a031f9c4a709a0fcb4eca728baa22`。schema version 2／anchored-context-v2、XPC capability version 1を維持。再学習・辞書更新は行わず、モデル品質未達の扱いも維持する。間引き、debounce、かな先行表示、自動確定、推論品質変更、定期再起動は追加していない。

### 性能測定

ログ・baselineソース・数値traceは `build/auto-mixed/latency-20260925/`。Mac15,6／Apple M3 Pro／36GiB、macOS 27、Xcode 27／Swift 6.4、AC電源・lowpowermode=0。同じ学習OFFの実Zenzai・モデル・receipt確認済み辞書/GGUFを使用。性能replay中に別のビルドや変換試験は走らせていないが、OSのCPU周波数・温度・他アプリ負荷は固定していない。

`MixedLatencyBenchmarkTests` は固定の試験文を1文字ずつ入力し、20/60/120/240文字で10文字削除・再入力する。各系列はそれぞれ40/80/140/260イベント。予定到着時刻に従う直列replayで、queueはその時刻から処理開始まで、追いつきは最後のキーの予定到着から最後の表示生成まで。文脈取得不可の固定条件でのCore＋実Zenzai＋純粋rendererの実時間であり、実IMK・XPC・画面の描画完了の遅延とは区別する。各系列の全prefixと編集を集計しており、全イベントが最大長の状態ではない。

最適化前の計測だけを足したソースを保存し、Debug、Release化のみ、最終最適化Releaseを順に実行した。プロセス開始後の辞書/GGUF準備＋最初の変換は、それぞれ443.658／176.158／139.982msでwarm系列から除外。LR JSON読込はこの初回値に含めない。OSのファイル/Metalキャッシュを消したcold測定ではない。

1キーの処理時間。各セルは **p50 / p95 / p99（ms）**。nearest-rankで集計。

| 最大文字数 | キー/秒 | Debug | Releaseのみ | 最適化Release |
|---:|---:|---:|---:|---:|
| 20 | 5 | 91.941 / 121.936 / 126.197 | 44.563 / 60.398 / 61.962 | 39.732 / 54.022 / 57.641 |
| 20 | 10 | 79.280 / 94.958 / 100.841 | 34.085 / 36.440 / 38.666 | 31.837 / 46.625 / 51.133 |
| 20 | 15 | 79.476 / 95.784 / 103.583 | 26.245 / 29.760 / 30.353 | 23.859 / 38.075 / 45.088 |
| 60 | 5 | 155.451 / 216.088 / 227.103 | 59.441 / 70.746 / 76.809 | 38.875 / 64.622 / 72.737 |
| 60 | 10 | 155.535 / 199.277 / 209.196 | 38.292 / 42.540 / 45.358 | 33.207 / 54.848 / 58.170 |
| 60 | 15 | 154.059 / 199.571 / 208.294 | 32.307 / 36.238 / 38.297 | 27.755 / 43.531 / 52.998 |
| 120 | 5 | 274.773 / 401.886 / 416.184 | 71.519 / 89.135 / 89.789 | 42.311 / 82.463 / 87.081 |
| 120 | 10 | 245.353 / 373.868 / 385.282 | 45.052 / 55.951 / 57.316 | 37.317 / 64.207 / 66.916 |
| 120 | 15 | 245.976 / 373.750 / 378.085 | 38.542 / 52.812 / 54.772 | 32.581 / 53.507 / 55.161 |
| 240 | 5 | 470.593 / 798.492 / 879.251 | 93.778 / 124.762 / 133.238 | 46.479 / 121.353 / 130.488 |
| 240 | 10 | 460.650 / 796.566 / 869.749 | 73.150 / 115.636 / 124.968 | 42.143 / 88.550 / 96.152 |
| 240 | 15 | 459.007 / 790.025 / 869.832 | 70.822 / 116.733 / 124.125 | 36.054 / 78.533 / 82.813 |

入力停止後の追いつき時間（ms）。queue/response自体のp50/p95/p99、待機数、処理内訳は `summary.json` に全条件を保存した。

| 最大文字数 | キー/秒 | Debug | Releaseのみ | 最適化Release |
|---:|---:|---:|---:|---:|
| 20 | 5 | 115.329 | 57.113 | 14.961 |
| 20 | 10 | 102.312 | 46.204 | 5.771 |
| 20 | 15 | 478.696 | 28.855 | 11.957 |
| 60 | 5 | 200.810 | 73.565 | 17.648 |
| 60 | 10 | 3742.058 | 53.455 | 13.814 |
| 60 | 15 | 5838.741 | 46.030 | 5.831 |
| 120 | 5 | 11437.405 | 85.443 | 21.708 |
| 120 | 10 | 19021.937 | 66.398 | 9.066 |
| 120 | 15 | 23469.088 | 57.382 | 5.642 |
| 240 | 5 | 69922.817 | 120.066 | 96.012 |
| 240 | 10 | 93116.236 | 556.979 | 78.729 |
| 240 | 15 | 100947.610 | 4097.749 | 101.306 |

- Debug→Releaseのみ、Debug→最終最適化の両方で1,560段階の表示ハッシュが全件一致。欠測0。ハッシュは固定例テストだけで生成し、利用者入力の診断には使わない。
- 最終版は現行Debug比で全12条件のp95が低下。240文字・15キー/秒は790.025→78.533ms（約90.1%低下）、追いつき100,947.610→101.306ms。Releaseのみ比でも同条件は116.733→78.533ms。
- 一方、**Releaseのみを基準にすると短文のp95非退行は未達**。20文字・10キー/秒で36.440→46.625ms、15キー/秒で29.760→38.075ms。初回実装でも同傾向があり、前後を交互に3回再測定した結果を `short-*.json` に保持した。不要ソート除去後の順位退行修正後の最終一巡でも約8〜10msの上昇が残る。中央値や追いつき時間の改善で、このp95悪化をなかったことにはしない。短文の追加評価・変換部の分析は残る。
- **特徴量＋LR＋Viterbiのwarm p95≤5msも全条件では未達**。最終版240文字の5/10/15キー毎秒は16.337／9.594／6.786ms、120文字・15キー/秒は4.348ms。目標を変更せず、性能の全合格とは報告しない。初回の最適化版も `first-optimized-*.json/log` として保存した。
- 同じraw/文脈の重複計算を省いても、条件付き短縮prefixは別に評価する。baselineのclassification/scorePass計器はT3主判定だけで、旧preferred側の重複評価を含まないため、この内訳だけで新旧の短縮率を算出しない。日英判定全体のjudgment時間は両者で同じ範囲を測る。
- 全系列合計のchild作成・候補計算はどちらも1,560→921。20文字の各40イベントでは40→24 child/候補計算。240文字の各260イベントでは260→152 child/候補計算。読みが変わるZenzai sessionまで保持した初回版より再利用を狭めたため、最終値は初回の72 childとは異なる。系列末尾の確定による解放はキーtraceの外だが、確定後のactiveChildCount=0を全系列で検証した。

### 自動検証と途中の失敗

- 最終のCore回帰67件・11 suite、skipなし、59.507秒。実GGUF backend readyを要求し、apple、meeting、記号、長音、asitanx、不成立ローマ字、候補選択・編集失効、Escape、確定、フォーカス/epoch、Unicode範囲、queue順序を確認。実Zenzaiを使う1,000回の入力・確定では、各回のchild数とqueue件数0、作成/解放数一致を検証。これはsession/queueの保持件数試験であり、長時間のRSSリーク検出試験ではない。
- 最終のgolden/Python parityは45件・10 suite、skipなし、0.723秒（`parity-exports.log`）。128件のv1 golden、凍結v2、fresh Pythonと、既存fixture v1/v2 export、承認済みv1と導入対象v2の各128数値とv2の21区間例を検証。activeIndices一致、logit/確率誤差1e-12未満を維持した。学習のやり直しはしていない。
- IMKクライアントの模擬欄/transport試験11件成功、0.005秒（`client.log`）。実アプリ打鍵とは区別する。インストーラーの模擬OS試験13件成功。既存bridge試験はrunner10件中9件成功・1件skip、1.254秒。skipは旧T4モデル用の明示artifact未指定試験で、現在のモデルの回帰67件とは別。候補分離・文脈/設定変更・実Zenzai交互session・学習境界の試験は実行した。
- 初回pureスクリプトを直接実行した際は実行権限がなくexit 126。`sh` で再実行して成功。初回pureの4件skipと、その後のparityの2 export skipは、最終の環境変数指定で解消した。sandbox内のhardware sysctl取得不可はホスト側で再取得。自動承認レビューによる拒否なし。
- 初回最適化66件も成功したが、短文p95上昇という計測上の未達を認めて追加修正・再検証した。テスト期待値、golden、閾値の緩和は一切行っていない。固定fixtureを出す依存Debug出力は集計後にログから除き、試験結果と数値traceを残した。実際の利用者の入力や確定文脈は収集していない。

### 実XPCで判明した退行と計画差分

最初のReleaseアプリはビルド・署名・反映が成功したが、更新済み実Mach XPC試験6件中、記号試験1件で10 assertionが失敗。空の確定左文脈を持つ `asita.`／`,`／`?`／`!`／`?!` が「明日」ではなく「9/26」を先頭に表示・確定した。ほか5件と実XPCの1,000回確定は成功（19.998秒）。成功したCore試験や文脈取得不可の1,560一致だけでは不十分だった。期待値を日付へ変更していない。

ABC選択中を確認する専用updateで旧Mixedへ戻し、同じ実XPC記号試験が成功（1.958秒）。Coreだけの空文脈試験も追加したが、こちらは修正前から成功しており、実サーバーの退行再現と混同しない。Coreテストでは同じ文脈を判定器と変換器の両方へ明示して確認する。

依存のZenzai sessionはlatticeだけでなく前回候補に由来する表記制約を保持し、次の読みの制約へ使用する。純粋なキャッシュとしての同値性が成立しないため、計画第3項の実Zenzai再利用を「同じ完全な変換入力」に限定した。読みが変わる場合は従来どおり新規child、辞書のみの変換は末尾編集でも再利用する。共有converterの純粋なmemoizationは維持し、全体のstopCompositionやモデル再起動は呼ばない。特定語・文字数で例外化する対応ではない。

この変更は表示維持を優先する計画差分で、当初期待したZenzai latticeの編集間再利用は未完。安全に広げるには、順位に影響する履歴と計算キャッシュを分離できる依存APIが必要。初回の高速な値で最終版を報告せず、制限後の全12条件を再測定した結果が上の表。旧結果は `history-cache-*.json/log` に保持した。

### 反映と残事項

順位退行修正版をMixed専用updateで反映済み。ビルドと導入先のapp/helper/モデル/自動・manualアイコンSHA一致、deep strict署名検証成功。IME・helperともRelease、診断はOFF。app SHAは `e0bd5775cf38916c27649cf1579aee72a6fbdfa037a0dce616f82576988f9176`、helperは `8da0f55eefffb932e6a4537a4471ad19f150e0b397a3072636842b001fc17a64`。モデルとアイコンは従来と同じ。更新前後の選択中ソースはABC、Mixedの全モード有効状態も一致し、再登録・再有効化や通常版の変更はなし。旧Mixedの復旧用コピーを同ディレクトリに保持した。

最終の導入済み実Mach XPC試験は6件・skipなし、19.792秒で成功（`installed-final.log`）。前回失敗した記号の表示・確定も期待値どおり。新設の実XPC 1,000回試験では「明日n」の表示・確定・ack後のraw/未ack確定が空、100回ごとのフォーカス更新を検証した。固定例の隔離sessionを使用し、実際の利用者の欄や入力履歴にはアクセスしていない。

実アプリ確認用にTextEditの空の新規書類を作成したが、最終反映後の操作時にツールが「Macがロック中、物理入力検出により自動解除停止」と返した。解除を利用者へ依頼しており、**更新後の実アプリへのキー入力は未実行**。IMKの模擬欄試験や実XPCの成功で代用したとは報告しない。通常版・secure field・複数アプリでの連続打鍵、長時間RSS、診断ONでの実アプリ計測も未実行。SwiftLintは未導入で未実行。既存のSwiftPM native build非推奨・依存APIの警告は残る。

最終の差分空白検査は成功。差分は未コミット。Release化、数値を変えない再計算削減、同じ読みの候補再利用、期限付き計測は反映済みで試用可能。短文のReleaseのみ比のp95非退行、判定5ms目標、読みが変わるZenzai sessionの安全な再利用は未達/未完であり、計画の全合格とは扱わない。次の作業はこの3点と、Mac解除後の実アプリ確認。

### 実アプリ操作の再試行（2026-09-25 10:46 JST）

利用者の依頼を受け、ロック解除後のTextEditで前回作成した空の試験書類を使用した。既存書類や利用者の入力履歴は使用していない。試験開始時の選択中ソースはmacOS標準日本語（`com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese`）。有効化済みMixed自動を専用controlの `restore` で選択し、CUAの `pressKey` により `asita` を1キーずつ送信した。貼り付け・typeTextは使っていない。

- MixedではAX値が `asita`、その後TextEditの自動大文字化を伴う `Asita` になった。未確定の日本語への変換は確認できなかった。送信後のTISはMixed自動を示した。
- 試験文字を消し、macOS標準日本語へ戻して同じ `pressKey("a")` を送る対照試験でも、`あ` ではなく `a` とTextEditの大文字化候補が表示された。送信後のTISは標準日本語のままだった。
- この結果はMixed固有の変換失敗を示すものではなく、操作ツールによる文字キー送信を通常のIME入力と同等に扱えないことを示す。キーイベント内部の配送経路は未確認なので、IMEを迂回する仕組みまでは断定しない。物理打鍵での変換・確定・削除・再入力・長文の追従性は依然未確認で、実アプリ試験成功とは報告しない。
- 試験文字を消し、空の書類を一時フォルダに `mixed-ime-ui-check-empty.rtf` として保存して閉じた。保存後のUI取得は `noWindowsAvailable` を返し、空書類の保存ファイルを確認した。入力ソースは試験前の標準日本語へ復帰済み。登録、有効状態、モデル、診断設定、導入アプリやコードには変更なし。

Macのロックという前回の制約は解消したが、今回は自動キー送信の制約で実入力確認に至らなかった。次の実アプリ確認には物理キー入力、または通常のIME経路を通ると検証済みのキー送信手段が必要。
