import copy
import unittest

import numpy as np

from learning import VERSIONS, matrix, positions, validate_config, vocabulary
from pipeline_io import HERE, PipelineError, read
from sample_weighting import PREFIX_POLICY, row_position_weights, weighting_audit


def row(original, text, augmentation="original", label="JA_ROMAN"):
    return dict(original_id=original, augmentation=augmentation,
                record=dict(raw=text, split="train", spans=[dict(start=0, end=len(text), label=label)]))


class SampleWeightingTests(unittest.TestCase):
    policy = dict(policy=PREFIX_POLICY, prefix_fraction=.5)

    def test_legacy_matrix_is_unchanged_and_opt_in_changes_only_weights(self):
        rows = [row("a", "asita"), row("a", "as", "prefix"), row("b", "note", label="RAW")]
        vocab = vocabulary(rows, VERSIONS[1], 512)
        x, y, old = matrix(rows, VERSIONS[1], vocab)
        new_x, new_y, weighted = matrix(rows, VERSIONS[1], vocab, self.policy)
        np.testing.assert_array_equal(old, [1/7]*7 + [1/4]*4)
        np.testing.assert_array_equal(weighted, [.5/5]*5 + [.5/2]*2 + [1/4]*4)
        np.testing.assert_array_equal(x.toarray(), new_x.toarray())
        np.testing.assert_array_equal(y, new_y)

    def test_more_completed_variants_cannot_dilute_prefix_mass(self):
        rows = [row("a", "asita"), row("a", "as", "prefix"), row("a", "asi", "prefix")]
        before = copy.deepcopy(rows)
        for extras in ([], [row("a", "asitaha", "boundary_variant")]*20,
                       [row("a", "asitaha", "context_variant")]*31):
            expanded = rows + extras
            sizes = [len(positions(r["record"])) for r in expanded]
            weights = row_position_weights(expanded, sizes, self.policy)
            report = weighting_audit(expanded, sizes, weights)
            self.assertAlmostEqual(report["mass_by_augmentation"]["prefix"], .5)
            self.assertAlmostEqual(report["total_mass"], 1)
            self.assertEqual(report["originals_by_eligible_family"], {"both": 1})
            self.assertEqual(weights[:3], [.5/sum(s for r,s in zip(expanded,sizes) if r['augmentation'] != 'prefix'), .1, .1])
        self.assertEqual(rows, before)

    def test_missing_or_ineligible_families_preserve_unit_weight(self):
        rows = [row("a", "!", label="LITERAL"), row("a", "as", "prefix"),
                row("b", "!", "prefix", "LITERAL"), row("b", "note", label="RAW"),
                row("c", "!?", label="AMBIGUOUS")]
        sizes = [len(positions(r["record"])) for r in rows]
        weights = row_position_weights(rows, sizes, self.policy)
        self.assertEqual(weights, [0, .5, 0, .25, 0])
        self.assertEqual(weighting_audit(rows, sizes, weights)["originals_by_eligible_family"],
                         {"prefix": 1, "non_prefix": 1, "no_eligible_positions": 1})

    def test_training_only_and_strict_policy_validation(self):
        config = read(HERE / "training_config.json")
        validate_config(dict(config, sample_weighting=self.policy))
        for value in (None, {}, dict(self.policy, policy="unknown"), dict(self.policy, extra=True),
                      *[dict(self.policy, prefix_fraction=f) for f in (0,1,-.1,1.1,True,float('nan'))]):
            with self.subTest(value=value), self.assertRaises(PipelineError):
                validate_config(dict(config, sample_weighting=value))
        for split in ("dev", "calibration", "test"):
            item = row("a", "asita")
            item['record']['split'] = split
            with self.assertRaises(PipelineError):
                matrix([item], VERSIONS[0], [], self.policy)
        with self.assertRaises(PipelineError):
            matrix([row("a", "asita", "unrecognized")], VERSIONS[0], [], self.policy)

    def test_order_and_lengths_do_not_change_original_total_mass(self):
        rows = [row("a", "asita"), row("a", "as", "prefix"), row("b", "a"*100),
                row("b", "a", "prefix"), row("a", "a", "roman_variant")]
        policy = dict(self.policy, prefix_fraction=.6)
        for current in (rows, list(reversed(rows))):
            sizes = [len(positions(r["record"])) for r in current]
            weights = row_position_weights(current, sizes, policy)
            for original in ("a", "b"):
                self.assertAlmostEqual(sum(w*s for r,s,w in zip(current,sizes,weights) if r['original_id']==original), 1)
            self.assertAlmostEqual(weighting_audit(current,sizes,weights)['mass_by_augmentation']['prefix'], 1.2)


if __name__ == "__main__": unittest.main()
