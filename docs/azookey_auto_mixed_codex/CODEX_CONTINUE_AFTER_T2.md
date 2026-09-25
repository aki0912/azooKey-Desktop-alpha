# Codexへの指示：T2完了済みフォークから再開

このZIPの `docs/auto-mixed/` 相当をフォークへ配置する。既存のユーザー編集済み資料・ソースを上書きせず差分を確認する。これは実装ソースや学習済みモデルを含まない仕様更新である。

```text
既存AGENTS.md、implementation_status.md、docs/auto-mixed/README.md、
docs/auto-mixed/docs/09_T2_MIGRATION.md、04_MODEL_AND_DATA.md、
05_TEST_AND_EVALUATION.md、06_IMPLEMENTATION_PLAN.mdを読んでください。

利用者によるとT2まで完了しています。git status、HEAD、T2の実装・テスト・
schema versionを実際に確認し、資料とコードの差分を記録してください。
T0〜T2は作り直さず、特徴量v1、LR、Viterbiとgoldenを回帰基準として保存してください。

次にT3の最初の小さな差分として、短い確定済み左文脈を任意入力に持つ
判定インターフェース・v2特徴量・同じrawで文脈を変える対照テストを実装してください。
アプリから既存の安全な経路で文脈を取得できるかを調査し、不可なら
未確定rawだけで動く互換経路を維持してください。文脈は記録しないでください。
made/no/to/nameの無条件保留は導入せず、文脈なし／低信頼時の保留を
データで調整できる実装にしてください。

学習済みモデルがない限り実際の曖昧語の判別性能を主張せず、機能フラグはOFF。
実行した検証と未実行事項をimplementation_status.mdに追記してください。
通常使用中のIMEのインストール・削除・登録変更は行わないでください。
```

T3以降は既存フォークの実装状態に合わせて進める。T2のSwift実装を直接見ていないため、型名・API・完了度合いをこのZIPで断定しない。
