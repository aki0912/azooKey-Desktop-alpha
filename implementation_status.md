# Auto Mixed Input 実装状況

2026-09-24時点。**T0〜T2と文脈v2の回帰を維持し、T3準備として権利確認・分割・増強・学習・校正・export・評価のローカルCLIを追加した。T3全体は未完了。** 実行したのはfixture専用のパイプライン検証で、実コーパスの本番学習ではない。自動混在入力はOFFのまま。最新の検証と残る作業は末尾の「T3準備差分」に記録した。

v1とv2のPython／Swift数値一致を確認した。学習済み判定モデル、実Zenzai接続、混在入力のIMK接続は未実装。人工係数の対照試験は文脈が判定まで届くことを確認するもので、実際の曖昧語の判別性能やv2の優位性を示さない。以下のT0〜T2記録は当時の資料パスを含む。資料移動と今回の差分は末尾のT3欄に記録した。

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
