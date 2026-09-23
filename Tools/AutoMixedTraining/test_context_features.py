import copy
import json
from pathlib import Path
import unittest

from context_features import (
    ROOT, anchored_features, contextual_features, record_context, validate_context_records,
)
from generate_context_golden import make_golden

HERE = Path(__file__).resolve().parent


class ContextContractTests(unittest.TestCase):
    def test_frozen_golden_and_v1_subset(self):
        golden = json.loads((HERE / "fixtures/feature_v2_golden.json").read_text())
        self.assertEqual(golden, make_golden(compact=True))
        self.assertEqual(len(golden["vectors"]), 128)
        for vector in make_golden()["vectors"]:
            self.assertEqual([key for key in vector["features"] if not key.startswith('["ctx",')],
                             anchored_features(vector["raw"], vector["index"]))
            self.assertEqual(len(set(vector["features"])), len(vector["features"]))

    def test_missing_empty_whitespace_and_scalar_bound(self):
        self.assertNotEqual(contextual_features("made", 0), contextual_features("made", 0, ""))
        self.assertNotEqual(contextual_features("made", 0, "I "), contextual_features(" made", 1, "I"))
        context = "older-prefix" + "👩‍💻e\u0301" * 8 + " "
        self.assertEqual(contextual_features("made", 0, context), contextual_features("made", 0, context[-30:]))
        self.assertNotEqual(contextual_features("made", 0, "é"), contextual_features("made", 0, "e\u0301"))

    def test_contrast_records_are_intent_contracts_and_keep_groups(self):
        records = [json.loads(line) for line in
                   (ROOT / "docs/azookey_auto_mixed_codex/fixtures/context_pairs.jsonl").read_text().splitlines()]
        validate_context_records(records)
        self.assertEqual(len(records), 5)
        contrast = [record for record in records if record["raw"] == "made"]
        self.assertEqual(len(contrast), 3)
        self.assertEqual(len({record["group_id"] for record in contrast}), 1)
        self.assertEqual({record_context(record) for record in contrast}, {"I ", "明日", None})
        self.assertEqual({record["spans"][0]["label"] for record in contrast}, {"RAW", "JA_ROMAN", "AMBIGUOUS"})
        split_leak = copy.deepcopy(records)
        split_leak[0]["split"] = "train"
        with self.assertRaises(ValueError):
            validate_context_records(split_leak)
        # All prefix variants inherit group_id, hence cannot be moved to a different split.
        prefix = copy.deepcopy(records[0])
        prefix.update(id="prefix", raw="ma", split="test", spans=[dict(start=0, end=2, label="RAW")])
        with self.assertRaises(ValueError):
            validate_context_records(records + [prefix])

    def test_old_records_default_to_missing_and_invalid_context_is_rejected(self):
        self.assertIsNone(record_context({}))
        self.assertEqual(record_context(dict(context_available=True, left_context="")), "")
        for invalid in [dict(context_available=True), dict(left_context="I "),
                        dict(context_available=False, left_context=""), dict(context_available=1),
                        dict(context_available=True, left_context="x" * 31),
                        dict(context_available=True, left_context="\ud800")]:
            with self.assertRaises(ValueError):
                record_context(invalid)

    def test_artifact_schema_and_fixture_kind(self):
        import jsonschema
        schema = json.loads((HERE / "language_model_v2.schema.json").read_text())
        jsonschema.Draft202012Validator.check_schema(schema)
        model = json.loads((HERE / "fixtures/language_model_v2_fixture.json").read_text())
        jsonschema.validate(model, schema)
        self.assertEqual(model["kind"], "fixture")
        self.assertEqual(model["feature_spec_version"], "anchored-context-v2")
        model["schema_version"] = 1
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(model, schema)


if __name__ == "__main__":
    unittest.main()
