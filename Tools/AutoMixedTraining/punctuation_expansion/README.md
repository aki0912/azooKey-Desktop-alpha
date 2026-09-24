# 記号を含む930原文の再学習

2026-09-24。旧700原文へ230原文を追加した。一括再学習したv2は、`asitanotennkiwoosiete.` の句点追加によるひらがな化を、通常辞書と実Zenzaiの双方で解消した。ただし既存入力の回帰試験に失敗したため、導入済みIMEには採用していない。モデルは `release_ready=false`。

## 追加データ

[原文](sentences.txt) はこのタスク内で作った230件。内訳は日本語75、混在45、英語60、構造を持つ記号40、Unicode記号10件。派生例をこの件数に含めていない。

対象は `. , ! ? : ; ...`、引用符、括弧、ハイフンの長音／英語複合語、URL、メール、ファイル名、path、識別子、日付、時刻、小数、負数、桁区切り、百分率、通貨、式、Unicode記号。記号は画面上の全角表示ではなく、実際のrawに入るASCII表記を基本にした。

日本語はかなで意図を明示し、固定Converterで211か所の読みを照合した。`shi/si` 等の別表記も既存の標準表検証を使う。[生成済みの確認表](generated/REVIEW.md) と [権利・確認範囲](RIGHTS_REVIEW.md) を参照。新規230件の利用者による全件確認は未実施。外部コーパスや実際の入力本文・文脈は取得していない。

今回の再現文とshi版は原文へ追加せず、開発回帰試験に分けた。これらの合格を独立した精度測定として数えない。

## 分割後の増強

新設のsource manifest任意フィールド `augmentation.boundary_policy="punctuation-context-v1"` がある場合だけ、句読点・括弧・空文脈の対照を追加する。未指定時は従来のpipelineを維持する。span/model schema、v1/v2の特徴量定義とgoldenは不変。

既存700原文とgroup分割をbaselineで固定し、新しいgroupだけを分割した後、ローマ字variant・記号・文脈・prefixを増強する。非空の文脈で意図を与えた短語、AMBIGUOUS、構造保護token、短すぎる語は自動の記号／文脈増強から除外。句読点・括弧の位置をscalar単位で付け直し、変換前の本文はそのまま保つ。元文一件あたりの合計学習重みは1のまま。

| 種類 | 行数 |
|---|---:|
| 原文 | 930 |
| ローマ字別表記 | 596 |
| 句読点・括弧 | 1,473 |
| 文脈可否の対照 | 1,876 |
| prefix | 3,788 |
| 合計 | 8,663 |

別splitと衝突した派生例1,816行は削除し、原文を別splitへ移さなかった。原文の分割はtrain642、dev100、calibration102、test86。testのうち新規原文は23件。旧testは以前に閲覧済みなので、全86件を新しい独立データとは呼ばない。

## 学習結果と時間

一括再学習は `build/auto-mixed/punctuation-930-20260924/`。データ構築・Swift照合9.378秒、LR学習とdev選択53.317秒、校正とdev閾値選択2.101秒、export0.804秒、合計65.603秒。manifestのモデルSHA-256は `2cef9e0443d6ca5f54caf9c999959aa78d0ad7f8b030e0462a1749a091b1e02b`。

語彙・係数はtrain、正則化と閾値はdev、sigmoidはcalibrationで求めた。従来の閾値候補グリッドと最低件数を維持し、testを見る前に候補を固定した。選ばれた閾値は文脈あり／なしとも0.99、切替ペナルティ0、hold0.65。

今回の再現例は、文脈取得不可／空文脈、si／shi、句点・読点の追加と削除、全体入力、確定、Escapeの原文回復で合格。実GGUFを指定したZenzaiと通常辞書の2試験も成功した。

一方、既存の `asitan` のpending n、`asitanote` のかな末尾、孤立made、日本語対照のnote、`meeting` の直後まで打ったprefixで、従来の期待値と差が出た。関連Core試験は34件のrunner集計で12 assertion失敗、5件skip。期待値は変更していない。モデル更新に伴う既存表示の変化を合格扱いせず、候補を未採用にした。

追補：その後の[退行原因調査](../../../docs/azookey_auto_mixed_codex/docs/11_RETRAINING_REGRESSION_REVIEW.md)で、下位adapterの失敗・通常辞書だけの表記変化・実Zenzaiの表記変化を切り分けた。日本語優先＋実Zenzaiでは「明日n」「明日のて」「まで」を維持した一方、文脈取得不可の `asitahameetingg` は英語境界を失って退行した。12 assertion失敗を12個の実機表示不具合と同一視しない。

### 凍結後のtest評価

同じ86原文で旧モデルと比較した。これはLR＋Viterbi＋保留までのオフライン指標で、日本語優先の表示処理・Zenzai・IMKの最終精度ではない。

| 指標 | 旧モデル | 再学習候補 |
|---|---:|---:|
| 日本語precision | 99.20% | 100.00% |
| 日本語recall | 74.25% | 54.55% |
| 英語span破壊 | 1/208 | 0/208 |
| 境界F1 | 0.700 | 0.627 |
| 保留率 | 15.76% | 26.60% |

英語を保つ側へ厳しい採用条件が選ばれ、今回の症状を解消しても全体のrecallと保留率は改善していない。0/208から実運用の英語破壊率0.5%以下を証明することもできない。評価後にこのtestへ合わせて再調整していない。

### 記号係数だけを更新した比較

全体の再学習による退行を避けられるか、別成果物で制約付きLRも実測した。非記号の係数と文脈、decoder、閾値、基準校正値を固定し、trainで記号を含むchar/ngramの係数だけをfit。devで正則化を選び、別calibrationで残差の倍率だけを推定した。実行時にモデルを切り替えるコードや特定語の例外は追加していない。

- `punctuation-symbol-refit-20260924`：既存486特徴を再学習、24.544秒。既存入力の回帰は維持したが、句点回帰8 assertion失敗。
- `punctuation-symbol-refresh-20260924`：486個の記号特徴をtrainから選び直し、全語彙数32,768を維持、41.565秒。句点回帰4 assertion失敗。

両方とも未採用。これらは全体の再学習とは異なる制約を持つ比較実験で、改善を主張するモデルではない。非記号係数固定の範囲では、負のshape係数や空文脈の過大な影響も残る。

## 再実行

出力先は新しい場所を指定する。既存モデル・評価結果を上書きしない。

```sh
PYTHONDONTWRITEBYTECODE=1 build/auto-mixed/training-env/bin/python \
  Tools/AutoMixedTraining/author_punctuation.py --output build/auto-mixed/new-symbol-sources

PYTHONDONTWRITEBYTECODE=1 build/auto-mixed/training-env/bin/python \
  Tools/AutoMixedTraining/train_punctuation.py \
  --manifest build/auto-mixed/new-symbol-sources/manifest.json \
  --baseline build/auto-mixed/expanded-700-se-20260924/dataset.json \
  --config build/auto-mixed/independent-thresholds-refined-20260924/config.json \
  --output build/auto-mixed/new-symbol-training
```

このCLIはtestを開かず、候補のexportまで行う。評価には既存 `pipeline.py evaluate` を使用し、実行後の追加調整にtestを使わない。

次に必要なのは、句読点改善と既存の入力途中の動作を両立する判定・変換区間の設計、文脈特徴の見直し、追加例の人手確認と独立した評価。現在の候補をアプリへコピーして改善済みと扱わない。
