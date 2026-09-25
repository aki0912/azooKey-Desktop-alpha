import copy
import os
from pathlib import Path
import unittest
from unittest.mock import patch

from dataset import load_dataset
from learning import (DEV_TARGETS, VERSIONS, load_checkpoint, metrics, model_thresholds,
                      select_decision_thresholds, threshold_candidates, tune_thresholds, validate_config)
from pipeline import main
from pipeline_io import HERE, PipelineError, read


def legacy(config):
    result = dict(config, schema_version=1, missing_context_increment=.07)
    result.pop("enter_ja_without_context_grid")
    return result


def small_dev():
    rows, scores = [], {}
    for name, label, context, probability in (("context-ja", "JA_ROMAN", "", .96),
                                             ("context-raw", "RAW", "left", .89),
                                             ("missing-ja", "JA_ROMAN", None, .995),
                                             ("missing-raw", "RAW", None, .98)):
        record = dict(id=name, raw="made", split="dev", spans=[dict(start=0, end=4, label=label)])
        if context is not None:
            record.update(context_available=True, left_context=context)
        rows.append(dict(record=record, protections=["inferred"] * 4, augmentation="original"))
        scores[name] = [dict(p_ja=probability)] * 4
    # Accessing a score for any excluded row will raise KeyError.
    rows += [dict(record=dict(id=split, split=split), augmentation="original")
             for split in ("train", "calibration", "test")]
    rows.append(dict(record=dict(id="augmented-dev", split="dev"), augmentation="prefix"))
    model = dict(schema_version=2, feature_spec_version=VERSIONS[1],
                 decoder=dict(switch_penalty=0), thresholds={})
    return model, dict(rows=rows), scores


class ThresholdSearchTests(unittest.TestCase):
    def setUp(self):
        self.config = read(HERE / "training_config.json")

    def test_independent_candidates_and_v1_legacy_compatibility(self):
        candidates = list(threshold_candidates(self.config))
        self.assertEqual([(t["enter_ja"], t["enter_ja_without_context"]) for t in candidates],
                         [(.90, .90), (.90, .95), (.90, .97), (.90, .99),
                          (.95, .95), (.95, .97), (.95, .99), (.99, .99)])
        old = legacy(self.config)
        self.assertEqual([(t["enter_ja"], t["enter_ja_without_context"]) for t in threshold_candidates(old)],
                         [(.90, .97), (.95, 1), (.99, 1)])
        old["feature_spec_version"] = VERSIONS[0]
        current = dict(self.config, feature_spec_version=VERSIONS[0])
        self.assertEqual(list(threshold_candidates(current)), list(threshold_candidates(old)))
        with self.assertRaises(PipelineError):
            model_thresholds(self.config, .95)

    def test_config_rejects_invalid_or_ambiguous_searches(self):
        for change in (dict(enter_ja_without_context_grid=[]), dict(enter_ja_without_context_grid=[1]),
                       dict(enter_ja_grid=[1]), dict(enter_ja_without_context_grid=[float("nan")]),
                       dict(enter_ja_without_context_grid=[True]), dict(enter_ja_without_context_grid=[-.1]),
                       dict(enter_ja_without_context_grid=[.8]), dict(missing_context_increment=.07),
                       dict(schema_version=3), dict(schema_version=True), dict(unknown=True)):
            with self.subTest(change=change), self.assertRaises(PipelineError):
                validate_config(dict(self.config, **change))
        scrambled = dict(self.config, enter_ja_grid=[.99, .9, .95, .9],
                         enter_ja_without_context_grid=[.99, .95, .9, .97, .9])
        self.assertEqual(list(threshold_candidates(scrambled)), list(threshold_candidates(self.config)))

    def test_search_uses_only_dev_originals_and_selects_independent_pair(self):
        model, data, scores = small_dev()
        config = dict(self.config, switch_penalty_grid=[0])
        before = copy.deepcopy((model, data, config))
        with patch("learning.score_record", side_effect=lambda _, r: scores[r["id"]]) as scorer:
            result = select_decision_thresholds(model, data, config)
            self.assertEqual(scorer.call_count, 4)
            old = select_decision_thresholds(model, data, legacy(config))
        self.assertEqual((model, data, config), before)
        self.assertEqual(result["selected"]["thresholds"], model_thresholds(config, .90, .99))
        self.assertEqual(result["selected"]["metrics"]["ja_recall"], 1)
        self.assertEqual(result["selected"]["metrics"]["english_span_damage_rate"], 0)
        self.assertEqual(old["selected"]["thresholds"]["enter_ja_without_context"], 1)
        self.assertEqual(old["selected"]["metrics"]["ja_recall"], .5)
        # Available empty context follows the available path, not the missing path.
        self.assertEqual(result["by_context"]["available"]["originals"], 2)
        self.assertEqual(result["by_context"]["unavailable"]["originals"], 2)
        self.assertEqual(result["targets"], DEV_TARGETS)
        self.assertFalse(result["quality_claim"])

    def test_no_passing_candidate_is_reported_without_weakening_targets(self):
        model, data, scores = small_dev()
        scores["missing-raw"] = [dict(p_ja=.9999)] * 4
        with patch("learning.score_record", side_effect=lambda _, r: scores[r["id"]]):
            result = select_decision_thresholds(model, data, dict(self.config, switch_penalty_grid=[0]))
        self.assertEqual(result["target_passing_candidates"], 0)
        self.assertFalse(result["selected_meets_dev_targets"])
        self.assertIn("english_span_damage_rate_max", result["selected"]["unmet_dev_targets"])
        self.assertEqual(result["targets"], dict(english_span_damage_rate_max=.005, ja_recall_min=.90,
                                                ja_precision_min=.98, boundary_f1_min=.90))

    def test_cached_metrics_match_uncached_metrics(self):
        model, data, scores = small_dev()
        rows = data["rows"][:4]
        model["thresholds"] = model_thresholds(self.config, .95, .97)
        with patch("learning.score_record", side_effect=lambda _, r: scores[r["id"]]):
            expected = metrics(model, rows)
        with patch("learning.score_record", side_effect=AssertionError("cached scores must be used")):
            self.assertEqual(expected, metrics(model, rows, precomputed_scores=[scores[r["record"]["id"]] for r in rows]))
        with self.assertRaises(PipelineError):
            metrics(model, rows, precomputed_scores=[])


@unittest.skipUnless(os.environ.get("AUTO_MIXED_THRESHOLD_RUN"), "Run threshold-only tuning first")
class FrozenThresholdRunTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = HERE.parents[1] / "build/auto-mixed/expanded-700-se-20260924"
        cls.data = load_dataset(cls.source / "dataset.json")
        cls.original = load_checkpoint(cls.source / "v2/calibrated.json", cls.data)
        cls.run_directory = Path(os.environ["AUTO_MIXED_THRESHOLD_RUN"])
        cls.config = read(cls.run_directory / "config.json")
        cls.tuned = load_checkpoint(cls.run_directory / "calibrated.json", cls.data)

    def test_frozen_parameters_provenance_and_no_test_dependence(self):
        for name in ("vocabulary", "coefficients", "intercept", "calibration"):
            self.assertEqual(self.tuned["model"][name], self.original["model"][name])
        self.assertNotEqual(self.tuned["model"]["model_version"], self.original["model"]["model_version"])
        self.assertEqual(self.tuned["training_manifest"]["config"], self.original["training_manifest"]["config"])
        self.assertEqual(self.tuned["training_manifest"]["threshold_tuning"]["parent_checkpoint_sha256"],
                         self.original["checkpoint_sha256"])
        self.assertFalse(self.tuned["release_ready"])
        self.assertEqual(len(self.tuned["threshold_tuning_report"]["trials"]), 40)
        dev_only = dict(self.data, rows=[r for r in self.data["rows"] if r["record"]["split"] == "dev"])
        # No fit, vocabulary rebuild, or calibration is allowed during a threshold-only run.
        with patch("learning.fit_lr", side_effect=AssertionError("must not refit")), \
             patch("learning.matrix", side_effect=AssertionError("must not recalibrate")):
            self.assertEqual(tune_thresholds(self.original, dev_only, self.config), self.tuned)
        legacy = select_decision_thresholds(self.original["model"], self.data,
                                            self.original["training_manifest"]["config"])
        self.assertEqual(legacy["selected"]["thresholds"], self.original["model"]["thresholds"])
        self.assertEqual(legacy["selected"]["decoder"], self.original["model"]["decoder"])
        self.assertEqual(legacy["selected"]["metrics"], self.original["calibration_report"]["selected_dev_metrics"])

    def test_rejects_unrelated_changes_fitted_inputs_and_existing_output(self):
        for field, value in (("seed", 1), ("minimum_ja", .2), ("minimum_path_margin", 0),
                             ("switch_penalty_grid", [0]), ("hold_ja", .1), ("logistic_C_grid", [1]),
                             ("sample_weighting", dict(policy="prefix-mass-v1", prefix_fraction=.5))):
            with self.subTest(field=field), self.assertRaises(PipelineError):
                tune_thresholds(self.original, self.data, dict(self.config, **{field: value}))
        with self.assertRaises(PipelineError):
            tune_thresholds(dict(self.original, phase="fitted"), self.data, self.config)
        with self.assertRaises(PipelineError):
            tune_thresholds(self.original, dict(self.data, dataset_sha256="different"), self.config)
        before = (self.run_directory / "calibrated.json").read_bytes()
        self.assertEqual(main(["tune-thresholds", "--model", str(self.source / "v2/calibrated.json"),
                              "--data", str(self.source / "dataset.json"), "--config", str(self.run_directory / "config.json"),
                              "--output", str(self.run_directory / "calibrated.json")]), 1)
        self.assertEqual((self.run_directory / "calibrated.json").read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
