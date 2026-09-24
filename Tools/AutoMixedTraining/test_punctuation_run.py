from collections import Counter, defaultdict
import os
from pathlib import Path
import unittest

from context_features import record_context
from dataset import load_dataset, near_key
from learning import positions
from pipeline_io import ROOT, read


@unittest.skipUnless(os.environ.get("AUTO_MIXED_PUNCTUATION_RUN"), "Build the punctuation candidate first")
class PunctuationRunTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = Path(os.environ["AUTO_MIXED_PUNCTUATION_RUN"])
        cls.data = load_dataset(cls.directory / "dataset.json")
        cls.old = load_dataset(ROOT / "build/auto-mixed/expanded-700-se-20260924/dataset.json")

    def test_all_frozen_originals_and_groups_are_preserved(self):
        old = {r["original_id"]: r["record"] for r in self.old["rows"] if r["augmentation"] == "original"}
        current = {r["original_id"]: r["record"] for r in self.data["rows"] if r["augmentation"] == "original"}
        self.assertEqual(len(old), 700)
        self.assertEqual(len(current), 930)
        for identifier, record in old.items():
            self.assertEqual(current[identifier], record)
        for group, entry in self.old["groups"].items():
            self.assertEqual(self.data["groups"][group]["split"], entry["split"])
        owners = defaultdict(set)
        for row in self.data["rows"]:
            owners[near_key(row["record"]["raw"])].add(row["record"]["split"])
        self.assertTrue(all(len(splits) == 1 for splits in owners.values()))

    def test_period_has_both_languages_and_empty_context_has_both_training_labels(self):
        period, empty = Counter(), Counter()
        for row in self.data["rows"]:
            r = row["record"]
            if r["split"] != "train":
                continue
            for i, label in positions(r):
                if "." in r["raw"][i + 1:i + 9]:
                    period[label] += 1
                if record_context(r) == "":
                    empty[label] += 1
        for counts in (period, empty):
            self.assertGreater(counts[0], 100)
            self.assertGreater(counts[1], 100)

    def test_export_and_timing_are_explicit_and_candidate_only(self):
        timing = read(self.directory / "timings.json")
        self.assertFalse(timing["test_evaluated"])
        self.assertGreater(timing["seconds"]["fit_and_dev_selection"], 0)
        self.assertGreaterEqual(timing["seconds"]["total"], sum(v for k, v in timing["seconds"].items() if k != "total"))
        manifest = read(self.directory / "export/manifest.json")
        self.assertFalse(manifest["release_ready"])
        self.assertEqual(manifest["training_manifest"]["dataset_sha256"], self.data["dataset_sha256"])


if __name__ == "__main__":
    unittest.main()
