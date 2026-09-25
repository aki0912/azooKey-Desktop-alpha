"""Fit current-raw symbol coefficients against a fixed calibrated LR baseline.

This is a constrained LR fit, not a spelling rule or a runtime model switch.
Non-symbol coefficients/keys, context features and decoder policy stay exact.
Dev selects L2 strength; a separate calibration partition scales only the residual.
"""
import argparse
from collections import Counter, defaultdict
import copy
import json
from pathlib import Path
import string
from time import perf_counter

import numpy as np
from scipy.optimize import minimize
from scipy.special import expit
from threadpoolctl import threadpool_limits

from dataset import load_dataset
from context_features import anchored_features
from learning import matrix, positions, rows_for, seal, validate_model
from pipeline import export
from pipeline_io import digest, environment, fingerprint, read, require, write_new


def symbol_feature(key):
    feature = json.loads(key)
    if feature[0] not in ("char", "ngram"):
        return False

    def contains(value):
        return (isinstance(value, list) and
                ((len(value) == 2 and value[0] == "CHAR" and isinstance(value[1], str)
                  and value[1] in string.punctuation) or any(contains(v) for v in value)))
    return contains(feature)


def objective(delta, x, target, weights, offset, strength):
    logits = offset + np.asarray(x @ delta).ravel()
    value = np.sum(weights * (np.logaddexp(0, logits) - target * logits)) + np.dot(delta, delta) / (2 * strength)
    gradient = np.asarray(x.T @ (weights * (expit(logits) - target))).ravel() + delta / strength
    return float(value), gradient


def optimize(x, target, weights, offset, strength):
    with threadpool_limits(limits=1):
        result = minimize(objective, np.zeros(x.shape[1]), args=(x, target, weights, offset, strength),
                          jac=True, method="L-BFGS-B", options=dict(maxiter=1000, ftol=1e-12, gtol=1e-8))
    require(result.success and np.all(np.isfinite(result.x)), "symbol LR optimization failed")
    return result.x


def refresh_symbols(base, training):
    """Use the existing symbol slots for train-only symbol features; keep all other keys."""
    per_original = defaultdict(set)
    for row in training:
        record = row["record"]
        if not any(char in string.punctuation for char in record["raw"]):
            continue
        for index, _ in positions(record):
            per_original[row["original_id"]].update(k for k in anchored_features(record["raw"], index) if symbol_feature(k))
    counts = Counter(k for keys in per_original.values() for k in keys)
    old = dict(zip(base["vocabulary"], base["coefficients"]))
    frozen = {k: v for k, v in old.items() if not symbol_feature(k)}
    slots = len(old) - len(frozen)
    keys = sorted(counts, key=lambda k: (-counts[k], k.encode("utf-8")))[:slots]
    require(len(keys) == slots, "not enough symbol features for fixed vocabulary budget")
    working = copy.deepcopy(base)
    working["vocabulary"] = sorted([*frozen, *keys], key=lambda k: k.encode("utf-8"))
    # The fresh fit learns absolute symbol coefficients around a frozen non-symbol offset.
    working["coefficients"] = [frozen.get(k, 0.0) for k in working["vocabulary"]]
    return working


def run(dataset, base_path, output, refresh_vocabulary=False):
    output = Path(output)
    require(not output.exists(), "symbol refit output already exists")
    started, timings = perf_counter(), {}
    data, base = load_dataset(dataset), read(base_path)
    validate_model(base)
    require(data["mode"] == "approved" and base["kind"] == "production"
            and base["feature_spec_version"] == "anchored-context-v2", "approved v2 baseline required")
    if refresh_vocabulary:
        phase = perf_counter()
        base = refresh_symbols(base, rows_for(data, "train"))
        timings["train_only_symbol_vocabulary"] = perf_counter() - phase
    selected = [i for i, key in enumerate(base["vocabulary"]) if symbol_feature(key)]
    require(selected, "baseline has no symbol features")
    coefficient = np.array(base["coefficients"])
    phase = perf_counter()
    prepared = {}
    for split in ("train", "dev", "calibration"):
        rows = rows_for(data, split, originals_only=split != "train")
        x, target, weights = matrix(rows, base["feature_spec_version"], base["vocabulary"])
        offset = base["calibration"]["a"] * (np.asarray(x @ coefficient).ravel() + base["intercept"]) + base["calibration"]["c"]
        active = x[:, selected]
        effective = np.asarray(active.getnnz(axis=1)) > 0
        require(all(np.count_nonzero(effective & (target == label)) >= 100 for label in (0, 1)),
                "symbol fitting/calibration needs at least 100 affected positions per class in every partition")
        prepared[split] = active, target, weights, offset
    timings["prepare_train_dev_calibration"] = perf_counter() - phase
    phase = perf_counter()
    tx, ty, tw, tz = prepared["train"]
    dx, dy, dw, dz = prepared["dev"]
    trials = []
    for strength in (0.1, 1.0, 10.0):
        delta = optimize(tx, ty, tw, tz, strength)
        loss = objective(delta, dx, dy, dw, dz, np.inf)[0] / dw.sum()
        trials.append((loss, strength, delta))
    loss, strength, delta = min(trials, key=lambda trial: trial[:2])
    timings["fit_and_dev_selection"] = perf_counter() - phase
    print("Constrained symbol LR fitted; non-symbol parameters preserved.", flush=True)
    phase = perf_counter()
    cx, cy, cw, cz = prepared["calibration"]
    residual = np.asarray(cx @ delta).ravel()[:, None]
    with threadpool_limits(limits=1):
        scale = minimize(objective, np.ones(1), args=(residual, cy, cw, cz, np.inf), jac=True,
                         method="L-BFGS-B", bounds=[(0, None)],
                         options=dict(maxiter=1000, ftol=1e-12, gtol=1e-8))
    require(scale.success and np.isfinite(scale.x[0]) and scale.x[0] > 0, "symbol residual calibration failed")
    timings["residual_calibration"] = perf_counter() - phase
    model = copy.deepcopy(base)
    for index, change in zip(selected, scale.x[0] * delta / base["calibration"]["a"]):
        model["coefficients"][index] += float(change)
    manifest = dict(dataset_sha256=data["dataset_sha256"], source_manifest_sha256=data["source_manifest_sha256"],
        source_manifest=data["source_manifest"], groups=data["groups"], environment=environment(),
        roman_revision=data["roman_revision"], roman_table_sha256=data["roman_table_sha256"],
        sample_weight="each original contributes total weight 1 across eligible positions and derived rows",
        vocabulary_partition="train symbols + frozen other keys" if refresh_vocabulary else "frozen previous train vocabulary",
        selection_partition="dev",
        symbol_refit=dict(base_model_sha256=digest(Path(base_path).read_bytes()), algorithm="fixed-calibrated-offset-lr-v2" if refresh_vocabulary else "fixed-calibrated-offset-lr-v1",
            trainable_features=len(selected), feature_rule="current-raw char/ngram containing ASCII punctuation",
            frozen=["other coefficients and keys", "intercept", "context features", "decoder", "thresholds", "base calibration"],
            chosen_C=strength, residual_scale=float(scale.x[0]), calibration_partition="calibration"))
    model["training_manifest_sha256"] = fingerprint(manifest)
    model["model_version"] = "offline-symbol-refit-" + model["training_manifest_sha256"][:16]
    validate_model(model)
    checkpoint = seal(dict(schema_version=1, phase="calibrated", mode="approved", dataset_sha256=data["dataset_sha256"],
        training_manifest=manifest, model=model, release_ready=False,
        fit_report=dict(selected_dev_log_loss=loss, C_trials=[dict(C=c, dev_log_loss=l) for l, c, _ in trials]),
        calibration_report=dict(partition="calibration", method="nonnegative residual scale with fixed baseline offset",
                                residual_scale=float(scale.x[0]), quality_claim=False)))
    write_new(output / "calibrated.json", checkpoint)
    phase = perf_counter()
    export(checkpoint, output / "export")
    timings["export"] = perf_counter() - phase
    timings["total"] = perf_counter() - started
    write_new(output / "timings.json", dict(clock="perf_counter", seconds=timings, test_evaluated=False))
    print("Calibrated symbol candidate exported; test unopened; release_ready=false.", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--base-model", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--refresh-symbol-vocabulary", action="store_true")
    args = parser.parse_args()
    run(args.data, args.base_model, args.output, args.refresh_symbol_vocabulary)
