"""Compile explicitly authored symbol examples; preserve the previous approved sources."""
import argparse
from collections import Counter
import copy
import html
import json
import os
from pathlib import Path

from author_expansion import parse_sentence, record, verify_readings
from boundary_augmentation import POLICY
from dataset import ROMAN_REVISION, ROMAN_SHA256, roman_table, validate_records
from pipeline_io import HERE, digest, read, require, write_new

SOURCE = HERE / "punctuation_expansion"
SOURCE_ID = "codex-authored-punctuation-20260924"
PROVENANCE = dict(kind="synthetic_approved", source_id=SOURCE_ID, rights_status="approved",
                  license_id="LicenseRef-UserAuthorization-20260924-Punctuation",
                  retrieved_at="2026-09-24", source_url="authored:" + SOURCE_ID)


def authored_records():
    table, records, readings = roman_table(), [], []
    category = None
    for line in (SOURCE / "sentences.txt").read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        if line.startswith("@"):
            category = line[1:]
            continue
        require(category is not None, "authored category missing")
        identifier = f"punctuation-{len(records) + 1:04}"
        # Authored whole sentences can start in an empty field. The other half
        # model clients that cannot provide context; no real context is read.
        context = "" if len(records) % 2 == 0 else None
        item, checks = record(identifier, identifier, category, parse_sentence(line, table), context)
        item["provenance"] = dict(PROVENANCE)
        item.pop("desired_display", None)  # Rendering punctuation is a separate runtime policy.
        records.append(item)
        readings.extend(dict(id=identifier, **check) for check in checks)
    validate_records([dict(item, split="train") for item in records])
    return records, readings


def build(output):
    output = Path(output)
    require(not output.exists(), "punctuation source output already exists")
    records, readings = authored_records()
    verify_readings(readings)
    output.mkdir(parents=True)
    raw = output / "samples.jsonl"
    raw.write_text("".join(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n" for r in records))
    manifest_path = HERE / "synthetic_expansion/generated/manifest.json"
    manifest = copy.deepcopy(read(manifest_path))
    for source in manifest["sources"]:
        for entry in [source["records"], source["approval"]["evidence"]]:
            entry["path"] = os.path.relpath(manifest_path.parent / entry["path"], output)
    evidence = SOURCE / "RIGHTS_REVIEW.md"
    manifest["sources"].append(dict(source_id=SOURCE_ID,
        records=dict(path="samples.jsonl", sha256=digest(raw.read_bytes())),
        approval=dict(status="approved", reviewer="conversation_user (use authorization); Codex (annotation checks)",
            reviewed_at="2026-09-24", license_id=PROVENANCE["license_id"], source_url=PROVENANCE["source_url"],
            retrieved_at=PROVENANCE["retrieved_at"], allowed_uses=["training", "evaluation", "derived_model"],
            evidence=dict(path=os.path.relpath(evidence, output), sha256=digest(evidence.read_bytes())),
            grouping_rule="Authored sentence family; preserve old partitions; split before symbol/context/spelling/prefix augmentation.",
            processing="Explicit synthetic intentions; actual pinned Swift reading verification; no external corpus or user input.",
            privacy_reviewed=True)))
    manifest["augmentation"]["boundary_policy"] = POLICY
    write_new(output / "manifest.json", manifest)
    write_new(output / "reading_checks.json", dict(roman_revision=ROMAN_REVISION, roman_table_sha256=ROMAN_SHA256,
        verified_by="actual Swift ComposingText", pairs=readings))
    write_new(output / "inventory.json", dict(records=len(records), original_groups=len(records),
        categories=dict(Counter(r["category"] for r in records)), human_review="not_yet_performed",
        source_sha256=digest((SOURCE / "sentences.txt").read_bytes()), verified_readings=len(readings)))
    lines = ["# 記号例文の確認表", "", "Codex作成・注釈確認。利用者による全件確認は未実施。",
             "記号は打鍵原文。日本語の読みはreading_checks.jsonで固定Converterと照合した。", "",
             "| ID | 種類 | raw | 文脈の条件 |", "|---|---|---|---|"]
    for r in records:
        values = [r["id"], r["category"], r["raw"], "取得成功・空" if r["context_available"] else "取得不可"]
        lines.append("| " + " | ".join(html.escape(v).replace("|", "&#124;") for v in values) + " |")
    (output / "REVIEW.md").write_text("\n".join(lines) + "\n")
    print(json.dumps(dict(authored_originals=len(records), verified_readings=len(readings))))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=SOURCE / "generated")
    build(parser.parse_args().output)
