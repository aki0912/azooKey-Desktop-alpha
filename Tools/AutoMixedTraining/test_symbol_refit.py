import unittest

import numpy as np
from scipy.sparse import csr_matrix

from refit_symbol_features import objective, optimize, refresh_symbols, symbol_feature


class SymbolRefitTests(unittest.TestCase):
    def test_refreshed_vocabulary_uses_training_symbols_and_preserves_other_coefficients(self):
        base = dict(vocabulary=['["char",0,["CHAR","a"]]', '["char",1,["CHAR","!"]]'], coefficients=[2.0, -1.0])
        row = dict(original_id="a", record=dict(raw="a.", spans=[dict(start=0, end=1, label="JA_ROMAN"), dict(start=1, end=2, label="LITERAL")]))
        refreshed = refresh_symbols(base, [row])
        weights = dict(zip(refreshed["vocabulary"], refreshed["coefficients"]))
        self.assertEqual(len(weights), 2)
        self.assertEqual(weights['["char",0,["CHAR","a"]]'], 2.0)
        self.assertTrue(any('"."' in k for k in weights))
        self.assertEqual(base["coefficients"], [2.0, -1.0])

    def test_only_actual_current_raw_symbol_keys_are_trainable(self):
        for key in ['["char",1,["CHAR","."]]', '["ngram",2,0,[["CHAR","e"],["CHAR",","]]]']:
            self.assertTrue(symbol_feature(key))
        for key in ['["char",0,["CHAR","a"]]', '["shape",1,"ascii_other"]', '["char",1,["EOS"]]',
                    '["char",0,["CHAR"," "]]', '["ctx","char",-1,["CHAR","."]]']:
            self.assertFalse(symbol_feature(key))

    def test_gradient_matches_finite_difference_and_zero_features_keep_offset(self):
        x = csr_matrix([[1., 0.], [0., 2.], [1., 1.], [0., 0.]])
        y, w, offset = np.array([1., 0., 1., 0.]), np.array([.2, .4, .3, .1]), np.array([-.3, .7, .1, 2.])
        delta = np.array([.2, -.4])
        _, gradient = objective(delta, x, y, w, offset, 2.)
        for i in range(2):
            plus, minus = delta.copy(), delta.copy()
            plus[i] += 1e-5
            minus[i] -= 1e-5
            numerical = (objective(plus, x, y, w, offset, 2.)[0] - objective(minus, x, y, w, offset, 2.)[0]) / 2e-5
            self.assertAlmostEqual(gradient[i], numerical, places=8)
        fitted = optimize(x, y, w, offset, 2.)
        self.assertLess(objective(fitted, x, y, w, offset, 2.)[0], objective(np.zeros(2), x, y, w, offset, 2.)[0])
        self.assertEqual((offset + x @ fitted)[3], offset[3])


if __name__ == "__main__":
    unittest.main()
