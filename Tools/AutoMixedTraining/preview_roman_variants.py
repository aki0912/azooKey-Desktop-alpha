"""Review pending local annotations and spelling variants without approving or training them."""
import argparse
import copy
import html
import json
from pathlib import Path
import subprocess
import sys

from dataset import (ROMAN_REVISION, ROMAN_SHA256, group_split, prune_cross_split_augmentations,
                     roman_table, validate_records, variants)
from pipeline_io import PipelineError, digest, fingerprint, integer, parse, require, write_new
from swift_bridge import validate_in_swift


def build_preview(path, seed=20260924, limit=2):
    integer(seed, 0, 2**32 - 1)
    integer(limit, 1, 8)
    source = Path(path).read_bytes()
    originals = [parse(line) for line in source.splitlines() if line.strip()]
    require(bool(originals), "review source is empty")
    records = copy.deepcopy(originals)
    for record in records:
        require(isinstance(record, dict) and record.get("split") == "unassigned"
                and isinstance(record.get("provenance"), dict)
                and record.get("provenance", {}).get("rights_status") == "pending_review",
                "preview requires pending, unassigned originals")
        record["split"] = "train"  # Existing source-only extension; no rights approval.
    validate_records(records)
    records.sort(key=lambda r: r["id"])
    groups = group_split(records, seed)  # Freeze review-only assignments BEFORE generating clones.
    table = roman_table()
    rows = []
    for record in records:
        record["split"] = groups[record["group_id"]]["split"]
        rows.append(dict(record=record, original_id=record["id"], augmentation="original"))
        for i, variant in enumerate(variants(record, table, limit), start=1):
            variant["id"] = record["id"] + "--roman-" + str(i)
            rows.append(dict(record=variant, original_id=record["id"], augmentation="roman_variant"))
    kept = prune_cross_split_augmentations(rows)
    pruned = len(rows) - len(kept)
    rows = kept
    validate_records([row["record"] for row in rows])
    validate_in_swift(rows, {r["id"]: r for r in records})
    result = dict(schema_version=1, kind="review_preview", training_eligible=False,
                  source_sha256=digest(source), seed=seed, max_variants=limit, groups=groups, rows=rows,
                  roman_revision=ROMAN_REVISION, roman_table_sha256=ROMAN_SHA256,
                  pruned_cross_split_augmentations=pruned,
                  split_policy="provisional_review_only; rebuild from approved originals before training",
                  validation="fixed_converter_same_reading; no_model_quality_claim")
    result["preview_sha256"] = fingerprint(result)
    return result


def review_markdown(preview):
    originals = {row["original_id"]: row["record"] for row in preview["rows"] if row["augmentation"] == "original"}
    generated = [row for row in preview["rows"] if row["augmentation"] == "roman_variant"]

    def cell(value):
        return "<code>" + html.escape(value).replace("|", "&#124;").replace("\n", "&#10;").replace("\r", "&#13;") + "</code>"

    lines = ["# ローマ字別表記の確認用プレビュー", "",
             f"原本{len(originals)}件に別表記{len(generated)}件を追加した、計{len(preview['rows'])}件の確認用データ。",
             "全件pending_reviewを維持し、権利承認・学習・精度評価は行っていない。元の注釈と生成後の打鍵表記は人手確認が必要。",
             "",
             "元文groupを仮分割してから生成し、派生行は同じgroup・splitを引き継ぐ。",
             "この仮分割は確認専用。学習時は承認済み原本全体をまとめて分割し直し、同じ増強処理を実行する。",
             "preview.jsonは学習用sealed datasetではなく、原本への連結や学習CLIへの投入はしない。",
             "",
             "JA_ROMAN区間だけを変更し、英語・保護文字列・空白・左文脈は保持した。",
             "固定Converterで変更区間の読み一致を確認済み。漢字変換・IME実打鍵の検証ではない。",
             f"元文あたり追加は最大{preview['max_variants']}件。全箇所を代表的な別表記にした例を先に、次に一部だけ変えた例を選ぶ。",
             "",
             "| 元ID | 派生ID | 元raw | 別表記raw | 仮split |",
             "|---|---|---|---|---|"]
    for row in generated:
        record = row["record"]
        lines.append("| " + " | ".join(cell(value) for value in [row["original_id"], record["id"],
                     originals[row["original_id"]]["raw"], record["raw"], record["split"]]) + " |")
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path, help="new directory")
    parser.add_argument("--seed", type=int, default=20260924)
    parser.add_argument("--max-variants", type=int, default=2)
    args = parser.parse_args(argv)
    try:
        require(not args.output.exists(), "preview output already exists")
        preview = build_preview(args.input, args.seed, args.max_variants)
        args.output.mkdir(parents=True, exist_ok=False)
        write_new(args.output / "preview.json", preview)
        with (args.output / "REVIEW.md").open("x") as stream:
            stream.write(review_markdown(preview))
        print(json.dumps(dict(status="review_only", rows=len(preview["rows"]), training_eligible=False)))
        return 0
    except (ValueError, KeyError, TypeError, OSError, RuntimeError, subprocess.SubprocessError) as exc:
        message = str(exc) if isinstance(exc, PipelineError) else "preview validation failed (no input text logged)"
        print(json.dumps(dict(status="error", error=message)), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
