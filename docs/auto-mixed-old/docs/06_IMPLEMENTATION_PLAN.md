# 06. Codex実装計画

## 0. 基本方針

大規模な一括改造ではなく、各stageでコード・テスト・未解決事項を残す。使用中のIMEを自動上書きしない。機能フラグOFFで既存挙動が変わらないことを毎stageで確認する。

Codexの実行環境がLinux等である場合、pure Core部分は対応するSwift toolchainで検証し、macOS固有のビルド／GUI試験は未実行と記録する。手元のコンパイラが無いのにビルド成功を書かない。

## 1. タスクと完了条件

### T0：現状固定・回帰baseline

対象：既存AGENTS、Package.swift、XPC、InputController、ビルド設定、CI、submodules。

実施：git statusとHEAD記録、参照commitとの差分確認、既存テストの実行条件を整理、隔離build先作成、変更対象一覧と現在のキー契約を記録。標準ローマ字の公開API、withSessionの実装、候補の全文消費判定、資源copyを確認する。

完了：`implementation_status.md`に確認SHA・ビルド条件・実行コマンドと結果を保存。ユーザー変更を残す。未確認のライブラリAPIは「仮」と明記。

### T1：原文・区間・表示のpure core

依存：T0。新規：RawCompositionBuffer、TextOffsetMap、AutoMixedTypes、MixedMarkedTextRenderer。

実施：scalar範囲型、書記素編集、raw/display mapping、span全被覆検証。分類器とZenzaiをprotocolのモックで差し替える。Space常時literal、Escape原文化を状態機械で先にテスト。

完了：Unicode・削除・範囲テスト、`event_cases.json`のモック基礎ケース。まだアプリに有効化UIを出さない。

### T2：特徴量と系列復号

依存：T1。新規：AnchoredCharacterFeatures、LogisticLanguageModel、ViterbiLanguageDecoder、ProtectedSpanDetector。

実施：referenceと同一の特徴量、モデルschema読込、finite検証、RAW mask、gap境界reset。モデルファイルの`kind=fixture`はテスト以外で拒否する。

完了：feature golden、正例方向、Viterbi brute-force比較、Python/Swift数値parity。学習済みモデルなしに自動モードを完成扱いしない。

### T3：データ・学習・評価

依存：T2。新規：Tools/AutoMixedTraining。

実装するCLI：

```text
validate-data --input ...
build-dataset --manifest ... --output ...
train --config ...
calibrate --model ... --data ...
export --model ... --output ...
evaluate --model ... --test ... --traces ...
```

上記は**実装予定のコマンド契約**であり、同梱済み学習CLIではない。各CLIは非ゼロ終了コード、入力検証、seed、metadata、依存lock fileを備える。CPU学習から始めGPU前提にしない。

完了：独立test、calibration、学習manifest、production model、model card、指標と失敗例。基準未達は機能フラグOFFを維持する。

### T4：Zenzai span bridge

依存：T1、T0の依存API確認。T3と並行可能。

実施：候補生成と学習の分離、bulk composition置換、child sessionの作成／破棄、raw suffix保全、全文候補のfilter。既存options生成を共有化しmanual回帰試験。未完`n`や区間境界を実Converterで検証。

完了：2つ以上のJA spanと2つ以上の入力sessionを交互に扱って候補混線なし。previewで学習が変化しない。モデルロード数増加なし。実Zenzai試験ができない環境ではT4は未完了とする。

### T5：XPCとUI統合

依存：T1/T2/T4。候補モデルが未完成ならテストビルドだけでmockを使う。

実施：CompositionPolicy、router、自動モード専用サーバーdispatch、mixed snapshot、capability、commitID、ack、フォーカス拘束。旧JSON decode、manual fallback。区間UIとTab/Enterの契約を実装。

完了：ThinClientInputPipelineTests、二重effect／古い応答テスト。auto停止時にlegacy managerが空でも混在原文を消さない。

### T6：保留・編集・ユーザー修正

依存：T3/T5。

実施：ヒステリシス、曖昧語保留、区間原文／JA強制、候補固定、中央編集、上限256、URL保護の境界、モデル破損時退避。非標準入力表で安全にmanualへ戻ること。

完了：全fixturesを適切な層のテストに接続。漢字の期待表記がmock値か実測値か分離されている。全英語時のTab制約をUIに表示。

### T7：品質・性能・プライバシーgate

依存：T6。

実施：05章のモデル評価・性能測定・アプリ試験・障害注入。入力内容がログ／analyticsへ出ないことを静的検索と動的試験で確認。未許可ネットワーク通信が増えていないことを確認。

完了：測定条件付きreport。英語保全とJA recallの両方合格。未対応欄・アプリ・既知障害をrelease notesへ記載。未達なら実験機能のままにする。

### T8：隔離配布・導入

依存：T7、配布権利確認。

実施：forkの表示名・bundle identifiers・Mach service・LaunchAgent・AppGroupの整合性確認、署名、公証等の必要手続き、資源LICENSE/NOTICE、戻し方をまとめる。インストールはユーザー操作として分離。

完了：元のazooKeyと識別でき、元の辞書・学習データ・設定を無断変更しない。アンインストール対象を自forkに限定できる。

## 2. 開発コマンドの扱い

以下は既存構造に基づく**確認の入口**。実行可否・scheme・destinationは実環境で確認する。

```bash
git status --short
git rev-parse HEAD
git submodule status
swift --version
swift test --package-path Core
# macOS / Xcodeのある環境のみ
xcodebuild -version
xcodebuild -list -project azooKeyMac.xcodeproj
```

上流のCIや実在するschemeからbuild/testコマンドを決定し、DerivedDataは通常アプリと分離する。`git reset --hard`、既存IME削除、`install.sh`、LaunchAgent登録／解除、全プロセスkillをCodexの通常検証へ混ぜない。

## 3. 変更記録の形式

`implementation_status.md`にstageごとに「変更ファイル」「実行したテストと結果」「未実行試験」「未解決の設計差分」「次stageの前提」を書く。コンパイルだけ通過、モックだけ通過、実Zenzai確認済み、実機GUI確認済みを区別する。

自分で作ったmock結果や計画目標を性能表の実測欄へ転記しない。評価で仕様変更が必要ならdecision logを更新し、既存テストの期待値を理由なく弱めない。
