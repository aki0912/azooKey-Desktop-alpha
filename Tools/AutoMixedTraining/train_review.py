"""Fit approved originals with both feature versions and freeze a local diagnostic run."""
import argparse
from pathlib import Path

from build_review_report import build_report
from dataset import build_dataset, load_sources
from learning import VERSIONS, train
from pipeline_io import HERE, read, require, write_new


def run(manifest, output):
    output = Path(output)
    require(not output.exists(), "review output already exists")
    source, _ = load_sources(manifest)
    require(source["mode"] == "approved", "review training requires approved originals")
    data = build_dataset(manifest)
    write_new(output / "dataset.json", data)
    for name, version in zip(("v1", "v2"), VERSIONS):
        config = dict(read(HERE / "training_config.json"), feature_spec_version=version, seed=source["seed"])
        write_new(output / name / "config.json", config)
        write_new(output / name / "fitted.json", train(data, config))
        print(name + " LR fitted; no release quality claim.", flush=True)
    build_report(output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=HERE / "approved_samples/manifest.json")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    run(args.manifest, args.output)
