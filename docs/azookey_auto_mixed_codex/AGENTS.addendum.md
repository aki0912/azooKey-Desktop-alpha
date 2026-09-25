# AGENTS.mdへの追記案

既存AGENTS.mdを上書きせず、必要箇所だけ統合する。

## Auto Mixed Input

- 仕様入口は`docs/auto-mixed/README.md`。着手時は`CODEX_START.md`と該当stageの文書を読む。
- 既存manual入力を維持する。自動モードは初期OFF。
- 原文を唯一の入力原本とし、かなや候補から英語を復元しない。
- 言語判定とZenzaiを分離し、クライアントへ推論・二重状態を追加しない。
- 既存XPCのイベント所有権、重複防止、フォーカス世代を維持する。
- production未学習モデルをダミー重みで代用しない。実測／mock／未実行を区別する。
- raw入力・候補・文脈をログや外部サービスへ送らない。
- インストール、既存IME削除、LaunchAgent変更、署名秘密情報操作は通常の実装タスクに含めない。
- stageごとのテストと未解決事項を`implementation_status.md`へ記録する。
