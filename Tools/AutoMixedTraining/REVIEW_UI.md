# 学習したモデルをローカルUIで確認する

現在の結果は旧50原文＋Codex作成650件の計700原文。**学習・校正は完了したが、品質基準には未達。** 追加分の人手確認は未実施。作成方針と確認表は [DATA_PLAN.md](synthetic_expansion/DATA_PLAN.md) を参照。通常使用中のIMEへ反映する機能はない。

| 最新test原文63件の診断 | v1 | v2 |
|---|---:|---:|
| JA再現率 | 648/960（67.5%） | 4/960（0.4%） |
| 英語span破壊率 | 0/158（Wilson 95%上限2.4%） | 0/158（同左） |
| 境界F1 | 0.702 | 0.000 |
| 保留率 | 18.0% | 56.1% |

v2は既存のdev探索で文脈なしの採用閾値1.0が選ばれ、大半の日本語を保留する。データ追加だけで実用化したとは言えない。保留もJAの見逃しに数え、目標90%を維持した。実入力分布での性能や文脈の効果は未確認。元文700件→増強後3,907行、前処理・fit・校正・レポートまでの実測は64.48秒。公式評価・parity・UI検証の時間は別。

## 作成済みの結果を開く

リポジトリ直下で次を実行し、[学習結果UI](http://127.0.0.1:8766/) を開く。

```sh
PYTHONDONTWRITEBYTECODE=1 build/auto-mixed/training-env/bin/python \
  Tools/AutoMixedTraining/review_server.py \
  --run build/auto-mixed/expanded-700-se-20260924 --port 8766
```

既に起動済みなら同じURLを開けばよい。終了は起動したターミナルのCtrl+C。ポートが使用中なら別の番号を指定し、起動時に表示されるURLを開く。成果物はgit管理外の `build/auto-mixed/` にあるので、別のcheckoutでは次の手順で作り直す。

1. 例文を選ぶと、正解区間とv1/v2の判定を表示する。区間の色は日本語・英字・保留・保護を表す。かな・漢字への変換結果ではない。
2. rawや左文脈を変えて「判定する」を押す。文脈OFFは取得不可、ONで空欄は取得成功した空文字。rawは最大256 Unicode scalars、左文脈は最大30 scalars。
3. スライダーで入力途中を試す。ブラウザーの書記素境界で区切るため、絵文字のZWJ列や結合文字を途中で切らない。サーバーには選んだprefixだけを渡し、特徴と実Coreの保護範囲を再計算する。表の位置・スコアはUnicode scalar単位。
4. 下段でtrain/dev/calibration/testを選び、分母付きの診断値と不一致例を見る。「試す」で該当例へ戻れる。自由入力の正解ラベルは推測しない。

校正済みでも小標本のスコアは実入力での正解確率を保証しない。未校正runを開いた場合は未校正と明示する。v1/v2は保留条件が異なるので、左文脈だけの効果を測る比較には使えない。今回のtestは確認UIへ公開済みであり、ここに合わせて閾値を調整しない。

## 同じ手順で新しい出力を作る

[TRAINING.md](TRAINING.md) の隔離Python環境と、固定ConverterのSwift検証環境を使う。外部コーパスの取得は不要。

```sh
PYTHONDONTWRITEBYTECODE=1 build/auto-mixed/training-env/bin/python \
  Tools/AutoMixedTraining/train_review.py \
  --manifest Tools/AutoMixedTraining/synthetic_expansion/generated/manifest.json \
  --baseline build/auto-mixed/approved-50-20260924/dataset.json \
  --output build/auto-mixed/new-expanded-review
```

出力先は未作成のディレクトリを指定する。実行内容は既存の権利検証、group分割、増強・Swift照合、v1/v2のfit、校正の試行、確認レポートの順。seedは承認manifestから引き継ぎ、既存設定の正解・校正最低件数・評価基準を変更しない。生成後はサーバーの `--run` にその出力先を指定する。

校正条件を満たさない場合も、`calibration_status.json` に失敗理由を保存し、`phase=fitted` の確認レポートを作る。コマンドがレポート作成を完了したことは、校正成功を意味しない。公式の `pipeline.py export/evaluate` は従来どおりcalibrated checkpointを要求する。再実行用CLIの検証結果は `build/auto-mixed/approved-50-review-20260924/` に別保存し、初回の凍結結果は上書きしていない。

## 旧50原文の履歴（2026-09-24）

以下は拡充前の記録。最新700原文の結果・検証はこの文書の冒頭と `implementation_status.md` 末尾を参照。旧test・checkpoint・レポートは上書きしていない。

[承認記録](approved_samples/RIGHTS_REVIEW.md) に従い、確認用原本のprovenanceだけを変更したコピーを使用した。fixtureを混ぜず、確認用の派生13行を原本として連結せず、50原文・36 groupから分割した。seedは20260924。

| 区画 | group | 原文 | 増強を含む行 | 原文のJA位置 | 原文のRAW位置 |
|---|---:|---:|---:|---:|---:|
| train | 25 | 31 | 212 | 316 | 132 |
| dev | 4 | 7 | 35 | 46 | 30 |
| calibration | 4 | 9 | 42 | 45 | 36 |
| test | 3 | 3 | 20 | 41 | 15 |

合計309行＝原文50＋ローマ字variant 13＋prefix 246。別splitと衝突する派生53行は除外した。語彙はtrainだけで作り、増強全体の元文重みは1を維持する。両モデルともdevでC=10を選択し、trainのfit対象は1,875位置。v1語彙は10,066、v2語彙は10,176特徴だった。

校正用原文はJA 45位置・RAW 36位置で、既存のapproved条件である各100位置に届かなかった。両モデルの校正はこの検査で停止したため、sigmoid校正、devでのdecoder・採用閾値の選択、runtime exportは未実施。UIの判定にはfitted checkpointの初期設定を使う。artifact内の `kind=production` は既存schemaで承認済みデータの候補を表す名称で、品質合格を意味しない。両方とも `release_ready=false`。

test原文3件・56採点位置の参考診断は次のとおり。保留した日本語も見逃しに数える。

| 指標 | v1 | v2 |
|---|---:|---:|
| JA再現率 | 22/41（53.7%） | 0/41（0.0%） |
| 英語span破壊率 | 0/4（0.0%） | 0/4（0.0%） |
| 保留率 | 21/56（37.5%） | 43/56（76.8%） |
| Brier | 0.09119 | 0.09152 |

英語spanは4件しかなく、破壊率0/4のWilson 95%区間は0〜49.0%。0%という点推定から安全性は主張できない。v2は保留が多く、このtestでは日本語を採用していない。閾値の条件差と未校正状態を含む結果であり、v2の学習失敗や文脈の効果を単独で断定する比較でもない。

次は独立した元文groupと文脈対照を増やし、新しいデータ版として分割・学習・校正を行う。100位置の最低条件を超えること自体は品質保証ではなく、十分な未閲覧test、条件を揃えた比較、実機・T4以降の評価も必要。件数合わせのために同じ例を校正用へ複製したり、testをdevへ移したりしない。

## 入力の扱いと検証範囲（旧50件の実行記録）

サーバーは127.0.0.1だけで待ち受け、Host/Originを検査する。自由入力のraw・左文脈はPOST本文で受け取り、アクセスログ・推論結果・ファイル・ブラウザー保存領域へ保存しない。レスポンスはno-store、外部CDN・通信・テレメトリは使わない。実Coreの保護検出へ渡すのはrawだけで、左文脈はPythonプロセス内で扱う。初回だけ純粋な保護検出ソースをswiftcでコンパイルする。

明示的に承認された学習例のrawと架空の左文脈は、学習データと静的レポートに含む。任意入力のログ非保存とは区別する。UIはアプリの入力欄・IME履歴を読まない。

既存回帰25件＋新規9件の計34テストが通過した。全50原文のライブ判定と静的レポートの一致、309行のCore保護mask、Unicode、group分割、元文重み、校正不足の拒否、HTTP境界と非保存を検証した。ブラウザーでは例文・自由入力・文脈取得不可／空文字・上限エラー・Unicode prefix・区画別表示を確認。再実行用CLIも実行し、初回とdataset、語彙、係数、設定、fit指標が一致した。

今回の承認済みモデルのSwiftスコアexport parityは校正未完了のため未実行。実Zenzai、IMK、表示ヒステリシス、実アプリの文脈取得、レイテンシ・メモリ測定も未実行。自動モードはOFF、T3全体は未完了。失敗・環境制約を含む実行記録は `implementation_status.md` に追記した。
