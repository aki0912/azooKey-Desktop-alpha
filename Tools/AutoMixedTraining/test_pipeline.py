import copy
from collections import Counter, defaultdict
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import numpy as np

from context_features import contextual_features
from dataset import (build_dataset, group_split, load_dataset, load_sources, near_key,
                     prefixes, roman_alternatives, roman_table, validate_records, variants)
from learning import (VERSIONS, calibrate, decode, features, load_checkpoint, matrix,
                      model_thresholds, score_record, train, validate_config, vocabulary)
from pipeline import export, main
from pipeline_io import HERE, ROOT, PipelineError, digest, fingerprint, parse, read, write_new


def example(identifier, raw, label="JA_ROMAN", group=None):
    return dict(id=identifier, group_id=group or identifier, split="fixture", raw=raw,
                spans=[dict(start=0, end=len(raw), label=label)], category="unit_test_only",
                provenance=dict(kind="authored_fixture", source_id="test", rights_status="fixture_only"))


class DataPipelineTests(unittest.TestCase):
    def test_strict_json_and_schema(self):
        for value in ['{"x":1,"x":2}', '{"x":NaN}', '{"x":Infinity}']:
            with self.assertRaises(PipelineError):
                parse(value)
        for change in [lambda r: r.update(extra=True), lambda r: r["spans"][0].update(end=99),
                       lambda r: r.update(left_context="secret"), lambda r: r.update(raw="\ud800")]:
            record = example("a", "made")
            change(record)
            with self.assertRaises(ValueError):
                validate_records([record])

    def test_group_split_is_order_independent_and_near_duplicates_join(self):
        records = [example(str(i), word) for i, word in enumerate(
            ["ashita", "kyou", "watashi", "sore", "desu", "kaku", "sushi", "michi", "tukau", "asa", "hiru", "yoru"])]
        records += [example("contrast", "ashita", "RAW", "other-intent"),
                    example("near-a", "this is a longer sentence", "RAW"),
                    example("near-b", "this is a longer sentencf", "RAW")]
        groups = group_split(records, 77)
        self.assertEqual(groups, group_split(list(reversed(records)), 77))
        self.assertEqual(groups["0"], groups["other-intent"])
        self.assertEqual(groups["near-a"], groups["near-b"])
        self.assertEqual({g["split"] for g in groups.values()}, {"train", "dev", "calibration", "test"})
        with self.assertRaises(PipelineError):
            group_split(records[:9], 77)

    def test_roman_variants_use_pinned_table_and_rebase_scalar_spans(self):
        table = roman_table()
        self.assertIn("si", roman_alternatives("shi", table))
        self.assertIn("ti", roman_alternatives("chi", table))
        self.assertIn("tu", roman_alternatives("tsu", table))
        self.assertEqual(roman_alternatives("kan'i", table), [])
        self.assertEqual(roman_alternatives("sh", table), [])
        record = example("sample", "👩‍💻shi Code")
        record["spans"] = [dict(start=0, end=3, label="LITERAL"), dict(start=3, end=6, label="JA_ROMAN"),
                           dict(start=6, end=7, label="GAP"), dict(start=7, end=11, label="RAW")]
        generated = variants(record, table, 8)
        self.assertTrue(generated)
        for variant in generated:
            validate_records([variant])
            self.assertTrue(variant["raw"].endswith(" Code"))
            self.assertEqual(variant["spans"][-1]["end"], len(variant["raw"]))
            self.assertEqual(variant["group_id"], record["group_id"])

    def test_prefixes_recompute_features_without_future_or_grapheme_cuts(self):
        record = example("prefix", "made e\u0301👩‍💻")
        outputs = list(prefixes(record, 4, 8))
        for output in outputs:
            validate_records([output])
            self.assertTrue(record["raw"].startswith(output["raw"]))
            self.assertEqual(output["group_id"], record["group_id"])
            self.assertNotEqual(output["raw"], "made e")
        prefix = next(r for r in outputs if r["raw"] == "ma")
        self.assertNotEqual(features(prefix, 1, VERSIONS[1]), contextual_features(record["raw"], 1))

    def test_rights_manifest_requires_evidence_and_cannot_promote_fixtures(self):
        manifest, _ = load_sources(HERE / "fixture_manifest.json")
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            source = base / "records.jsonl"
            record = example("approved-unit", "made")
            record["split"] = "unassigned"
            record["provenance"] = dict(kind="authored", source_id="unit", rights_status="approved", license_id="TEST-NOT-A-CORPUS",
                                        source_url="authored:test", retrieved_at="2026-09-24")
            source.write_text(json.dumps(record) + "\n")
            evidence = base / "review.txt"
            evidence.write_text("Unit test evidence only. Not approval of a real corpus.\n")
            approval = dict(status="approved", reviewer="unit-test", reviewed_at="2026-09-24", license_id="TEST-NOT-A-CORPUS",
                            source_url="authored:test", retrieved_at="2026-09-24", allowed_uses=["training", "evaluation", "derived_model"],
                            evidence=dict(path="review.txt", sha256=digest(evidence.read_bytes())), grouping_rule="original", processing="none",
                            privacy_reviewed=True)
            source_entry = dict(source_id="unit", records=dict(path="records.jsonl", sha256=digest(source.read_bytes())), approval=approval)
            approved = dict(manifest, mode="approved", sources=[source_entry])
            path = base / "manifest.json"
            path.write_text(json.dumps(approved))
            self.assertEqual(len(load_sources(path)[1]), 1)
            for mutation in [lambda a: a["sources"][0]["approval"].update(status="pending_review"),
                             lambda a: a["sources"][0]["approval"].update(allowed_uses=["evaluation"]),
                             lambda a: a["sources"][0]["approval"].update(privacy_reviewed=False),
                             lambda a: a["sources"][0]["records"].update(sha256="0" * 64),
                             lambda a: a["sources"][0]["records"].update(path="https://example.invalid/data"),
                             lambda a: a.update(mode="fixture")]:
                changed = copy.deepcopy(approved)
                mutation(changed)
                path.write_text(json.dumps(changed))
                with self.assertRaises(PipelineError):
                    load_sources(path)
            record["provenance"].update(kind="authored_fixture", rights_status="fixture_only")
            source.write_text(json.dumps(record) + "\n")
            approved["sources"][0]["records"]["sha256"] = digest(source.read_bytes())
            path.write_text(json.dumps(approved))
            with self.assertRaises(PipelineError):
                load_sources(path)

    def test_fixture_build_keeps_group_and_prunes_cross_split_augmentations(self):
        # This unit test isolates split/augmentation logic; the CLI smoke uses the real Swift bridge.
        def masks(rows, originals):
            for row in rows:
                row["protections"] = ["inferred"] * len(row["record"]["raw"])
        with patch("swift_bridge.validate_in_swift", side_effect=masks):
            data = build_dataset(HERE / "fixture_manifest.json")
        self.assertEqual(data["mode"], "fixture")
        self.assertGreater(data["pruned_cross_split_augmentations"], 0)
        owners, prefixes_per_original = defaultdict(set), Counter()
        for row in data["rows"]:
            r = row["record"]
            self.assertEqual(r["split"], data["groups"][r["group_id"]]["split"])
            owners[near_key(r["raw"])].add(r["split"])
            prefixes_per_original[row["original_id"]] += row["augmentation"] == "prefix"
        self.assertTrue(all(len(v) == 1 for v in owners.values()))
        self.assertTrue(all(n <= 8 for n in prefixes_per_original.values()))

    def test_train_only_vocabulary_and_original_sample_weight(self):
        rows = [dict(record=example("a", "shi"), original_id="source"),
                dict(record=example("b", "si"), original_id="source"),
                dict(record=example("c", "en", "RAW"), original_id="another")]
        vocab = vocabulary(rows, VERSIONS[0], 32768)
        _, y, weights = matrix(rows, VERSIONS[0], vocab)
        self.assertAlmostEqual(sum(weights[:5]), 1.0)
        self.assertAlmostEqual(sum(weights[5:]), 1.0)
        self.assertEqual(set(y), {0, 1})
        heldout = '["char",0,["CHAR","q"]]'
        self.assertNotIn(heldout, vocab)
        self.assertEqual(vocab, sorted(vocab, key=lambda key: key.encode()))
        mixed = example("excluded", "a !?")
        mixed["spans"] = [dict(start=0, end=1, label="JA_ROMAN"), dict(start=1, end=2, label="GAP"),
                          dict(start=2, end=3, label="LITERAL"), dict(start=3, end=4, label="AMBIGUOUS")]
        self.assertEqual(matrix([dict(record=mixed, original_id="x")], VERSIONS[0], vocab)[1].tolist(), [1])

    def test_cli_errors_are_nonzero_and_do_not_echo_corpus(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "bad.jsonl"
            path.write_text('{"raw":"PRIVATE-CONTEXT-DO-NOT-LOG"}\n')
            result = subprocess.run([sys.executable, str(HERE / "pipeline.py"), "validate-data", "--input", str(path)],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("PRIVATE-CONTEXT", result.stdout + result.stderr)
            destination = Path(folder) / "existing.json"
            write_new(destination, dict(original=True))
            with self.assertRaises(FileExistsError):
                write_new(destination, dict(overwrite=True))
            self.assertEqual(read(destination), dict(original=True))


@unittest.skipUnless(os.environ.get("AUTO_MIXED_TRAINING_DATASET"), "Run offline fixture smoke first")
class FittedPipelineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = load_dataset(os.environ["AUTO_MIXED_TRAINING_DATASET"])
        cls.config = read(HERE / "training_config.json")
        cls.config.update(vocabulary_max_features=512, logistic_C_grid=[1.0], switch_penalty_grid=[1.2], enter_ja_grid=[.9])
        cls.checkpoint = train(cls.data, cls.config)

    def test_fitting_uses_train_and_dev_only_and_is_deterministic(self):
        changed = copy.deepcopy(self.data)
        for row in changed["rows"]:
            if row["record"]["split"] in ("test", "calibration"):
                for span in row["record"]["spans"]:
                    if span["label"] in ("JA_ROMAN", "RAW"):
                        span["label"] = "RAW" if span["label"] == "JA_ROMAN" else "JA_ROMAN"
        # Same provenance ID for this unit perturbation: coefficients must not depend on withheld labels.
        other = train(changed, self.config)
        self.assertEqual(self.checkpoint, other)
        self.assertEqual(self.checkpoint["model"]["kind"], "fixture")
        for row in self.data["rows"][:10]:
            scores = score_record(self.checkpoint["model"], row["record"])
            x, _, _ = matrix([row], VERSIONS[1], self.checkpoint["model"]["vocabulary"])
            expected = x @ np.array(self.checkpoint["model"]["coefficients"]) + self.checkpoint["model"]["intercept"]
            from learning import positions
            np.testing.assert_allclose([scores[i]["logit"] for i, _ in positions(row["record"])], expected, atol=1e-12, rtol=0)

    def test_calibration_ignores_test_and_export_cannot_change_fixture_kind(self):
        checkpoint = calibrate(self.checkpoint, self.data)
        changed = copy.deepcopy(self.data)
        changed["rows"] = [r for r in changed["rows"] if r["record"]["split"] != "test"]
        self.assertEqual(checkpoint, calibrate(self.checkpoint, changed))
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder) / "export"
            export(checkpoint, out)
            self.assertEqual(read(out / "model.json")["kind"], "fixture")
            self.assertEqual(read(out / "manifest.json")["model_sha256"], digest((out / "model.json").read_bytes()))
            self.assertEqual(len(read(out / "parity.json")["vectors"]), 128)
            with self.assertRaises(PipelineError):
                export(self.checkpoint, Path(folder) / "uncalibrated")
            checkpoint["model"]["kind"] = "production"
            path = Path(folder) / "tampered.json"
            write_new(path, checkpoint)
            with self.assertRaises(PipelineError):
                load_checkpoint(path, self.data)

    def test_nonconvergence_fails_instead_of_exporting_partial_fit(self):
        config = dict(self.config, max_iter=1, tolerance=1e-12)
        from sklearn.exceptions import ConvergenceWarning
        with self.assertRaises(ConvergenceWarning):
            train(self.data, config)


if __name__ == "__main__":
    unittest.main()
