# 作成時とT2後方針更新時の検証結果

検証日：2026-09-23。以下はZIP同梱のPython参照実装・素材の検証。T2完了は利用者の申告であり、この環境でフォークのSwift実装を検査した結果ではない。

| 検証 | 結果 |
|---|---|
| Python unit tests | 24 tests passed。うち2件は新しい文脈対照レコードの契約確認 |
| 区間データ | 50件、scalar範囲・全被覆・group split整合性を確認 |
| 文脈対照例 | 5件、scalar範囲・全被覆・group split・availabilityの整合性を確認。モデル予測精度は未測定 |
| 特徴量・数値golden | 128件、Python参照実装内で一致 |
| Viterbi | 長さ1〜7のサンプルを全path探索と比較し最小cost一致 |
| JSON Schema | 今回の環境に`jsonschema`がなく未実行。JSON構文とPython semantic validatorを検証。前版のschema成功を今回の成功に流用しない |
| イベント契約 | 16件、構造・ID等を確認。IMEでの実行試験ではない |
| v2 feature golden／Swiftとのparity | 未実施。v2はT3で実装する仕様であり、現ZIPに学習済みモデル・v2参照特徴量はない |
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
