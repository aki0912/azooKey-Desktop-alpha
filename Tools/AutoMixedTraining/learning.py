"""CPU LR fitting and sigmoid calibration; fixture runs cannot produce production models."""
from collections import Counter, defaultdict
import copy
import math
import warnings

import jsonschema
import numpy as np
from scipy.sparse import csr_matrix
from sklearn.exceptions import ConvergenceWarning
from sklearn.linear_model import LogisticRegression
from threadpoolctl import threadpool_limits

from context_features import anchored_features, contextual_features, record_context
from auto_mixed_reference import stable_sigmoid, viterbi
from dataset import load_dataset
from pipeline_io import (HERE, ROOT, SPLITS, encoded, environment, fields, fingerprint,
                         integer, number, read, require)

VERSIONS = ("anchored-char-v1", "anchored-context-v2")


def features(record, index, version):
    if version == VERSIONS[0]:
        return anchored_features(record["raw"], index)
    require(version == VERSIONS[1], "unknown feature specification")
    return contextual_features(record["raw"], index, record_context(record))


def labels(record):
    return [span["label"] for span in record["spans"] for _ in range(span["start"], span["end"])]


def positions(record):
    return [(i, int(label == "JA_ROMAN")) for i, label in enumerate(labels(record))
            if label in ("RAW", "JA_ROMAN") and record["raw"][i].isascii() and record["raw"][i].isalpha()]


def rows_for(data, split, originals_only=False):
    return [row for row in data["rows"] if row["record"]["split"] == split
            and (not originals_only or row["augmentation"] == "original")]


def vocabulary(rows, version, maximum):
    per_original = defaultdict(set)
    for row in rows:
        for index, _ in positions(row["record"]):
            per_original[row["original_id"]].update(features(row["record"], index, version))
    frequency = Counter(key for values in per_original.values() for key in values)
    ranked = sorted(frequency, key=lambda key: (-frequency[key], key.encode("utf-8")))[:maximum]
    return sorted(ranked, key=lambda key: key.encode("utf-8"))


def matrix(rows, version, vocab):
    index = {key: i for i, key in enumerate(vocab)}
    counts = Counter()
    for row in rows:
        counts[row["original_id"]] += len(positions(row["record"]))
    columns, offsets, target, weights = [], [0], [], []
    for row in rows:
        record = row["record"]
        for position, label in positions(record):
            columns.extend(sorted(index[key] for key in features(record, position, version) if key in index))
            offsets.append(len(columns))
            target.append(label)
            weights.append(1 / counts[row["original_id"]])
    return (csr_matrix((np.ones(len(columns), dtype=np.float64), columns, offsets), shape=(len(target), len(vocab))),
            np.array(target, dtype=np.int64), np.array(weights, dtype=np.float64))


def log_loss(logits, target, weights):
    return float(np.average(np.logaddexp(0, logits) - target * logits, weights=weights))


def fit_lr(x, y, weights, strength, config):
    require(set(y) == {0, 1}, "fitting partition needs both RAW and JA_ROMAN examples")
    estimator = LogisticRegression(C=strength, l1_ratio=0, solver="lbfgs", fit_intercept=True,
                                   class_weight=None, random_state=config["seed"], max_iter=config["max_iter"],
                                   tol=config["tolerance"])
    with warnings.catch_warnings(), threadpool_limits(limits=1):
        warnings.simplefilter("error", ConvergenceWarning)
        estimator.fit(x, y, sample_weight=weights)
    require(estimator.classes_.tolist() == [0, 1], "unexpected positive-label direction")
    return estimator


def validate_config(config):
    fields(config, ("schema_version", "seed", "feature_spec_version", "vocabulary_max_features", "logistic_C_grid",
                    "max_iter", "tolerance", "switch_penalty_grid", "enter_ja_grid", "hold_ja",
                    "missing_context_increment", "minimum_ja", "minimum_path_margin"))
    require(type(config["schema_version"]) is int and config["schema_version"] == 1
            and config["feature_spec_version"] in VERSIONS, "unknown training config")
    integer(config["seed"], 0, 2**32 - 1)
    integer(config["vocabulary_max_features"], 1, 32768)
    integer(config["max_iter"], 1, 10000)
    number(config["tolerance"], 1e-12, 1e-3)
    for key, low, high in (("logistic_C_grid", 1e-6, 1e6), ("switch_penalty_grid", 0, 100), ("enter_ja_grid", 0, 1)):
        require(isinstance(config[key], list) and 1 <= len(config[key]) <= 10, "invalid parameter grid")
        for value in config[key]:
            number(value, low, high)
    for key in ("hold_ja", "missing_context_increment", "minimum_ja"):
        number(config[key], 0, 1)
    number(config["minimum_path_margin"], 0, 10000)
    require(config["hold_ja"] <= min(config["enter_ja_grid"]), "hold threshold exceeds entry threshold")


def model_thresholds(config, enter):
    result = dict(enter_ja=enter, hold_ja=config["hold_ja"])
    if config["feature_spec_version"] == VERSIONS[1]:
        result.update(enter_ja_without_context=min(1, enter + config["missing_context_increment"]),
                      minimum_ja=config["minimum_ja"], minimum_path_margin=config["minimum_path_margin"])
    return result


def validate_model(model):
    require(model.get("feature_spec_version") in VERSIONS, "unknown model feature version")
    schema_path = (ROOT / "docs/auto-mixed-old/schemas/language_model.schema.json" if model["feature_spec_version"] == VERSIONS[0]
                   else HERE / "language_model_v2.schema.json")
    require(jsonschema.Draft202012Validator(read(schema_path)).is_valid(model), "model schema mismatch")
    require(len(encoded(model)) <= 5 * 1024 * 1024, "model exceeds 5 MiB")
    vocab = model["vocabulary"]
    require(vocab == sorted(set(vocab), key=lambda s: s.encode("utf-8")) and len(vocab) == len(model["coefficients"]),
            "invalid vocabulary or coefficient count")
    for value in model["coefficients"] + [model["intercept"], *model["calibration"].values()]:
        require(type(value) in (float, int) and math.isfinite(value), "nonfinite model number")
    thresholds = model["thresholds"]
    require(thresholds["hold_ja"] <= thresholds["enter_ja"], "invalid model thresholds")
    if model["schema_version"] == 2:
        require(thresholds["enter_ja"] <= thresholds["enter_ja_without_context"], "invalid missing-context threshold")


def seal(checkpoint):
    checkpoint.pop("checkpoint_sha256", None)
    checkpoint["checkpoint_sha256"] = fingerprint(checkpoint)
    return checkpoint


def load_checkpoint(path, data=None):
    checkpoint = read(path)
    checksum = checkpoint.pop("checkpoint_sha256", None)
    require(checksum == fingerprint(checkpoint), "checkpoint checksum mismatch")
    checkpoint["checkpoint_sha256"] = checksum
    require(checkpoint["mode"] in ("fixture", "approved") and checkpoint["phase"] in ("fitted", "calibrated"), "invalid checkpoint")
    require(checkpoint["model"]["kind"] == ("fixture" if checkpoint["mode"] == "fixture" else "production"), "fixture taint lost")
    require(checkpoint["model"]["training_manifest_sha256"] == fingerprint(checkpoint["training_manifest"]), "training manifest checksum mismatch")
    validate_model(checkpoint["model"])
    if data:
        require(checkpoint["dataset_sha256"] == data["dataset_sha256"] and checkpoint["mode"] == data["mode"],
                "checkpoint belongs to a different dataset/mode")
    return checkpoint


def train(data, config):
    validate_config(config)
    env = environment()
    version = config["feature_spec_version"]
    training, dev = rows_for(data, "train"), rows_for(data, "dev", True)
    vocab = vocabulary(training, version, config["vocabulary_max_features"])
    require(vocab, "training vocabulary is empty")
    x, y, weights = matrix(training, version, vocab)
    dx, dy, dw = matrix(dev, version, vocab)
    require(len(dy) and set(dy) == {0, 1}, "dev needs both labels")
    trials = []
    for strength in sorted(set(config["logistic_C_grid"])):
        estimator = fit_lr(x, y, weights, strength, config)
        trials.append((log_loss(estimator.decision_function(dx), dy, dw), strength, estimator))
    loss, strength, estimator = min(trials, key=lambda item: item[:2])
    manifest = dict(dataset_sha256=data["dataset_sha256"], source_manifest_sha256=data["source_manifest_sha256"],
                    source_manifest=data["source_manifest"], roman_revision=data["roman_revision"], roman_table_sha256=data["roman_table_sha256"],
                    config=config, environment=env, chosen_C=strength, selection_partition="dev",
                    vocabulary_partition="train", groups=data["groups"],
                    sample_weight="each original contributes total weight 1 across all eligible positions/variants/prefixes")
    model = dict(schema_version=1 if version == VERSIONS[0] else 2, feature_spec_version=version,
                 kind="fixture" if data["mode"] == "fixture" else "production",
                 model_version="offline-candidate-" + fingerprint(manifest)[:16], positive_label="JA_ROMAN",
                 vocabulary=vocab, coefficients=estimator.coef_[0].tolist(), intercept=float(estimator.intercept_[0]),
                 calibration=dict(a=1.0, c=0.0), decoder=dict(switch_penalty=config["switch_penalty_grid"][0]),
                 thresholds=model_thresholds(config, config["enter_ja_grid"][0]), training_manifest_sha256=fingerprint(manifest))
    validate_model(model)
    return seal(dict(schema_version=1, phase="fitted", mode=data["mode"], dataset_sha256=data["dataset_sha256"],
                     model=model, training_manifest=manifest,
                     fit_report=dict(train_positions=len(y), dev_positions=len(dy), selected_dev_log_loss=loss,
                                     C_trials=[dict(C=c, dev_log_loss=l) for l, c, _ in trials]), release_ready=False))


def score_record(model, record):
    index = {key: i for i, key in enumerate(model["vocabulary"])}
    scores = []
    for position in range(len(record["raw"])):
        active = sorted(index[key] for key in features(record, position, model["feature_spec_version"]) if key in index)
        logit = model["intercept"]
        for i in active:
            logit += model["coefficients"][i]
        probability = stable_sigmoid(model["calibration"]["a"] * logit + model["calibration"]["c"])
        scores.append(dict(active_indices=active, logit=logit, p_ja=probability))
    return scores


def decode(model, record, protection, scores):
    ps = [s["p_ja"] if mask == "inferred" else .5 for s, mask in zip(scores, protection)]
    path, cursor = [], 0
    penalty = model["decoder"]["switch_penalty"]
    while cursor < len(ps):
        if protection[cursor] in ("gap", "literal"):
            path.append(protection[cursor].upper())
            cursor += 1
            continue
        end = cursor + 1
        while end < len(ps) and protection[end] not in ("gap", "literal"):
            end += 1
        path += viterbi(ps[cursor:end], penalty, ["RAW" if m == "raw" else None for m in protection[cursor:end]])
        cursor = end
    decoded = list(path)
    cursor = 0
    while cursor < len(path):
        end = cursor + 1
        while end < len(path) and path[end] == path[cursor]:
            end += 1
        if path[cursor] == "JA_ROMAN":
            run = ps[cursor:end]
            thresholds = model["thresholds"]
            enter = thresholds["enter_ja"]
            hold = sum(run) / len(run) < enter
            if model["schema_version"] == 2:
                if record_context(record) is None:
                    enter = thresholds["enter_ja_without_context"]
                margin = sum(math.log(min(max(p, 1e-7), 1 - 1e-7)) - math.log1p(-min(max(p, 1e-7), 1 - 1e-7)) for p in run)
                margin -= penalty * ((cursor > 0 and path[cursor - 1] == "RAW") + (end < len(path) and path[end] == "RAW"))
                hold = sum(run) / len(run) < enter or min(run) < thresholds["minimum_ja"] or margin < thresholds["minimum_path_margin"]
            if hold:
                decoded[cursor:end] = ["UNRESOLVED"] * (end - cursor)
        cursor = end
    return decoded


def metrics(model, rows):
    counts = Counter()
    squared, nll = 0.0, 0.0
    bins = [dict(count=0, sum_p=0.0, sum_y=0) for _ in range(10)]
    for row in rows:
        record = row["record"]
        scores = score_record(model, record)
        path = decode(model, record, row["protections"], scores)
        expected = labels(record)
        for i, y in positions(record):
            p = scores[i]["p_ja"]
            predicted = path[i] == "JA_ROMAN"
            counts["tp" if y and predicted else "fn" if y else "fp" if predicted else "tn"] += 1
            counts["held"] += path[i] == "UNRESOLVED"
            squared += (p - y)**2
            nll -= math.log(max(p if y else 1 - p, 1e-15))
            bucket = bins[min(int(p * 10), 9)]
            bucket["count"] += 1
            bucket["sum_p"] += p
            bucket["sum_y"] += y
        for span in record["spans"]:
            if span["label"] == "RAW":
                counts["english_spans"] += 1
                counts["damaged_english_spans"] += any(p == "JA_ROMAN" for p in path[span["start"]:span["end"]])
        gold_edges = {i for i in range(1, len(expected)) if expected[i - 1] in ("RAW", "JA_ROMAN") and expected[i] in ("RAW", "JA_ROMAN") and expected[i - 1] != expected[i]}
        eligible = {i for i in range(1, len(expected)) if expected[i - 1] in ("RAW", "JA_ROMAN") and expected[i] in ("RAW", "JA_ROMAN")}
        pred_edges = {i for i in eligible if path[i - 1] in ("RAW", "JA_ROMAN") and path[i] in ("RAW", "JA_ROMAN") and path[i - 1] != path[i]}
        counts["boundary_tp"] += len(gold_edges & pred_edges)
        counts["boundary_fp"] += len(pred_edges - gold_edges)
        counts["boundary_fn"] += len(gold_edges - pred_edges)
    def ratio(a, b):
        return a / b if b else None
    total = sum(counts[k] for k in ("tp", "fp", "tn", "fn"))
    n = counts["english_spans"]
    damage = ratio(counts["damaged_english_spans"], n)
    interval = None
    if n:
        z = 1.959963984540054
        center = (damage + z*z/(2*n)) / (1 + z*z/n)
        width = z * math.sqrt(damage*(1-damage)/n + z*z/(4*n*n)) / (1 + z*z/n)
        interval = [max(0, center - width), min(1, center + width)]
    return dict(counts=dict(counts), positions=total, english_span_damage_rate=damage, english_damage_wilson95=interval,
                ja_recall=ratio(counts["tp"], counts["tp"] + counts["fn"]), ja_precision=ratio(counts["tp"], counts["tp"] + counts["fp"]),
                boundary_f1=ratio(2*counts["boundary_tp"], 2*counts["boundary_tp"]+counts["boundary_fp"]+counts["boundary_fn"]),
                hold_rate=ratio(counts["held"], total), brier=ratio(squared, total), log_loss=ratio(nll, total),
                reliability=[dict(count=b["count"], mean_probability=ratio(b["sum_p"], b["count"]), observed_ja=ratio(b["sum_y"], b["count"])) for b in bins])


def calibrate(checkpoint, data):
    require(checkpoint["phase"] == "fitted", "calibration requires an uncalibrated checkpoint")
    result = copy.deepcopy(checkpoint)
    model = result["model"]
    config = result["training_manifest"]["config"]
    environment()
    rows = rows_for(data, "calibration", True)
    x, y, weights = matrix(rows, model["feature_spec_version"], model["vocabulary"])
    minimum = 2 if data["mode"] == "fixture" else 100
    require(min(Counter(y).get(0, 0), Counter(y).get(1, 0)) >= minimum, "calibration partition has insufficient examples of both labels")
    logits = np.asarray(x @ np.array(model["coefficients"]) + model["intercept"]).reshape(-1, 1)
    calibrator = fit_lr(logits, y, weights, np.inf, config)
    model["calibration"] = dict(a=float(calibrator.coef_[0][0]), c=float(calibrator.intercept_[0]))
    # Learned sigmoid sign is exported directly as sigmoid(a*z+c), with no private sklearn attributes.
    require(model["calibration"]["a"] > 0, "calibration reversed positive-label direction; inspect data")
    trials = []
    dev = rows_for(data, "dev", True)
    for penalty in sorted(set(config["switch_penalty_grid"])):
        for enter in sorted(set(config["enter_ja_grid"])):
            model["decoder"]["switch_penalty"] = penalty
            model["thresholds"] = model_thresholds(config, enter)
            report = metrics(model, dev)
            damage = report["english_span_damage_rate"]
            recall = report["ja_recall"]
            require(damage is not None and recall is not None, "dev requires English spans and JA positions")
            trials.append((damage > .005, -recall if damage <= .005 else damage, damage, penalty, enter, report))
    best = min(trials, key=lambda t: t[:5])
    model["decoder"]["switch_penalty"] = best[3]
    model["thresholds"] = model_thresholds(config, best[4])
    result["phase"] = "calibrated"
    result["calibration_report"] = dict(partition="calibration", positions=len(y), regularization="none",
                                        decoder_selection_partition="dev", selected_dev_metrics=best[5],
                                        quality_claim=False)
    result["training_manifest"]["calibration"] = dict(parameters=model["calibration"], decoder=model["decoder"], thresholds=model["thresholds"])
    model["training_manifest_sha256"] = fingerprint(result["training_manifest"])
    validate_model(model)
    return seal(result)


def evaluate(checkpoint, data, traces=False):
    require(checkpoint["phase"] == "calibrated", "evaluate a frozen calibrated checkpoint")
    rows = rows_for(data, "test", True)
    model = checkpoint["model"]
    by_context = {state: metrics(model, [r for r in rows if (record_context(r["record"]) is not None) == available])
                  for state, available in (("available", True), ("unavailable", False))}
    categories = sorted({r["record"]["category"] for r in rows})
    report = dict(schema_version=1, mode=data["mode"], evaluation_kind="fixture_smoke_only" if data["mode"] == "fixture" else "offline_holdout",
                  checkpoint_sha256=checkpoint["checkpoint_sha256"], dataset_sha256=data["dataset_sha256"],
                  test=metrics(model, rows), by_context=by_context,
                  by_category={c: metrics(model, [r for r in rows if r["record"]["category"] == c]) for c in categories},
                  release_ready=False, not_evaluated=["real Zenzai/roman validity gate", "display hysteresis", "IMK", "latency/RSS", "user overrides"],
                  model_card=dict(feature_spec_version=model["feature_spec_version"], positive_label="JA_ROMAN",
                                  training_manifest_sha256=model["training_manifest_sha256"], environment=checkpoint["training_manifest"]["environment"],
                                  rights_mode=data["mode"], training_groups=sum(g["split"] == "train" for g in data["groups"].values())))
    if traces:
        from swift_bridge import validate_in_swift
        traces_by_original = []
        for row in rows:
            record = row["record"]
            if not record["raw"].isascii():
                continue
            trace = []
            for end in range(1, len(record["raw"]) + 1):
                prefix = dict(record, raw=record["raw"][:end], spans=[dict(s, end=min(end, s["end"]))
                              for s in record["spans"] if s["start"] < end])
                trace.append(dict(record=prefix, original_id=row["original_id"], augmentation="prefix"))
            traces_by_original.append(trace)
        # Prefix masks and features are both recomputed; neither comes from the completed sentence.
        all_prefixes = [row for trace in traces_by_original for row in trace]
        if all_prefixes:
            validate_in_swift(all_prefixes, {})
        flips, steps = 0, 0
        for trace in traces_by_original:
            previous = []
            for candidate in trace:
                current = decode(model, candidate["record"], candidate["protections"], score_record(model, candidate["record"]))
                if previous:
                    flips += sum(a != b for a, b in zip(previous, current))
                    steps += 1
                previous = current
        report["prefix_replay"] = dict(consecutive_steps=steps, changed_previous_positions=flips,
                                        ascii_records_replayed=len(traces_by_original),
                                        unicode_records_not_replayed=len(rows) - len(traces_by_original),
                                        feature_and_mask_recomputed_at_each_prefix=True, is_IMK_typing_trace=False)
    return report
