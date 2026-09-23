"""These tests verify reference math and fixtures, NOT macOS/Swift/IME behavior."""
from __future__ import annotations
import copy
import itertools
import json
import math
import random
import unittest
from pathlib import Path
from auto_mixed_reference import (
    anchored_features, build_vocabulary, check_scalar_text, stable_sigmoid,
    LinearLanguageModel, validate_model, validate_span_record, validate_record_set,
    viterbi, LABELS,
)
ROOT = Path(__file__).resolve().parents[1]

def load(relative):
    return json.loads((ROOT / relative).read_text(encoding='utf-8'))

class FeatureTests(unittest.TestCase):
    def test_feature_count(self):
        self.assertEqual(len(anchored_features('hello', 2)), 61)

    def test_case_values_but_distinct_shape(self):
        lo, up = anchored_features('swift', 0), anchored_features('Swift', 0)
        nonshape = lambda keys: [k for k in keys if not k.startswith('["shape"')]
        self.assertEqual(nonshape(lo), nonshape(up))
        self.assertNotEqual(lo, up)

    def test_boundary_not_literal_collision(self):
        keys = anchored_features('BOS', 0)
        self.assertIn('["char",-1,["BOS"]]', keys)
        self.assertIn('["char",0,["CHAR","b"]]', keys)
        self.assertIn('["char",3,["EOS"]]', keys)

    def test_scalar_indices(self):
        text = '👩\u200d💻'
        self.assertEqual(len(text), 3)
        self.assertEqual(len(text.encode('utf-16-le')) // 2, 5)
        self.assertIn('["char",0,["CHAR","\\u200d"]]', anchored_features(text, 1))

    def test_invalid_surrogate(self):
        with self.assertRaises(ValueError):
            check_scalar_text('\ud800')

    def test_invalid_index(self):
        with self.assertRaises(IndexError):
            anchored_features('', 0)

    def test_vocabulary_is_train_row_frequency(self):
        vocab = build_vocabulary([['z', 'a', 'a'], ['z', 'b']], limit=2)
        self.assertEqual(vocab, ['a', 'z'])

    def test_128_golden_vectors(self):
        lm = LinearLanguageModel(load('fixtures/language_model_fixture.json'), allow_fixture=True)
        golden = load('fixtures/feature_golden.json')['vectors']
        self.assertEqual(len(golden), 128)
        for vector in golden:
            with self.subTest(raw=vector['raw'], index=vector['index']):
                self.assertEqual(anchored_features(vector['raw'], vector['index']), vector['features'])
                score = lm.score(vector['raw'], vector['index'])
                self.assertEqual(score['active_indices'], vector['active_indices'])
                self.assertAlmostEqual(score['logit'], vector['logit'], places=12)
                self.assertAlmostEqual(score['p_ja'], vector['p_ja'], places=12)

class ModelTests(unittest.TestCase):
    def test_sigmoid_extremes(self):
        self.assertEqual(stable_sigmoid(1000), 1)
        self.assertEqual(stable_sigmoid(-1000), 0)
        self.assertEqual(stable_sigmoid(0), 0.5)

    def test_fixture_rejected_by_default(self):
        with self.assertRaises(ValueError):
            LinearLanguageModel(load('fixtures/language_model_fixture.json'))

    def test_corrupt_numeric_rejected(self):
        model = load('fixtures/language_model_fixture.json')
        model['coefficients'][0] = float('nan')
        with self.assertRaises(ValueError):
            validate_model(model, allow_fixture=True)

    def test_mismatched_coefficients_rejected(self):
        model = load('fixtures/language_model_fixture.json')
        model['coefficients'].pop()
        with self.assertRaises(ValueError):
            validate_model(model, allow_fixture=True)

class DecoderTests(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(viterbi([]), [])

    def test_tie_prefers_raw(self):
        self.assertEqual(viterbi([.5] * 5, 0), ['RAW'] * 5)

    def test_forced_mask(self):
        self.assertEqual(viterbi([.999, .999], forced=['RAW', 'RAW']), ['RAW', 'RAW'])

    def test_unregularized(self):
        self.assertEqual(viterbi([.1, .9, .1], 0), ['RAW', 'JA_ROMAN', 'RAW'])

    def test_regularization_reduces_isolated_switch(self):
        self.assertEqual(viterbi([.1, .6, .1], 1.2), ['RAW'] * 3)

    def test_cost_matches_brute_force(self):
        rng = random.Random(42)
        for n in range(1, 8):
            for _ in range(15):
                ps = [rng.choice([.05, .3, .5, .7, .95]) for _ in range(n)]
                penalty = rng.choice([0, .4, 1.2, 2.0])
                mask = [rng.choice([None, None, 'RAW', 'JA_ROMAN']) for _ in range(n)]
                def cost(path):
                    if any(m is not None and m != label for m, label in zip(mask, path)):
                        return math.inf
                    emission = sum(-math.log(p if l == 'JA_ROMAN' else 1-p) for l,p in zip(path, ps))
                    return emission + penalty * sum(path[i] != path[i-1] for i in range(1,n))
                got = viterbi(ps, penalty, mask)
                best = min(cost(path) for path in itertools.product(LABELS, repeat=n))
                self.assertAlmostEqual(cost(got), best, places=10)

    def test_invalid_probability(self):
        with self.assertRaises(ValueError):
            viterbi([float('nan')])
        with self.assertRaises(ValueError):
            viterbi([.5], -1)

class RecordTests(unittest.TestCase):
    def records(self):
        return [json.loads(line) for line in (ROOT/'fixtures/span_cases.jsonl').read_text(encoding='utf-8').splitlines()]

    def test_all_50_records(self):
        records = self.records()
        self.assertEqual(len(records), 50)
        validate_record_set(records)

    def test_reject_overlap(self):
        record = self.records()[0]
        record['spans'][1]['start'] -= 1
        with self.assertRaises(ValueError):
            validate_span_record(record)

    def test_reject_group_split_leak(self):
        records = self.records()[:2]
        records[1]['group_id'] = records[0]['group_id']
        records[1]['split'] = 'train'
        with self.assertRaises(ValueError):
            validate_record_set(records)

if __name__ == '__main__':
    unittest.main()
