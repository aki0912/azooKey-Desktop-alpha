# ローカル学習パイプラインの準備

`pipeline.py` に6つのCLIを実装した。原本と権利確認資料を検証し、元文groupの分割を固定した後でローマ字variantとprefixを増やす。CPUでLRを学習し、別のcalibration区画でsigmoid校正を行い、Swift用JSONと検証用parityを書き出す。

今回実行したのは、同梱fixtureによるパイプラインの動作確認だけ。fixtureの少数例で実際に係数をfitするが、出力は常に `kind=fixture` であり、本番学習や精度評価の代わりにはしない。権利確認済み実コーパスはこのリポジトリにない。T3全体は未完了、自動モードはOFFのまま。

## 環境とfixtureによる再実行

```sh
python3 -m venv build/auto-mixed/training-env
build/auto-mixed/training-env/bin/python -m pip install -r Tools/AutoMixedTraining/requirements.lock

PYTHONDONTWRITEBYTECODE=1 build/auto-mixed/training-env/bin/python \
  Tools/AutoMixedTraining/fixture_smoke.py \
  --output build/auto-mixed/new-training-check
```

出力先は未作成のディレクトリを指定する。既存の評価やモデルは上書きしない。smokeは全CLI、Pythonテスト、fitしたv1/v2 artifactのSwift parityを実行する。fixtureの原本とgoldenは書き換えない。個別CLIのPython実行環境も同じvenvを使う。

`requirements.lock` は今回検証したPython 3.11環境の全実行依存をversion固定したもの。パッケージ配布物のhash付きlockではない。実行時はlockとの差異を検査し、Python版・依存版・lock SHA・実装SHAを学習manifestに残す。scikit-learn 1.9.1の公開 `coef_` / `intercept_` と `classes_ == [0,1]` を確認してexportする。疎なfloat64 CSR、LBFGS、L2、class_weightなし、1 threadを使用する。[LogisticRegression公式API](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.LogisticRegression.html)

Swiftによる入力検証には既存Coreの依存解決済み環境が必要。今回のMacではSwiftPMのnative方式を使用した。Converterは既存の固定revisionと標準表のchecksumを確認する。Swiftの準備がない環境ではbuild-datasetを成功扱いにせず失敗する。学習中にIMEやConverterServerを起動・インストールしない。

## データを受け入れる条件

原本はローカルJSONL。URLからデータを取得する実装はない。資料は現在 `docs/azookey_auto_mixed_codex/docs/04_MODEL_AND_DATA.md` と同ディレクトリの `schemas/` に配置されている。

注釈方法を確認するための [AI作成サンプル50件と人手確認表](review_samples/REVIEW.md) を別に用意した。2026-09-24に利用者が原本50件とローマ字別表記13件の内容を全件採用した。[内容確認記録](review_samples/annotation_review.json) に対象IDとhashを保存している。権利statusはpending_reviewで、fixtureにも権利承認済み学習原本にも含めていない。次は権利・利用条件の確認記録を整える。

| モード | 受け入れるもの | 出力の扱い |
|---|---|---|
| fixture | kind=authored_fixture、rights_status=fixture_only、split=fixture | 動作検証専用。途中checkpointからexportまでfixtureを保持 |
| approved | kind=authored/licensed/synthetic_approved、rights_status=approved、split=unassigned、承認manifestあり | 実際にfit・校正した候補モデル。release_readyはfalse |

approvedの `split=unassigned` は学習原本専用の拡張。既存span schemaは変更せず、原本の検証時に分割未指定を確認したうえで、その他の欄を既存schemaで検証する。既にtrain/dev/test等を指定した原本を黙って再分割しない。分割済みデータは本ツールが作るsealed datasetとして扱う。

承認manifestの雛形は `approval_manifest.example.json`。雛形はpending_reviewのため、そのままでは実行できない。利用するデータの責任者が確認した内容を記載する。

- source_id、原本の相対パスとSHA-256。
- status=approved、確認者、確認日、license_id、出典の識別子またはURL、取得日。
- training/evaluation/derived_modelを含む許可用途。合成データの場合も元サービスの条件と承認資料を含める。
- ローカルのライセンス・確認記録の相対パスとSHA-256。権利確認資料は参照するだけで取得しない。
- 元文・テンプレート・言い換え・文脈対照を同じgroupにする規則、加工内容、プライバシー確認済みの明示。

原本側のprovenanceにあるsource_id・license_id・source_url・retrieved_atと承認manifestが一致することを検証する。確認できるのは承認情報の記載・照合・改変検知であり、ライセンスの法的適合性を自動判定するものではない。今回、実データへの承認を代行してはいない。

fixtureと実データの混在、pending_review、証拠不足、hash不一致、余分なJSON項目、NaN/Inf、重複キー、不正なscalar被覆・contextを拒否する。checkpointとdatasetのhash・modeも照合する。これらのchecksumは事故検知用で、悪意ある書換えに対する署名ではない。

## 分割を先に固定し、増強で変えない

1. 原本のschema・権利情報を検証する。同一IDや既存split混在を拒否する。
2. group_idを基礎に、同一rawの文脈対照と近重複原本を同じ連結成分へまとめる。漏洩検査用の比較キーだけで小文字化・空白圧縮・数字置換を行う。12文字以上では類似度0.95以上も統合する。モデル入力のrawは変更しない。
3. seedと成分IDのSHA-256で順序を決め、70/10/10/10を最大剰余法で割り当てる。丸め後の実数を保存する。4区画を作れるよう最低10成分を要求する。
4. 分割を保存してからJA spanのvariantを生成し、scalar長に合わせて後続spanをずらす。英語・literal・gapは書き換えない。
5. 各元レコードに最大8 prefixを追加する。短prefixを優先し、残りはseedで決定する。未来の文字を含む特徴や保護maskを使い回さない。
6. 別splitの原本・増強文と重複する増強文は除外し、件数を残す。元文や増強文を別splitへ移動して衝突を隠さない。

原文の共通由来をrawだけで完全には判定できない。注釈者によるgroup_id付与が前提で、近重複検査は補助。初期の人手確認済み小規模データ向けに原本上限は10,000件、近重複検査はO(n²)としている。大規模コーパスへの対応は別途必要。

variantは固定Converterの表で同じかなになる表記だけを使う。初期の増強対象はshi/si、chi/ti、tsu/tu、fu/hu、ji/zi、sha/sya等の拗音、cha/tya/cya・ja/jya/zya等、小書き文字のx/l。この一覧は増強候補を選ぶためのもので、Converterの変換表を置き換えない。実表の読みが一致しない組は生成しない。

元文1件につき、複数のJ区間を代表的な別表記にした例を先に、その後に一部だけ変えた例を作る。既定では最大2件、manifestで0〜8件を指定できる。組み合わせの全列挙はしない。英語・literal・gap・曖昧区間と左文脈、意図表記は保持し、変わった長さに合わせてUnicode scalar offsetを再計算する。

nn/xnは固定表から境界を認識するが置換しない。n・促音の途中子音はそのまま残し、直後の置換で先頭子音が変わる候補を除外する。以前はこれらを含むJ区間全体を省いていたが、現在はほかの完全なtokenの別表記を作れる。アポストロフィ・大文字・未完の末尾を含むJ区間は今回も省く。Pythonでかなへの変換結果を推測せず、生成した変更run全体を実 `ComposingText.insertAtCursorPosition(_:inputStyle:)` の `.roman2kana` で比較する。不一致なら処理全体を失敗させ、正解を変更して通さない。Zenzai推論・候補学習は呼ばない。

初期方式の「固定表にあるすべての同義表記」から、上記の表記群に絞る方式へ変更した。少数の原本にca/ci/whu等の追加例が偏ることを避けるためで、これらの打鍵をConverterから削除したわけではない。生成件数と学習データの内容は変わるため、過去のfixture学習結果との直接比較には使わない。v1/v2特徴量・既存golden・元文ごとの合計sample weight 1は維持する。

prefixはASCII同士の境界に限定し、結合文字・ZWJを切らない。全Unicode書記素のprefix増強は未対応。保護maskは全行について実 `ProtectedSpanDetector` で生成する。依存ライブラリのDEBUG出力が本文を含み得るため、専用Swift検証プロセスでは本文処理中のstdout/stderrを抑止する。入力は一時ファイルに渡し、終了後に削除する。文脈はSwift検証へ渡さない。

### 確認待ちの原本で別表記を確認する

[50件から作成した別表記一覧](review_samples/roman_variants/REVIEW.md) は元文50件＋追加13件の計63件。学習に投入できない `review_preview` として保存した。再生成時は未作成の出力ディレクトリを指定する。

```sh
PYTHONDONTWRITEBYTECODE=1 build/auto-mixed/training-env/bin/python \
  Tools/AutoMixedTraining/preview_roman_variants.py \
  --input Tools/AutoMixedTraining/review_samples/samples_50.jsonl \
  --output build/auto-mixed/new-roman-preview --max-variants 2
```

この確認用CLIはpending_review・unassignedの原本だけを受け入れ、まず元文groupを仮分割し、その後で別表記を作る。別splitと衝突する派生行は学習経路と同じ関数で除外する。fixtureへの変更や権利承認は行わず、元の50件も書き換えない。出力のpreview.jsonは学習用sealed datasetではない。学習時は、承認済み原本全体を本来のbuild-datasetへ渡して分割・増強し直す。確認用の派生行を原本として連結すると二重増強になるため、投入しない。

## CLIと各区画の用途

以下はコマンド名と引数の対応。`<...>` は利用者が指定するローカルパスで、実データを同梱したという意味ではない。

| CLI | 入出力と用途 |
|---|---|
| `validate-data --input <fixture.jsonl>` | fixtureの形式確認。実データには `--manifest <approval.json>` を使う |
| `build-dataset --manifest <manifest.json> --output <dataset.json>` | 権利検証、group分割、variant/prefix、実Swift検証、sealed dataset |
| `train --config <config.json> --data <dataset.json> --output <fitted.json>` | trainだけで語彙と係数を作る。Cはdevのlog lossで選択 |
| `calibrate --model <fitted.json> --data <dataset.json> --output <calibrated.json>` | calibrationの原本だけでsigmoidをfit。decoderと採用閾値はdevで選ぶ |
| `export --model <calibrated.json> --output <new-directory>` | model.json、manifest.json、固定自作例のparity.jsonを書き出す |
| `evaluate --model <calibrated.json> --test <dataset.json> --traces --output <report.json>` | sealed datasetのtest原本だけを評価。追加の学習・閾値選択なし |

全CLIは非ゼロ終了、既存出力の上書き拒否、入力検証を備える。ログには本文やcontextを出さず、件数・状態・内容を含まないエラーだけを出す。学習データの成果物には、明示的に渡された注釈済みraw/contextが含まれる。アプリの入力欄・ユーザー入力履歴から収集する機能はない。

語彙はtrainだけのdocument frequencyで上位を選び、同順位と最終順はUTF-8順にする。元レコードごとのDFを数え、増強で長い文章だけを優遇しない。位置sample weightは、全variant/prefixを含めて元レコードあたり合計1に正規化する。GAP/LITERAL/AMBIGUOUSの位置、およびASCII英字以外の位置はbinary学習から除外する。

校正は正例JA_ROMAN=1に対する `sigmoid(a*z+c)`。校正用LRは正則化なし。逆向きの係数になった場合や片方のclassが不足する場合は失敗させる。最低件数はfixtureで各class 2位置、approvedで100位置としている。100は品質保証の基準ではなく、極小の校正を拒否する入口。optimizerの非収束も成功扱いにしない。

devでは英語span破壊率0.5%以下の候補からJA recallを優先する。該当候補がなければ破壊率が最小の候補を診断用に残す。これを合格モデルとは扱わない。設定と選択結果をmanifestに記録する。v1とv2では利用できる保留条件が異なるため、今回のsmoke結果を同条件の品質比較として使わない。実比較では候補条件を揃えたablationが必要。

## 評価と残る作業

評価JSONは英語span破壊率とWilson区間、JA precision/recall、境界F1、保留率、Brier、10bin reliabilityを出す。文脈の有無とcategory別も分け、分母0はnull。`--traces` はASCII原本の全prefixで特徴と実Swift保護maskを再計算し、既存位置の反転数を数える。Unicode原本は未replay件数を報告する。IMK打鍵試験やSwiftのレイテンシ測定ではない。

評価はLR＋Viterbi＋保護＋今回の採用条件までのオフライン判定。実ローマ字妥当性gate、T4のZenzai、T6の表示ヒステリシスと利用者修正、IMK、メモリ・p95は未評価としてreportに残す。fixture評価は `fixture_smoke_only` と表示する。新しい出力先へ再実行することは可能であり、凍結testを一度だけ開く運用・レビューはデータ管理側で守る必要がある。

今後必要なのは権利と注釈を確認した実コーパス、十分な独立test、条件を揃えたv1/v2比較、失敗例のレビュー、T4以降の統合と品質・性能gate。候補artifactをアプリへ自動コピー・登録する処理は追加していない。
