# Codexへ渡す開始指示

## 配置

この資料フォルダの中身を、azooKey-Desktopのフォークの`docs/auto-mixed/`へ置く。既存リポジトリとユーザー変更を残す。`AGENTS.addendum.md`は追記案であり、既存AGENTS.mdの置換ファイルではない。

## 開始プロンプト

```text
azooKey-Desktopに、切替不要の日英混在入力を実装します。
最初に既存AGENTS.mdとdocs/auto-mixed/README.md、CODEX_START.md、
docs/02_UPSTREAM_MAP.md、docs/06_IMPLEMENTATION_PLAN.mdを読んでください。

実装仕様はdocs/auto-mixed/docs/にあります。
現在のHEAD・依存ライブラリ・XPC構造を確認し、参照commitとの差分を記録してください。
新設API名を既存APIと誤認せず、実際の定義を確認してください。

今回はT0とT1を完了してください。原文バッファ、Unicode範囲、モックを使った
混在表示と状態遷移を小さい差分で実装し、既存manual入力を変更しないでください。
未学習モデルを本番モデルとして扱わず、実Zenzai統合はT4として分離してください。

実行したテスト、失敗、実行環境の制約、未確認事項をimplementation_status.mdへ記録し、
次に進める状態を示してください。通常使用中のIMEのインストール・削除・登録変更は
行わず、既存のユーザー変更を破棄しないでください。
```

## 次stage用プロンプト

```text
implementation_status.mdとdocs/auto-mixed/docs/06_IMPLEMENTATION_PLAN.mdを読み、
完了済みstageの条件を確認してから次の1stageを実装してください。
仕様差分が必要なら理由と影響を書くこと。テストの期待値を理由なく弱めないこと。
実機や学習が必要で実行できない項目は未実行とし、成功したように報告しないでください。
```

## 学習データ作成を依頼する場合

```text
T3の準備としてdocs/auto-mixed/docs/04_MODEL_AND_DATA.mdとschemas/を読み、
権利を確認できるデータだけを使う学習パイプラインを作ってください。
まず同梱fixtureで形式と特徴量parityを確認し、実学習用データと混同しないでください。
元文group単位でsplitしてからローマ字variantとprefixを増強し、
train/dev/calibration/testの漏洩を防いでください。
未確認の公開コーパスを勝手にダウンロードして学習に混ぜないでください。
```

## 最初に人が決めておくとよい事項

この仕様は「Spaceは空白、Tabは候補」「自動モードは標準ローマ字入力だけ」「最初は実験機能OFF」を初期判断としている。ここを変える場合は01章とキー操作テストを一緒に変更する。設計が曖昧なままCodexに自動推測させない。

開発用Mac・Xcode・署名Team・フォークの表示名／識別子は実環境で決める。学習段階では権利確認済みデータの利用方針と、機能を有効化する精度gateを承認する。
