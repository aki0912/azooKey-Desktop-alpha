# 自動日英入力：IME接続の開発手順

2026-09-24時点で、Coreの混在入力からConverterServer・IMKクライアントまでの接続を追加した。通常ビルドはOFF。T3の品質基準、T5の実機確認、T6の中央編集、T7/T8の評価・隔離配布は未完了で、日常利用できる完成版ではない。

## 有効化の契約

開発ビルドの `Contents/Resources/auto-mixed-experiment.json` が存在し、`enabled` がtrueの場合だけ、IMEは既存の `.composition(.snapshot)` でcapabilityを確認する。サーバーは `auto-mixed-model.json` のSHA-256・schema・非fixture条件とGGUFの存在を確認する。未対応サーバー、壊れたモデル、非標準入力表ではmanualへ戻る。

マーカーの形式は次のとおり。これは設定案ではなく、`AutoMixedExperiment.Configuration` の実装済み契約である。

```json
{"enabled": true, "modelSHA256": "学習済みruntime exportのSHA-256（64桁）"}
```

マーカーをsource resourcesへ追加しない。ユーザー設定へ有効化状態を書き込まない。開発ビルドのメニューに「自動日英入力（実験）」を表示する。capability返答前にmanual入力が始まった場合、そのフォーカスでは途中からautoへ切り替えない。

## ビルド出力への資源配置

`Tools/prepare_auto_mixed_ime_build.py` は既にビルドしたappに実験用モデルと、取得済みGGUF・ngram資源を配置する。出力はこのcheckoutの `build/` 内だけに制限する。receiptの5資源のsize/SHA-256をすべて照合し、fixtureを拒否してからコピーする。学習、ダウンロード、起動、インストール、登録、署名は行わない。

```sh
python3 Tools/prepare_auto_mixed_ime_build.py \
  --app build/auto-mixed/xcode-derived/Build/Products/Debug/azooKeyMac.app \
  --model build/auto-mixed/independent-thresholds-refined-20260924/export/model.json \
  --resources build/auto-mixed/runtime-resources
```

`kind=production` はruntime形式の識別であり、品質合格を意味しない。現在のモデルは引き続き `release_ready=false`。資源配置はappの内容を変更するため、配布用署名の代用にはならない。生成物は通常版と同じbundle/Mach service/AppGroup識別子を持つ段階なので、起動や入力ソース登録へ進めない。T8で名前・識別子・辞書領域を分ける必要がある。

今回確認したビルドはXcode 27、arm64 Debug、署名なし。DerivedData・SourcePackagesは `build/auto-mixed/` 内。`Tools/embed_converter_server.sh` は開発時だけ `AZOOKEY_PREBUILT_CONVERTER_SERVER_DIR` で検証済みSwiftPM出力を指定できる。指定がない通常ビルドの処理は従来どおり。未初期化submoduleのモデル資源は取得済みファイルへの一時リンクでビルドし、そのリンクは検証後に削除した。実行ログと制約は `implementation_status.md` に記録した。

## 現在のキー契約

- 文字とSpaceは原文へ追加する。Spaceは空白を入力する。
- Tab/Shift-Tabは候補の移動。候補対象の区間を強調表示する。Enterで候補採用、候補選択外のEnterで全体確定する。
- Escapeは原文表示へ戻す。Backspaceは末尾の書記素単位で削除する。
- 英字だけのcomposition中もTabはフォーカス移動へ使えない。メニューの説明にも記載した。
- OSの即時確定・非アクティブ化では、元の入力欄へ表示済み文字列を同期確定する。未応答の打鍵がある場合は原文を復元して確定するため、漢字表示を維持できない場合がある。
- Commandはアプリへ通す。英数/かなによる切替や非標準入力表はmanualへ退避する。auto中は既存のライブ変換設定・AI変換メニューを無効にする。

左右キー・マウスによる中央編集、任意区間の選択・強制指定は未完成。未対応キーはcomposition中にconsumeされることがある。候補やフォーカスの実IMKイベント順序、Cmd+A/C/V、アプリ側の選択変更は未検証。

## 学習・障害回復・プライバシー

実験版IMEはpreviewも確定も変換学習OFF。commitIDのackは保留中の確定文字列を除去するために使い、候補tokenを学習させない。未ack確定は8件まで保持し、超過時は原文を保持して追加確定を止める。ackに伴う候補学習は別の実装課題である。

raw・短い左右文脈・回復journalはメモリ内に限る。文脈は既存のIMK取得経路で最大30 UTF-16単位を要求し、transport/factoryでも30文字以下に制限する。新しいcompositionを開始する打鍵でのみ判定器へ渡す。取れない場合は文脈なしで動作する。依存ライブラリのdebug出力に入力が含まれるため、実験マーカーのあるConverterServerは受付開始前にstdout/stderrを破棄する。実運用の全ログ経路の監査・動的検証はT7に残る。

旧フォーカス・別server epochの応答は挿入しない。確定effectはsnapshotと別に重複を除く。auto要求は旧キー要求の無制限再送を使わず、失敗時に元の欄で原文回復してmanualへ戻る。プロセスクラッシュをまたぐ無損失・exactly-onceは保証しない。未応答Enterを含む障害回復は、複数の未確定入力をまとめた原文になる場合がある。
