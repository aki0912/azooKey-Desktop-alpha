# 学習済みモデルで混在入力を試す

`AutoMixedPlayground` は、この画面の中で原文入力、混在プレビュー、候補選択、確定を試すmacOSアプリです。T4の実Converter接続を使います。通常のIMEに組み込むT5のXPC／IMK接続はまだありません。

## 起動

リポジトリ直下で実行します。初回のReleaseビルドには時間がかかります。

```sh
# プロジェクトが固定している変換資源を取得。既に取得済みならchecksumの検証だけ。
python3 Tools/fetch_auto_mixed_resources.py

# 現在の学習済みv2モデルと、取得済みZenzai資源を使う。
sh Tools/run_auto_mixed_playground.sh
```

`build/auto-mixed/AutoMixedPlayground.app` を生成し、スクリプトから中の実行ファイルを直接起動します。検証MacではLaunchServices経由の起動がライブラリ読込待ちになることがあったため、当面は上記スクリプトを使ってください。開発用アプリはこのcheckout内の資源にリンクしており、アプリだけを別のMacへコピーする配布形式ではありません。

既定の判定器は `build/auto-mixed/independent-thresholds-refined-20260924/export/model.json`。モデルの重み・閾値は維持し、試用アプリの表示方針を「日本語優先・英単語判定あり」に変更しました。英単語辞書とモデルの両方に根拠がある区間を原文保持し、それ以外の有効なローマ字は日本語の候補または読みを表示します。英単語判定の試用パラメータは `Core/Sources/Core/InputUtils/AutoMixed/EnglishLexiconResources/english-policy.json` にあり、校正済みの英語確率ではありません。任意のv2モデルと資源フォルダは次のように指定できます。

```sh
sh Tools/run_auto_mixed_playground.sh path/to/model.json path/to/resources
```

`resources` には `ggml-model-Q5_K_M.gguf` を置きます。既定の資源フォルダがない場合だけ、起動スクリプトは同梱かな漢字辞書を使います。明示したZenzai資源が欠けていれば起動エラー、モデル読込に失敗した場合は画面に失敗を表示して原文を維持します。

学習済みJSONはgit管理外の既存成果物です。クリーンなcheckoutに自動生成したfixtureを代入することはありません。元の学習／export手順は [TRAINING.md](AutoMixedTraining/TRAINING.md) を参照してください。

## 操作

- 「入力原文」に英数のまま入力します。例は `APIwotukau`。判断が曖昧でもローマ字として成立すれば、日本語を優先します。現在のモデルでは `sushi` → `寿司`、単独の `made` → `まで`、`to` → `と` になります。
- 英単語の完全一致とモデルの根拠を合わせて、`note`、`meeting`、`hello` 等を原文保持します。`mee` のような入力途中は、よく使われる単語のprefixであり、モデルにも強い根拠がある場合だけ英字で残します。英語表示の維持基準は開始基準より少し緩くし、同じ区間の追加入力・末尾削除の揺れを抑えます。
- 末尾が未完ローマ字でも、日本語の完成部分＋未完文字を表示します。現在のモデルでは `asita` → `明日`、`asitan` → `明日n`、`asitano` → `明日の`。日本語の根拠が弱い場合は漢字候補ではなく読み＋未完文字を使います。URL等は保護し、途中区間の未完子音も強制変換しません。
- 末尾がかなとして完成し、前半は高信頼でも全体の漢字変換にはまだ確信が足りない場合は、条件を満たした最後の入力単位をひらがなで表示します。例は `asitanot` → `明日のt`、`asitanote` → `明日のて`。この状態の候補選択は前半の漢字候補が対象です。単独の `note` を常に `のて` にする規則ではありません。
- Spaceは原文の空白として残ります。Enterで下の「確定した文章」につなげます。
- 「候補 / 次へ」で右端の日本語区間の候補を開きます。候補のボタンかEnterで採用し、もう一度Enterで文章を確定します。
- Escapeは候補を閉じ、候補が閉じていれば原文表示に戻します。原文表示のEnterは原文を確定します。
- 左文脈を有効にすると、このウィンドウ内で確定した文章の末尾だけを次の判定に使います。入力中は設定を変えられません。他アプリの文脈を読み取りません。
- 原文欄は最大256 Unicode scalarです。確定結果はメモリ上の試用欄にだけ追加され、終了時に消えます。

同じ綴りでも周囲の入力で判断は変わります。`I made a note` のmadeや、`go to the meeting` のtoは英字を維持します。曖昧語を無条件に保留するリストはありません。辞書だけで任意の部分文字列を英語にしないため、`asitanote` 内のnoteを勝手に切り出しません。未知語や辞書にない製品名、混在境界では誤判定が残り得ます。Escapeで原文へ戻せます。

Tabは、この試用ウィンドウでは通常のフォーカス移動です。IMEのTabによる候補操作、区間移動、OS入力欄への確定、commit ackはT5以降で接続します。中央編集も原文欄の置換として試す段階で、IMKの漢字表示上のカーソル編集を実装したものではありません。

## 資源と保存範囲

英単語辞書としてSCOWL 2020.12.07の小規模な派生表（50,957語）を同梱しています。標準的な米英綴りの一部を使い、元の権利表示・取得元・checksum・加工手順を保存しています。詳細は [辞書README](../Core/Sources/Core/InputUtils/AutoMixed/EnglishLexiconResources/README.md) と [Copyright](../Core/Sources/Core/InputUtils/AutoMixed/EnglishLexiconResources/Copyright) を参照してください。辞書の照合はローカルで行い、データを学習へ混ぜません。英語判定の履歴は入力中だけメモリに保持し、確定・取消・空入力・エラーで破棄します。

日本語変換資源の取得先は `.gitmodules` とHEADのgitlinkに一致する以下の2か所です。最新版へ追従しません。

| 資源 | 固定revision | 取得量 |
|---|---|---|
| [Zenzai GGUF](https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf/tree/c67e03e07d215c869f591b274c1631170d3e11fe) | `c67e03e07d215c869f591b274c1631170d3e11fe` | 73,871,936 bytes |
| [base_n5_lm](https://huggingface.co/Miwa-Keita/base_n5_lm/tree/160a305a89c033ac53a674baeac4470cf531a71b) | `160a305a89c033ac53a674baeac4470cf531a71b` | 4ファイル、44,638,008 bytes |

`build/auto-mixed/runtime-resources/` に保存し、Hugging Face APIのLFS SHA-256と照合します。ファイル別のURL・revision・サイズ・checksumは同フォルダの `receipt.json` に残ります。不一致の既存ファイルを上書きしません。submoduleや通常使用中のIMEを変更しません。

GGUFの配布ページはApache-2.0を表示しています。base_n5_lmの固定revisionにはLICENSE／モデルカードがなく、再配布の権利確認は未完了です。今回の取得は依頼に基づくローカル動作検証用で、リポジトリへのバイナリ追加・配布はしていません。補助ngramは取得・checksum確認済みですが、試用アプリは個人ngramを使わないため、パーソナライズ推論は検証対象外です。学習パイプラインのコーパスへは混ぜません。

試用プロセスは入力・文脈のファイル保存と変換候補の学習を行いません。依存ライブラリに入力を出力する経路があるため、起動直後に標準出力・標準エラーを破棄します。起動／変換の問題はウィンドウに表示します。IME本体のログ経路に対するT7の監査を済ませたという意味ではありません。

## 検証の境界

実施結果・失敗と修正・環境制約は [implementation_status.md](../implementation_status.md) に記録しています。T3の品質gateは未達、通常IMEの機能フラグはOFFのままです。現在の成果物を使ってT4と試用画面を進める判断であり、精度が実用水準に達したという判断ではありません。
