# 参照実装の範囲

`auto_mixed_reference.py`は文字位置特徴量v1、float64 LR数値計算、2状態Viterbi、素材整合性の参照実装です。IME、ローマ字変換器、学習器、保護語辞書、完成した言語segmenterではありません。保護規則、未完ローマ字、ヒステリシス、Swift、Zenzai adapterは実装計画で作成します。

`test_reference.py`は22個のunit testsを含みます。`validate_bundle.py`はJSON素材の整合性を検証します。実行結果は`../VALIDATION_REPORT.md`を参照してください。

`../fixtures/language_model_fixture.json`は数値parity専用の人工的な係数です。言語能力はありません。production runtimeは`kind=fixture`を拒否し、モデルの学習結果として使わないでください。

最小Python版は3.10を想定しています。ランタイムIMEにPythonを組み込む設計ではありません。
