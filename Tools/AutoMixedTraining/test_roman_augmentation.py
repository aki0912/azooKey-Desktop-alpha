import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from dataset import (ROMAN_ALIAS_FAMILIES, group_split, load_dataset, prune_cross_split_augmentations, roman_alternatives,
                     roman_table, validate_records, variants)
from pipeline_io import HERE, PipelineError, write_new
from preview_roman_variants import build_preview, main
from swift_bridge import validate_in_swift


class RomanAugmentationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.table = roman_table()

    def record(self, raw):
        return dict(id="source", group_id="group", split="train", raw=raw,
                    spans=[dict(start=0, end=len(raw), label="JA_ROMAN")], category="unit",
                    provenance=dict(kind="authored_fixture", rights_status="fixture_only", source_id="unit"))

    def test_common_aliases_are_bidirectional_and_pinned(self):
        for a, b in [("shi", "si"), ("tsu", "tu"), ("chi", "ti"), ("fu", "hu"),
                     ("ji", "zi"), ("sha", "sya"), ("cho", "tyo"), ("xya", "lya")]:
            self.assertEqual(self.table[a], self.table[b])
            self.assertEqual(roman_alternatives(a, self.table)[0], b)
            self.assertEqual(roman_alternatives(b, self.table)[0], a)
        self.assertNotIn("si", roman_alternatives("shi", {"shi": "し", "si": "す"}))
        self.assertEqual(roman_alternatives("u", self.table), [])
        self.assertEqual(roman_alternatives("ka", self.table), [])

    def test_profile_covers_multiple_syllables_then_keeps_local_variants(self):
        choices = roman_alternatives("shitsuchi", self.table)
        self.assertEqual(choices[0], "situti")
        for candidate in ["sitsuchi", "shituchi", "shitsuti"]:
            self.assertIn(candidate, choices)
        self.assertEqual(len(set(choices)), len(choices))

    def test_n_and_gemination_do_not_discard_other_complete_tokens(self):
        for a, b in [("wohozonshite", "wohozonsite"), ("konnnichiwa", "konnnitiwa"),
                     ("satsukisannniaimashita", "satukisannniaimasita"), ("shinn", "sinn"),
                     ("sshi", "ssi"), ("ttsu", "ttu"), ("masshiro", "massiro")]:
            self.assertEqual(roman_alternatives(a, self.table)[0], b)
        self.assertNotIn("sci", roman_alternatives("sshi", self.table))
        for raw in ["sh", "shik", "n", "kan'i", "SHI", "し"]:
            self.assertEqual(roman_alternatives(raw, self.table), [])

    def test_all_ja_spans_change_but_unicode_context_and_other_labels_stay(self):
        chunks = [("LITERAL", "👩‍💻e\u0301"), ("JA_ROMAN", "shi"), ("GAP", " "),
                  ("RAW", "tsushima"), ("JA_ROMAN", "tsu"), ("AMBIGUOUS", "chi")]
        record = self.record("".join(text for _, text in chunks))
        record.update(context_available=True, left_context="これは ", desired_display="意図のmetadata")
        record["spans"] = []
        at = 0
        for label, text in chunks:
            record["spans"].append(dict(start=at, end=at + len(text), label=label))
            at += len(text)
        before = copy.deepcopy(record)
        outputs = variants(record, self.table, 2)
        self.assertEqual(outputs[0]["raw"], "👩‍💻e\u0301si tsushimatuchi")
        self.assertEqual(record, before)
        self.assertEqual(len(outputs), 2)
        for output in outputs:
            validate_records([output])
            for key in ["group_id", "split", "provenance", "context_available", "left_context", "desired_display"]:
                self.assertEqual(output[key], record[key])
            for old, new in zip(record["spans"], output["spans"]):
                if old["label"] != "JA_ROMAN":
                    self.assertEqual(record["raw"][old["start"]:old["end"]], output["raw"][new["start"]:new["end"]])

    def test_bounded_deterministic_output_and_scalar_limit(self):
        record = self.record("shitsuchi" * 25)
        self.assertEqual(variants(record, self.table, 2), variants(record, self.table, 2))
        self.assertEqual(len(variants(record, self.table, 2)), 2)
        self.assertEqual(variants(record, self.table, 0), [])
        long_record = self.record("a" * 253 + "si")
        for result in variants(long_record, self.table, 8):
            self.assertLessEqual(len(result["raw"]), 256)
        self.assertEqual(variants(self.record("a" * 254 + "si"), {"si": "し", "shi": "し"}, 8), [])

    def test_cross_split_clones_are_pruned_not_reassigned(self):
        left, right = self.record("shi"), self.record("si")
        right.update(id="right", group_id="right", split="test")
        clone = variants(left, self.table, 1)[0]
        rows = [dict(record=left, augmentation="original"), dict(record=right, augmentation="original"),
                dict(record=clone, augmentation="roman_variant")]
        self.assertEqual(prune_cross_split_augmentations(rows), rows[:2])
        self.assertEqual(clone["split"], "train")

    def test_review_preview_splits_before_variants_and_stays_unapproved(self):
        source = HERE / "review_samples/samples_50.jsonl"
        before = source.read_bytes()
        real_variants = variants
        assignments = {}

        def freeze(records, seed):
            assignments.update(group_split(records, seed))
            return assignments

        def check_split(record, table, limit):
            self.assertTrue(assignments)
            self.assertEqual(record["split"], assignments[record["group_id"]]["split"])
            return real_variants(record, table, limit)

        def masks(rows, originals):
            for row in rows:
                row["protections"] = ["inferred"] * len(row["record"]["raw"])

        with patch("preview_roman_variants.variants", side_effect=check_split), \
                patch("preview_roman_variants.group_split", side_effect=freeze), \
                patch("preview_roman_variants.validate_in_swift", side_effect=masks):
            preview = build_preview(source)
        self.assertEqual(source.read_bytes(), before)
        self.assertEqual(preview["kind"], "review_preview")
        self.assertFalse(preview["training_eligible"])
        self.assertGreater(len(preview["rows"]), 50)
        for row in preview["rows"]:
            r = row["record"]
            self.assertEqual(r["provenance"]["rights_status"], "pending_review")
            self.assertEqual(r["split"], preview["groups"][r["group_id"]]["split"])
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "preview.json"
            write_new(path, preview)
            with self.assertRaises(PipelineError):
                load_dataset(path)
            with patch("preview_roman_variants.build_preview") as build:
                self.assertEqual(main(["--input", str(source), "--output", folder]), 1)
                build.assert_not_called()

    def test_review_preview_refuses_fixture_and_presplit_records(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "source.jsonl"
            for split, rights in [("unassigned", "fixture_only"), ("train", "pending_review")]:
                record = self.record("shi")
                record["split"] = split
                record["provenance"]["rights_status"] = rights
                path.write_text(json.dumps(record) + "\n")
                with self.assertRaises(PipelineError):
                    build_preview(path)

    @unittest.skipUnless(os.environ.get("AUTO_MIXED_TRAINING_DATASET"), "Run offline fixture smoke for real Swift checks")
    def test_alias_families_and_contexts_match_in_real_converter(self):
        raw_cases = {token for family in ROMAN_ALIAS_FAMILIES for token in family}
        raw_cases.update(token for token in self.table if token.startswith(("x", "l")))
        raw_cases.update(["wohozonshite", "konnnichiwa", "satsukisannniaimashita", "shinn",
                          "sshi", "ttsu", "masshiro", "ccha", "shitsuchi"])
        rows, originals = [], {}
        for i, raw in enumerate(sorted(raw_cases)):
            original = self.record(raw)
            original["id"] = str(i)
            originals[str(i)] = original
            for candidate in variants(original, self.table, 8):
                rows.append(dict(record=candidate, original_id=str(i), augmentation="roman_variant"))
        self.assertGreater(len(rows), 70)
        validate_in_swift(rows, originals)
        self.assertTrue(all(len(row["protections"]) == len(row["record"]["raw"]) for row in rows))


if __name__ == "__main__":
    unittest.main()
