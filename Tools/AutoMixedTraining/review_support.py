"""Read-only review of fitted checkpoints; live input stays in process memory."""
from collections import Counter
from pathlib import Path
import json
import subprocess

from context_features import check_scalar_text, record_context
from dataset import load_dataset
from learning import VERSIONS, decode, labels, load_checkpoint, metrics, positions, rows_for, score_record
from pipeline_io import HERE, ROOT, SPLITS, digest, fields, read, require

DETECTOR = ROOT / "Core/Sources/Core/AutoMixed/ProtectedSpanDetector.swift"
BRIDGE = HERE / "ProtectionBridge/main.swift"


def protection_executable():
    key = digest(DETECTOR.read_bytes() + BRIDGE.read_bytes())[:20]
    output = ROOT / "build/auto-mixed/review-bridge" / key
    if not output.is_file():
        output.parent.mkdir(parents=True, exist_ok=True)
        cache = ROOT / "build/auto-mixed/clang-cache"
        result = subprocess.run(["swiftc", "-module-cache-path", str(cache), str(DETECTOR), str(BRIDGE),
                                 "-o", str(output)], capture_output=True, timeout=120)
        require(result.returncode == 0, "cannot compile the local Core protection bridge")
    return output


def protection_masks(executable, raws):
    result = subprocess.run([str(executable)], input=json.dumps(raws, ensure_ascii=True).encode(),
                            capture_output=True, timeout=15)
    require(result.returncode == 0, "Core protection bridge failed")
    masks = json.loads(result.stdout)
    require(len(masks) == len(raws), "protection response count differs")
    for raw, mask in zip(raws, masks):
        require(len(mask) == len(raw) and set(mask) <= {"inferred", "raw", "literal", "gap"}, "invalid protection mask")
    return masks


def validate_input(payload):
    fields(payload, ("raw", "context_available"), ("left_context",))
    check_scalar_text(payload["raw"])
    require(1 <= len(payload["raw"]) <= 256, "raw must contain 1 to 256 Unicode scalars")
    record_context(payload)
    return payload


def prediction(model, record, mask):
    scores = score_record(model, record)
    return dict(labels=decode(model, record, mask, scores),
                scores=[score["p_ja"] for score in scores], logits=[score["logit"] for score in scores])


def partition_summary(data):
    result = {}
    for split in SPLITS:
        originals = rows_for(data, split, True)
        counts = Counter(label for row in originals for _, label in positions(row["record"]))
        result[split] = dict(originals=len(originals), rows=len(rows_for(data, split)),
                             groups=len({data["groups"][row["record"]["group_id"]]["component"] for row in originals}),
                             ja_positions=counts[1], raw_positions=counts[0])
    return result


def make_report(data, checkpoints, calibrations):
    originals = [row for row in data["rows"] if row["augmentation"] == "original"]
    result = dict(schema_version=1, run_kind="approved_small_sample_diagnostic", release_ready=False,
                  dataset_sha256=data["dataset_sha256"], seed=data["seed"], partitions=partition_summary(data),
                  original_count=len(originals), row_count=len(data["rows"]),
                  augmentation_counts=dict(Counter(row["augmentation"] for row in data["rows"])),
                  pruned_cross_split_augmentations=data["pruned_cross_split_augmentations"],
                  limitations=["Small authored sample; not a generalization or release claim",
                               "v1/v2 gates differ; this is not a controlled context ablation",
                               "Test has been exposed for review; do not tune against it",
                               "No Zenzai, IMK, display hysteresis, latency or real-client context evaluation"], models={}, samples=[])
    for name, checkpoint in checkpoints.items():
        model = checkpoint["model"]
        result["models"][name] = dict(phase=checkpoint["phase"], calibration=calibrations[name],
            feature_spec_version=model["feature_spec_version"], model_version=model["model_version"],
            vocabulary_size=len(model["vocabulary"]), fit_report=checkpoint["fit_report"],
            chosen_C=checkpoint["training_manifest"]["chosen_C"], thresholds=model["thresholds"], decoder=model["decoder"],
            metrics_kind="uncalibrated_diagnostic" if checkpoint["phase"] == "fitted" else "calibrated_diagnostic",
            partitions={split: metrics(model, rows_for(data, split, True)) for split in SPLITS})
    for row in originals:
        record = row["record"]
        result["samples"].append(dict(id=row["original_id"], group_id=record["group_id"], split=record["split"],
            raw=record["raw"], category=record["category"], desired_display=record.get("desired_display"),
            context_available=record.get("context_available", False), left_context=record.get("left_context"),
            gold=labels(record), predictions={name: prediction(cp["model"], record, row["protections"])
                                            for name, cp in checkpoints.items()}))
    result["samples"].sort(key=lambda record: record["id"])
    return result


class ReviewSession:
    def __init__(self, run, executable=None):
        self.run = Path(run)
        self.report = read(self.run / "report.json")
        data = load_dataset(self.run / "dataset.json")
        require(data["mode"] == "approved", "review requires approved training data")
        require(data["dataset_sha256"] == self.report["dataset_sha256"], "review dataset mismatch")
        self.models = {}
        for name, version in zip(("v1", "v2"), VERSIONS):
            phase = self.report["models"][name]["phase"]
            require(phase in ("fitted", "calibrated"), "unsupported review phase")
            checkpoint = load_checkpoint(self.run / name / (phase + ".json"), data)
            require(checkpoint["phase"] == phase and checkpoint["model"]["feature_spec_version"] == version,
                    "review checkpoint phase/version mismatch")
            require(checkpoint["model"]["model_version"] == self.report["models"][name]["model_version"], "review model mismatch")
            self.models[name] = checkpoint["model"]
        self.executable = executable or protection_executable()

    def infer(self, payload):
        record = validate_input(payload)
        mask = protection_masks(self.executable, [record["raw"]])[0]
        return dict(protections=mask, models={name: prediction(model, record, mask) for name, model in self.models.items()})
