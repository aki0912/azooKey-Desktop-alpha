# 03. アーキテクチャと実装契約

この章の新しい型・APIは**提案**であり、上流に実装済みという意味ではない。既存の入口は02章を参照する。

## 1. 責務を4層に分ける

| 層 | 責務 | 禁止事項 |
|---|---|---|
| IMKクライアント | 同期的なキー所有権、XPC送信、marked text描画、確定effect | モデル推論、独自のかな変換、確定後の本文の自動修正 |
| MixedCompositionEngine | 原文・区間・カーソル・候補の状態遷移 | IMK呼出し、ファイルI/O、ネットワーク |
| LanguageSegmenter | 保護規則、特徴量、LR、系列復号、保留 | 英字の破壊的正規化、候補確定・学習 |
| ZenzaiSpanBridge | 日本語区間の候補生成、既存設定適用、確定学習 | 英語区間の変換、候補表示だけでの学習 |

判定・レンダリングはpureな処理としてCoreに置く。IMK/AppKit不要のテストで検証できるようにする。既存変換資源はサーバー側で共有する。[S3]

## 2. 原文の唯一性と範囲型

`RawCompositionBuffer` が原本である。モデル、かな文字列、marked textから原文を再生成してはならない。

```swift
// 新規型のインターフェース案。実装時に必要なinit/validation等を加える。
struct ScalarRange: Codable, Sendable, Equatable {
    let lowerBound: Int
    let upperBound: Int                 // end-exclusive
}
struct UTF16Range: Codable, Sendable, Equatable {
    let location: Int
    let length: Int
}
enum SpanKind: String, Codable, Sendable {
    case japaneseRoman, raw, literal, gap, unresolved
}
struct MixedSpan: Sendable {
    let id: UUID
    let sourceRange: ScalarRange
    var kind: SpanKind
    var selectedCandidateToken: String?
    var userOverride: SpanOverride?
}
struct CompositionIdentity: Codable, Sendable, Equatable {
    let sessionEpoch: UUID
    let compositionID: UUID
    let revision: UInt64
}
```

原文offsetの単位はUnicode scalar。`Swift.String.count`は書記素数なのでscalar数やUTF-16数に使わない。`NSRange`へ渡す値は**表示文字列のUTF-16単位**へ変換する。[S16]

`TextOffsetMap` は以下を持つ。

- 原文scalar境界↔Swift文字列index、書記素境界のテーブル。
- 表示された各runのraw範囲とdisplay UTF-16範囲。
- 変換runはmany-to-manyのatomic対応。中間位置の1対1対応を捏造しない。

例：`👩‍💻`はUnicode scalar 3個、UTF-16 code unit 5個、通常の書記素1個。`e\u0301`はscalar2個・書記素1個。Backspaceは書記素単位、データ範囲はscalar単位、IMK描画はUTF-16単位で計算する。

不変条件：spanは原文全体を重複なく被覆し、空区間を持たない。既定のrendererではliteral/gap/rawの出力は対応する原文sliceと完全一致する。Mixed自動の記号表示policyを明示的に指定した場合だけ、非保護literal内の5記号を同じ長さの日本語記号へ置換できる（§11.2）。実入力の大文字小文字や記号を小文字化したモデル入力で置換しない。

## 3. キーイベント処理

```text
同期Routerで所有権確定
 → サーバーがeventIDとepochを検査
 → RawEditを適用 / revisionを進める
 → 保護区間と強制指定の更新
 → LanguageSegmenterで候補区間を計算
 → 曖昧・未完・表示安定化規則を適用
 → dirtyな日本語区間だけZenzaiへ候補要求
 → MixedMarkedTextRendererで全体を連結
 → snapshotとeffectsを返す
```

`RawEdit` は挿入、範囲削除、カーソル移動を表す。Tab・候補選択など原文を変更しない操作でも表示revisionは進める。原文revisionと表示revisionを分離してもよいが、候補結果の照合には必要な両方を含める。

モデル欠損や非対応入力styleはモード開始前に判定する。無効な状態のまま「自動モード」と表示しない。英数／かな切替、composition commit/stop、deactivate、候補コマンドの**すべて**をauto/manualへ正しく振り分ける。

## 4. 状態機械

```text
idle
 └─ printable → composing
composing
 ├─ edit → composing（再推定）
 ├─ Tab → selecting(spanID, candidateGeneration)
 ├─ Enter / OS commit → commit transaction → idle
 ├─ Escape → rawPreview（原文を維持）
 └─ stop/deactivate → lifecycle処理
selecting
 ├─ Tab / Shift+Tab → 選択移動
 ├─ Enter → composing（候補を内部で採用）
 ├─ Escape → composing（候補を閉じる）
 └─ edit → composing（候補世代を破棄し再推定）
rawPreview
 ├─ edit → composing（再推定を再開）
 ├─ Enter → 原文確定 → idle
 └─ Tab → 区間修正候補
```

rawPreviewは推定を一時停止した表示状態。Escape直後の再描画だけで再変換しない。通常入力で解除される。候補を選択した区間は、原文を編集しない限りユーザー選択を保持する。隣接区間の編集で文脈が変わっても既に選んだ候補を無断変更しない。

## 5. 保護規則

優先順位はセキュリティ／非対応経路のゲート → ユーザー指定 → 明確な保護パターン → モデル推定。日本語強制指定でも、URL全体など意味のある単位を部分破壊しないようUIに対象範囲を表示する。

| 原文 | 初期処理 |
|---|---|
| URL、メールアドレス | token全体をliteral。安全な区切りまで維持 |
| パス、拡張子付きファイル、`snake_case`、`foo::bar` | 明確な記号構造を持つtokenをliteral |
| `API` / `HTTP`の2文字以上の連続大文字 | そのrunだけraw固定。後ろの`wotukau`まで保護しない |
| `Swiftde` | `Swift`の保護ヒントを候補境界にする。全token固定は禁止 |
| `made` / `name` | hard保護はしない。取得可能な文脈と校正した採用条件で判断し、根拠が弱ければraw表示。09章参照 |
| 既存かな漢字・絵文字 | literal。新たに再変換しない |
| ASCII空白 | gap。1個も削除・合成しない |

URLの終端とその直後のローマ字が空白なしで連結された場合は、規則だけで意図を断定できない。安全側にURL全体を維持し、利用者の区間修正または明示的区切りを必要とする。この限界は評価表に記録する。

英単語辞書は曖昧語情報・境界候補・ユーザー保護語の補助とし、辞書掲載だけで全tokenをliteralにしない。保護辞書は同梱権利を確認し、まずは少数の自作サンプルで始める。

## 6. 既存Zenzaiへの接続

### 6.1 セッションと排他

既存サーバーは共有Converterと`createSession`/`withSession`を使う。[S3] mixedの各日本語spanには軽量なchild conversion sessionを対応させ、重み本体を再ロードしない。

auto系コマンドは `main.swift` のdispatchでlegacy用`withConverterSession`の**外側へ分岐**させる。bridgeがchild sessionを有効化する際に、未確認のネストした`withSession`復元規則へ依存しない。

すべてのConverter操作を現行同様サーバーMainActor上で逐次実行する。`withSession(childID) { ... }`内ではsuspendしない。child sessionは区間の消滅・composition終了・セッションcloseで必ずremoveする。上限は同時32個を暫定値とし、超過区間は原文表示で保留する。モデル精度が悪いと区間が増えるので、上限発生率も計測する。

依存ライブラリの実装調査でchild sessionの共存や候補保持が不適切と判明した場合、stage gateで停止してadapter設計を変更する。複数の巨大モデルインスタンスを作ることで回避しない。

### 6.2 提案するbridge契約

```swift
@MainActor
protocol JapaneseSpanConverting {
    func candidates(for request: JapaneseSpanRequest) throws -> JapaneseSpanResult
    func recordCommittedSelection(_ token: CandidateToken) throws
    func release(spanID: UUID)
    func releaseAll()
}
```

`JapaneseSpanRequest`：compositionID/revision、spanID、原文ローマ字slice、左文脈、右文脈、既存inputStyle、候補要求のrichフラグ、設定version。日英判定器へ渡す短い確定済み左文脈はこれとは別の任意入力。利用可能性、フォーカス、revisionを含む契約は09章を参照。

`JapaneseSpanResult`：同じidentity、変換済みsource範囲、未完suffix範囲、全区間を被覆する候補、opaque candidate token、fallback reason。`Candidate`の任意文字列をクライアントから再構成して学習させない。token→実Candidateはサーバー所有にする。

既存`SegmentsManager`にはこの契約がそのまま存在しない。以下の小さい変更を加える。

1. 生ローマ字でcompositionを一括置換するAPIを追加し、最後に1回だけ候補要求する。既存の1文字挿入APIをループして毎回Zenzaiを呼ぶ実装は不可。
2. `ComposingText`と標準入力表を使ってraw→かな・未完suffixを解釈する。公開APIで必要な範囲情報が取れるか確認し、取れなければ最小のadapter境界を設けてテストする。独自ローマ字テーブルを作らない。
3. optionsの生成・user dictionary・資源解決を共有化し、legacyとautoで設定がずれないようにする。巨大な`SegmentsManager`を複製しない。
4. `mainResults`から区間全体を消費する候補だけ採用する。未完suffixがある場合は変換可能prefixの全量を消費する候補＋suffixを合成する。部分候補を全文候補と誤認しない。
5. 候補プレビューと確定学習を分離する。既存`prefixCandidateCommited`は学習と部分確定を伴うため、プレビューには使わない。[S6]

### 6.3 境界・文脈・キャッシュ

隣り合うJA文字ラベルは1つの変換spanにまとめる。1モーラごとにZenzaiを呼ばない。モデルが出した境界はローマ字の途中で切れる可能性があるため、04章の妥当性チェックでinvalid spanを保留へ戻す。

左から順に変換する。左文脈はアプリから既存方式で取得した限定文脈＋現在composition内の前方表示。右文脈は既存取得方式の限定文脈を用い、未知の後続候補を正解として与えない。文脈上限は最初は既存30文字を尊重し、任意に全文取得へ拡張しない。[S3][S5]

cache keyにはraw、input table version、左右文脈、モデル／辞書／設定version、richフラグを含める。これはメモリ内のみ保持する。前方候補が変わった場合は、後方の未選択JA spanの文脈依存cacheを無効化する。ユーザーが選んだ候補は保持する。

## 7. 学習と確定

mixed全体の確定時に表示文字列を1回だけOSへ挿入する。spanごとに先にinsertTextしてから全文insertTextしない。

学習は、確定transactionに含まれるJA候補だけに適用する。英語・literal・unresolved・未完suffixを日本語の学習データへ入れない。設定で学習OFFなら一切更新しない。取消・Escapeの原文確定・候補の閲覧だけでは選択候補を学習しない。

安全な初期実装は、クライアントで確定effectを適用した後に`commitApplied(commitID)`をサーバーへ返し、存続中のpending commit tokenに対して一度だけ学習する方式。ack喪失時は学習を諦める（再挿入はしない）。ackと重複防止はセッション内のみ保証する。未ackの候補tokenに必要なchild session／候補情報は、上限付きのpending commit領域でackまたは破棄まで保持する。通常のcomposition終了で先に破棄して無効tokenを学習しない。

プロセスクラッシュをまたぐexactly-onceはこの仕様の保証外。

**2026-09-24のT5実験実装との差分**：変換学習はpreview・確定ともOFFに限定した。`AutoMixedServerSession` は未ackの確定文字列を最大8件保持するが、候補tokenは学習用に保持せず、確定時にchildを解放する。理由は、OSへの同期確定とack後の学習を同時に導入せず、まず重複挿入を防ぐ契約を検証するため。影響として実験版IMEではユーザーの候補選択を学習しない。学習を有効にする前に上記pending candidate領域・一度だけの学習・ack喪失試験が必要である。

## 8. XPCと古い応答

新規フィールド案：

```text
request.autoMixedContext?: {policy, protocolVersion, sessionEpoch, compositionID}
response.autoMixedSnapshot?: {identity, spans, markedText, cursorUTF16,
                              activeSpanID, candidateGeneration, fallbackReason}
response.commitEffects?: [{commitID, compositionID, text}]
```

既存responseのmarked textにも混在全体を反映し、mixed構造は区間UIの追加情報にする。wire型へ`NSAttributedString`やSwift `String.Index`を送らない。文字列と整数範囲と列挙値だけを使う。[S12]

新しいnonoptionalフィールドにSwiftの初期値を書くだけでは旧JSONの欠損に対応できない。`decodeIfPresent`等で明示的な既定値を設け、旧データroundtripをテストする。旧サーバーへ未知のenum caseを送らず、capability確認が取れない場合はmanualで動作する。

snapshotと確定effectを同一視しない。古いsnapshotは破棄できるが、未適用の有効なcommit effectまでrevisionだけで捨てると入力が欠落する。確定effectは順序付けとcommitID ledgerで管理し、同一セッション・クライアントで重複適用を防ぐ。

フォーカス世代が違う応答を現在の入力欄へ適用しない。遅延確定は元クライアントとcompositionの対応が有効な間だけ適用する。deactivate時に新しい欄への挿入で帳尻を合わせない。OSによるcommit/stop順序の違いを実機テストする。

実装済みwire契約は `ConverterSessionCommand.autoMixed(AutoMixedRequest)` と、optionalの `ConverterServerResponse.autoMixedCapability / autoMixed`。上のフィールド名は当初案であり、定義済みAPI名と混同しない。protocol version 1、server epoch、focus UUID、単調operationID、composition UUID、revision、raw、scalar/UTF-16 span、commit effectsを運ぶ。旧サーバーには既存 `.composition(.snapshot)` だけでcapabilityを問い合わせる。旧JSONで両optional fieldがない場合もdecodeできる。

IMKの `commitComposition` は復帰前の即時確定を要求するため、実験クライアントは元の入力欄へ最後の表示を同期挿入し、古いfocusを失効させる。未応答キーがある場合は最後のack済みraw＋未応答打鍵から原文を復元する。影響は遅延時に漢字候補を保持できない場合があること。言語推定はクライアントで再実行しない。通常Enterの確定は引き続きserver commitID/ackを使う。実OSのイベント順序の確認は未実行。

## 9. 同期イベント所有権と障害

既存routerはCommandを同期的に通し、pending中は保守的にconsumeする。[S4] autoでは、最終acknowledged状態にmixedのcomposition有無も加える。Tab/Space/Enterの判断をmanualの`InputState.event`だけに委ねない。

Commandを通す方針は維持するが、Cmd+A/C/Vやアプリ選択変更との整合性は実機gateで検証する。IMKの`handle`が返った後にキーを「返す」APIがあると仮定しない。疑似キー再送による回復は実装しない。

サーバー一時切断時：既存の同一eventID再送機構の範囲内で復旧する。新サーバーepochでは確定済みか不明な操作を盲目的に再送しない。クライアントが保持する最終表示／原文回復情報は応答再適用と回復のための一時ledgerであり、別の推定状態機械を持たせない。メモリ内のみとし、同じ有効なcompositionの範囲で原文維持を優先する。

初期auto transportでは上記の同一eventID再送を利用せず、順序queueの失敗通知で原文回復してmanualへ戻す。理由は既存キー再送が新epochでも継続するため。manual側の再送機構は維持する。autoの再接続後継続、保留journalの長時間上限、同時クラッシュ時の挙動はT7の障害評価に残す。

サーバーとIMEの同時クラッシュ、OSが破棄したcomposition、失われた確定ackについて無損失を保証しない。正常稼働時の文字欠落／二重挿入はrelease blocker、障害時の残余リスクは明示して測定する。

## 10. 性能方針

まず現行の逐次XPC応答構造のまま、判定を軽量化しZenzai要求をdirtyな区間へ限定する。分類器を速くしてもZenzaiがキーごとの応答を支配する可能性がある。初期版で推論結果を別push通知にするような非同期プロトコル再設計は行わない。

測定で入力追従に問題が出たら、原文snapshotの先行応答＋後続候補通知を**別フェーズ**として設計する。その場合はidentity照合、順序制御、callback lifetimeの再設計が必要。根拠なく「debounceを入れれば完成」としない。

---
出典番号は [08. 一次資料・設計判断](08_SOURCES_AND_DECISIONS.md) を参照。

## 11. ローカル併用profileの実装差分（2026-09-24）

試験版は `IMEIdentity.mixed` としてbundle・接続・保存先を分離し、InputModeに日本語・英数・自動を定義した。日本語／英数は既存manual、自動は実験マーカーとcapabilityを要求する。通常版にはマーカーも自動modeも追加しない。手動composition中に自動を選んだ場合は確定まで有効化を待つ。

capabilityを待つ間の打鍵をclientが保持し、確認後に順番に送る。未対応／失敗なら原文を元の欄へ一度だけ回復する。旧focus失効・Unicode削除・手動既定は独立harnessで検証した。初回GGUF/Metal初期化のためauto timeoutを5秒とし、manualの既存1秒設定は維持する。未応答journalの長時間上限や障害時の無損失保証を完了したという意味ではない。

このMac用profileはad-hoc署名・Sandbox/AppGroupなしのローカル専用保存先を用いる。正式配布向け要件を満たしたとはしない。実Mach XPC変換は確認済みだが、macOSの親入力ソースがenabled=falseのため実IMK打鍵は未実行。再ログイン後に確認する。導入仕様・制約は `Tools/AUTO_MIXED_IME.md` と `implementation_status.md` 末尾を参照。

### 11.1 かなキーと自動モードの維持（2026-09-24）

自動モードで「かな」キーを受けた場合は、`AutoMixedIMEClient` がその場で消費し、モード・未確定文字列・未応答打鍵を維持する。capability確認中も同じ扱いとし、このキーをrawやサーバーの手動キー処理へ送らない。英数キー、非標準入力style、明示的なモード変更は従来の終了経路を維持する。手動日本語へ移るには入力メニューから選ぶ。通常版とmanual入力のキー処理は変更しない。

旧試用仕様では英数／かなキーの両方で自動を終了していた。実機ログでは自動モード通知とcapability確認が成功した後にdeactivateとmanual配送が発生し、利用者もかなキーの使用を確認した。日本語優先の自動入力を選んだ利用者が、かなキーで意図せず英語判定を失うため仕様を変更する。これにより自動モード中のかなキーによる手動切替・確定は行われなくなる。通知欠落は今回の再現では観測されなかったため、先に追加した `MixedInputModeResolver` とTISによる初期補完は撤去した。通知は従来の `setValue` 経路で受ける。

診断ログでは入力文字やkey codeを保存せず、かな／英数という固定のモード操作分類と手動終了理由を区別する。モデル・特徴量・閾値・辞書はこの修正で変更しない。模擬IMK欄の回帰と実機の物理打鍵は区別し、実行結果は `implementation_status.md` に記録する。

### 11.2 日本語優先の記号表示（2026-09-24）

`MixedPunctuationPolicy` をengine／rendererへ任意注入する。学習器やsegmenterが返すspan、原文バッファ、モデル入力は変更しない。`ProtectedSpanDetector` は従来のscalar分類に加え、既存の構造保護tokenを示すbool配列を返す。分類・境界ヒント・v1/v2 goldenは不変。保護token内は記号policyを適用しない。

policyはliteralに含まれる `- . , [ ]` だけを置換する。全置換は単一BMP scalar同士でUTF-16長も同一。結合文字を含む書記素は変更しないため、literal runの非atomicな座標対応を維持できる。英語raw区間の直後は半角を継続し、空白や日本語で解除する。閉じ括弧は対応する開き括弧に合わせる。数値に隣接する記号は入力途中も原文保持する。

新しいcompositionの左端は既存の短い確定文脈から判断する（末尾のASCII英字は英語の表示証拠として扱う）。文脈がない場合は日本語優先。この値はメモリ内のみ。`refreshCandidates` が後続日本語spanへ渡す左側表示、marked text、Tabの記号候補、Enter／OS確定の内容で同じpolicyを使う。EscapeのrawPreviewとprovider失敗時は原文を維持する。XPCのschema、SpanKind、モデルschemaは追加・変更しない。

旧仕様「全ASCII記号をliteral表示」からの差分であり、日常の日本語入力で句読点・かぎ括弧・長音を打てるようにするための変更。T0〜T2の既定rendererやmanualを変えず、Mixedの試用runtime／playgroundで有効にする。英文や数値の直後の句読点を日本語にしたい場合など、文脈だけでは意図を断定できない制約は残る。原文復帰と保護token保持を優先する。
