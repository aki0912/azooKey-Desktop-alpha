"""Bounded punctuation/context contrasts, called only after original-group splitting."""
import copy

from context_features import record_context
from pipeline_io import fingerprint

POLICY = "punctuation-context-v1"


def eligible(record):
    # Do not erase a context that supplies the intent of an ambiguous short word.
    # Structural tokens and incomplete/numeric authored examples remain explicit sources.
    return (record_context(record) in (None, "") and len(record["raw"]) >= 8
            and record["raw"][-1:].isascii() and record["raw"][-1:].isalpha()
            and all(s["label"] in ("JA_ROMAN", "RAW", "GAP") for s in record["spans"]))


def surround(record, left, right):
    item = copy.deepcopy(record)
    item["raw"] = left + record["raw"] + right
    offset = len(left)
    spans = ([dict(start=0, end=offset, label="LITERAL")] if left else [])
    spans += [dict(s, start=s["start"] + offset, end=s["end"] + offset) for s in record["spans"]]
    end = offset + len(record["raw"])
    if right:
        spans.append(dict(start=end, end=end + len(right), label="LITERAL"))
    item["spans"] = spans
    item.pop("desired_display", None)
    return item


def contrasts(record, roman_variants):
    if not eligible(record):
        return []
    selector = int(fingerprint(record["id"])[:8], 16)
    punctuation = [surround(record, "", "."),
                   surround(record, "", (",", "!", "?", "...", ":", ";")[selector % 6]),
                   surround(record, *[("[", "]"), ("(", ")"), ('"', '"')][selector % 3])]
    # Keep spelling variation at punctuation boundaries, without a Cartesian expansion.
    if roman_variants:
        punctuation.append(surround(roman_variants[0], "", "."))
    output = [(r, "boundary_variant") for r in punctuation if len(r["raw"]) <= 256]
    for original in [record] + [r for r, _ in output]:
        item = copy.deepcopy(original)
        if record_context(item) is None:
            item.update(context_available=True, left_context="")
        else:
            item["context_available"] = False
            item.pop("left_context", None)
        output.append((item, "context_variant"))
    return output
