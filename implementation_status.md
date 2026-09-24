# Auto Mixed Input 実装状況

2026-09-24時点。**旧50原文へCodex作成650件を追加し、計700原文でv1/v2のLR学習・校正・runtime exportを完了した。品質基準は未達で、T3全体は未完了。** 増強後は3,907行。追加650件の人手確認も未実施。自動混在入力はOFFのまま。続く閾値の独立探索でdevの保留率は改善したが、品質目標は未達。最新記録は末尾の「文脈別の閾値を独立探索」を参照。

fixtureと今回の校正済み候補でPython／Swift数値一致を確認した。候補モデルはrelease_ready=false。実Zenzai接続・混在入力のIMK接続・十分な独立品質評価は未完成。実入力での曖昧語の判別性能やv2の優位性は主張しない。以下の各stageは当時の資料パス・実行結果を含む履歴である。

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
