"""Train/calibrate/export a separate v2 candidate without opening the test partition."""
import argparse
from collections import Counter
from pathlib import Path
from time import perf_counter

from dataset import build_dataset
from learning import calibrate, train
from pipeline import export
from pipeline_io import read, require, write_new
from typing_evaluation import evaluate_typing


def run(manifest, baseline, config_path, output):
    output = Path(output)
    require(not output.exists(), "training output already exists")
    config = read(config_path)
    require(config["feature_spec_version"] == "anchored-context-v2", "preserve the current v2 feature contract")
    started = perf_counter()
    timings = dict(clock="perf_counter", seconds={}, test_evaluated=False)
    phase = perf_counter()
    data = build_dataset(manifest, baseline)
    write_new(output / "dataset.json", data)
    write_new(output / "config.json", config)
    timings["seconds"]["dataset_and_swift_validation"] = perf_counter() - phase
    write_new(output / "inventory.json", dict(rows=len(data["rows"]),
        originals=sum(r["augmentation"] == "original" for r in data["rows"]),
        augmentations=dict(Counter(r["augmentation"] for r in data["rows"])),
        original_splits=dict(Counter(r["record"]["split"] for r in data["rows"] if r["augmentation"] == "original")),
        baseline_dataset_sha256=data["baseline_dataset_sha256"], dataset_sha256=data["dataset_sha256"],
        pruned_cross_split_augmentations=data["pruned_cross_split_augmentations"]))
    print("Dataset and Swift reading/protection validation completed.", flush=True)
    phase = perf_counter()
    fitted = train(data, config)
    write_new(output / "fitted.json", fitted)
    timings["seconds"]["fit_and_dev_selection"] = perf_counter() - phase
    print("LR fit and dev regularization selection completed.", flush=True)
    phase = perf_counter()
    calibrated = calibrate(fitted, data)
    write_new(output / "calibrated.json", calibrated)
    timings["seconds"]["calibration_and_dev_thresholds"] = perf_counter() - phase
    phase = perf_counter()
    export(calibrated, output / "export")
    timings["seconds"]["export"] = perf_counter() - phase
    phase = perf_counter()
    write_new(output / "typing_dev.json", evaluate_typing(data, output / "export/model.json"))
    timings["seconds"]["runtime_typing_dev"] = perf_counter() - phase
    timings["seconds"]["total"] = perf_counter() - started
    write_new(output / "timings.json", timings)
    print("Separate candidate exported with runtime typing dev report; test unopened; release_ready=false.", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    run(args.manifest, args.baseline, args.config, args.output)
