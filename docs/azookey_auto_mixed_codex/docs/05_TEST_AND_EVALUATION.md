# 05. テスト計画と合格条件

## 1. 評価を4つに分離する

1. **素材・数値契約**：同梱reference、schema、fixtureの整合性。
2. **アプリロジック**：モック分類器・モックZenzaiでキー操作と文字保存を検証。
3. **学習モデル品質**：凍結holdoutで日英区間判定と保留率を検証。
4. **実機統合**：実Zenzai・IMK・XPC・対象アプリで操作性と性能を検証。

1が通っても2〜4の代わりにはならない。mockで日本語変換結果を固定しても、実Zenzaiが同じ漢字を出せると報告しない。

## 2. 自動テスト

| テスト群 | 主なケース | 不変条件 |
|---|---|---|
| RawBuffer | 挿入、中央削除、絵文字、結合文字 | 元文字を欠落・重複させない |
| OffsetMap | ASCII/かな/漢字/サロゲート/ZWJ | scalarとUTF-16を混同しない |
| Features | BOS/EOS、大小文字、unknown、prefix | PythonとSwiftが同じindex集合 |
| LR export | 正例方向、巨大正負logit、欠損ファイル | finiteなp、正しいlabel方向 |
| Viterbi | λ=0、切替罰則、tie、hard mask | 定義したcostの最適path |
| Segmenter | URL、識別子、空白、同一rawで異なる左文脈、曖昧語 | 保護tokenと空白を完全維持。孤立語の無条件保留を入れない |
| Context | 取得不可、空文字取得、フォーカス変更、遅延応答 | availabilityを混同せず、別欄の文脈を混ぜない |
| Roman adapter | `shi/si`、`n`、`nn`、`kan'i`、`k` | 依存Converterの仕様と一致 |
| MixedComposer | 英日交互、3区間以上、候補採用 | JA以外を変換しない |
| Edit UI | Escape、Tab、Enter、Backspace | rawPreviewと候補選択が混同されない |
| Lifecycle | commit/stop/deactivate/close | 古い入力欄へeffectを適用しない |
| XPC | 旧JSON、重複event、重複commit、古いrevision | 欠落・二重確定を起こさない |
| Learning | preview、取消、英語、学習OFF | 確定済みJAだけ学習 |
| Resources | fixture model、破損、未知version | 自動モードを安全に開始拒否 |
| Manual regression | 通常かな漢字、既存shortcuts、custom table | 既存挙動を維持 |

`fixtures/event_cases.json`は期待動作の契約。イベント名は既存API名ではなく、Codexが作るテストハーネスの入力である。OSキーeventへのmappingは別にテストする。

## 3. モデルの指標

以下は**暫定合格目標**。すべて実データと対象マシンで測定してから採用判断する。

| 指標 | 暫定目標・報告方法 |
|---|---|
| 英語span破壊率 | 明確な英語spanのうち1文字でもJAへ誤分類したspan数 / 英語span数 ≤0.5% |
| JA文字recall | 明確なJA_ROMAN文字のうちJAとして処理した割合 ≥90%。保留はFN |
| JA文字precision | JAと処理した文字のうち正しい割合 ≥98% |
| 言語境界F1 | 明確なJA↔RAW境界、完全一致基準で≥0.90 |
| 保護token維持 | 手動確定までraw完全一致。必須fixtureは100% |
| prefix安定性 | 入力1文字あたりの既存表示runの変更回数・p95を報告 |
| 初回変換遅延 | 最終的なJA spanに対し変換表示までに必要だった追加打鍵数 |
| 保留率 | 全体・曖昧語・短語・domain別。0%を目指さない |
| 校正 | Brier score、10bin reliability、サンプル数。平均pをspan正解確率と扱わない |
| 保護の副作用 | URLに続く無区切りJAなど、過剰保護のJA miss率 |

全部rawなら英語破壊率0%でもJA recall0%なので不合格。AMBIGUOUSは主指標の分母から分け、raw維持／明示修正のしやすさを測る。

境界F1は正解ラベルがJA/RAWの隣接位置だけを対象にし、GAP/LITERAL/AMBIGUOUSを跨ぐ境界は別集計。英語破壊率には標本数とWilson等の信頼区間を添える。小規模データの「0件」だけで実運用の0.5%以下を証明したと扱わない。

2,000件以上の明確な英語spanを含む独立testを評価開始目安とする。言語、単語、原文groupの偏りを併記する。必要標本数は許容する信頼区間幅に合わせて増やす。

比較baselineは「すべてraw」「単語単位LR」「文字位置LR（λ=0）」「文字位置LR＋Viterbi＋保護／保留」。保護・保留・妥当性検査を一つずつ外すablationを出し、どの仕組みが何を改善／悪化させたか確認する。

T2後の比較にはv1 LR＋Viterbiと、同じ保護規則・分割で学習した確定済み左文脈付きv2 LR＋Viterbiを追加する。同一rawを `I ` と `明日` で入力する対照ペア、文脈取得不可、日本語文中の英語引用を別集計する。`fixtures/context_pairs.jsonl` は仕様上の期待意図であり、学習済みモデルの予測ではない。閾値と保留率のトレードオフを一緒に報告する。

### 2026-09-25追補：開発データの実runtime入力途中評価

`Tools/AutoMixedTraining/pipeline.py evaluate-typing --model <v2-export.json> --data <dataset.json> --output <new-report.json>` は、sealed datasetのdev原文だけを実Swiftの `JapanesePreferredSegmenter` へ渡す。元文groupと既存の分割は維持し、train／calibration／testや派生行を評価集合へ混ぜない。各原文をUnicode書記素単位で追加、末尾削除、各prefixの新規入力として再生する。毎回、現在のrawだけから特徴量・保護・ローマ字妥当性・辞書判定を計算する。

出力は原文数、方向別のJA precision/recall、綴りが最後まで入力されたRAW正解spanの露出数と日本語化回数、既存位置のspan kind変化数、追加／削除／貼り付けのspan差、segment処理時間p50/p95。取得不可／空／非空文脈を分ける。読み表示と漢字変換は言語指標ではともにJAだが、span差の比較では区別する。短いprefixは元文の意図で採点しており、入力だけで意図が一意に決まるという評価ではない。露出数は同じ原文の相関した観測で、独立した正解例数ではない。英語の既存hysteresisによる差もあり、貼り付けとの差0を無条件の合格基準にはしない。

これはモデル単体の完成文評価を補う候補比較資料で、閾値順位付けの目的関数や品質目標は変更しない。`train_punctuation.py` はexport後に同じdev評価を実行して `typing_dev.json` を残す。reportを確認せず合格モデルと扱わない。最終の漢字／かな表記は別の人工回帰試験と実Zenzaiで検証する。開発データの一般reportはZenzai、実IMK、独立testの評価ではない。本文・文脈をreportやログへ出さず、一時入力ファイルを終了時に削除する。

## 4. Zenzaiの評価

判定器が渡した原文／読みspanが正しいか、候補生成が正しいか、選択UIが正しいかを分ける。

実Zenzaiでは同じ読みの候補表記が変わり得る。fixtureの`desired_display`は希望例であり、実モデル用の唯一正解としない。人手で許容表記を定めたsubsetに限りTop-1／Top-5を測る。

テストには文脈なし、英語を挟んだ文脈、先行候補変更後、同じ原文だが違う入力欄、異なる2セッションの交互入力を含める。セッションキャッシュの混線や、片方のstopが他方を消す問題を重点確認する。

### 固定例の内部判定と表示の契約（2026-09-25）

再学習候補へ旧モデルの内部kindをそのまま要求しない。特徴量v1/v2・LR/Viterbi・goldenと、人工スコアによる閾値・保護・pending tailの試験は従来どおり固定する。実学習モデルの回帰は、以下の表示と原文保持を別に確認する。

- `asitanx` は利用者確認済みの「明日nx」を正解とする。下位adapterへ「日本語区間を一つも含めない」と要求した旧負例を外し、日本語優先runtimeで `asita → asitan → asitanx`、Backspace・再入力・貼り付け・確定・Escapeを検証する。漢字変換対象は先頭の `asita`、原文は `asitanx` のまま。末尾 `nx` を捨てたり補正したりしない。モデルごとの一つのspan／複数spanの違いは固定しない。
- 孤立した `made`／`to` は日本語区間・全範囲・正しい読みを要求する。japaneseKanaだけに限定しない。文中 `I made a note` 等の英語保持、人工スコアでの漢字／かな選択条件は維持する。
- 通常辞書だけの `made` は「まで／間で」、`asitanote` は「明日のて／明日の手」を許容する。理由は、かなpreviewか漢字変換かの違いと、固定辞書の候補順位である。判定器を通さない `SegmentsManager` でも「間で／明日の手」が先頭になることを対照試験で確認する。日本語以外への区間化、読みの欠落、fallback、Escape時の原文変化は許容しない。
- 実Zenzaiでは `made → まで`、`asitanote → 明日のて` の従来の完全一致を維持する。実GGUFのbackend readyを確認し、資源なしのskipを成功扱いしない。句点追加で「教えて」を維持する既存回帰も変更しない。

これらは固定例の合格条件の訂正であり、学習ラベル・モデル・実装・品質目標の変更ではない。通常辞書だけでも常に同じひらがな表記を優先する製品要件を設ける場合は、別途候補順位または変換区間の設計と試験が必要になる。

## 5. 性能計測

| 項目 | 初期budget |
|---|---|
| features＋LR＋Viterbi | warm、256 scalars以下、p95≤5msを目標 |
| モデルファイル | 5MiB以下 |
| 追加常駐メモリ | mixed機能OFFとの差分32MiB以下を目標 |
| 子変換session | 32個以下。解放後に無限増加しない |
| end-to-end | 固定値保証はしない。入力→marked textのp50/p95/p99を実測 |

ZenzaiモデルサイズをプロセスRSSと同一視しない。測定条件にMac型番、チップ、RAM、macOS/Xcode/Swift版、電源設定、モデル／辞書hash、ライブ変換設定を含める。

完成文一括だけでなく、10/20/40文字毎秒のreplay、cold起動、cache hit/miss、連続1,000文字、中央編集、複数アプリ切替で測る。20文字毎秒でqueueが持続的に増える、文字順が崩れる、確定が二重になる場合は不合格。

## 6. 実機の対象表

| 種類 | 最低限の確認例 |
|---|---|
| AppKit | TextEdit |
| WebKit | Safariのtextarea、検索欄 |
| Chromium | Chromeのtextarea、contenteditable |
| Electron | VS Codeの編集欄、検索欄 |
| チャット | WebチャットのEnter送信と複数行入力 |
| Terminal | Terminal等。初期はmanual推奨、autoは非推奨の実験対象 |
| セキュア入力 | パスワード／認証ダイアログ。OSの保護経路を侵害しない |
| アクセシビリティ | キーボードのみの候補修正、状態を色だけに依存しない |

対応アプリとして宣言するには、純英語、混在、Space/Tab/Enter、Cmd+A/C/V、選択変更、フォーカス移動、英数／かな切替をすべて確認する。「エディタだから全欄同じ」は仮定しない。

## 7. 障害注入

応答遅延、同じeventID再送、古いeventID、重複commit effect、ack喪失、サーバーrestart、古いepochの応答、候補選択中の文字追加入力、deactivate直後の返答を再現する。

正常時の二重挿入0件・欠落0件は必須。クラッシュ後に確定の適用有無を確定できないケースでは再挿入しない方針を検証し、原文回復可能性と残余リスクを記録する。再現できなかった障害ケースを「合格」にしない。

## 8. この資料で実行できる検証

```bash
cd docs/auto-mixed
python3 -m unittest discover -s reference -p 'test_*.py' -v
python3 reference/validate_bundle.py
```

標準ライブラリで動くreferenceの検証。任意で`jsonschema`を導入してschema自体の検証も行う。実Swift parity・学習・macOSビルドは未実行として別欄へ記録する。
