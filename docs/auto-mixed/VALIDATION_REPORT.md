# 作成時の検証結果

検証日：2026-09-23。以下は本資料に同梱したPython参照実装・素材の検証。

| 検証 | 結果 |
|---|---|
| Python unit tests | 22 tests passed |
| 区間データ | 50件、scalar範囲・全被覆・group split整合性を確認 |
| 特徴量・数値golden | 128件、Python参照実装内で一致 |
| Viterbi | 長さ1〜7のサンプルを全path探索と比較し最小cost一致 |
| JSON Schema | Draft 2020-12、schema本体とレコード／モデルfixtureを検証 |
| イベント契約 | 16件、構造・ID等を確認。IMEでの実行試験ではない |
| Swiftとのparity | 未実施 |
| LR学習／推定精度 | 未実施。fixture重みは人工的な数値テスト専用 |
| macOSビルド／署名 | 未実施 |
| 実Zenzai／IMK／対象アプリ | 未実施 |

## 再実行

```bash
cd docs/auto-mixed
python3 -m unittest discover -s reference -p 'test_*.py' -v
python3 reference/validate_bundle.py
```

JSON Schema部分はjsonschemaがある環境で実行する。標準ライブラリだけでもsemantic validatorとunit testsは動作する。テストは正解精度やアプリ完成を示すものではない。
