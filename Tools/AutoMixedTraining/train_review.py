"""Fit approved originals with both feature versions and freeze a local diagnostic run."""
import argparse
from pathlib import Path
from time import perf_counter

from build_review_report import build_report
from dataset import build_dataset, load_sources
from learning import VERSIONS, train
from pipeline_io import HERE, read, require, write_new


def run(manifest, output, baseline=None):
    started = perf_counter()
    timings = dict(schema_version=1, clock="perf_counter", seconds={})
    output = Path(output)
    require(not output.exists(), "review output already exists")
    source, _ = load_sources(manifest)
    require(source["mode"] == "approved", "review training requires approved originals")
    phase = perf_counter()
    data = build_dataset(manifest, baseline)
    write_new(output / "dataset.json", data)
    timings["seconds"]["build_dataset_and_write"] = perf_counter() - phase
    for name, version in zip(("v1", "v2"), VERSIONS):
        config = dict(read(HERE / "training_config.json"), feature_spec_version=version, seed=source["seed"])
        write_new(output / name / "config.json", config)
        phase = perf_counter()
        write_new(output / name / "fitted.json", train(data, config))
        timings["seconds"][name + "_fit_and_write"] = perf_counter() - phase
        print(name + " LR fitted; no release quality claim.", flush=True)
    phase = perf_counter()
    build_report(output)
    timings["seconds"]["calibration_export_and_review"] = perf_counter() - phase
    timings["seconds"]["total"] = perf_counter() - started
    timings["calibration_status"] = {name: read(output / name / "calibration_status.json")["status"] for name in ("v1", "v2")}
    write_new(output / "timings.json", timings)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=HERE / "approved_samples/manifest.json")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--baseline", type=Path, help="preserve all original records and partitions of this sealed dataset")
    args = parser.parse_args()
    run(args.manifest, args.output, args.baseline)
