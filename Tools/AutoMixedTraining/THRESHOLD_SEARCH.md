# 文脈あり／なしの採用閾値を別々に探索する

2026-09-24。固定した700原文版のv2で、文脈あり0.90・文脈なし0.98の候補を得た。devの日本語再現率は旧設定の1.0%から68.0%、保留率は65.8%から21.9%へ変わり、英語破壊は0/115区間だった。**品質目標をすべて満たす候補はなく、本番採用はしない。** 今回の指標はdevで選んだ開発結果であり、test評価ではない。

## 係数を固定して閾値を比較する

基準は `build/auto-mixed/expanded-700-se-20260924/v2/calibrated.json` と同じrunのsealed dataset。語彙・LR係数・切片・sigmoid校正値は完全一致を維持した。最低文字スコア0.55、path margin 1.2、hold_ja 0.65も変更していない。追加学習・再校正・原文の再分割は行わず、旧runとtestの成果物も保持する。

従来の設定version 1は `min(1, enter_ja + missing_context_increment)` を使う。旧checkpointの再現用にこの経路を残す。新しい学習設定version 2では `enter_ja_without_context_grid` を明示し、文脈ありの `enter_ja_grid` との組み合わせを探索する。制約は `enter_ja <= enter_ja_without_context < 1`。新設定では1.0を拒否し、取得した空文字は引き続き文脈ありとして扱う。モデルschema・Swiftの判定APIは変更しない。

| 実行 | 文脈ありの候補 | 文脈なしの候補 | 有効な組×切替ペナルティ |
|---|---|---|---:|
| 新しい既定設定 | 0.90, 0.95, 0.99 | 0.90, 0.95, 0.97, 0.99 | 8×5 = 40 |
| 詳細探索 | 同上 | 0.90, 0.95, 0.97, 0.98, 0.982, 0.984, 0.986, 0.988, 0.99, 0.995 | 21×5 = 105 |

切替ペナルティは既存の0, 0.4, 0.8, 1.2, 2.0を維持し、両実行とも0が選ばれた。詳細探索は最初のdev結果を見て0.97〜0.99付近を細分化したもので、独立した確認試験ではない。既定設定には最初の小さいグリッドを残し、詳細探索の設定はrun内のconfig.jsonへ保存した。

選択順序は従来どおり、英語span破壊率0.5%以下を優先し、その中でJA再現率を最大化する。同点は英語破壊率、切替ペナルティ、文脈あり閾値、文脈なし閾値の昇順で決める。条件内の候補がなければ最少破壊の診断用候補を保存するが、合格とはしない。

全候補の指標、選択番号、文脈別の分母と指標、仕様05章の4目標への未達項目を保存する。英語破壊率≤0.5%、JA再現率≥90%、JA適合率≥98%、境界F1≥0.90を変更していない。`target_passing_candidates` はこのdev診断の合格数で、releaseの許可ではない。指標が未定義の項目も合格扱いしない。

## 105候補にも品質目標を満たすものはなかった

devは77原文・61成分・JA 1,033位置・RAW 545位置・英語115区間。文脈ありは14原文だが、binary採点はJA 10位置・RAW 18位置に限られる。文脈なしは63原文・JA 1,023位置・RAW 527位置。

| 設定 | JA再現率 | 保留率 | 英語破壊 | 境界F1 |
|---|---:|---:|---:|---:|
| 旧v2：0.95／1.00 | 10/1,033 = 1.0% | 65.8% | 0/115 | 0.000 |
| 40候補の選択：0.90／0.99 | 497/1,033 = 48.1% | 34.9% | 0/115 | 0.558 |
| 105候補の選択：0.90／0.98 | 702/1,033 = 68.0% | 21.9% | 0/115 | 0.652 |
| 参考：0.90／0.97、切替0 | 81.4% | 12.5% | 3/115 = 2.61% | 0.640 |
| 既存v1の同じdev | 72.2% | 18.1% | 0/115 | 0.769 |

詳細探索では英語制約内が80/105候補、4目標すべてを満たす候補は0。選択候補のJA適合率は100%だが、JA再現率と境界F1が未達。文脈なしのJA再現率は692/1,023 = 67.6%、文脈ありは10/10。文脈あり0.90と0.95は選択候補で同点のため、既存の同点規則で0.90になった。少数の文脈例から0.90が一般に最適だとは言えない。

0/115の英語破壊率のWilson 95%上限は3.23%。実入力の破壊率0.5%以下を確認できる標本数ではない。v1より良い結果も得ていない。次は英語を含む混在境界や文脈対照のデータ・注釈を見直し、改善後に未閲覧の独立testを用意する。既存testへ今回の候補を当てて閾値を選び直すことはしない。

## 再現する

通常の `train` → `calibrate` も新設定で独立探索する。既存の校正済みモデルを比較する場合は、追加した `tune-thresholds` を使う。旧checkpointの設定をコピーし、今回変える設定だけを書き換える。seedや係数の学習条件を現在の既定値へ置き換えない。出力先は未作成の場所を指定する。

```sh
PYTHONDONTWRITEBYTECODE=1 build/auto-mixed/training-env/bin/python - <<'PY'
import sys
sys.path.insert(0, 'Tools/AutoMixedTraining')
from pipeline_io import read, write_new

checkpoint = read('build/auto-mixed/expanded-700-se-20260924/v2/calibrated.json')
config = dict(checkpoint['training_manifest']['config'])
config.pop('missing_context_increment', None)
config.update(schema_version=2,
              enter_ja_without_context_grid=[.90, .95, .97, .98, .982, .984, .986, .988, .99, .995])
write_new('build/auto-mixed/new-threshold-search/config.json', config)
PY

PYTHONDONTWRITEBYTECODE=1 build/auto-mixed/training-env/bin/python \
  Tools/AutoMixedTraining/pipeline.py tune-thresholds \
  --model build/auto-mixed/expanded-700-se-20260924/v2/calibrated.json \
  --data build/auto-mixed/expanded-700-se-20260924/dataset.json \
  --config build/auto-mixed/new-threshold-search/config.json \
  --output build/auto-mixed/new-threshold-search/calibrated.json
```

CLIは新設定version 2を要求する。入力は校正済みcheckpointと同じsealed datasetに限定し、閾値グリッド以外の設定変更や既存出力への上書きを拒否する。`training_manifest.config` と `calibration_report` は元のfit・校正時の履歴として保持し、最新の探索条件と結果は `training_manifest.threshold_tuning` と `threshold_tuning_report` に入る。親checkpointのSHA、新しい実装hash、選択したdecoder／閾値を記録し、モデルIDとmanifest hashを更新する。

今回の出力先は `build/auto-mixed/independent-thresholds-20260924/` と `build/auto-mixed/independent-thresholds-refined-20260924/`。後者のcomparison.jsonで同じdev上の旧v1・旧v2・今回の候補を比較できる。exportは数値一致を検証するローカル候補であり、両方ともrelease_ready=false。自由入力・アプリ文脈の取得や記録は追加していない。
