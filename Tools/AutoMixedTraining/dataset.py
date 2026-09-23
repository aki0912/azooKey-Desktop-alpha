"""Verify rights, freeze group splits, then augment. No network or input-history access."""
from collections import defaultdict
import copy
from difflib import SequenceMatcher
from datetime import date
import json
from pathlib import Path
import re

import jsonschema

from context_features import record_context, validate_context_records
from pipeline_io import (ROOT, SPLITS, checked_file, digest, fields, fingerprint, integer,
                         local_file, parse, read, require)

SPAN_SCHEMA = read(ROOT / "docs/azookey_auto_mixed_codex/schemas/span_record.schema.json")
ROMAN_REVISION = "ad714fea8cb2fe113aea86ba5c42563cdaf77cfb"
ROMAN_SHA256 = "395a0e855172931f66ee50473ba9466fcb5a71c4ffeda4a5c54c3ac006d2245b"
ROMAN_TABLE = "build/auto-mixed/core/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModule/InputManagement/InputTables/defaultRoman2Kana.swift"


def validate_records(records):
    require(isinstance(records, list) and records, "dataset must contain records")
    validator = jsonschema.Draft202012Validator(SPAN_SCHEMA)
    for record in records:
        require(validator.is_valid(record), "record violates span schema")
    try:
        validate_context_records(records)
    except (ValueError, TypeError) as exc:
        raise ValueError("invalid span coverage, group split or context") from exc


def load_sources(manifest_path):
    manifest = read(manifest_path)
    fields(manifest, ("schema_version", "mode", "seed", "sources", "augmentation"))
    require(type(manifest["schema_version"]) is int and manifest["schema_version"] == 1
            and manifest["mode"] in ("fixture", "approved"), "unknown source manifest version/mode")
    integer(manifest["seed"], 0, 2**32 - 1)
    fields(manifest["augmentation"], ("max_variants", "max_prefixes"))
    integer(manifest["augmentation"]["max_variants"], 0, 8)
    integer(manifest["augmentation"]["max_prefixes"], 0, 8)
    require(isinstance(manifest["sources"], list) and manifest["sources"], "sources required")
    base = Path(manifest_path).resolve().parent
    records, source_ids = [], set()
    for source in manifest["sources"]:
        fields(source, ("source_id", "records"), ("approval",))
        require(isinstance(source["source_id"], str) and source["source_id"] and source["source_id"] not in source_ids,
                "source IDs must be unique")
        source_ids.add(source["source_id"])
        path = checked_file(base, source["records"])
        batch = [parse(line) for line in path.read_bytes().splitlines() if line.strip()]
        if manifest["mode"] == "approved":
            approval = source.get("approval", {})
            fields(approval, ("status", "reviewer", "reviewed_at", "license_id", "source_url", "retrieved_at",
                              "allowed_uses", "evidence", "grouping_rule", "processing", "privacy_reviewed"))
            require(approval["status"] == "approved" and approval["privacy_reviewed"] is True, "approval/privacy review required")
            for key in ("reviewer", "reviewed_at", "license_id", "source_url", "retrieved_at", "grouping_rule", "processing"):
                require(isinstance(approval[key], str) and approval[key].strip(), "incomplete rights provenance")
            for key in ("reviewed_at", "retrieved_at"):
                date.fromisoformat(approval[key])
            require(isinstance(approval["allowed_uses"], list) and
                    {"training", "evaluation", "derived_model"} <= set(approval["allowed_uses"]), "rights do not cover pipeline use")
            checked_file(base, approval["evidence"])
        else:
            require("approval" not in source, "fixture mode cannot assert production approval")
        for record in batch:
            require(isinstance(record, dict), "record must be an object")
            provenance = record.get("provenance", {})
            require(provenance.get("source_id") == source["source_id"], "record/source provenance mismatch")
            if manifest["mode"] == "fixture":
                require(provenance.get("kind") == "authored_fixture" and provenance.get("rights_status") == "fixture_only"
                        and record.get("split") == "fixture", "fixture records must remain fixture-only")
            else:
                require(provenance.get("kind") in ("authored", "licensed", "synthetic_approved") and
                        provenance.get("rights_status") == "approved" and record.get("split") == "unassigned",
                        "approved inputs must be reviewed, unsplit, and not fixtures")
                for key in ("license_id", "source_url", "retrieved_at"):
                    require(provenance.get(key) == source["approval"][key], "record approval metadata mismatch")
                # Input-only extension; the supplied v1/v2 runtime record schemas stay unchanged.
                record["split"] = "train"
            records.append(record)
    validate_records(records)
    return manifest, records


def near_key(raw):
    # Used only for leakage checks, never as model input or a replacement for raw.
    return re.sub(r"\d+", "#", " ".join(raw.lower().split()))


def group_split(records, seed):
    parent = {r["group_id"]: r["group_id"] for r in records}

    def root(group):
        while parent[group] != group:
            parent[group] = parent[parent[group]]
            group = parent[group]
        return group

    # Exact/near duplicate originals and same-raw context contrasts stay in one component.
    # O(n²) intentionally: fail closed for the initial reviewed small corpus, no silent sampling.
    require(len(records) <= 10000, "initial pipeline supports at most 10000 source records")
    keys = [near_key(r["raw"]) for r in records]
    for i, left in enumerate(records):
        for j in range(i):
            same = keys[i] == keys[j]
            close = (min(len(keys[i]), len(keys[j])) >= 12 and
                     min(len(keys[i]), len(keys[j])) / max(len(keys[i]), len(keys[j])) >= .95 and
                     SequenceMatcher(None, keys[i], keys[j], autojunk=False).ratio() >= .95)
            if same or close:
                a, b = sorted((root(left["group_id"]), root(records[j]["group_id"])))
                parent[b] = a
    components = sorted({root(g) for g in parent}, key=lambda g: (fingerprint([seed, g]), g))
    require(len(components) >= 10, "need at least ten independent source groups for four-way split")
    # Largest remainder allocation; rounding is reported, not silently called exact 70/10/10/10.
    counts = [len(components) * p // 10 for p in (7, 1, 1, 1)]
    order = sorted(range(4), key=lambda i: (-(len(components) * (7, 1, 1, 1)[i] % 10), i))
    for i in order[:len(components) - sum(counts)]:
        counts[i] += 1
    assignments, offset = {}, 0
    for split, count in zip(SPLITS, counts):
        for component in components[offset:offset + count]:
            assignments[component] = split
        offset += count
    return {g: {"component": root(g), "split": assignments[root(g)]} for g in sorted(parent)}


def roman_table():
    path = local_file(ROOT, ROMAN_TABLE)
    require(digest(path.read_bytes()) == ROMAN_SHA256, "pinned Converter roman table checksum changed")
    pairs = re.findall(r'^\s*"([a-z]+)": "([\u3041-\u3096]+)",?$', path.read_text(), re.MULTILINE)
    # Only complete kana-producing, vowel-ending rules. n, apostrophe, doubled consonants,
    # incremental suffix rules and special mappings are intentionally outside this augmenter.
    return {key: kana for key, kana in pairs if key[-1] in "aeiou"}


def roman_alternatives(raw, table):
    tokens, cursor = [], 0
    ordered = sorted(table, key=lambda key: (-len(key), key))
    while cursor < len(raw):
        token = next((t for t in ordered if raw.startswith(t, cursor)), None)
        if token is None:
            return []
        tokens.append(token)
        cursor += len(token)
    variants = []
    for i, token in enumerate(tokens):
        for alternative in sorted(t for t in table if t != token and table[t] == table[token]):
            variants.append("".join(tokens[:i] + [alternative] + tokens[i + 1:]))
    return sorted(set(variants))


def variants(record, table, limit):
    outputs = []
    for i, span in enumerate(record["spans"]):
        if span["label"] != "JA_ROMAN":
            continue
        start, end = span["start"], span["end"]
        for raw in roman_alternatives(record["raw"][start:end], table):
            item = copy.deepcopy(record)
            item["raw"] = record["raw"][:start] + raw + record["raw"][end:]
            if len(item["raw"]) > 256:
                continue
            delta = len(raw) - (end - start)
            item["spans"][i]["end"] += delta
            for following in item["spans"][i + 1:]:
                following["start"] += delta
                following["end"] += delta
            outputs.append(item)
    return outputs[:limit]


def prefixes(record, seed, limit):
    # Shortest ASCII prefixes first; no cut before a combining mark/ZWJ/emoji component.
    # We augment only at ASCII scalar boundaries, leaving Unicode graphemes intact.
    ends = [i for i in range(1, len(record["raw"]))
            if record["raw"][i - 1].isascii() and record["raw"][i].isascii()]
    chosen = ends[:min(2, limit)]
    rest = sorted(ends[len(chosen):], key=lambda i: fingerprint([seed, record["id"], record["raw"], i]))
    for end in sorted(chosen + rest[:max(0, limit - len(chosen))]):
        item = copy.deepcopy(record)
        item["raw"] = record["raw"][:end]
        item["spans"] = [dict(span, end=min(span["end"], end)) for span in record["spans"] if span["start"] < end]
        yield item


def build_dataset(manifest_path):
    manifest, records = load_sources(manifest_path)
    records.sort(key=lambda r: r["id"])
    groups = group_split(records, manifest["seed"])  # Freeze BEFORE either augmentation.
    table = roman_table() if manifest["augmentation"]["max_variants"] else {}
    rows = []
    for record in records:
        record["split"] = groups[record["group_id"]]["split"]
        full = [record] + variants(record, table, manifest["augmentation"]["max_variants"])
        additions = [(full[0], "original")] + [(r, "roman_variant") for r in full[1:]]
        # At most eight prefixes per original, not eight per generated spelling.
        prefix_candidates = [(r, "prefix") for item in full for r in prefixes(item, manifest["seed"], 8)]
        prefix_candidates.sort(key=lambda pair: (len(pair[0]["raw"]) > 2, fingerprint(pair[0])))
        additions += prefix_candidates[:manifest["augmentation"]["max_prefixes"]]
        seen = set()
        for item, augmentation in additions:
            identity = fingerprint([item["raw"], item["spans"], record_context(item)])
            if identity in seen:
                continue
            seen.add(identity)
            item = copy.deepcopy(item)
            item["id"] = fingerprint([record["id"], augmentation, identity])
            rows.append(dict(record=item, original_id=record["id"], augmentation=augmentation))
    # Derived text shared by different splits is pruned, never moved to a new split.
    # Originals already share a component. This also removes commonplace short-prefix collisions.
    owners = defaultdict(set)
    for row in rows:
        owners[near_key(row["record"]["raw"])].add(row["record"]["split"])
    kept = [r for r in rows if r["augmentation"] == "original" or len(owners[near_key(r["record"]["raw"])]) == 1]
    dropped = len(rows) - len(kept)
    validate_records([r["record"] for r in kept])
    from swift_bridge import validate_in_swift
    validate_in_swift(kept, {r["id"]: r for r in records})
    bundle = dict(schema_version=1, mode=manifest["mode"], seed=manifest["seed"], source_manifest=manifest,
                  source_manifest_sha256=fingerprint(manifest), groups=groups, rows=kept,
                  pruned_cross_split_augmentations=dropped, roman_revision=ROMAN_REVISION,
                  roman_table_sha256=ROMAN_SHA256 if table else None)
    bundle["dataset_sha256"] = fingerprint(bundle)
    return bundle


def load_dataset(path):
    bundle = read(path)
    expected = bundle.pop("dataset_sha256", None)
    require(expected == fingerprint(bundle), "dataset checksum mismatch")
    bundle["dataset_sha256"] = expected
    require(bundle["mode"] in ("fixture", "approved"), "unknown dataset mode")
    require(bundle["mode"] == bundle["source_manifest"]["mode"] and
            bundle["source_manifest_sha256"] == fingerprint(bundle["source_manifest"]), "source manifest/mode mismatch")
    validate_records([row["record"] for row in bundle["rows"]])
    for row in bundle["rows"]:
        record = row["record"]
        require(bundle["groups"][record["group_id"]]["split"] == record["split"], "derived record escaped source group")
        expected_rights = "fixture_only" if bundle["mode"] == "fixture" else "approved"
        require(record["provenance"]["rights_status"] == expected_rights, "dataset rights taint mismatch")
        require(len(row["protections"]) == len(record["raw"]) and set(row["protections"]) <= {"inferred", "raw", "literal", "gap"},
                "invalid stored protection mask")
    return bundle
