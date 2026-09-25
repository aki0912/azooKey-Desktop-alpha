# 08. 一次資料・設計判断・未確認事項

## 1. 出典の読み方

確認日：2026-09-23。文書内の`[S番号]`は以下の一次資料を示す。GitHubは可能な限り調査したcommitへ固定した。外部ページは後から変化するため、実装時のHEADとライセンスを再確認する。

新しい構成・閾値・操作・テスト目標は、本資料による設計提案であり、上流またはX投稿者の設計の引用ではない。

## 2. 一次資料

### S1：上流コミット
https://github.com/azooKey/azooKey-Desktop/commit/b7ec0e4f27cf19d6a3aefa77d4b5ea7f2ebe5376

コミットID、日時、変更メッセージの確認。

### S2：IMKクライアント
https://github.com/azooKey/azooKey-Desktop/blob/b7ec0e4f27cf19d6a3aefa77d4b5ea7f2ebe5376/azooKeyMac/InputController/azooKeyMacInputController.swift

薄いクライアント、キーイベントID、pending数、activationGeneration、XPC応答とeffect適用の確認。

### S3：変換サーバーとセッション
https://github.com/azooKey/azooKey-Desktop/blob/b7ec0e4f27cf19d6a3aefa77d4b5ea7f2ebe5376/Core/Sources/ConverterServer/main.swift

https://github.com/azooKey/azooKey-Desktop/blob/b7ec0e4f27cf19d6a3aefa77d4b5ea7f2ebe5376/Core/Sources/ConverterServer/ConverterSession.swift

https://github.com/azooKey/azooKey-Desktop/blob/b7ec0e4f27cf19d6a3aefa77d4b5ea7f2ebe5376/Core/Sources/ConverterServer/ConverterServer%2BKeyEvent.swift

共有Converter、withSession、MainActor、イベント重複防止、contextの確認。

### S4：同期イベントルーター
https://github.com/azooKey/azooKey-Desktop/blob/b7ec0e4f27cf19d6a3aefa77d4b5ea7f2ebe5376/Core/Sources/Core/XPC/ConverterClientEventRouter.swift

同期consume/fallthrough、Command、pending時の扱い。

### S5 / S6：SegmentsManager
https://github.com/azooKey/azooKey-Desktop/blob/b7ec0e4f27cf19d6a3aefa77d4b5ea7f2ebe5376/Core/Sources/Core/InputUtils/SegmentsManager.swift

S5：ComposingText、insert、Zenzai v3 options、resourcesDirectoryURL。
S6：requestCandidates、prefixCandidateCommited、候補選択と学習。

### S7：snapshot生成
https://github.com/azooKey/azooKey-Desktop/blob/b7ec0e4f27cf19d6a3aefa77d4b5ea7f2ebe5376/Core/Sources/ConverterServer/ConverterServer%2BSnapshot.swift

manager.isEmptyの早期return、marked text、候補UI、資源解決。

### S8：Swift Package
https://github.com/azooKey/azooKey-Desktop/blob/b7ec0e4f27cf19d6a3aefa77d4b5ea7f2ebe5376/Core/Package.swift

Swift tools 6.1、Converter revision、Zenzai trait、Coreのplatform指定。

### S9：公開README
https://github.com/azooKey/azooKey-Desktop

公開READMEで開発環境の記載を参照した。ただし検索／取得表示に旧Zenzaiパスが含まれていた。現在のチェックアウトのREADME・ビルド設定・CIで再確認する。

### S10：モデルsubmodules
https://github.com/azooKey/azooKey-Desktop/blob/b7ec0e4f27cf19d6a3aefa77d4b5ea7f2ebe5376/.gitmodules

v3.2 GGUFとbase_n5_lmの参照先確認。

### S11：Zenzai GGUFページ
https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf

モデルページのライセンス表示とファイルサイズの確認。モデルカードだけで推論メモリや本用途の性能を断定しない。

### S12：XPCのデータ契約
https://github.com/azooKey/azooKey-Desktop/blob/b7ec0e4f27cf19d6a3aefa77d4b5ea7f2ebe5376/Core/Sources/Core/XPC/ConverterServerXPCProtocol.swift

JSON/Codableのコマンド・snapshot・effects。

### S13：上流ライセンス
https://github.com/azooKey/azooKey-Desktop/blob/b7ec0e4f27cf19d6a3aefa77d4b5ea7f2ebe5376/LICENSE

上流DesktopコードのMIT許諾文。他の資源のライセンス判断とは分離する。

### S14：ロジスティック回帰の公式実装資料
https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.LogisticRegression.html

学習API、正則化、solver等。実装時の依存versionをlockする。

### S15：確率校正の公式資料
https://scikit-learn.org/stable/modules/calibration.html

独立データを用いた校正、sigmoid校正等。export時の符号と数値一致を検証する。

### S16：NSStringとmacOS入力
https://developer.apple.com/documentation/foundation/nsstring/length

https://developer.apple.com/documentation/inputmethodkit/imkinputcontroller/selectionrange()

NSString/UTF-16とmarked textの選択範囲に関する参照入口。具体的なIMK呼出しは上流S2を優先して実装確認する。

### S17：Codexのリポジトリ指示
https://developers.openai.com/codex/guides/agents-md

既存AGENTS.mdを尊重し、長い仕様は必要時に別ファイルから読む構成の参考。Codexのモデル・料金・実行枠を本資料で仮定しない。

### S18：着想元（ユーザー提示）
https://x.com/nya3_neko2/status/2102713076319768605

投稿本文／動画は取得できなかった。ユーザーが引用した「ロジスティック回帰で文字列の日本語ローマ字らしさを判定し、日本語区間をZenzai変換」という説明を要件の起点にした。作者の特徴量・学習データ・ソース公開状況・動作精度は未確認。

## 3. 設計判断ログ

| ID | 採用判断 | 理由／代替案 |
|---|---|---|
| ADR-001 | サーバー側へmixed engine | 現行の薄いIMKクライアントを維持。クライアントへモデルを置く二重状態を避ける |
| ADR-002 | 生ローマ字を原本にする | 後からJA↔RAWが変わっても復元可能。かなから逆変換しない |
| ADR-003 | 文字位置LR＋Viterbi | 空白なし混在に対応。単語LRだけでは境界が足りない |
| ADR-004 | 保護・保留・手動区間修正 | 真に曖昧な入力を一意に決定できない |
| ADR-005 | Space常時空白、Tab候補 | 判定が変わってSpaceの意味が変わる事故を避ける |
| ADR-006 | Swift native推論 | Python/外部サーバーの常駐やIPCを追加しない |
| ADR-007 | 共有Zenzai＋区間session | 既存モデルと設定を再利用。モデルを区間ごとに複製しない |
| ADR-008 | manualを残し初期OFF | 日常のIMEを壊さず段階的に導入 |
| ADR-009 | 自動学習データ収集なし | ローカルであっても入力履歴保存のリスクを追加しない |
| ADR-010 | 初期は同期候補応答を維持 | 非同期push拡張を同時に入れず、性能測定後に判断 |

## 4. 未確認・実装で解決する項目

- LRを学習した実精度、英語誤変換率、prefixでの安定性。
- 子変換sessionの詳細なメモリ／キャッシュ挙動と、依存Converterの未完suffix取得API。
- 実機でのZenzai速度、対象Macでの総メモリ、アプリ別IMEの相性。
- X投稿者の実装詳細や動画での操作。
- base_n5_lm等、同梱資源全体の配布条件。
- 最新チェックアウトでの署名・scheme・資源copyの詳細。

これらは推測で埋めず、T0/T3/T4/T7/T8のstage gateで結果を記録する。
