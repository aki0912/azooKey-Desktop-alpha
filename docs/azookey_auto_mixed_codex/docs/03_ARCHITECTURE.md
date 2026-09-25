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

例：`👩‍💻`はUnicode scalar 3個、UTF-16 code unit 5個、通常の書記素1個。`e\u0301`はscalar2個・書記素1個。原文のBackspaceは書記素単位（Mixedの日本語区間は§11.5の読み単位）、データ範囲はscalar単位、IMK描画はUTF-16単位で計算する。

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

### 11.3 長音を含む日本語の変換単位（2026-09-24）

表示だけの `-` → `ー` では `harike-n` が長音の前後で分割され、単語全体を辞書へ渡せなかった。JapanesePreferredSegmenterは日本語と判断した先頭runに長音と標準ローマ字として成立する後続runが連なる場合、全体を一つのjapaneseRoman spanにする。英語と判定済みの先頭run、数値隣接、保護token、空白・句読点・Unicode書記素境界を越えて結合しない。`su-pa-` のpa、`ra-men` のmenを独立した英単語とみなして途中分割せず、長音を含む綴り全体を検証する。英語との混在意図が曖昧な長音列では日本語を優先し、Escapeで原文へ戻せる。

依存の標準ローマ字表はASCII `-` を自動で `ー` にしない。RomanSpanReadingは変換用コピーのみ `-` を `ー` にし、bridgeはそのコピーを既存ComposingTextへ渡す。元のraw、特徴量、モデル入力、scalar範囲は変更しない。両文字とも1 scalar／1 UTF-16単位で、読みに変わったspanは既存のatomicな座標対応を使う。

利用者が使う `harike-n` の末尾nも変換するため、長音を含み、依存のcompositionSeparator規則で全体がかなになる場合だけ終端nを「ん」としてpreviewする。依存の公開 `insertAtCursorPosition([InputElement])` と `.compositionSeparator` の定義・試験を確認して使用した。合成した終端要素は変換器の中だけにあり、rawや元の範囲に加えない。次の編集では原文から再構成し、no／nyaなどを継続できる。従来の `asitan` → `明日n` は維持する。OSへ早期確定しない。

長音を含む日本語spanは読みだけに限定せず通常の辞書／Zenzai候補を要求する。学習済み確率や判定閾値を変更するものではない。manualの入力経路、モデルschema、XPC version 1、v1/v2 goldenは不変。

### 11.4 日本語文の句点と裸のファイル名の曖昧性（2026-09-25）

従来の裸のファイル名規則は `英数字.英字…` 全体を保護するため、`asitanotennkiwosirabetehosii.d` の最後のdで、それまでの日本語文までliteralに戻した。Mixedの日本語優先表示では、最初のドット前が英単語辞書の完全一致でなく、未完部分なしにローマ字として読め、現在のprefixの平均日本語スコアが既存のhold閾値以上の場合、裸のファイル名という解釈を採用しない。同じ文脈・モデルの評価を先に使い、文脈ありで閾値を満たさない場合だけ、文脈なし対照を別計算して同じhold閾値を要求する。前回表示の固定や特定の語・拡張子の例外ではなく、貼り付け・削除・再入力でも現在のrawから判断する。

文脈なし対照は、文脈モデルの低スコアにより、既に成立しているかな表示までファイル名へ戻ることを防ぐために使う。閾値を下げたり、日本語の漢字候補を無条件で採用したりはしない。保護を解いた後のspan・漢字／かなは、元の文脈付き判定を使用する。

URL、メール、明示的パス、識別子、バージョンの保護は先に適用し、この緩和の対象にしない。T0〜T2の既定保護検出、学習器・特徴量・モデル・閾値・goldenも維持する。記号表示側は同じ裸のファイル名判定について、日本語spanがドット前をすべて被覆していれば保護を再適用しない。原文のドット・scalar範囲は保存し、Escapeで原文を確定できる。

記号表示の保護は「現在のraw」と「確定文脈＋raw」の両方で調べ、いずれかで保護されれば維持する。確定済み日本語を前に連結した結果、新しく入力した `main.swift` がファイル名規則に一致しなくなり、ドットを句点へ変えていた問題も防ぐ。確定済みURLの続きという既存の保護も維持する。

これは§5の「拡張子付きファイルを保護」へのMixed表示限定の例外。`nihongo.txt` のように日本語としての根拠がある裸の名前は日本語文として表示される可能性がある。ファイル名・ドメインの意図をrawだけで完全には識別できないため、明示的な `./nihongo.txt` やURL、または原文確定で区別する。一般的なファイル名の認識精度向上を主張するものではない。

### 11.5 読み単位のBackspaceと一時的なかな表示（2026-09-25）

Mixedのruntimeと試用アプリは、新設 `JapaneseBackspaceEditing` をengineへ注入する。既定nilの既存呼出しとmanualは従来の原文削除を維持。末尾のjapaneseRoman／japaneseKana区間で読みが完成している場合だけ、読みの最後の単位を削る。小書き `ぁぃぅぇぉゃゅょゎ` は直前の通常かなとまとめ、単独の小書き、`っ・ん・ー` は独立した単位とする。末尾未完英字、raw/literal/gap、変換失敗時は原文1書記素削除を使用する。

実装は新設 `RomanReadingBackspaceEditor`。依存の `ComposingText` を使う既存RomanSpanReadingで解析し、目的の読みに一致する原文prefixを最長で保持する。`kitte → きっ` や `kanji → かん` のように切り詰めだけでは足りない部分は、依存の公開 `InputStyleManager.exportTable(.defaultRomanToKana)` から逆引きし、短い綴り、同長なら辞書順で選ぶ。組合せ全体を再解析して読みの完全一致を検証してから編集する。独立segment境界をそのまま削ると `nki` の「ん」まで失うため、削除単位には使用しない。原文はキー履歴でなく編集後の入力を表し、Escapeでも組み直した綴りを表示する。

削除後は対象spanをjapaneseKanaとして保持し、検証済みの読みを表示する。他区間のID・表示・採用候補は維持し、編集した区間の採用候補とconverter childを解放する。連続Backspaceはかな表示を維持し、次のinsert/spaceまたはTabで通常の判定・変換へ戻す。Enter／OS commitはかなの表示内容を確定する。Escapeの原文表示中は原文1書記素削除の後も原文表示に留まる。確定・取消・空入力・フォーカス終了でpreviewを解放する。

XPCとモデルschemaは不変。応答済みの編集後rawをledgerへ保存するが、未応答キーの回復では読みを推測せず、従来の原文1書記素削除を維持する。例えばasitaの削除応答前に通信が失敗した場合の回復はasit、正常応答後はasiとなる。この非常時の制約を通常時の読み削除の成功と混同しない。中央編集と直接入力されたUnicodeかなへの読み単位適用は対象外。


### 11.6 英単語境界と日本語長音の統合評価（2026-09-25）

Mixed runtimeのembeddedEnglishSplitは、辞書の完全一致と既存English gateを通った英語候補の右側に対してもlongVowelSpanを適用する。これにより `sample + node-ta` の日本語を `node`／`-`／`ta` に分断せず、一つの原文範囲で変換する。スコアが十分な既存の分割は維持する。

元の文全体の日本語スコアが不足する場合、英語候補が完成した日本語ローマ字ではなく、全体が辞書登録語・辞書のprefixでなく、後続も辞書登録語・prefixでないことを条件に、後続だけの対照判定を行う。後続の読みはComposingTextで検証し、対照は既存のJapanesePreferredSegmenterを確定文脈なしで使用する。全区間がjapaneseRomanとなる場合に限って漢字変換を採用する。対照内では追加の後続対照を禁止し、結果は1回の判定内で共有する。特徴量・係数・閾値・モデルschemaは変更しない。

これは学習された全文確率と同等という主張ではなく、runtimeの明示的な代替候補の評価。長音は従来の単独語と同じ読み検証ルールを使う。英語に続く日本語が元モデルで低く評価されても、独立した日本語として単独入力時の条件を満たすか確認できる。最初に試した「後続の文字スコア平均にhold閾値を要求するだけ」の方式では長音語の既存単独ルールと一致せず、sampleの例が解消しなかったため採用していない。

同じ英語候補の後ろが読みとしては妥当でも判定が弱い場合、バッファ末尾だけはunresolvedの原文として保持する。英語境界を崩して後続文字を英語へ取り込まず、辞書にないという理由だけで日本語へ変換しない。入力履歴で境界を固定せず現在rawから再評価し、貼付・削除・再入力でも同じ候補を検討する。

明示的ハイフンを挟んだ両側が完全な英単語で、左側が既に英語として採用されている場合は右側も英語として保持する。`sample-data`／`sample-node` を長音にしないための一般規則で、sample固有の例外ではない。URL・パス・識別子・数式の保護は優先する。通常版/manual、XPC、辞書、原文とUnicode範囲は変更しない。曖昧な未知語をすべて判別できるわけではなく、詳細な検証・未実行事項はimplementation_statusに記録する。

### 11.7 完成した日本語読みの末尾境界を再評価する（2026-09-25）

`kaihatu` は左文脈取得不可のとき、凍結判定器の採用閾値をわずかに下回り、表示用adapterが `kaiha`（漢字候補）＋ `tu`（かな末尾）に分割していた。変換器へ「かいはつ」全体が届かないため、通常辞書・実Zenzaiで全体を直接変換した場合の先頭候補「開発」を表示できない。

JapanesePreferredSegmenterに限り、既存英語・保護・長音の判定後に、同じ推定対象範囲全体を覆う隣接した japaneseRoman ＋ japaneseKana の2区間を再評価する。全体が既存の日本語優先の漢字変換条件を満たし、両区間と全体が未完英字のない読みとして成立し、両側の読みの連結が全体の読みと一致することを要求する。さらに、かな末尾の**各位置**の日本語スコアが `max(hold_ja, minimum_ja)` 以上の場合だけ、一つの日本語変換区間へ結合する。平均だけで弱い末尾を覆い隠さない。

これは「既存の漢字／かな境界は維持する」方針への限定的な仕様差分。言語判定の保留境界を、単語としての変換境界へ無条件に固定してしまうことを防ぐ。末尾の根拠が強い他の語も全体変換へ移る可能性があり、`kaihatu` 固有の例外や候補順位の固定はしない。弱い末尾の `asitanote` は従来の読み表示を維持する。日本語スコアは漢字表記の正解確率ではなく、この規則の一般的な精度は未評価。

凍結TrainedMixedSegmenter・特徴量・LR・Viterbi・係数・閾値・schemaは変更しない。現在rawと既存のスコアだけを使い、追加の推論や辞書探索は行わない。未完子音・原文範囲・英語や保護区間は結合しない。既存の編集時のspan照合によって区間結合時の古い候補を失効させ、Tabは全体の詳細候補、Backspaceは全体の読みを対象にする。manual・通常版・XPCの操作仕様は不変。

### 11.8 確定左文脈によるかな表示固定の回復（2026-09-25）

長い固定の日本語文脈を添えると、現行LRの日本語スコアが過度に下がり、完成した `asita` までjapaneseKanaとなる条件を確認した。かな専用spanは変換器を呼ばず、Tabも漢字候補を取得しないため、「確定後から変換できない」という症状になる。確定時のengine解放と次の入力での再作成は働いており、この再現では状態の残留が原因ではない。

JapanesePreferredSegmenterは、既存の英語・保護・長音・混在区間の判定を先に行ったうえで、読みとして成立する範囲が文脈付きではjapaneseKanaになる場合だけ、文脈なしの既存runtime判定を対照として実行する。範囲全体が英単語辞書の完全一致・prefixである場合は対象外。対照が日本語roman／かなだけを返し、少なくとも一つの漢字変換可能区間を含む場合に、その区間構成を元のscalar範囲へ写して採用する。対照に英語・不成立原文・保留が残る場合や、日本語の根拠が不足してかなだけになる場合は採用しない。

対照は現在の区間rawに対する1回のruntime呼出し（既存の末尾判定に伴うprefix再評価を含む）で、文脈取得不可として動かすためこの回復自体は再帰しない。対照内の後続対照も無効化し、候補探索の分岐を増やさない。前回表示や過去の入力回数には依存しない。候補生成のMixedSessionConverterには元の確定左文脈を渡し続ける。モデル・特徴量・係数・閾値・schemaや辞書を変更せず、manualの経路も変更しない。

これは表示の採用方針の仕様差分であり、学習済みモデルの文脈性能が改善したという主張ではない。文脈が示す弱い日本語判定より、独立した綴りの判定を優先する場合が増える。made/name/note/no/toや英語prefixは除外し、未知語の誤変換が皆無とは扱わない。追加の判定コストの長文p95/p99は未評価。本文・確定文脈を新たに記録する機能は追加しない。

### 11.9 確定文脈によるローマ字入力単位の分断を防ぐ（2026-09-25）

`hennkoutennga` は「へんこうてんが」と読めるが、確定済みの日本語文脈によって先頭の `hen` が英語と判定される場合がある。英単語の切り出しが `nn` の途中を区切ると、残りの `nkoutennga` だけが「んこうてんが」として変換器へ渡される。

埋込み英単語の候補が既存の英語条件を通ったとき、確定文脈があれば、対象区間のローマ字入力単位を確認する。区間が読みとして成立する場合（未完の末尾を含む）、標準ComposingTextの独立境界を使う。候補の開始か終了がその境界と一致しない場合は、同じ原文を文脈なしで評価し、候補が既存の英語条件を満たすことも要求する。満たさなければその候補を除外し、通常の日本語判定へ進む。`meeting` のように入力単位を跨ぐ本来の英語も、原文のスコアで条件を満たせば維持する。

境界の取得は候補が見つかってから区間ごとに1回だけ行う。この検査に使う文脈なしのスコアは、単語全体の英語判定と共有し、1回のsegment呼出しで最大1回計算する。辞書の単語全体に対する判定、モデル・閾値・辞書、文脈なしの入力、保護範囲は変更しない。特定の単語を除外するリストは追加しない。漢字変換には元の確定文脈を引き続き渡す。
