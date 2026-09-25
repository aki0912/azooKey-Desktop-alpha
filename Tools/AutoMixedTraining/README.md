# T3の最初の差分：確定済み左文脈を使うv2候補

この文書は特徴量・数値契約・対照試験を説明する。追加した学習CLIの使い方と権利・分割の契約は [TRAINING.md](TRAINING.md) を参照。アプリからは呼ばれず、自動混在入力はOFFのまま。仕様入口は現在の作業ツリーでは `docs/azookey_auto_mixed_codex/docs/09_T2_MIGRATION.md`。利用者が移動した `docs/auto-mixed-old/` はT2の回帰資料として保持する。

## 入力と寿命

新しいpure Core APIは `ContextualLanguageJudging.judge(LanguageJudgmentInput)`。既存の `LanguageSegmenter.segment(_:)` やXPCの `ConverterTextContext` とは別の定義である。

- `raw` はその打鍵時点の未確定prefixだけを渡す。範囲は従来どおりraw内のUnicode scalar位置。
- `CommittedLeftContext.unavailable` が既定。取得成功時だけ `.available(text)` を使う。空文字の取得成功を欠損と混同しない。値は末尾30 scalarsに切り詰め、正規化や空白除去をしない。切断位置は書記素境界に丸めない。
- 呼び出し側は、現在の入力欄で取得が許可され、選択範囲がなく、フォーカスが一致し、セキュア入力でないことを確認する必要がある。今回のAPI自体はアプリを読まない。実クライアントによるこの確認はT5で実装・検証する。
- `focusIdentity` とrawの `revision` は呼び出し側が渡す。入力は不変で、作成ごとに新しい `requestID` が付く。文脈だけの更新、availabilityの更新、フォーカス変更も新しい入力を作り、結果の `isCurrent(for:)` を確認する。本文のhashは使わない。
- 判定器にキャッシュ・非同期処理・候補採用処理はない。結果にraw・文脈・特徴キーを保存しない。入力・文脈・特徴オブジェクトのdebug表示は伏せる。ログ、ディスク、入力履歴収集へ文脈を出す処理は追加しない。

09章の `userOverrides`、Zenzai候補cacheの無効化、古い非同期応答を実際に破棄するXPC配線、文脈変更後の採用済み候補維持はT4〜T6に残す。今回それらを実装済みとしない。既存T1エンジンの候補保持処理は変更しない。

## 特徴キーの契約

`feature_spec_version = anchored-context-v2`。`context_features.py` とSwiftの `ContextualCharacterFeatures`、固定goldenを対にする。v1の61個のキーはそのまま含め、文脈キーだけを追加する。全キーはASCII escapeしたcompact JSON、ASCII A–Zのみ小文字化、UTF-8順、binary presence。rawと文脈を連結しない。文脈の文字をViterbiの位置へ追加しない。

| キー配列 | 定義 |
|---|---|
| `["ctx","availability",value]` | `available` または `unavailable`。欠損時はこの1個だけ追加 |
| `["ctx","char",offset,symbol]` | 取得成功時、末尾からoffset=-1〜-30。値はv1と同じCHAR/BOS形式 |
| `["ctx","shape",offset,shape]` | 同じ位置の文字種。短い文脈の外側はbos |
| `["ctx","boundary",shape]` | 直前scalarの文字種。成功した空文字はempty |
| `["ctx","suffix",length,[characters]]` | 末尾2/3/4 scalars。必要な長さがある場合だけ生成。空白を含む |
| `["ctx","word",[characters]]` | 末尾のspace形状だけを除いた後、末尾にあるASCII英字run。空なら生成しない |

shapeは以下の固定範囲で決める。Unicodeバージョンやlocaleの変更で結果を変えない。

- upper/lower/digit：ASCII英大文字／英小文字／数字。
- space：U+0009〜000D、0020、3000。
- punctuation：ASCII句読記号の4範囲（0021〜002F、003A〜0040、005B〜0060、007B〜007E）、3001〜3002、FF01、FF1F。
- japanese：3041〜3096、30A1〜30FA、30FC、FF66〜FF9F、3400〜4DBF、4E00〜9FFF、F900〜FAFF、20000〜323AF。これは特徴の粗い固定分類であり、言語の正解ラベルではない。
- 残りはASCIIならascii_other、それ以外はnon_ascii。

文脈キーはrawの各位置に共通して付く。前文脈と個々の曖昧語の交互作用が十分に表現できるかは未評価。改善が必要なら別feature versionにし、v1・v2を上書きしない。

## モデルと条件付き保留

v1はschema 1 / `anchored-char-v1`、v2はschema 2 / `anchored-context-v2`。新schemaは `language_model_v2.schema.json`。既存v1 schemaは変更しない。モデルと特徴型のversionが合わない場合は、評価時にエラーにする。production読込は両versionで `kind=fixture` を拒否する。

LRのfloat64内積・sigmoid・ViterbiはT2と共通。数値goldenの許容誤差は従来どおり1e-12未満。保護規則、hard RAW mask、gap/literalの復号リセットを変更しない。

v2ではJA仮説runに対して次の条件をすべて要求する。不成立なら `.unresolved` としてrawを維持する。単語名による分岐はない。

| モデルのthresholds | 条件 |
|---|---|
| `enter_ja` | 文脈available時のrun内平均pの下限 |
| `enter_ja_without_context` | unavailable時の平均pの下限。enter_ja以上・1以下 |
| `minimum_ja` | run内の最小pの下限。0〜1 |
| `minimum_path_margin` | JA runをRAWへ置き換えた場合のコスト増分の下限。有限・0以上 |

コスト増分は、他のラベルを固定したままJA run全体をRAWに反転する局所的な比較。各位置の `log(p)-log(1-p)` の和から、隣接するRAW境界ごとにswitch penaltyを引く。pのclipはViterbiと同じ1e-7。gap/literal境界には罰則を入れない。「最良の次点pathとの差」や「spanの校正済み正解確率」ではない。系列全体の第二候補を求める処理はこの小差分に含めない。

閾値はartifactに必須。fixtureの数値は配線試験用で、本番採用値ではない。`hold_ja` はv1と同じ整合性検査を維持し、表示ヒステリシスへの接続はT6に残す。保留を通過したJAも未検証の仮説であり、結果の `safeSpans` はJAをunresolvedに戻す。実Converterの妥当性検査・変換はT4。

文脈なしでv2を呼ぶ場合は明示的な欠損特徴を使う。従来のv1 segmenterはrawだけで動く互換・比較経路として残す。本番でどちらの経路を選ぶかはdev評価後に決める。

## 検証と未実装部分

```sh
sh Tools/test_auto_mixed_parity.sh
PYTHONDONTWRITEBYTECODE=1 build/auto-mixed/training-env/bin/python -m unittest discover -s Tools/AutoMixedTraining -p 'test_*.py' -v
```

Pythonの全テストには [TRAINING.md](TRAINING.md) の隔離venvを使う。学習済みfixtureを使うテストも含める場合は同文書のsmokeを実行する。`generate_context_golden.py` は標準ライブラリだけで固定の自作テスト文から788件を生成し、`--golden` はそこから決定的に選んだ128件を出力する。通常の検証では保存済みgoldenを書き換えず、新しい結果と比較する。入力欄・ユーザー入力履歴・外部コーパスは読み取らない。

v1の128件golden・325件のfresh特徴量／score・372件のdecoder pathは維持。v2は128件goldenと788件freshのキー・active index・logit・pをSwift/Python間で比較する。対照例は利用者提供の5件の意図契約と人工係数を使い、文脈経路、欠損、保留の調整可能性、raw保全、保護区間、古いrequestの識別を検証する。

データの任意context項目は `record_context` で検査する。旧レコードはunavailable。availableなら30 scalars以下の文字列が必須、unavailableならleft_context自体を許容しない。元文・対照ペア・prefixのgroupがsplitを跨ぐ場合は拒否する。後続差分で学習CLIを追加し、旧50原文とCodex作成650原文の計700件でLR学習・校正を実行した。[学習結果UI](REVIEW_UI.md) でv1/v2を比較できる。追加分の人手確認と、十分な独立品質・速度評価は未完了。T3全体の完了条件を満たしたものではない。
