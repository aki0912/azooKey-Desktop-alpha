# azooKey Mixed のローカル試用

通常版と併用する試験版を `azooKey Mixed` として用意した。**自動・日本語・英数** の3モードを実装した。導入後、利用者から動作開始の報告があり、親入力ソースと自動モードの有効化をAPIでも確認した。広範なアプリでの実打鍵試験は引き続き未完了。現在の学習済みモデルを使うが、品質基準は未達で `release_ready=false`。中央編集・長時間利用・広範なアプリ互換性の確認は残っている。

## 導入・更新

このMacで検証した構成はmacOS 27、arm64、Xcode 27、Swift 6.4。取得済みのGGUF・4 marisa資源とreceipt、学習済みruntime exportを使用する。スクリプトはコーパス取得や再学習を行わない。

```sh
python3 Tools/build_mixed_ime.py
python3 Tools/install_mixed_ime.py install --dry-run
python3 Tools/install_mixed_ime.py install
python3 Tools/install_mixed_ime.py status
```

導入済みの版を更新するときは、未確定文字を確定し、ABCやmacOS標準日本語などMixed以外へ切り替えてから次を実行する。`update` は入力ソースを再登録・再有効化せず、現在のモード設定を保つ。

```sh
python3 Tools/install_mixed_ime.py update --dry-run
python3 Tools/install_mixed_ime.py update
```

ビルド先は `build/auto-mixed/mixed-ime/azooKeyMixed.app`。ユーザーの `Library/Input Methods/azooKeyMixed.app` と専用LaunchAgentへ導入し、このアプリの入力ソースだけを登録・有効化する。インストーラーは現在選択中の入力ソースを切り替えない。更新前には別の入力ソースを選ぶ。通常版を置き換える既存 `install.sh` は使わない。

作業中の書類を保存して一度ログアウト・ログインし直し、システム設定 → キーボード → テキスト入力「編集」→「＋」で日本語の `azooKey Mixed` を追加する。その後、画面上部の入力メニューから `azooKey Mixed（自動）` を選ぶ。通常版はそのまま残す。再ログイン後も一覧に出ない場合の原因は未確認で、有効化できたとは扱わない。設定画面の手順は[Appleの入力ソース設定ガイド](https://support.apple.com/ja-jp/guide/mac-help/mchl84525d76/mac)を参照。

- **自動**：日本語を優先し、モデルと英単語辞書の条件を満たす英語を保持する。例：`asitahameetinggaarimasu` → `明日はmeetingがあります`。
- **日本語**：既存の手動日本語入力。Spaceの候補操作などは従来の経路を使う。
- **英数**：既存の英数入力。

自動モード中の「かな」キーは自動モードを維持し、未確定文字列もそのまま残す（capability確認中も同じ）。手動日本語へ移る場合は入力メニューで「日本語」を選ぶ。英数キーは従来どおり英数へ切り替え、自動へ戻るときは入力メニューで選び直す。手動入力が残っている場合、自動判定はその確定後から開始する。日本語／英数モード内の従来キー操作は変更しない。

## 通常版との分離

| 対象 | azooKey Mixed |
|---|---|
| アプリ／実行ファイル | `azooKeyMixed.app` / `azooKeyMixed` |
| bundle ID | `dev.azookey.inputmethod.azooKeyMixed` |
| Mach service／LaunchAgent | `dev.azookey.inputmethod.azooKeyMixed.ConverterServer` |
| 入力モードID末尾 | `.Automatic` / `.Japanese` / `.Roman` |
| 設定domain | `dev.azookey.inputmethod.azooKeyMixed.preferences` |
| API key account | `dev.azookey.inputmethod.azooKeyMixed.preference.OpenAiApiKey` |
| 辞書・学習データ | ユーザーの `Library/Application Support/azooKeyMixed` 以下 |
| カスタム入力表ディレクトリ名 | `azooKeyMixed` |

通常版の設定・辞書・APIキーを自動移行しない。Mixedの設定がないときは既定値を使い、通常版のUserDefaultsへfallbackしない。埋め込みhelperの `--identity` でも同じ識別子を検証する。通常のXcodeビルドの識別子・署名設定・保存先は従来どおり。

ローカル署名用の有効な証明書が見つからなかったため、この試用ビルドは**ad-hoc署名、App Sandbox/App Groupなし、専用のローカル保存先**を使う。一般配布用のDeveloper ID署名・公証は未実施。通常版のsandboxやOSのセキュリティ設定を解除する処理はない。再配布に必要な同梱資源の権利表示も未完了。

導入前にbundle ID・3モード・接続名・helperの保存先識別子・厳密な署名検証を行う。別アプリやsymlinkは上書きしない。コピー・起動・登録が失敗した場合は旧MixedアプリとLaunchAgentへ復旧する。停止後は専用jobの消失を最大8秒待つ。起動時のlaunchdのEIOは、専用jobが存在しない場合に限り最大2秒再試行する。OS登録途中の失敗を含む完全なトランザクション保証ではない。

## 自動モードの操作

- 文字とSpaceは原文へ追加する。Spaceは空白を入力する。
- Tab/Shift-Tabは候補移動。対象区間を強調する。Enterで候補採用、候補選択外のEnterで全体確定。
- Escapeで原文表示へ戻す。Backspaceは末尾の書記素単位で削除。
- 英字だけの入力中もTabは候補操作に使う。Commandキー操作はアプリへ通す。
- `- . , [ ]` は日本語優先で `ー 。 、 「 」` を表示・確定する。英語の直後は半角を保つ。例：`asita.` → `明日。`、`apple.` → `apple.`、`[apple]` → `「apple」`。空白の後は日本語優先に戻り、閉じ括弧は開き括弧に合わせる。
- 日本語の単語内の長音は、前後をまとめて変換する。`harike-n`／`harike-nn` → `ハリケーン`、`ko-hi-` → `コーヒー` など。長音を含む読みの末尾nは「ん」として候補生成し、続けて入力すると原文から読み直す。Escapeでは元の `-` とローマ字に戻る。
- URL・ファイル名などの保護tokenと、数字に接する記号は半角を保つ。確定直後の判断には取得可能な短い左文脈を使い、取得できなければ日本語優先。Escapeで元のASCII記号へ戻せる。対象は上記5記号で、ほかの記号は従来どおり。
- フォーカス移動やOSの即時確定では、元の入力欄へ表示済み文字列を確定する。未応答打鍵があれば原文を保全するため、漢字表示を失うことがある。
- 非標準入力表・未対応サーバー・壊れたモデルでは手動日本語へ戻る。入力メニュー内の案内で準備中／利用不可を表示する。自動モード中は既存ライブ変換設定とAI変換メニューを使用しない。

左右キー・マウスによる中央編集、任意区間の選択・強制指定は未完成。未対応キーが入力中に消費される場合がある。検証済みのアプリ・操作と未実行項目は `implementation_status.md` 末尾を参照。

## 有効化・障害回復・プライバシー

通常sourceにマーカーは置かず、自動入力はOFF。専用ビルドの `Contents/Resources/auto-mixed-experiment.json` がenabled=trueの場合だけ、選択した自動モードで既存 `.composition(.snapshot)` によるcapability確認を行う。モデルSHA-256・schema・非fixture・GGUFの存在を照合する。`kind=production` はruntime形式の識別であり、品質合格ではない。

初回のcapability確認中も打鍵を保持し、対応サーバーと確認できてから順番に送る。失敗時は元の入力欄へ原文を一度だけ回復する。GGUF/Metalの初期化を考慮し、自動要求の応答待ちは5秒、手動入力の既存1秒設定は維持する。旧フォーカス・別server epochの返答は挿入しない。commitIDで二重確定を除外し、auto要求を無制限再送しない。プロセスクラッシュをまたぐ無損失は保証しない。

自動入力のpreviewも確定も変換学習OFF。未ack確定文字列は8件まで保持し、ackはその除去に使う。raw・短い文脈・回復journalはメモリ内だけ。既存IMK経路で最大30 UTF-16単位を要求し、transportでも長さを制限する。取得できなければ文脈なしで動く。Mixedアプリのdebug入力記録を止め、実験helperのstdout/stderrを受付開始前に破棄し、専用LaunchAgentも両出力を破棄する。全ログ経路の動的監査はT7に残る。

## 検証・削除

```sh
python3 Tools/tests/test_mixed_ime_install.py
python3 Tools/test_mixed_ime_client.py
# 実際に専用サーバーを導入した場合だけ、CoreのMixedIMEInstalledTestsを
# AUTO_MIXED_INSTALLED_TEST=1 で実行する。通常版へ接続しない。
```

インストーラーテストは一時領域と模擬OS呼出しを使う。クライアント試験は通常IMEのtest hostを起動せず、本物のクライアント実装と模擬IMK欄・transportで検証する。いずれも実機入力の代用とはしない。

削除時は先に通常版など別の入力ソースへ切り替える。

```sh
python3 Tools/install_mixed_ime.py uninstall --dry-run
python3 Tools/install_mixed_ime.py uninstall
```

Mixedの入力ソースだけを無効化し、専用アプリとLaunchAgentを削除する。設定・辞書・APIキーは残す。通常版へは触れない。開発時の `MixedIMEControl current` は現在のIDを表示し、`restore <ID>` は既に有効な入力ソースを選び直すだけで登録・有効化を変更しない。

## 日本語確定後の英単語保持（2026-09-24）

短い日本語文脈があると `app` の時点で日本語化し、`apple` の英語判定にも届かなくなる条件を修正した。辞書に一致し、日本語ローマ字として未完／不成立の語に限り、現在のrawだけでも従来の英語条件を確認する。`app → appl → apple` の入力・削除・再入力、日本語確定後の繰返しを回帰対象にした。`made/note/name` 等の完成したローマ字の扱い、モデル、辞書、通常manualは変更しない。実施結果と実機未確認範囲はimplementation_status末尾を参照。

この修正版は専用update経路で反映済み。更新済みhelperで日本語確定後の `app → appl → apple` と既存meeting混在の実Mach XPC試験が成功した。入力モードの有効設定は保持し、利用者の選択中ソースは切り替えていない。

入力メニューの補助表示は、controllerが実際に認識している「自動」「日本語（手動）」「英数」を示す。OSの選択名が自動なのに「現在は日本語入力（手動）」となる場合や、「自動：現在は日本語入力（準備中／利用不可）」の表示が続く場合は、英単語の判定より前の段階で自動入力が有効になっていない可能性がある。

実機ログでは自動モード通知とcapability確認は成功していた。その後の「かな」キーが自動入力を終了し、以降の文字を手動日本語へ送っていた。利用者もかなキー操作を確認した。今回の修正ではこのキーで自動を解除せず、原因ではなかったOS選択状態による初期モード補完は撤去した。修正版は反映済み。利用者はかなキーを含む再現操作で「明日apple」になることを確認し、状態ログでもかなキー以後の自動配送と正常応答を確認した。今回の手順以外の確認範囲・未実行事項は `implementation_status.md` 末尾を参照。

## 入力本文を含まない診断ログ

利用者の明示的な調査依頼に対応する診断版は、次の指定で作成する。

```sh
python3 Tools/build_mixed_ime.py --diagnostics
python3 Tools/install_mixed_ime.py update
python3 Tools/collect_mixed_diagnostics.py --last 10m
```

更新前には未確定入力を確定し、ABCへ切り替える。診断版はmacOSのUnified Loggingへ、モード通知、開始条件、自動／manualの配送先、capability、XPCの成功・失敗・切断、runtimeロード段階を記録する。プロセス間はランダムsession UUID、controller内はowner UUIDで対応づける。本文、キーの文字／キーコード、候補、文脈、入力のハッシュ、アプリ名、エラー全文、APIキーは記録しない。一般の既存debugログは有効化しない。

既定ビルドではOFF。専用bundleの期限付きマーカーがあるMixedだけで有効になり、ビルドから24時間またはプロセス当たり10,000件で新規記録を停止する。既に記録したメタデータの保持期間はOSのログ管理に従う。回収先は `build/auto-mixed/diagnostics-events.jsonl`。診断後は `--diagnostics` なしで再ビルド・更新して無効化できる。
