# 700原文を出発点に、必要なデータ量を測る

2026-09-24。最初の目安は500〜1,000原文とし、Codexで650件を追加して計700件にした。これは学習・校正と不足の診断を始める規模で、実用精度を保証する件数ではない。次の拡充目標は10,000原文だが、先に文脈なしv2の過剰な保留と注釈を点検する。同じ文の表記違いやprefixを、独立した原文数に数えない。

件数の根拠は仕様 `docs/azookey_auto_mixed_codex/docs/04_MODEL_AND_DATA.md` §5.1の500〜1,000→10,000→必要なら50,000という計画値。仕様は最初の例を人手確認する前提だが、追加650件の人手確認は未実施である。今回の学習は、利用者の作成・利用指示に基づく合成データによる診断として進めた。[許可と確認範囲](RIGHTS_REVIEW.md) に記録した。

「それなりに動く」の判定には05章の英語span破壊率0.5%以下、JA再現率90%以上、JA適合率98%以上、境界F1 0.90以上を使う。英語spanを2,000件以上含む独立testも評価開始の目安。学習用原文を1万件にしても、この評価データや実機試験を省けない。

## 追加した650件と、人に確認してほしい箇所

| 内容 | 追加原文 | 狙い |
|---|---:|---|
| 日常・仕事・開発・生活・検索の日英混在 | 250 | 空白あり／なし、英語の前後の日本語、異なる用途 |
| 日本語だけ | 100 | 英語を含まない普通の入力も日本語として扱う |
| 英語だけ | 140 | 英文をローマ字日本語へ誤分類しない |
| 短い検索語 | 30 | 短文でも日英双方を含める |
| URL・メール・path・識別子・Unicodeなど | 30 | 保護区間と通常入力の境界を調べる |
| 20種類の曖昧raw×5文脈条件 | 100 | 同じrawの英語／日本語／引用、文脈未取得／取得した空文字 |

原本は [sentences.txt](sentences.txt) と [context_intents.json](context_intents.json)。明示した文章から [samples.jsonl](generated/samples.jsonl) を作る。外部コーパスを取得せず、実ユーザーの入力・文脈も収集していない。20語にはmade/no/to/name以外にare/me/so/hi/he/do/go/ore/site/sake/take/hate/mine/same/came/koiを含む。文脈なし／空文脈の40件はAMBIGUOUSのままbinary学習から除外する。単語名で無条件保留するコードは追加していない。

人の確認は [全650件の確認表](generated/REVIEW.md) から行える。優先順位は次のとおり。

1. 文脈対照100件：文脈と入力意図が自然か、JA/RAWを一意に決めてよいか。「日本語文中の英単語」をJAに誤注釈していないか。
2. 保護区間30件：URL末尾などの境界が意図どおりか。正解ラベルがLITERALでも現在の検出器がすべて保護できるとは限らない。
3. 残る520件：各用途から抜き取り、自然な打鍵・英単語・読み・区間を確認する。最終的に人手確認済みの初期集合とする際には全件の採否を記録する。

機械検証で区間の被覆、scalar範囲、schema、553か所の日本語の読みを確認した。読みは固定Converterの実 `ComposingText` と照合する。これで入力意図や文章の自然さまで正しいとしたわけではない。

## 原文の分割を固定してから増強する

旧50原文と旧分割をsealed datasetで固定する。同じrawの文脈対照・近重複を統合し、既存groupに属する追加例はそのsplitを継承する。異なる旧splitを結ぶ例はエラー。新規成分だけを70/10/10/10へ割り当て、その後shi/si・tsu/tu等の既存variantとprefixを作る。語彙はtrainだけから作り、元文あたり合計重み1を維持する。

分割と前処理の分離は [scikit-learnの漏洩防止ガイド](https://scikit-learn.org/stable/common_pitfalls.html) に沿う。近重複検査だけで意味の似たテンプレートを完全に検出できるわけではなく、由来のgroup付けと人の確認も必要。

最終成果物は `build/auto-mixed/expanded-700-se-20260924/`。実数・モデル診断・時間は `implementation_status.md` の末尾に記録した。元文700件から増えた行を原文数と混同しない。追加後もT0〜T2、v1/v2特徴量、LR、Viterbi、golden、span/model schema、通常のmanual入力は変更していない。

## 件数の効果をdevで測り、testで調整しない

`learning_size_probe.py` はtrainの成分を100→250→全421と増やす。部分集合は入れ子で、各元文の派生行をまとめて選ぶ。各段階でtrain限定の語彙を作り直し、同じdev原文でlog lossを比較する。v2、C=1.0を固定し、校正・閾値選択・test採点・モデルexportは行わない。

これは [学習曲線の考え方](https://scikit-learn.org/stable/auto_examples/model_selection/plot_learning_curve.html) を使った診断。単一seedの自作分布であり、1万件の性能を外挿する根拠にはしない。原文を増やしてdev誤差が下がり続けるか、用途別の不足が残るかを見て次の量を決める。

本学習ではCをdevで、sigmoidをcalibrationで決め、閾値も既存のdev探索をそのまま使った。各class 100位置という校正の入口条件やテスト期待値は緩めていない。UIのtestはすでに閲覧済み。これに合わせて閾値や係数を変更せず、次の改善後には別途凍結した独立testを用意する。

## 再実行する

既存の隔離Python・固定Converter環境を使う。出力先は未作成のディレクトリを指定する。

```sh
PYTHONDONTWRITEBYTECODE=1 build/auto-mixed/training-env/bin/python \
  Tools/AutoMixedTraining/author_expansion.py \
  --output build/auto-mixed/new-authored-expansion

PYTHONDONTWRITEBYTECODE=1 build/auto-mixed/training-env/bin/python \
  Tools/AutoMixedTraining/train_review.py \
  --manifest build/auto-mixed/new-authored-expansion/manifest.json \
  --baseline build/auto-mixed/approved-50-20260924/dataset.json \
  --output build/auto-mixed/new-expanded-review

PYTHONDONTWRITEBYTECODE=1 build/auto-mixed/training-env/bin/python \
  Tools/AutoMixedTraining/learning_size_probe.py \
  --data build/auto-mixed/new-expanded-review/dataset.json \
  --output build/auto-mixed/new-expanded-review/learning_size.json
```

旧baselineがないcheckoutでは、先に `approved_samples/manifest.json` を既存の `train_review.py` へ渡して旧50件のsealed datasetを再現する。baselineを省いて再分割した結果を、今回の比較対象としない。

モデル・レポート・timings.jsonはbuild配下のローカル成果物。アプリへの導入は行わず、自動モードはOFFを維持する。次は文脈なしv2の採用条件をdevで検討し、文脈付き例と各用途の人手確認済み原文を増やす。データ量だけでは採用条件や特徴量の不足を解消できない。
