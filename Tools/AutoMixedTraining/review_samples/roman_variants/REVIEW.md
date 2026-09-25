# ローマ字別表記の確認用プレビュー

原本50件に別表記13件を追加した、計63件の確認用データ。
2026-09-24に利用者が原本50件と別表記13件の全件を採用した。内容確認の対象IDとhashは [annotation_review.json](../annotation_review.json) に記録した。権利statusはpending_reviewを維持し、権利承認・学習・精度評価は行っていない。

元文groupを仮分割してから生成し、派生行は同じgroup・splitを引き継ぐ。
この仮分割は確認専用。学習時は承認済み原本全体をまとめて分割し直し、同じ増強処理を実行する。
preview.jsonは学習用sealed datasetではなく、原本への連結や学習CLIへの投入はしない。

JA_ROMAN区間だけを変更し、英語・保護文字列・空白・左文脈は保持した。
固定Converterで変更区間の読み一致を確認済み。漢字変換・IME実打鍵の検証ではない。
元文あたり追加は最大2件。全箇所を代表的な別表記にした例を先に、次に一部だけ変えた例を選ぶ。

| 元ID | 派生ID | 元raw | 別表記raw | 仮split | 判定 |
|---|---|---|---|---|---|
| <code>sample-001</code> | <code>sample-001--roman-1</code> | <code>raisyuuZoomdehanashimasu</code> | <code>raishuuZoomdehanasimasu</code> | <code>train</code> | 採用 |
| <code>sample-001</code> | <code>sample-001--roman-2</code> | <code>raisyuuZoomdehanashimasu</code> | <code>raishuuZoomdehanashimasu</code> | <code>train</code> | 採用 |
| <code>sample-002</code> | <code>sample-002--roman-1</code> | <code>shiryouniURLwoharu</code> | <code>siryouniURLwoharu</code> | <code>dev</code> | 採用 |
| <code>sample-007</code> | <code>sample-007--roman-1</code> | <code>coffeewonondematsu</code> | <code>coffeewonondematu</code> | <code>calibration</code> | 採用 |
| <code>sample-008</code> | <code>sample-008--roman-1</code> | <code>PDFwohozonshitemaildeokuru</code> | <code>PDFwohozonsitemaildeokuru</code> | <code>train</code> | 採用 |
| <code>sample-012</code> | <code>sample-012--roman-1</code> | <code>ticket noyuukoukigenwoshiraberu</code> | <code>ticket noyuukoukigenwosiraberu</code> | <code>train</code> | 採用 |
| <code>sample-014</code> | <code>sample-014--roman-1</code> | <code>Please kakuninshitekudasai</code> | <code>Please kakuninsitekudasai</code> | <code>train</code> | 採用 |
| <code>sample-018</code> | <code>sample-018--roman-1</code> | <code>watashihatoukyouheikimasu</code> | <code>watasihatoukyouheikimasu</code> | <code>train</code> | 採用 |
| <code>sample-019</code> | <code>sample-019--roman-1</code> | <code>shigatsutsuitachi</code> | <code>sigatutuitati</code> | <code>calibration</code> | 採用 |
| <code>sample-019</code> | <code>sample-019--roman-2</code> | <code>shigatsutsuitachi</code> | <code>sigatsutsuitachi</code> | <code>calibration</code> | 採用 |
| <code>sample-020</code> | <code>sample-020--roman-1</code> | <code>satsukisannniaimashita</code> | <code>satukisannniaimasita</code> | <code>test</code> | 採用 |
| <code>sample-020</code> | <code>sample-020--roman-2</code> | <code>satsukisannniaimashita</code> | <code>satukisannniaimashita</code> | <code>test</code> | 採用 |
| <code>sample-034</code> | <code>sample-034--roman-1</code> | <code>このmenuwotojiru</code> | <code>このmenuwotoziru</code> | <code>train</code> | 採用 |
