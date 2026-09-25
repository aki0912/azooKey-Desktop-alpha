"""Compile explicitly authored intents; verify every Japanese reading in the fixed Swift Converter."""
import argparse
from collections import Counter
import copy
import html
import json
from pathlib import Path
import re

from dataset import ROMAN_REVISION, ROMAN_SHA256, roman_table, validate_records
from pipeline_io import HERE, digest, read, require, write_new
from swift_bridge import validate_in_swift

SOURCE = HERE / "synthetic_expansion"
SOURCE_ID = "codex-authored-expansion-20260924"
PROVENANCE = dict(kind="synthetic_approved", source_id=SOURCE_ID, rights_status="approved",
                  license_id="LicenseRef-UserAuthorization-20260924-Expansion",
                  source_url="authored:" + SOURCE_ID, retrieved_at="2026-09-24")


def romanize(reading, table):
    # Invert only the pinned table. Preferred familiar spellings are checked in Swift below.
    preferred = {"か": "ka", "き": "ki", "く": "ku", "け": "ke", "こ": "ko",
                 "し": "shi", "せ": "se", "ち": "chi", "つ": "tsu", "ふ": "fu", "じ": "ji", "ん": "nn",
                 "ぁ": "xa", "ぃ": "xi", "ぅ": "xu", "ぇ": "xe", "ぉ": "xo", "っ": "xtu"}
    for stem, vowel in (("しゃ", "sha"), ("しゅ", "shu"), ("しょ", "sho"),
                        ("ちゃ", "cha"), ("ちゅ", "chu"), ("ちょ", "cho"),
                        ("じゃ", "ja"), ("じゅ", "ju"), ("じょ", "jo")):
        preferred[stem] = vowel
    inverse = {}
    for raw, kana in sorted(table.items(), key=lambda item: (len(item[0]), item[0])):
        inverse.setdefault(kana, raw)
    for kana, raw in preferred.items():
        require(table.get(raw) == kana, "preferred spelling differs from pinned table")
        inverse[kana] = raw
    keys = sorted(inverse, key=lambda key: (-len(key), key))
    chunks, offset = [], 0
    while offset < len(reading):
        key = next((key for key in keys if reading.startswith(key, offset)), None)
        require(key is not None, "reading is not covered by the pinned table")
        chunks.append((key, inverse[key]))
        offset += len(key)
    output = []
    for index, (kana, raw) in enumerate(chunks):
        if kana == "っ" and index + 1 < len(chunks):
            following = chunks[index + 1][1]
            if following[0] in "bcdfghjkmprstvwyz":
                raw = following[0]
        output.append(raw)
    return "".join(output)


def parse_sentence(text, table):
    pieces, cursor = [], 0
    while cursor < len(text):
        if text[cursor] in "[{":
            closing = "]" if text[cursor] == "[" else "}"
            end = text.find(closing, cursor + 1)
            require(end > cursor + 1, "unclosed or empty authored segment")
            kind = "RAW" if text[cursor] == "[" else "LITERAL"
            value = text[cursor + 1:end]
            for part in re.split(r"( +)", value):
                if part:
                    pieces.append(("GAP" if part.isspace() else kind, part, None))
            cursor = end + 1
        elif "ぁ" <= text[cursor] <= "ゖ":
            end = cursor + 1
            while end < len(text) and "ぁ" <= text[end] <= "ゖ":
                end += 1
            reading = text[cursor:end]
            pieces.append(("JA_ROMAN", romanize(reading, table), reading))
            cursor = end
        else:
            require(not text[cursor].isascii() or not text[cursor].isalpha(), "English must have explicit RAW markup")
            require(text[cursor] not in "]}", "unmatched authored closing bracket")
            pieces.append(("GAP" if text[cursor] == " " else "LITERAL", text[cursor], None))
            cursor += 1
    return pieces


def record(identifier, group, category, pieces, context=None):
    raw, spans, display, readings = "", [], "", []
    for kind, value, reading in pieces:
        start = len(raw)
        raw += value
        if spans and spans[-1]["label"] == kind:
            spans[-1]["end"] = len(raw)
        else:
            spans.append(dict(start=start, end=len(raw), label=kind))
        display += reading if reading is not None else value
        if reading is not None:
            readings.append(dict(raw=value, reading=reading))
    result = dict(id=identifier, group_id=group, split="unassigned", raw=raw, spans=spans,
                  category=category, context_available=context is not None, provenance=dict(PROVENANCE),
                  desired_display=display, note="Codex作成・注釈確認。利用者による全件確認は未実施。意図表記はかなで保持。")
    if context is not None:
        result["left_context"] = context
    return result, readings


def authored_records():
    table = roman_table()
    records, readings = [], []
    category, serial = None, 0
    for line in (SOURCE / "sentences.txt").read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        if line.startswith("@"):
            category = line[1:]
            continue
        require(category is not None, "authored domain missing")
        serial += 1
        identifier = f"expansion-{serial:04}"
        item, checks = record(identifier, identifier, category, parse_sentence(line, table))
        records.append(item)
        readings.extend(dict(id=identifier, **check) for check in checks)
    for intent in read(SOURCE / "context_intents.json"):
        raw, reading = intent["raw"], intent["reading"]
        group = "expansion-context-" + raw
        for suffix, label, context in (
            ("english", "RAW", intent["english_context"]),
            ("japanese", "JA_ROMAN", intent["japanese_context"]),
            ("quoted", "RAW", intent["quoted_context"]),
            ("unavailable", "AMBIGUOUS", None),
            ("empty", "AMBIGUOUS", ""),
        ):
            item, checks = record(group + "-" + suffix, group, "context_" + suffix,
                                  [(label, raw, reading if label == "JA_ROMAN" else None)], context)
            if label == "AMBIGUOUS":
                item.pop("desired_display")
            records.append(item)
            readings.extend(dict(id=item["id"], **check) for check in checks)
    validation = copy.deepcopy(records)
    for item in validation:
        item["split"] = "train"
    validate_records(validation)
    return records, readings


def verify_readings(readings):
    originals, rows = {}, []
    for index, pair in enumerate(readings):
        # Literal hiragana inserted via the same public composing API is the expected target.
        identifier = str(index)
        originals[identifier] = dict(raw=pair["reading"], spans=[dict(start=0, end=len(pair["reading"]), label="JA_ROMAN")])
        rows.append(dict(original_id=identifier, augmentation="roman_variant",
                         record=dict(raw=pair["raw"], spans=[dict(start=0, end=len(pair["raw"]), label="JA_ROMAN")])))
    validate_in_swift(rows, originals)


def build(output):
    output = Path(output)
    require(not output.exists(), "expansion output already exists")
    records, readings = authored_records()
    verify_readings(readings)
    output.mkdir(parents=True)
    raw_file = output / "samples.jsonl"
    raw_file.write_text("".join(json.dumps(item, ensure_ascii=False, separators=(",", ":")) + "\n" for item in records))
    write_new(output / "reading_checks.json", dict(roman_revision=ROMAN_REVISION, roman_table_sha256=ROMAN_SHA256,
                                                   verified_by="actual Swift ComposingText", pairs=readings))
    def relative(path):
        import os
        return os.path.relpath(path, output)
    old = read(HERE / "approved_samples/manifest.json")
    old_source = old["sources"][0]
    old_source["records"]["path"] = relative(HERE / "approved_samples/samples_50.jsonl")
    old_source["approval"]["evidence"]["path"] = relative(HERE / "approved_samples/RIGHTS_REVIEW.md")
    evidence = SOURCE / "RIGHTS_REVIEW.md"
    approval = dict(status="approved", reviewer="conversation_user (use authorization); Codex (annotation checks)",
                    reviewed_at="2026-09-24", license_id=PROVENANCE["license_id"], source_url=PROVENANCE["source_url"],
                    retrieved_at=PROVENANCE["retrieved_at"], allowed_uses=["training", "evaluation", "derived_model"],
                    evidence=dict(path=relative(evidence), sha256=digest(evidence.read_bytes())),
                    grouping_rule="One authored intent family; same-raw context contrasts; near duplicate components; frozen old partitions.",
                    processing="Explicit authored sentences, deterministic fixed-table romanization, actual Swift reading checks; no external corpus.",
                    privacy_reviewed=True)
    old["sources"].append(dict(source_id=SOURCE_ID, records=dict(path="samples.jsonl", sha256=digest(raw_file.read_bytes())), approval=approval))
    write_new(output / "manifest.json", old)
    write_new(output / "inventory.json", dict(records=len(records), authored_groups=len({r["group_id"] for r in records}),
        categories=dict(Counter(r["category"] for r in records)), reading_checks=len(readings), human_review="not_yet_performed",
        source_sha256={name: digest((SOURCE / name).read_bytes()) for name in ("sentences.txt", "context_intents.json")}))
    lines = ["# 追加例の確認表", "", "全件Codex作成・注釈確認。利用者による全件確認は未実施。", "",
             "| ID | 種類 | rawと意図表記 | 左文脈 | 人の確認 |", "|---|---|---|---|---|"]
    for item in records:
        focus = "要確認：文脈と入力意図" if item["category"].startswith("context_") else (
            "要確認：保護範囲" if item["category"] == "protected" else "抜取確認：自然さ・区間・読み")
        values = [item["id"], item["category"], item["raw"] + " → " + item.get("desired_display", "意図を固定しない"),
                  repr(item.get("left_context")) if item["context_available"] else "取得不可", focus]
        lines.append("| " + " | ".join(html.escape(value).replace("|", "&#124;") for value in values) + " |")
    (output / "REVIEW.md").write_text("\n".join(lines) + "\n")
    print(json.dumps(dict(records=len(records), groups=len({r["group_id"] for r in records}), verified_readings=len(readings))))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=SOURCE / "generated")
    build(parser.parse_args().output)
