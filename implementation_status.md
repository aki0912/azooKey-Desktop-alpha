# Auto Mixed Input 実装状況

2026-09-23時点。**T0・T1を完了し、次はT2へ進める。** 追加した処理はアプリから呼ばれない独立Coreであり、自動混在入力をIMEで利用できる段階ではない。変更後のCoreテストは86件通過（既存70件＋追加16件）。ユーザー設定を一時変更する既存テスト1件は除外した。

実装範囲は原文保持、Unicode範囲、モックによる混在表示と状態遷移。学習済み判定モデル、実Zenzai接続、IMKへの接続は未実装である。モックの漢字表記はテスト用の固定値であり、実モデルの出力や精度を示さない。

## T0：参照commitと現状の確認を完了

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

## 実行した検証と失敗

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

### 再実行コマンド

リポジトリルートから実行する。依存解決済み環境を前提とするCoreテストと、依存不要のT1テストを分けた。

```sh
sh Tools/test_auto_mixed_core.sh

CLANG_MODULE_CACHE_PATH="$PWD/build/auto-mixed/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/build/auto-mixed/swift-cache" \
swift test --package-path Core \
  --scratch-path "$PWD/build/auto-mixed/core" \
  --cache-path "$PWD/build/auto-mixed/cache" \
  --disable-sandbox --build-system native --skip testOptionPunctuationMappings

python3 -m unittest discover -s docs/auto-mixed/reference -p 'test_*.py' -v
python3 docs/auto-mixed/reference/validate_bundle.py
git diff --check
```

baseline用コピーは`mkdir -p build/auto-mixed/baseline`後、`git archive HEAD Core | tar -x -C build/auto-mixed/baseline`で作成。`Core/Package.resolved`もコピーし、上の`--package-path`を`build/auto-mixed/baseline/Core`へ変更して実行した。

初回依存解決は、同じcache環境変数を付けて`swift package --package-path Core --scratch-path "$PWD/build/auto-mixed/core" --cache-path "$PWD/build/auto-mixed/cache" --disable-sandbox resolve`を実行した。ビルド・失敗のログは`build/auto-mixed/`の`baseline.log`、`baseline-retry.log`、`resolve.log`、`baseline-resolved.log`、`baseline-native.log`、`pure-tests.log`、`pure-tests-final.log`、`core-after.log`に残る。

## 未実行事項と次stageの前提

次は`docs/auto-mixed/docs/04_MODEL_AND_DATA.md`とschemaを読み、T2の特徴量・系列復号・モデル読込を実装する。T1の`LanguageSegmenter`へ接続し、Swift/Python parityとfixtureモデル拒否を検証する。未学習状態で自動モードを有効にしない。

| stage／検証 | 残る作業 |
|---|---|
| T2・T3 | 実分類器、Swift特徴量golden／数値parity、productionモデル学習・精度評価、model card。今回のPython成功はSwift parityや学習完了を意味しない |
| T4 | 実Zenzai bridge、bulk composition置換、候補全文消費・suffix確認、previewと学習の分離。2入力session×複数JA spanで混線・解放・モデルロード数を実測する |
| T5 | policy／capability／mixed snapshot、event再送、commitIDとack、旧JSON互換、フォーカス拘束、ThinClientInputPipelineTests。今回のCore既存XPCテストだけで混在XPC統合済みとはしない |
| T6 | 区間指定・中央編集UI・256scalar上限・曖昧語保留・非標準入力表の退避、残るmock_core fixture |
| macOSアプリ | モデルsubmodule未取得。アプリ全体のbuild/test、実Zenzai、署名、GUI、入力欄・キーボード回帰は未実行。IMEを導入せずにできる隔離ビルド準備から再開する |
| CI差分 | Ubuntu未実行。SwiftLint実行ファイルが環境にないため、`swiftlint --quiet --strict`は未実行。後続CIで必要 |
| T7・T8 | 実測性能・精度・障害注入・配布ライセンス・識別子・署名と導入。今回の範囲外 |

通常使用中のIMEのインストール・削除・登録変更、LaunchAgent操作、プロセス終了、ユーザー辞書・学習データの変更は行っていない。追加コードにはファイルI/O、ネットワーク通信、入力ログ保存、モデル資源のロードを含めていない。
