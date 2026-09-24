import contextlib
import copy
import http.client
import io
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest

from build_review_report import build_report
from dataset import load_dataset, load_sources, near_key
from learning import calibrate, evaluate, load_checkpoint, matrix, rows_for
from pipeline import export
from pipeline_io import HERE, PipelineError, read
from review_server import make_server
from review_support import ReviewSession, make_report, protection_masks, validate_input
from train_review import run


class ReviewInputTests(unittest.TestCase):
    def test_approval_changes_only_provenance_and_preserves_reviewed_source(self):
        manifest, validated = load_sources(HERE / "approved_samples/manifest.json")
        approved = [json.loads(line) for line in (HERE / "approved_samples/samples_50.jsonl").read_text().splitlines()]
        original = [json.loads(line) for line in (HERE / "review_samples/samples_50.jsonl").read_text().splitlines()]
        self.assertEqual(manifest["mode"], "approved")
        self.assertEqual(len(validated), 50)
        self.assertEqual(len(approved), 50)
        for before, after in zip(original, approved):
            self.assertEqual(before["provenance"]["rights_status"], "pending_review")
            self.assertEqual(after["provenance"]["rights_status"], "approved")
            self.assertEqual({k: v for k, v in before.items() if k != "provenance"},
                             {k: v for k, v in after.items() if k != "provenance"})

    def test_live_input_preserves_unicode_and_distinguishes_unavailable_from_empty(self):
        for context in ({"context_available": False}, {"context_available": True, "left_context": ""},
                        {"context_available": True, "left_context": "あ" * 30}):
            payload = dict(raw="👩‍💻e\u0301shi", **context)
            self.assertEqual(validate_input(payload), payload)
        for invalid in [None, [], {}, dict(raw="", context_available=False),
                        dict(raw="a" * 257, context_available=False), dict(raw="\ud800", context_available=False),
                        dict(raw="made", context_available=1), dict(raw="made", context_available=True),
                        dict(raw="made", context_available=True, left_context="a" * 31),
                        dict(raw="made", context_available=False, left_context="PRIVATE"),
                        dict(raw="made", context_available=False, extra=True)]:
            with self.assertRaises((ValueError, TypeError)):
                validate_input(invalid)

    def test_runner_refuses_overwrite_and_fixture_without_training(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaisesRegex(PipelineError, "already exists"):
                run(HERE / "approved_samples/manifest.json", folder)
            output = Path(folder) / "fixture"
            with self.assertRaisesRegex(PipelineError, "approved originals"):
                run(HERE / "fixture_manifest.json", output)
            self.assertFalse(output.exists())


@unittest.skipUnless(os.environ.get("AUTO_MIXED_REVIEW_RUN"), "Set the approved review run to exercise fitted models")
class ApprovedReviewTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.review_run = Path(os.environ["AUTO_MIXED_REVIEW_RUN"])
        cls.session = ReviewSession(cls.review_run)
        cls.data = load_dataset(cls.review_run / "dataset.json")

    def test_live_predictions_match_frozen_report_for_all_50_originals(self):
        self.assertEqual(len(self.session.report["samples"]), 50)
        for sample in self.session.report["samples"]:
            payload = dict(raw=sample["raw"], context_available=sample["context_available"])
            if payload["context_available"]:
                payload["left_context"] = sample["left_context"]
            self.assertEqual(self.session.infer(payload)["models"], sample["predictions"])

    def test_real_core_protection_agrees_for_all_augmented_rows_and_prefixes(self):
        rows = self.data["rows"]
        masks = protection_masks(self.session.executable, [row["record"]["raw"] for row in rows])
        self.assertEqual(masks, [row["protections"] for row in rows])
        prefix, full = protection_masks(self.session.executable, ["https:", "https://example.invalid/a"])
        self.assertNotEqual(prefix, full[:len(prefix)])  # A URL's future tail must not protect its prefix.
        result = self.session.infer(dict(raw="👩‍💻e\u0301desu", context_available=False))
        self.assertEqual(result["protections"][:5], ["literal"] * 5)
        for output in result["models"].values():
            self.assertEqual(len(output["scores"]), 9)
            self.assertEqual(output["labels"][:5], ["LITERAL"] * 5)

    def test_v1_context_compatibility_and_live_input_is_not_persisted(self):
        before = {p: p.read_bytes() for p in self.review_run.rglob("*") if p.is_file()}
        original_report = copy.deepcopy(self.session.report)
        outputs = [self.session.infer(dict(raw="made", **context)) for context in (
            dict(context_available=False), dict(context_available=True, left_context=""),
            dict(context_available=True, left_context="PRIVATE-CONTEXT"))]
        self.assertEqual(outputs[0]["models"]["v1"], outputs[1]["models"]["v1"])
        self.assertEqual(outputs[0]["models"]["v1"], outputs[2]["models"]["v1"])
        self.assertEqual(self.session.report, original_report)
        self.assertEqual({p: p.read_bytes() for p in self.review_run.rglob("*") if p.is_file()}, before)
        self.assertNotIn("PRIVATE-CONTEXT", json.dumps(outputs))

    def test_calibration_gate_and_official_export_evaluation_remain_strict(self):
        report = self.session.report
        self.assertEqual(report["partitions"]["calibration"]["ja_positions"], 45)
        self.assertEqual(report["partitions"]["calibration"]["raw_positions"], 36)
        self.assertFalse(report["release_ready"])
        checkpoints = {}
        for name in ("v1", "v2"):
            cp = load_checkpoint(self.review_run / name / "fitted.json", self.data)
            checkpoints[name] = cp
            self.assertEqual(report["models"][name]["phase"], "fitted")
            self.assertEqual(report["models"][name]["calibration"]["status"], "blocked")
            with self.assertRaisesRegex(PipelineError, "insufficient examples"):
                calibrate(cp, self.data)
            with self.assertRaisesRegex(PipelineError, "calibrated checkpoint"):
                evaluate(cp, self.data)
            with tempfile.TemporaryDirectory() as folder:
                with self.assertRaisesRegex(PipelineError, "calibrated checkpoint"):
                    export(cp, Path(folder) / "export")
            self.assertFalse((self.review_run / name / "calibrated.json").exists())
            self.assertFalse((self.review_run / name / "export").exists())
        self.assertEqual(make_report(self.data, checkpoints, {n: report["models"][n]["calibration"] for n in checkpoints}), report)
        with self.assertRaisesRegex(PipelineError, "already frozen"):
            build_report(self.review_run)

    def test_actual_split_has_no_cross_partition_raw_or_group_leakage_and_unit_weight(self):
        from collections import defaultdict
        owners, weights_by_original = defaultdict(set), defaultdict(float)
        for row in self.data["rows"]:
            record = row["record"]
            owners[near_key(record["raw"])].add(record["split"])
            self.assertEqual(record["split"], self.data["groups"][record["group_id"]]["split"])
        self.assertTrue(all(len(splits) == 1 for splits in owners.values()))
        self.assertEqual(len(self.data["rows"]), 309)
        from learning import positions
        for model in self.session.models.values():
            training = rows_for(self.data, "train")
            _, _, weights = matrix(training, model["feature_spec_version"], model["vocabulary"])
            weights_by_original.clear()
            offset = 0
            for row in training:
                end = offset + len(list(positions(row["record"])))
                weights_by_original[row["original_id"]] += sum(weights[offset:end])
                offset = end
            for weight in weights_by_original.values():
                self.assertTrue(weight == 0 or abs(weight - 1) < 1e-12)

    def test_http_origin_input_errors_and_logs_do_not_expose_live_input(self):
        with make_server(self.session) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                def request(method, path, payload=None, headers=None):
                    connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=10)
                    connection.request(method, path, body=payload, headers=headers or {})
                    response = connection.getresponse()
                    result = (response.status, dict(response.getheaders()), response.read())
                    connection.close()
                    return result
                logs = io.StringIO()
                with contextlib.redirect_stderr(logs):
                    status, headers, body = request("GET", "/api/report")
                    self.assertEqual(status, 200)
                    self.assertEqual(json.loads(body), self.session.report)
                    self.assertEqual(headers["Cache-Control"], "no-store")
                    self.assertNotIn("Access-Control-Allow-Origin", headers)
                    self.assertEqual(request("GET", "/../approved_samples/samples_50.jsonl")[0], 404)
                    self.assertEqual(request("GET", "/", headers={"Host": "other.invalid"})[0], 403)
                    self.assertEqual(request("GET", "/", headers={"Origin": "https://other.invalid"})[0], 403)
                    payload = json.dumps(dict(raw="made", context_available=True, left_context="PRIVATE-CONTEXT"))
                    status, _, body = request("POST", "/api/infer", payload, {"Content-Type": "application/json"})
                    self.assertEqual(status, 200)
                    self.assertNotIn(b"PRIVATE-CONTEXT", body)
                    for payload in ('{"PRIVATE-CONTEXT":', '{"raw":"a","raw":"b"}', '"PRIVATE-CONTEXT"'):
                        status, _, body = request("POST", "/api/infer", payload, {"Content-Type": "application/json"})
                        self.assertEqual(status, 400)
                        self.assertNotIn(b"PRIVATE-CONTEXT", body)
                    self.assertEqual(request("POST", "/api/infer", "{}", {"Content-Type": "text/plain"})[0], 400)
                    self.assertEqual(request("POST", "/api/infer", "x" * 16385, {"Content-Type": "application/json"})[0], 400)
                self.assertEqual(logs.getvalue(), "")
            finally:
                server.shutdown()
                thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
