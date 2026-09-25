"""Fit nested train groups and score fixed dev data without test evaluation or model export."""
import argparse
from pathlib import Path
from time import perf_counter

from dataset import load_dataset
from learning import VERSIONS, fit_lr, log_loss, matrix, rows_for, vocabulary
from pipeline_io import HERE, fingerprint, read, require, write_new


def training_subsets(data, sizes=(100, 250)):
    rows = rows_for(data, "train")
    component = lambda row: data["groups"][row["record"]["group_id"]]["component"]
    groups = sorted({component(row) for row in rows}, key=lambda group: fingerprint([data["seed"], "size-probe", group]))
    for count in sorted({min(size, len(groups)) for size in (*sizes, len(groups))}):
        selected = set(groups[:count])
        yield count, [row for row in rows if component(row) in selected]


def probe(data_path, output):
    require(not Path(output).exists(), "learning-size report already exists")
    data = load_dataset(data_path)
    config = dict(read(HERE / "training_config.json"), feature_spec_version=VERSIONS[1], seed=data["seed"])
    dev = rows_for(data, "dev", True)
    trials = []
    for count, training in training_subsets(data):
        started = perf_counter()
        vocab = vocabulary(training, VERSIONS[1], config["vocabulary_max_features"])
        x, y, weights = matrix(training, VERSIONS[1], vocab)
        dx, dy, dw = matrix(dev, VERSIONS[1], vocab)
        estimator = fit_lr(x, y, weights, 1.0, config)
        trials.append(dict(train_groups=count, train_originals=len({row["original_id"] for row in training}),
                           train_rows=len(training), train_positions=len(y), vocabulary=len(vocab),
                           train_log_loss=log_loss(estimator.decision_function(x), y, weights),
                           dev_log_loss=log_loss(estimator.decision_function(dx), dy, dw),
                           elapsed_seconds=perf_counter() - started))
        print(f"Size probe completed for {count} training groups.", flush=True)
    write_new(output, dict(schema_version=1, kind="synthetic_dev_size_diagnostic", release_ready=False,
        dataset_sha256=data["dataset_sha256"], feature_spec_version=VERSIONS[1], C=1.0,
        calibration="none", selection="nested train components; fixed dev originals; no test scores",
        weighting="one per original across variants/prefixes and eligible positions", trials=trials,
        limitations=["single seed", "authored synthetic distribution", "dev already used for model development",
                     "no decoder/threshold selection", "cannot establish a required production sample size"]))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    probe(args.data, args.output)
