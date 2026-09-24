# azooKey Mixed のローカル試用

通常版と併用する試験版を `azooKey Mixed` として用意した。**自動・日本語・英数** の3モードを実装した。2026-09-24のこの環境ではインストール・専用サーバー起動まで成功したが、macOSの親入力ソースが無効のままで、実際のモード選択・打鍵は未確認。まず再ログイン後の有効化確認が必要。現在の学習済みモデルを使うが、品質基準は未達で `release_ready=false`。中央編集・長時間利用・広範なアプリ互換性の確認は残っている。

## 導入・更新

このMacで検証した構成はmacOS 27、arm64、Xcode 27、Swift 6.4。取得済みのGGUF・4 marisa資源とreceipt、学習済みruntime exportを使用する。スクリプトはコーパス取得や再学習を行わない。

```sh
python3 Tools/build_mixed_ime.py
python3 Tools/install_mixed_ime.py install --dry-run
python3 Tools/install_mixed_ime.py install
python3 Tools/install_mixed_ime.py status
```

ビルド先は `build/auto-mixed/mixed-ime/azooKeyMixed.app`。ユーザーの `Library/Input Methods/azooKeyMixed.app` と専用LaunchAgentへ導入し、このアプリの入力ソースだけを登録・有効化する。インストーラーは現在選択中の入力ソースを切り替えない。更新前には別の入力ソースを選ぶ。通常版を置き換える既存 `install.sh` は使わない。

作業中の書類を保存して一度ログアウト・ログインし直し、システム設定 → キーボード → テキスト入力「編集」→「＋」で日本語の `azooKey Mixed` を追加する。その後、画面上部の入力メニューから `azooKey Mixed（自動）` を選ぶ。通常版はそのまま残す。再ログイン後も一覧に出ない場合の原因は未確認で、有効化できたとは扱わない。設定画面の手順は[Appleの入力ソース設定ガイド](https://support.apple.com/ja-jp/guide/mac-help/mchl84525d76/mac)を参照。

- **自動**：日本語を優先し、モデルと英単語辞書の条件を満たす英語を保持する。例：`asitahameetinggaarimasu` → `明日はmeetingがあります`。
- **日本語**：既存の手動日本語入力。Spaceの候補操作などは従来の経路を使う。
- **英数**：既存の英数入力。

英数／かなキーは英数／日本語へ切り替える。自動へ戻るときは入力メニューで選び直す。切替時に手動入力が残っている場合、自動判定はその確定後から開始する。

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

導入前にbundle ID・3モード・接続名・helperの保存先識別子・厳密な署名検証を行う。別アプリやsymlinkは上書きしない。コピー・起動・登録が失敗した場合は旧MixedアプリとLaunchAgentへ復旧する。停止直後のlaunchdのEIOは、専用jobが存在しない場合に限り最大2秒再試行する。OS登録途中の失敗を含む完全なトランザクション保証ではない。

## 自動モードの操作

- 文字とSpaceは原文へ追加する。Spaceは空白を入力する。
- Tab/Shift-Tabは候補移動。対象区間を強調する。Enterで候補採用、候補選択外のEnterで全体確定。
- Escapeで原文表示へ戻す。Backspaceは末尾の書記素単位で削除。
- 英字だけの入力中もTabは候補操作に使う。Commandキー操作はアプリへ通す。
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
