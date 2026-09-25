# 02. 既存コード調査と変更地図

## 1. 調査基準

確認日：2026-09-23。取得できたmainのコミット：

```text
azooKey/azooKey-Desktop
b7ec0e4f27cf19d6a3aefa77d4b5ea7f2ebe5376
コミット日時：2026-09-05T08:11:43Z
メッセージ：feat(input): 予測候補の受理にConverterの新APIを利用する (#373)
```

このコミットは設計の参照基準であり、利用者の作業ツリーを強制的にresetする指示ではない。実装時にHEADが異なれば差分を調べ、対応する入口を再確認する。[S1]

`Core/Package.swift` はswift-tools-version 6.1、Converter依存を `ad714fea8cb2fe113aea86ba5c42563cdaf77cfb` に固定し、macOSではZenzai traitを有効にしている。Coreのplatform指定はmacOS 13だが、これをアプリ全体の動作保証OSと混同しない。[S8]

参照した公開READMEはmacOS 15+、Xcode 26.1+、Git LFSなどを開発要件に挙げていた。ただしREADMEのZenzaiパスが旧版だったため、**実装時はチェックアウトした `.gitmodules`、ビルド設定、CIを優先して再確認する**。[S9]

## 2. 確認した現在の入力パイプライン

```text
azooKeyMacInputController.handle
  → ConverterClientEventRouter.disposition（同期的なconsume / fallthrough）
  → ConverterKeyEventRequest / ConverterServerClient.sendKeyEvent
  → ConverterServer.handle / withConverterSession
  → ConverterServer.handleKeyEvent
  → UserAction.getUserAction → InputState.event → ClientAction
  → SegmentsManager / ComposingText / KanaKanjiConverter.requestCandidates
  → ConverterSessionSnapshot + ConverterClientEffect
  → InputController.apply / marked text・候補UI更新
```

既存サーバーは共有 `KanaKanjiConverter` を1個持ち、`createSession` / `withSession` で変換状態を切り替える。処理はサーバープロセスのMainActorに集約されている。IMEクライアントのMainActorと、別プロセスのMainActorは別である。[S2][S3]

`handleKeyEvent` には同じeventIDの再送に前回応答を返す処理と、古いeventIDを拒否する処理がある。クライアント側にもpending event数とactivationGenerationがある。新機能でこれらを削除しない。[S2][S3]

## 3. 既存ファイルと変更方針

以下のファイルは実際のソースまたは検索結果で存在を確認したもの。新設ファイルは次節で区別する。

| 既存パス | 確認した責務 | 変更内容 |
|---|---|---|
| `azooKeyMac/InputController/azooKeyMacInputController.swift` | IMK入力、XPC送信、世代チェック、effect適用 | 自動モード設定の同期、混在snapshot描画、送信先クライアント世代の拘束 |
| `Core/Sources/Core/XPC/ConverterClientEventRouter.swift` | 同期的なイベント所有権 | 自動モード・未確定状態を認識。Space/Tabを従来InputStateだけで判定しない |
| `Core/Sources/Core/XPC/ConverterServerXPCProtocol.swift` | Data上のJSON/Codableコマンドと応答 | mixed state、revision、capability、区間操作コマンドを追加 |
| `Core/Sources/ConverterServer/main.swift` | セッション、共有Converter、ライフサイクル | auto分岐、区間用変換sessionの生成と破棄、確定／停止の分岐 |
| `Core/Sources/ConverterServer/ConverterSession.swift` | manager、inputState、inputLanguage、eventID・文脈 | 独立したmixed engineを所有。既存managerと状態を混ぜない |
| `Core/Sources/ConverterServer/ConverterServer+KeyEvent.swift` | キーイベント→状態遷移→effects | 原文字列をUserAction変換前に混在engineへ渡す |
| `Core/Sources/ConverterServer/ConverterServer+Snapshot.swift` | marked text・候補等のsnapshot生成 | 自動モード専用の合成snapshot。従来manager.isEmptyによる早期returnを分岐 |
| `Core/Sources/Core/InputUtils/SegmentsManager.swift` | 1つのcomposition、候補要求、候補学習 | 安全な区間アダプター用APIを追加し、候補生成と確定学習を分離 |
| `Core/Sources/Core/InputUtils/Actions/UserAction.swift` | キーから操作への対応 | manual維持。autoの文字列正規化をこの経路に任せない |
| `Core/Sources/Core/InputUtils/InputState.swift` | 従来入力の状態遷移 | manualの回帰を防ぐ。autoは独立状態機械を使う |
| `Core/Sources/Core/Configs/BoolConfigItem.swift` 等 | 永続設定の既存型 | 自動混在入力の有効化などを既存方式に合わせて追加 |
| `Core/Sources/ConverterServer/ConverterServer+Settings.swift` | サーバー設定の列挙・更新 | 設定descriptorとモード説明を追加 |
| `Core/Tests/CoreTests/XPCTests/ConverterClientEventRouterTests.swift` | ルーターのテスト | 自動モード、pending、Command、Tabのケース追加 |
| `Core/Tests/CoreTests/XPCTests/ConverterServerContractTests.swift` | XPCデータ契約のテスト | 欠損フィールド既定値、追加snapshot、バージョン不一致 |
| `azooKeyMacTests/ThinClientInputPipelineTests.swift` | 薄いクライアント入力パイプライン | 重複effect、旧フォーカス応答、pendingイベント |

## 4. 新設するモジュール（名称は本仕様の提案）

```text
Core/Sources/Core/AutoMixed/
  AutoMixedTypes.swift
  RawCompositionBuffer.swift
  TextOffsetMap.swift
  ProtectedSpanDetector.swift
  AnchoredCharacterFeatures.swift
  LogisticLanguageModel.swift
  ViterbiLanguageDecoder.swift
  LanguageStabilityPolicy.swift
  MixedCompositionEngine.swift
  MixedMarkedTextRenderer.swift
  MixedCandidateController.swift
Core/Sources/ConverterServer/
  ConverterServer+AutoMixed.swift
  ZenzaiSpanBridge.swift
Core/Tests/CoreTests/AutoMixedTests/
Tools/AutoMixedTraining/
azooKeyMac/Resources/AutoMixed/
```

新API名・型名は既存実装の存在を意味しない。とくに `ZenzaiSpanBridge` や `replaceCompositionFromRaw` はこれから実装する境界である。

## 5. Zenzaiとモデル資源の実際

確認コミットの `.gitmodules` は次を参照していた。[S10]

```text
azooKeyMac/Resources/gguf → Miwa-Keita/zenz-v3.2-small-gguf
azooKeyMac/Resources/base_n5_lm → Miwa-Keita/base_n5_lm
```

`SegmentsManager` は解決済みresourcesDirectoryURL配下の `ggml-model-Q5_K_M.gguf` を使う。ソースのsubmoduleパスと最終app bundleの資源パスを同一視しない。ビルド時のコピー設定を確認する。[S5]

公開GGUFページにはQ5_K_M 73.9MB、Apache-2.0という表示がある。ただしこの数値はモデルファイルの表示サイズであり、プロセス全体のメモリ使用量ではない。配布時は固定したrevisionのライセンスファイルも確認する。[S11]

## 6. やってはいけない変更

- すべての入力を先に既存managerへ入れ、かなになった後に英語を推測して戻す。
- サーバーがconsumeしたキーを後からアプリへ再送し、入力順序を推測で補う。
- 古い説明にあるAPI名をそのまま使う。たとえば現在の入力styleと合わない名称を捏造しない。
- `SegmentsManager` ごとにZenzai重みを再ロードする。
- `Task.detached` へ既存Converterやmanagerを渡し、スレッド安全と仮定する。
- `prefixCandidateCommited` を候補のプレビュー段階で呼ぶ。このメソッドは変換学習の更新とcompositionの部分確定を含む。[S6]
- mixed modeなのに従来managerが空という理由で空snapshotを返す。[S7]

---
出典番号は [08. 一次資料・設計判断](08_SOURCES_AND_DECISIONS.md) を参照。
