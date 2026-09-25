# 入力途中の学習重みの比較

2026-09-25。記号・文脈variantを追加したときに入力途中の重みが薄まる問題へ、任意の配分設定を追加した。旧設定・既定config・導入済みモデルは維持している。

## 配分の契約

学習configの任意フィールド：

```json
"sample_weighting": {"policy": "prefix-mass-v1", "prefix_fraction": 0.5}
```

各train原文の学習対象位置をprefix群と非prefix群に分け、指定比率と残りの比率をそれぞれ配る。群内ではASCII英字のJA_ROMAN／RAW位置へ均等配分する。非prefix群は原文・ローマ字・記号・文脈variant。意図的に未完な原文も非prefix群に属する。片方に対象位置がなければ残る群へ全重みを配り、両方なければ対象外とする。対象を持つ原文の総重みは1のまま。0/1・非有限値・未知policy・未知の増強種別は拒否する。

省略時の全位置均等配分を保持する。devとcalibrationは原文のみの従来の重みを使い、testを学習・選定に用いない。configのoptional追加だけで、model／span schema・特徴量v1/v2・分割・学習ラベルを変更しない。manifestには規則、各群を持つ原文数、増強種別の対象位置数と実際の重みを保存する。本文・文脈・原文IDを重みの監査集計へ追加しない。

## 比較条件

既存930原文datasetをそのまま使用（SHA `ec912fd6d4731d141604f5b7012a0ccb5cd5cc8d58b32a40dd5f09fc2a80e2e3`）。新コーパスやvariantは追加していない。train642原文中、両群に対象位置を持つ586件・非prefixだけ28件・対象なし28件。総重み614のうちprefixは234.2676から293へ増えた。記号と文脈variantの寄与は逆に減るため、句点回帰も検証する。

`prefix_weighted_config.json` は前候補と同じ正則化・校正・閾値探索条件で、比率0.5だけを加えた。0.5は旧データで概ね半分だったprefixの配分を参考にした比較条件であり、devや回帰試験に合わせて複数比率を探索したものではない。語彙は前候補と完全一致。修正後コードでも設定省略で前候補を再学習すると、全係数・切片・fit reportが完全一致した。

候補の係数・語彙はtrain、Cはdev、sigmoid校正はcalibration、閾値・切替ペナルティはdevから決定。結果はC=10、採用閾値は文脈あり／なしとも0.99、hold0.65、切替ペナルティ0。モデルSHAは `471a88a65739d72386d57fef1531c0a3aa0a031f9c4a709a0fcb4eca728baa22`。`kind=production` は権利確認済みデータでfitした形式上の分類で、採用済みや品質合格を意味しない。`release_ready=false`。

## 結果と採否

比較元は、前回の英単語境界修正を適用した930原文候補。dev原文100件で比較し、testの採点やtestに合わせた調整はしていない。

| 指標 | 前候補 | prefix 0.5候補 |
|---|---:|---:|
| 完成文dev・JA recall（判定器） | 52.25% | 54.54% |
| 完成文dev・JA precision（判定器） | 100% | 100% |
| 完成文dev・英語区間破壊（判定器） | 0 / 155 | 0 / 155 |
| 完成文dev・保留率（判定器） | 33.33% | 31.71% |
| 追加時・完成済み英語区間の日本語化 | 139 / 2,596（5.35%） | 135 / 2,596（5.20%） |
| 追加時・JA recall（日本語優先処理込み） | 96.36% | 96.25% |
| 追加時・JA precision（日本語優先処理込み） | 95.47% | 95.41% |
| 追加時・既存位置のkind変更 | 924 | 834 |
| 追加と貼り付けのspan差 | 3 / 2,708 | 6 / 2,708 |
| 追加と削除のspan差 | 6 / 2,608 | 8 / 2,608 |

入力途中の改善は小さく、方向間の差は増えた。2,596は同じ原文を逐次入力した相関する露出数で、独立した英単語数ではない。JAは漢字変換・読み表示の両方を含み、完成文の意図ラベルで途中入力を採点する。短いprefixの意図が一意に決まるという主張や、独立testの精度改善の主張はしない。

比較学習時点では、既存の8 assertion失敗のうち、下位adapterのasitan／asitanoとpending n表示の4件、空文脈noteの1件が解消。一方、asitanxの負例が新しく失敗した。asitanxの先頭asitaのスコアが採用基準を通るようになり、後続nxが別扱いになったため。通常辞書のasitanote／madeとmadeの区間kindの3件も残り、合計4 assertion失敗。その時点では既存期待値を変更しなかった。失敗数だけを採用判断に使わない。

実Zenzaiではmeetingの入力途中、一般的な日本語表示、句点の「教えて」の保持、下位adapterの未完nの4試験が成功した。これは固定例の隔離試験で、通常辞書の失敗を打ち消すものではない。

後続の利用者確認で「明日nx」が正解とされ、テスト訂正を依頼された。残る4 assertionを調べ、旧モデルのkind固定と通常辞書／Zenzaiの表記の混同を訂正した。日本語区間・読み・原文保持を検証し、通常辞書は実際の候補順位に基づく2表記に限定、実Zenzaiの完全一致は維持する。理由と影響は [05章の固定例契約](../../docs/azookey_auto_mixed_codex/docs/05_TEST_AND_EVALUATION.md#固定例の内部判定と表示の契約2026-09-25)、検証結果は [implementation_status.md](../../implementation_status.md) の「回帰テストの契約訂正」を参照。失敗の訂正はモデルの精度改善ではなく、上表のdev指標も不変。

**2026-09-25、利用者の更新指示でローカルMixed版へ試用反映済み。** `release_ready=false` を維持し、配布品質の合格とはしない。曖昧語の品質、入力方向による差、実機での操作性は引き続き評価が必要で、テスト訂正だけで実用品質を達成したとはしない。

## 時間と検証

macOS 27 arm64／Xcode 27／Swift 6.4／Python 3.11.9、既存lockを使用。実測は `build/auto-mixed/prefix-mass-20260925/timings.json`。

- 従来設定の再現確認：49.075秒。
- prefix候補の学習・C選択：50.008秒。
- 校正・dev閾値選択：1.773秒。
- export：0.677秒。
- 実Swiftのdev入力途中評価：121.367秒。1候補8,024 snapshot。
- 比較全体：222.931秒。独立test評価・実IMK試験は含まない。

学習パイプラインの単体試験・fixtureのv1/v2学習／export・Python/Swift数値parityも実行した。失敗と再検証を含む詳細は [implementation_status.md](../../implementation_status.md) の同日追記を参照。raw/contextを評価reportへ記録せず、アプリ入力を取得していない。後続のIME更新では実Mach XPCの5試験も成功したが、実機打鍵・長時間利用・配布品質評価は未実施。

## 再実行

既存のsealed datasetを使い、以下の出力先を未作成のパスに置き換える。前候補は上書きしない。

```sh
task_python=build/auto-mixed/training-env/bin/python
task_output=build/auto-mixed/new-prefix-weighted
task_data=build/auto-mixed/punctuation-930-20260924/dataset.json
export PYTHONDONTWRITEBYTECODE=1
"$task_python" Tools/AutoMixedTraining/pipeline.py train \
  --config Tools/AutoMixedTraining/prefix_weighted_config.json \
  --data "$task_data" --output "$task_output/fitted.json"
"$task_python" Tools/AutoMixedTraining/pipeline.py calibrate \
  --model "$task_output/fitted.json" --data "$task_data" \
  --output "$task_output/calibrated.json"
"$task_python" Tools/AutoMixedTraining/pipeline.py export \
  --model "$task_output/calibrated.json" --output "$task_output/export"
"$task_python" Tools/AutoMixedTraining/pipeline.py evaluate-typing \
  --model "$task_output/export/model.json" --data "$task_data" \
  --output "$task_output/typing_dev.json"
```
