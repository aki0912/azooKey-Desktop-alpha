"""Validate bundle fixtures. Optional jsonschema improves structural validation."""
from __future__ import annotations
import json
import sys
from pathlib import Path
from auto_mixed_reference import validate_record_set, validate_model

ROOT = Path(__file__).resolve().parents[1]
def load(path):
    return json.loads((ROOT/path).read_text(encoding='utf-8'))

def main() -> int:
    records = [json.loads(s) for s in (ROOT/'fixtures/span_cases.jsonl').read_text(encoding='utf-8').splitlines() if s.strip()]
    validate_record_set(records)
    model = load('fixtures/language_model_fixture.json')
    validate_model(model, allow_fixture=True)
    vectors = load('fixtures/feature_golden.json')['vectors']
    events = load('fixtures/event_cases.json')['cases']
    assert len({e['id'] for e in events}) == len(events), 'event IDs must be unique'
    assert all(e['events'] and e['expected'] for e in events), 'event contracts must be nonempty'
    try:
        import jsonschema
    except ImportError:
        print('JSON Schema: not run (jsonschema not installed); semantic validation passed.')
    else:
        for schema_name, instances in [('span_record.schema.json', records),('language_model.schema.json',[model])]:
            schema = load('schemas/'+schema_name)
            jsonschema.Draft202012Validator.check_schema(schema)
            validator = jsonschema.Draft202012Validator(schema)
            for instance in instances:
                validator.validate(instance)
        print('JSON Schema: passed (Draft 2020-12).')
    print(f'Span records: {len(records)} valid; golden vectors: {len(vectors)}; event contracts: {len(events)} structurally valid.')
    print('NOT executed: Swift parity, LR training, macOS build, real Zenzai, IMK event contracts.')
    return 0

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, KeyError, AssertionError, OSError) as exc:
        print(f'Validation failed: {exc}', file=sys.stderr)
        raise SystemExit(1)
