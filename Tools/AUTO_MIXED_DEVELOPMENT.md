# 自動混在入力の開発ガイド

このブランチでは、通常版に加えて日英の自動混在入力を試す `azooKey Mixed` を実装している。Swiftの開発者向けに、変更先と検証手順をまとめる。初めて変更する場合は、下の責務表を確認してから対象のテストを選ぶ。導入・更新は [AUTO_MIXED_IME.md](AUTO_MIXED_IME.md) を参照。

## 入力処理を変えるときは、担当する層を選ぶ

表のパスはプロジェクトルートからの相対パス。

| 変更したい処理 | 主な変更先 | 守る条件 |
|---|---|---|
| 特徴量・確率・言語区間の判定 | `Core/Sources/Core/AutoMixed/` のモデル・判定器 | Pythonとの数値一致。学習時と実行時で特徴量の定義を揃える |
| 日本語優先、英語保持、読みの補正 | `Core/Sources/Core/InputUtils/AutoMixed/JapanesePreferredSegmenter.swift` | 保護対象の原文とUnicode scalar範囲を保つ。追加判定の再帰を制限する |
| 未確定文字・候補選択・原文回復 | `Core/Sources/Core/AutoMixed/MixedCompositionEngine.swift` | 表示候補で原文を書き換えない。終了時は子セッションを解放する |
| 辞書・Zenzaiへの候補要求 | `Core/Sources/Core/InputUtils/AutoMixed/ZenzaiSpanBridge.swift` | 候補トークンの寿命を守る。詳細候補は候補一覧を開くときに取得する |
| 要求の順序・確定通知 | `Core/Sources/Core/XPC/AutoMixedServerSession.swift` | 古いrevisionを拒否し、確定通知を受領するまで保持する |
| 入力欄への反映・接続終了 | `azooKeyMac/InputController/AutoMixedIMEClient.swift` | 先に応答の世代を無効化してから接続を終了する。原文を重複挿入しない |

`RawCompositionBuffer` は編集ごとに文字位置の対応表を更新する。読む側で再生成する必要はない。候補一覧からの直接選択には `selectCandidate(at:revision:adopt:)` を使う。確定時・取消時・空バッファになったときの片付けは、エンジン内の共通処理にまとめている。

## 仕様の回帰と、学習済みモデルの回帰を分けて検証する

まずCore全体を実行する。以下はこのMacのSwift 6.4で使ったコマンド。`native` は同環境の既存ビルドに合わせた指定で、SwiftPMから非推奨警告が出る。

```sh
swift test --package-path Core --scratch-path build/auto-mixed/core \
  --cache-path build/auto-mixed/cache --disable-sandbox --build-system native -c release
python3 Tools/test_mixed_ime_client.py
python3 -m unittest discover -s Tools/tests -p 'test_*.py'
```

かな末尾の編集や原文回復など、特定の状態を必ず通したいテストには人工係数を使う。`KanaTailTests` の辞書・Zenzai試験もこの方式で、日本語区間とかな末尾が分かれた状態を再現する。再学習で区間が結合されても、この編集経路の検証は残る。学習済みモデルの判定結果は、次の実モデル試験で確認する。

```sh
AUTO_MIXED_RUNTIME_MODEL="$PWD/build/auto-mixed/prefix-mass-20260925/export/model.json" \
AUTO_MIXED_ZENZAI_RESOURCES="$PWD/build/auto-mixed/runtime-resources" \
swift test --package-path Core --scratch-path build/auto-mixed/core \
  --cache-path build/auto-mixed/cache --disable-sandbox --build-system native -c release
```

モデルは明示的に選ぶ。上記は2026-09-25の試用モデルの例で、ファイルはGitに含まれない。資源の準備は [AUTO_MIXED_PLAYGROUND.md](AUTO_MIXED_PLAYGROUND.md)、学習手順は [AutoMixedTraining/TRAINING.md](AutoMixedTraining/TRAINING.md) を参照。実Zenzai試験にはMetalを利用できる環境が必要。環境変数を指定しない試験はスキップされるため、実行件数だけで実モデル検証の完了を判断しない。

特徴量・モデル読込・判定器を変えた場合は、Pythonとの数値一致も検証する。

```sh
sh Tools/test_auto_mixed_parity.sh --build-system native -c release
build/auto-mixed/training-env/bin/python -m unittest discover \
  -s Tools/AutoMixedTraining -p 'test_*.py'
swiftlint --quiet --strict
```

学習後のv1/v2 exportを比較するテストでは、`AUTO_MIXED_TRAINING_EXPORTS` または `AUTO_MIXED_APPROVED_EXPORTS` に、両方のexportディレクトリをコロンで区切って渡す。後者は承認済みデータから作ったモデル用。Pythonのテストとビルド・インストーラーのテストはCIでも実行する。

## ビルドには使用するv2モデルを必ず指定する

```sh
python3 Tools/build_mixed_ime.py \
  --model build/auto-mixed/prefix-mass-20260925/export/model.json
```

`--model` は必須。古い学習結果を暗黙に選ぶ既定値は設けていない。Mixedの実行経路は文脈特徴を持つv2を必要とするため、v1・fixture・サイズ超過はビルド開始前に拒否する。完全なschemaと係数の検証はSwiftのモデル読込が担当する。

生成先は `build/auto-mixed/mixed-ime/azooKeyMixed.app`。このコマンドはインストールしない。入力方法への反映には、導入ガイドにある別の更新操作が必要。

## 過去の資料は回帰データの参照元でもある

`docs/auto-mixed-old/` には、現在もSwiftテストとPython学習処理が読む固定の期待値・参照実装・schemaがある。名前だけを理由に削除すると数値回帰が壊れる。移動する場合は、まずコードからの参照を検索する。

現在の設計判断は [設計書](../docs/azookey_auto_mixed_codex/docs/03_ARCHITECTURE.md)、試用上の制約は [導入ガイド](AUTO_MIXED_IME.md) を参照。`implementation_status.md` は作業当時の検証記録として扱う。新しい不具合は、入力例・モデルのSHA-256・左文脈の有無・失敗したテストを添えると、言語判定と入力状態のどちらに原因があるかを追いやすい。

更新日: 2026-09-25
