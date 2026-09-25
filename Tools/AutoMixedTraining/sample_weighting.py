"""Training-only mass allocation; no corpus text or original IDs in the audit."""
from collections import Counter

from pipeline_io import fields, number, require

PREFIX_POLICY = "prefix-mass-v1"
AUGMENTATIONS = {"original", "roman_variant", "prefix", "boundary_variant", "context_variant"}


def validate_weighting(policy):
    fields(policy, ("policy", "prefix_fraction"))
    require(policy["policy"] == PREFIX_POLICY, "unknown sample weighting policy")
    number(policy["prefix_fraction"], 0, 1)
    require(0 < policy["prefix_fraction"] < 1, "both training families need positive mass")


def row_position_weights(rows, sizes, policy=None):
    """One weight per eligible position in each row, with unit mass per original.

    The legacy path is exactly uniform over positions. Opt-in reserves a fraction
    for prefixes; if only one family has eligible positions it receives all mass.
    Authored incomplete originals remain non-prefix examples, not new variants.
    """
    require(len(rows) == len(sizes), "weight row count mismatch")
    totals, families = Counter(), Counter()
    if policy is not None:
        validate_weighting(policy)
    for row, size in zip(rows, sizes):
        original = row["original_id"]
        totals[original] += size
        if policy is not None:
            require(row["record"]["split"] == "train", "prefix weighting is training-only")
            require(row.get("augmentation") in AUGMENTATIONS, "unknown weighted augmentation")
            families[original, row["augmentation"] == "prefix"] += size
    weights = []
    for row, size in zip(rows, sizes):
        original = row["original_id"]
        if not size:
            weights.append(0.0)
        elif policy is None:
            weights.append(1 / totals[original])
        else:
            prefix = row["augmentation"] == "prefix"
            fraction = policy["prefix_fraction"] if prefix else 1 - policy["prefix_fraction"]
            if not families[original, not prefix]:
                fraction = 1.0
            weights.append(fraction / families[original, prefix])
    return weights


def weighting_audit(rows, sizes, weights):
    """Aggregate counts/mass only, to distinguish augmentation volume from influence."""
    eligible, mass = Counter(), Counter()
    originals = {}
    for row, size, weight in zip(rows, sizes, weights):
        kind = row["augmentation"]
        eligible[kind] += size
        mass[kind] += size * weight
        families = originals.setdefault(row["original_id"], set())
        if size:
            families.add("prefix" if kind == "prefix" else "non_prefix")
    counts = Counter("both" if len(f) == 2 else next(iter(f)) if f else "no_eligible_positions"
                     for f in originals.values())
    return dict(originals=len(originals), originals_by_eligible_family=dict(counts),
                eligible_positions_by_augmentation=dict(eligible), mass_by_augmentation=dict(mass),
                total_mass=sum(mass.values()))
