# azooKey Desktop：切替不要の日英混在入力 — Codex実装資料

作成日：2026-09-23 ／ 設計版：1.0 ／ 仮称：Auto Mixed Input

## 目的

azooKey-Desktopをフォークし、英語とローマ字日本語を同じ未確定バッファに入力できるmacOS IMEを作る。文字特徴のロジスティック回帰で言語区間を推定し、日本語区間だけを既存Zenzaiに渡す。英語・URL・コードなどの原文は維持する。

**これは実装仕様・テスト素材であり、完成したIMEや学習済み判定モデルではない。** Zenzai実機動作、学習精度、macOSビルド・署名は、この資料作成時には実行していない。添付Pythonコードのテストは、特徴量とデータ形式の仕様を検証するもので、IMEの完成を意味しない。

着想元はユーザーが引用したX投稿の説明。投稿本文・動画は取得できなかったため、投稿者の非公開コード、特徴量、精度を再現・確認したという意味ではない。

## 推奨構成

```text
InputMethodKit / 既存の薄いクライアント
    ↓ XPC：キーイベント、イベントID、フォーカス世代
ConverterServer
    ├─ 原文バッファ（唯一の入力原本）
    ├─ URL・識別子等の保護
    ├─ 文字特徴 → Logistic Regression → Viterbi区間推定
    ├─ 保留・表示安定化・ユーザー修正
    ├─ 日本語区間 → 既存Converter / Zenzai
    └─ 英字原文＋日本語候補 → 混在marked text
    ↓ snapshot / 一度だけ適用する確定effect
InputMethodKit：表示と確定
```

実行時にPython、LM Studio、Ollama、汎用LLM、外部推論APIを追加しない。学習時だけPythonを使い、判定重みをJSONで書き出してSwiftで評価する。Zenzai重みは既存アプリの資源を共用する。

## 読む順序

| ファイル | 内容 |
|---|---|
| `CODEX_START.md` | Codexに最初に渡す指示と作業の進め方 |
| `docs/01_REQUIREMENTS_UX.md` | 対象範囲、Space/Tab/Enter、曖昧語、編集仕様 |
| `docs/02_UPSTREAM_MAP.md` | 確認したコミット、既存ファイルと変更箇所 |
| `docs/03_ARCHITECTURE.md` | 状態・XPC・Zenzai連携・文字オフセット・障害処理 |
| `docs/04_MODEL_AND_DATA.md` | 特徴量、Viterbi、学習・校正・データ作成 |
| `docs/05_TEST_AND_EVALUATION.md` | 単体・統合・実機・性能・精度の合格条件 |
| `docs/06_IMPLEMENTATION_PLAN.md` | 段階ごとのタスク、依存関係、完了条件 |
| `docs/07_SECURITY_RELEASE.md` | ローカル処理、ライセンス、隔離ビルド、配布 |
| `docs/08_SOURCES_AND_DECISIONS.md` | 一次資料と設計判断、未確認事項 |
| `VALIDATION_REPORT.md` | 作成時に実行した検証と未実施事項 |
| `AGENTS.addendum.md` | 既存AGENTS.mdへ統合する短い追記案 |
| `schemas/` | 学習・評価レコードとモデルのJSON Schema |
| `fixtures/` | 仕様上の入力例、イベント列、特徴量golden |
| `reference/` | Python特徴量参照実装、Viterbi参照実装、素材検証 |

## 重要な設計上の約束

1. 英語か日本語か判定する前に、原文をかなへ破壊的変換しない。
2. 文字列全体に1個の二値ラベルを付けるだけでは、混在区間を検出できない。文字位置ラベルと系列復号を使う。
3. `made`、`no`、`to`などは、入力文字だけで意図を一意に決められない。曖昧時は原文表示を選び、区間修正を可能にする。
4. 推定はmarked text内で可逆。判定確率だけを理由にOSへ早期確定しない。
5. 自動モードのSpaceは常に実際の空白。変換候補はTabで操作する。日本語モードの従来操作は変更しない。
6. 精度・速度の数値は開発目標であり、測定結果ではない。

## 配置と利用

このフォルダの内容を、フォークしたリポジトリの `docs/auto-mixed/` に配置する。次に `CODEX_START.md` の「開始プロンプト」をCodexへ渡す。既存 `AGENTS.md` は上書きせず、追記案から必要箇所だけ統合する。

全資料を常時AGENTS.mdへ貼り付けず、各フェーズで必要な文書だけ読む。macOSのアプリ統合・署名・GUI動作確認は、対象MacとXcodeで行う。通常使用中のIMEを変更するインストール操作は、コード変更・ビルドとは分ける。

## 添付素材の規模

区間意図データ50件、キー操作等の契約16件、特徴量・数値golden128件、参照コード22テストを同梱。学習済み日英判定モデルは含まない。`language_model_fixture.json`はテスト専用の人工係数。
