"""Validate build inputs without compiling, packaging, or installing an IME."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_mixed_ime as builder
from prepare_auto_mixed_ime_build import validate_model_header


class BuildTests(unittest.TestCase):
    def test_unsupported_models_fail_before_building_or_changing_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            model = root / "model.json"
            for value in [
                {"kind": "production", "schema_version": 1, "feature_spec_version": "anchored-char-v1"},
                {"kind": "fixture", "schema_version": 2, "feature_spec_version": "anchored-context-v2"},
                {"kind": "production", "schema_version": 2, "feature_spec_version": "unknown"},
                [],
            ]:
                with self.subTest(model=value):
                    model.write_text(json.dumps(value))
                    with patch.object(builder, "run") as run, patch.object(builder, "OUTPUT", root / "output"):
                        with self.assertRaisesRegex(ValueError, "trained v2 runtime export"):
                            builder.build(model, root / "resources")
                    run.assert_not_called()
                    self.assertFalse((root / "output").exists())

    def test_header_accepts_v2_and_rejects_oversized_or_invalid_json(self):
        with tempfile.TemporaryDirectory() as temporary:
            model = Path(temporary) / "model.json"
            model.write_text(json.dumps({"kind": "production", "schema_version": 2,
                                         "feature_spec_version": "anchored-context-v2"}))
            validate_model_header(model)
            model.write_text("invalid json")
            with self.assertRaises(ValueError):
                validate_model_header(model)
            with model.open("wb") as file:
                file.truncate(5 * 1024 * 1024 + 1)
            with self.assertRaisesRegex(ValueError, "size limit"):
                validate_model_header(model)

    def test_cli_requires_an_explicit_model(self):
        result = subprocess.run([sys.executable, str(Path(builder.__file__))], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("--model", result.stderr)


if __name__ == "__main__":
    unittest.main()
