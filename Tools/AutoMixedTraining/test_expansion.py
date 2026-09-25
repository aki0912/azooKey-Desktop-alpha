from collections import Counter
import json
import os
from pathlib import Path
import unittest

from author_expansion import SOURCE, authored_records, parse_sentence, romanize
from dataset import group_split, load_dataset, load_sources, near_key, roman_table
from learning import labels, positions
from learning_size_probe import training_subsets
from pipeline_io import HERE, PipelineError, read


class ExpansionTests(unittest.TestCase):
    def test_authored_source_matches_generated_records_and_preserves_review_status(self):
        records, readings = authored_records()
        stored = [json.loads(line) for line in (SOURCE / "generated/samples.jsonl").read_text().splitlines()]
        self.assertEqual(records, stored)
        self.assertEqual(readings, read(SOURCE / "generated/reading_checks.json")["pairs"])
        self.assertEqual(len(records), 650)
        self.assertEqual(len({r["id"] for r in records}), 650)
        self.assertEqual(len({r["group_id"] for r in records}), 570)
        self.assertEqual(len(readings), 553)
        self.assertEqual(read(SOURCE / "generated/inventory.json")["human_review"], "not_yet_performed")
        manifest, all_records = load_sources(SOURCE / "generated/manifest.json")
        self.assertEqual(len(all_records), 700)
        self.assertEqual(manifest["mode"], "approved")

    def test_romanization_uses_pinned_table_and_handles_n_and_gemination(self):
        table = roman_table()
        self.assertEqual(romanize("しつちふじ", table), "shitsuchifuji")
        self.assertEqual(romanize("こんにちは", table), "konnnichiha")
        self.assertEqual(romanize("せつめい", table), "setsumei")
        self.assertEqual(romanize("きって", table), "kitte")
        self.assertEqual(parse_sentence("{👩‍💻}し[Code] ", table),
                         [("LITERAL", "👩‍💻", None), ("JA_ROMAN", "shi", "し"), ("RAW", "Code", None), ("GAP", " ", None)])
        for text in ("[unclosed", "{}", "hello", "し}"):
            with self.assertRaises(PipelineError):
                parse_sentence(text, table)

    def test_context_intents_are_grouped_and_ambiguity_is_excluded(self):
        records, _ = authored_records()
        contexts = [r for r in records if r["category"].startswith("context_")]
        self.assertEqual(len(contexts), 100)
        for raw in {r["raw"] for r in contexts}:
            family = [r for r in contexts if r["raw"] == raw]
            self.assertEqual(len(family), 5)
            self.assertEqual(len({r["group_id"] for r in family}), 1)
            self.assertEqual(Counter(labels(r)[0] for r in family), {"RAW": 2, "JA_ROMAN": 1, "AMBIGUOUS": 2})
            for record in family:
                if record["category"] == "context_empty":
                    self.assertTrue(record["context_available"])
                    self.assertEqual(record["left_context"], "")
                    self.assertEqual(positions(record), [])
                if record["category"] == "context_unavailable":
                    self.assertFalse(record["context_available"])
                    self.assertNotIn("left_context", record)
                    self.assertEqual(positions(record), [])

    def test_frozen_split_retains_old_assignments_and_joins_new_contexts(self):
        records = [dict(group_id=str(i), raw=word) for i, word in enumerate(
            ["ashita", "kyou", "watashi", "sore", "desu", "kaku", "sushi", "michi", "tukau", "asa", "hiru", "yoru"])]
        old = group_split(records, 20260924)
        expanded = records + [dict(group_id="contrast", raw="ashita"), dict(group_id="added", raw="new different example")]
        groups = group_split(expanded, 20260924, old)
        for group, info in old.items():
            self.assertEqual(groups[group]["split"], info["split"])
        self.assertEqual(groups["contrast"]["split"], old["0"]["split"])
        self.assertEqual(groups, group_split(list(reversed(expanded)), 20260924, old))
        with self.assertRaisesRegex(PipelineError, "frozen source group missing"):
            group_split(records[1:] + [dict(group_id="extra", raw="other example")], 20260924, old)

    def test_near_duplicate_bridge_cannot_merge_different_frozen_partitions(self):
        records = [dict(group_id=str(i), raw=word) for i, word in enumerate(
            ["ashita", "kyou", "watashi", "sore", "desu", "kaku", "sushi", "michi", "tukau", "asa", "hiru", "yoru"])]
        records += [dict(group_id="left", raw="a" * 20), dict(group_id="right", raw="a" * 18 + "bb"),
                    dict(group_id="bridge", raw="a" * 19 + "b")]
        frozen = {"left": dict(component="left", split="train"), "right": dict(component="right", split="test")}
        with self.assertRaisesRegex(PipelineError, "different frozen partitions"):
            group_split(records, 77, frozen)

    def test_size_probe_uses_nested_whole_train_components_only(self):
        data = dict(seed=1, groups={str(i): dict(component=str(i // 2), split="train") for i in range(20)}, rows=[])
        for i in range(20):
            for augmentation in ("original", "prefix", "roman_variant"):
                data["rows"].append(dict(original_id=str(i), augmentation=augmentation,
                    record=dict(group_id=str(i), split="train", raw="made")))
        for split in ("dev", "calibration", "test"):
            data["rows"].append(dict(original_id=split, record=dict(group_id=split, split=split, raw="withheld")))
        previous = set()
        for count, rows in training_subsets(data, (2, 5)):
            ids = {row["original_id"] for row in rows}
            self.assertLessEqual(previous, ids)
            self.assertEqual(len(rows), count * 2 * 3)
            self.assertTrue(all(row["record"]["split"] == "train" for row in rows))
            previous = ids


@unittest.skipUnless(os.environ.get("AUTO_MIXED_EXPANSION_RUN"), "Run the expanded approved dataset first")
class ExpandedRunTests(unittest.TestCase):
    def test_baseline_partitions_originals_and_group_leakage(self):
        from collections import defaultdict
        run = Path(os.environ["AUTO_MIXED_EXPANSION_RUN"])
        data = load_dataset(run / "dataset.json")
        baseline = load_dataset(HERE.parents[1] / "build/auto-mixed/approved-50-20260924/dataset.json")
        self.assertEqual(data["baseline_dataset_sha256"], baseline["dataset_sha256"])
        old = {r["original_id"]: r["record"] for r in baseline["rows"] if r["augmentation"] == "original"}
        current = {r["original_id"]: r["record"] for r in data["rows"] if r["augmentation"] == "original"}
        self.assertEqual(len(current), 700)
        for identifier, record in old.items():
            self.assertEqual(current[identifier], record)
        for group, info in baseline["groups"].items():
            self.assertEqual(data["groups"][group]["split"], info["split"])
        owners = defaultdict(set)
        for row in data["rows"]:
            owners[near_key(row["record"]["raw"])].add(row["record"]["split"])
        self.assertTrue(all(len(value) == 1 for value in owners.values()))
        self.assertGreaterEqual(len({g["component"] for g in data["groups"].values()}), 500)

    def test_calibration_has_both_classes_and_timing_is_measured(self):
        data = load_dataset(Path(os.environ["AUTO_MIXED_EXPANSION_RUN"]) / "dataset.json")
        counts = Counter(label for row in data["rows"] if row["augmentation"] == "original"
                         and row["record"]["split"] == "calibration" for _, label in positions(row["record"]))
        self.assertGreaterEqual(counts[0], 100)
        self.assertGreaterEqual(counts[1], 100)
        timings = read(Path(os.environ["AUTO_MIXED_EXPANSION_RUN"]) / "timings.json")
        self.assertEqual(timings["clock"], "perf_counter")
        self.assertTrue(all(value > 0 for value in timings["seconds"].values()))
        self.assertGreaterEqual(timings["seconds"]["total"], sum(value for key, value in timings["seconds"].items() if key != "total"))


if __name__ == "__main__":
    unittest.main()
