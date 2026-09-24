import copy
import unittest

from author_punctuation import authored_records
from boundary_augmentation import contrasts, eligible
from context_features import record_context
from dataset import prune_cross_split_augmentations, validate_records


def example(raw="ashitanoyotei", label="JA_ROMAN", context=None):
    r = dict(id="unit", group_id="unit", split="train", raw=raw,
             spans=[dict(start=0, end=len(raw), label=label)], context_available=context is not None)
    if context is not None:
        r["left_context"] = context
    return r


class BoundaryAugmentationTests(unittest.TestCase):
    def test_complete_sentences_get_punctuation_and_both_availability_states(self):
        source = example()
        old = copy.deepcopy(source)
        derived = contrasts(source, [])
        self.assertEqual(source, old)
        self.assertEqual(len(derived), 7)
        self.assertEqual({record_context(r) for r, _ in derived}, {None, ""})
        for r, _ in derived:
            self.assertEqual((r["group_id"], r["split"]), (source["group_id"], "train"))
            self.assertEqual(r["spans"][0]["start"], 0)
            self.assertEqual(r["spans"][-1]["end"], len(r["raw"]))
            self.assertTrue(all(a["end"] == b["start"] for a, b in zip(r["spans"], r["spans"][1:])))
            ja = [r["raw"][s["start"]:s["end"]] for s in r["spans"] if s["label"] == "JA_ROMAN"]
            self.assertEqual(ja, [source["raw"]])

    def test_context_intents_ambiguous_short_and_structural_inputs_are_not_cloned(self):
        for r in [example(context="英語の引用"), example(label="AMBIGUOUS"), example("made"),
                  example("https://example.invalid", "LITERAL"), example("nihongodesu.")]:
            self.assertFalse(eligible(r))
            self.assertEqual(contrasts(r, []), [])
        with_empty = contrasts(example(context=""), [])
        self.assertTrue(any(not r["context_available"] and "left_context" not in r for r, _ in with_empty))

    def test_roman_alternative_at_period_keeps_its_own_offsets_and_scalar_count(self):
        source, alternative = example(), example("asitanoyotei")
        derived = contrasts(source, [alternative])
        self.assertEqual(len(derived), 9)
        selected = next(r for r, tag in derived if tag == "boundary_variant" and r["raw"] == "asitanoyotei.")
        self.assertEqual(selected["spans"][-1], dict(start=12, end=13, label="LITERAL"))

    def test_new_surface_collision_is_pruned_without_reassigning_originals(self):
        original = example("ashitanoyotei.")
        original["split"] = "test"
        rows = [dict(record=original, original_id="test", augmentation="original")]
        rows += [dict(record=r, original_id="train", augmentation=tag) for r, tag in contrasts(example(), [])]
        kept = prune_cross_split_augmentations(rows)
        self.assertEqual(kept[0], rows[0])
        self.assertFalse(any(r["record"]["raw"] == original["raw"] and r["record"]["split"] == "train" for r in kept))

    def test_authored_corpus_is_separate_from_regression_examples_and_fixtures(self):
        records, readings = authored_records()
        self.assertGreaterEqual(len(records), 200)
        self.assertGreater(len(readings), 100)
        self.assertEqual(len(records), len({r["id"] for r in records}))
        validate_records([dict(r, split="train") for r in records])
        for r in records:
            self.assertNotIn("asitanotennkiwoosiete", r["raw"])
            self.assertNotIn("asitanotennkiwooshiete", r["raw"])
            self.assertEqual(r["provenance"]["kind"], "synthetic_approved")
        self.assertTrue(any(not r["context_available"] for r in records))
        self.assertTrue(any(r["context_available"] for r in records))


if __name__ == "__main__":
    unittest.main()
