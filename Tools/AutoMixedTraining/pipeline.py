#!/usr/bin/env python3
"""Local training CLI. No download, IME installation, or application input collection."""
import argparse
import json
from pathlib import Path
import sys
import subprocess

from dataset import build_dataset, load_dataset, load_sources, validate_records
from learning import (VERSIONS, calibrate, decode, evaluate, features, load_checkpoint, score_record, train,
                      tune_thresholds, validate_model, viterbi)
from pipeline_io import HERE, ROOT, PipelineError, digest, environment, fingerprint, parse, read, require, write_new


def export(checkpoint, output):
    require(checkpoint["phase"] == "calibrated", "export requires a calibrated checkpoint")
    model = checkpoint["model"]
    validate_model(model)
    output = Path(output)
    require(not output.exists(), "export directory already exists")
    version = model["feature_spec_version"]
    golden_path = (ROOT / "docs/auto-mixed-old/fixtures/feature_golden.json" if version == VERSIONS[0]
                   else HERE / "fixtures/feature_v2_golden.json")
    vectors = []
    for vector in read(golden_path)["vectors"]:
        record = dict(raw=vector["raw"])
        context = vector.get("left_context")
        if context is not None:
            record.update(left_context=context[-30:], context_available=True)
        scores = score_record(model, record)
        i = vector["index"]
        vectors.append(dict(raw=record["raw"], index=i, left_context=record.get("left_context"),
                            features=features(record, i, version), **scores[i]))
    decoders = []
    for probabilities in ([.5] * 8, [0, 1, .2, .9], [v["p_ja"] for v in vectors]):
        for penalty in (0, .4, model["decoder"]["switch_penalty"]):
            decoders.append(dict(probabilities=probabilities, switch_penalty=penalty,
                                 path=viterbi(probabilities, penalty)))
    segment_cases = []
    if version == VERSIONS[1]:
        authored = [("made", ["inferred"] * 4), ("API made", ["raw"] * 3 + ["gap"] + ["inferred"] * 4),
                    ("ashita made", ["inferred"] * 6 + ["gap"] + ["inferred"] * 4),
                    ("AAmadeBB", ["raw"] * 2 + ["inferred"] * 4 + ["raw"] * 2),
                    ("https://example.test/a", ["literal"] * 22),
                    ("e\u0301desu", ["literal"] * 2 + ["inferred"] * 4),
                    ("👩‍💻 made", ["literal"] * 3 + ["gap"] + ["inferred"] * 4)]
        for raw, mask in authored:
            require(len(raw) == len(mask), "authored parity mask length mismatch")
            for context in (None, "I ", "明日"):
                record = dict(raw=raw)
                if context is not None:
                    record.update(left_context=context, context_available=True)
                segment_cases.append(dict(raw=raw, left_context=context, protections=mask,
                                          labels=decode(model, record, mask, score_record(model, record))))
    # Only fixed authored golden text is exported for parity; never corpus context or held-out text.
    write_new(output / "model.json", model)
    write_new(output / "parity.json", dict(feature_spec_version=version, vectors=vectors, decoders=decoders, segment_cases=segment_cases))
    write_new(output / "manifest.json", dict(schema_version=1, model_sha256=digest((output / "model.json").read_bytes()),
                                             training_manifest=checkpoint["training_manifest"],
                                             checkpoint_sha256=checkpoint["checkpoint_sha256"],
                                             mode=checkpoint["mode"], release_ready=False))


def parser():
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate-data", help="check fixture records or an approved source manifest")
    source = validate.add_mutually_exclusive_group(required=True)
    source.add_argument("--input", type=Path)
    source.add_argument("--manifest", type=Path)
    build = commands.add_parser("build-dataset", help="verify rights, split groups, augment, then validate in Swift")
    build.add_argument("--manifest", required=True, type=Path)
    build.add_argument("--output", required=True, type=Path)
    fitting = commands.add_parser("train", help="train-only vocabulary and LR; select C on dev")
    fitting.add_argument("--config", required=True, type=Path)
    fitting.add_argument("--data", required=True, type=Path)
    fitting.add_argument("--output", required=True, type=Path)
    calibration = commands.add_parser("calibrate", help="fit sigmoid on calibration; select decoder on dev")
    calibration.add_argument("--model", required=True, type=Path, help="fitted checkpoint")
    calibration.add_argument("--data", required=True, type=Path)
    calibration.add_argument("--output", required=True, type=Path)
    tuning = commands.add_parser("tune-thresholds", help="search independent entry thresholds on dev; freeze LR and calibration")
    tuning.add_argument("--model", required=True, type=Path, help="calibrated checkpoint")
    tuning.add_argument("--data", required=True, type=Path, help="same sealed dataset")
    tuning.add_argument("--config", required=True, type=Path, help="version 2 config; only entry grids may change")
    tuning.add_argument("--output", required=True, type=Path)
    exporting = commands.add_parser("export", help="export immutable runtime JSON plus manifest and parity")
    exporting.add_argument("--model", required=True, type=Path, help="calibrated checkpoint")
    exporting.add_argument("--output", required=True, type=Path)
    evaluation = commands.add_parser("evaluate", help="evaluate frozen test partition; no tuning")
    evaluation.add_argument("--model", required=True, type=Path, help="calibrated checkpoint")
    evaluation.add_argument("--test", required=True, type=Path, help="same sealed dataset; only test partition is scored")
    evaluation.add_argument("--traces", action="store_true")
    evaluation.add_argument("--output", required=True, type=Path)
    return root


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        environment()
        if args.command == "validate-data":
            if args.manifest:
                manifest, records = load_sources(args.manifest)
                mode = manifest["mode"]
            else:
                records = [parse(line) for line in args.input.read_bytes().splitlines() if line.strip()]
                validate_records(records)
                require(all(r["provenance"]["rights_status"] == "fixture_only" and r["split"] == "fixture" for r in records),
                        "non-fixture validation requires a rights manifest")
                mode = "fixture"
            print(json.dumps(dict(status="valid", mode=mode, records=len(records))))
        elif args.command == "build-dataset":
            require(not args.output.exists(), "output artifact already exists")
            data = build_dataset(args.manifest)
            write_new(args.output, data)
            print(json.dumps(dict(status="built", mode=data["mode"], rows=len(data["rows"]),
                                  pruned_cross_split_augmentations=data["pruned_cross_split_augmentations"])))
        elif args.command == "train":
            require(not args.output.exists(), "output artifact already exists")
            write_new(args.output, train(load_dataset(args.data), read(args.config)))
            print('{"status":"fitted","release_ready":false}')
        elif args.command == "calibrate":
            require(not args.output.exists(), "output artifact already exists")
            data = load_dataset(args.data)
            write_new(args.output, calibrate(load_checkpoint(args.model, data), data))
            print('{"status":"calibrated","release_ready":false}')
        elif args.command == "tune-thresholds":
            require(not args.output.exists(), "threshold tuning output already exists")
            data = load_dataset(args.data)
            checkpoint = tune_thresholds(load_checkpoint(args.model, data), data, read(args.config))
            write_new(args.output, checkpoint)
            search = checkpoint["threshold_tuning_report"]
            print(json.dumps(dict(status="thresholds_tuned", candidates=len(search["trials"]),
                                  target_passing_candidates=search["target_passing_candidates"], release_ready=False)))
        elif args.command == "export":
            export(load_checkpoint(args.model), args.output)
            print('{"status":"exported","release_ready":false}')
        elif args.command == "evaluate":
            require(not args.output.exists(), "frozen evaluation output already exists")
            data = load_dataset(args.test)
            write_new(args.output, evaluate(load_checkpoint(args.model, data), data, args.traces))
            print('{"status":"evaluated","release_ready":false}')
    except (ValueError, KeyError, TypeError, OSError, RuntimeError, ArithmeticError, Warning, subprocess.SubprocessError) as exc:
        # Schema/library exceptions can embed data. Emit only our deliberately content-free diagnostics.
        message = str(exc) if isinstance(exc, PipelineError) else "validation or computation failed (no input text logged)"
        print(json.dumps(dict(status="error", error=message)), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
