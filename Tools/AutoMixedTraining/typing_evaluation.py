"""Development-only prefix evaluation through the actual Swift Japanese-preferred policy."""
from collections import Counter
import math
import os
from pathlib import Path
import platform
import subprocess
import tempfile

from context_features import record_context
from learning import rows_for, validate_model
from pipeline_io import ROOT, digest, encoded, read, require

KINDS = {'japaneseRoman', 'japaneseKana', 'raw', 'unresolved', 'literal', 'gap'}
JAPANESE = {'japaneseRoman', 'japaneseKana'}


def frame_labels(frame):
    require(type(frame['end']) is int and frame['end'] >= 0, 'invalid typing endpoint')
    cursor, result = 0, []
    for span in frame['spans']:
        require(span['kind'] in KINDS and span['start'] == cursor and cursor < span['end'] <= frame['end'],
                'invalid typing span coverage')
        result.extend([span['kind']] * (span['end'] - cursor))
        cursor = span['end']
    require(cursor == frame['end'], 'incomplete typing coverage')
    return result


def summarize(rows, responses):
    require(len(rows) == len(responses), 'typing row count mismatch')
    phases = {p: Counter() for p in ('forward', 'backward', 'paste')}
    latencies = {p: [] for p in phases}
    consistency = Counter()
    for row, response in zip(rows, responses):
        record = row['record']
        forward = response['forward']
        ends = [frame['end'] for frame in forward]
        require(ends and ends[0] == 0 and ends[-1] == len(record['raw']) and
                all(a < b for a, b in zip(ends, ends[1:])), 'invalid forward trace endpoints')
        require([f['end'] for f in response['paste']] == ends and
                [f['end'] for f in response['backward']] == list(reversed(ends[:-1])), 'trace directions do not align')
        expected = [s['label'] for s in record['spans'] for _ in range(s['start'], s['end'])]
        forward_spans = {f['end']: f['spans'] for f in forward}
        for phase, frames in response.items():
            require(phase in phases, 'unknown typing phase')
            counts = phases[phase]
            previous = None
            for frame in frames:
                labels = frame_labels(frame)
                require(math.isfinite(frame['milliseconds']) and frame['milliseconds'] >= 0, 'invalid typing latency')
                latencies[phase].append(frame['milliseconds'])
                counts['snapshots'] += 1
                if previous is not None:
                    counts['transitions'] += 1
                    counts['changed_existing_kind_positions'] += sum(a != b for a, b in zip(previous, labels))
                    counts['compared_existing_positions'] += min(len(previous), len(labels))
                previous = labels
                if phase != 'forward':
                    consistency[phase + '_comparisons'] += 1
                    consistency[phase + '_span_differences'] += frame['spans'] != forward_spans[frame['end']]
                for i, actual in enumerate(labels):
                    if expected[i] not in ('RAW', 'JA_ROMAN') or not record['raw'][i].isascii() or not record['raw'][i].isalpha():
                        continue
                    positive = actual in JAPANESE
                    counts['tp' if expected[i] == 'JA_ROMAN' and positive else
                           'fn' if expected[i] == 'JA_ROMAN' else 'fp' if positive else 'tn'] += 1
                    counts['unresolved_positions'] += actual == 'unresolved'
                # Count a gold English span only after its full spelling is present.
                # Each later snapshot is another exposure, not an independent sample.
                for span in record['spans']:
                    if span['label'] == 'RAW' and span['end'] <= frame['end']:
                        counts['complete_english_span_exposures'] += 1
                        counts['damaged_complete_english_span_exposures'] += any(
                            label in JAPANESE for label in labels[span['start']:span['end']])
    def ratio(a, b): return a / b if b else None
    output = {}
    for phase, c in phases.items():
        samples = sorted(latencies[phase])
        output[phase] = dict(counts=dict(c),
            ja_recall=ratio(c['tp'], c['tp'] + c['fn']), ja_precision=ratio(c['tp'], c['tp'] + c['fp']),
            complete_english_span_damage_rate=ratio(c['damaged_complete_english_span_exposures'], c['complete_english_span_exposures']),
            segment_milliseconds=dict(p50=samples[math.ceil(len(samples)*.5)-1] if samples else None,
                                      p95=samples[math.ceil(len(samples)*.95)-1] if samples else None))
    return dict(originals=len(rows), phases=output, consistency=dict(consistency))


def evaluate_typing(data, model_path):
    model_path = Path(model_path).resolve()
    model = read(model_path)
    validate_model(model)
    require(model['kind'] == 'production' and model['feature_spec_version'] == 'anchored-context-v2',
            'typing evaluation requires a trained v2 export')
    require(data['mode'] == 'approved', 'typing evaluation requires approved authored data')
    rows = rows_for(data, 'dev', True)
    require(rows, 'typing evaluation needs dev originals')
    request = dict(rows=[dict(raw=r['record']['raw'], left_context=record_context(r['record'])) for r in rows])
    work = ROOT / 'build/auto-mixed'
    work.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='typing-evaluation-', dir=work) as temporary:
        folder = Path(temporary)
        input_file, output_file = folder/'request.json', folder/'response.json'
        input_file.write_bytes(encoded(request))
        env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(work/'clang-cache'),
            SWIFTPM_MODULECACHE_OVERRIDE=str(work/'swift-cache'), AUTO_MIXED_TYPING_REQUEST=str(input_file),
            AUTO_MIXED_TYPING_RESPONSE=str(output_file), AUTO_MIXED_TYPING_MODEL=str(model_path))
        command = ['swift', 'test', '--package-path', 'Core', '--scratch-path', str(work/'core'),
                   '--cache-path', str(work/'cache'), '--disable-sandbox', '--filter', 'AutoMixedTypingEvaluationTests']
        if platform.system() == 'Darwin': command += ['--build-system', 'native']
        # Corpus processing is muted in the dedicated Swift harness, including DEBUG prints.
        log_path = work / ('typing-evaluation-' + folder.name.removeprefix('typing-evaluation-') + '.log')
        with log_path.open('xb') as log:
            result = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=log, timeout=1800)
        require(result.returncode == 0 and output_file.exists(), 'Swift typing evaluation failed; see isolated build log')
        response = read(output_file)
        require(response['request_sha256'] == digest(input_file.read_bytes()) and
                response['model_sha256'] == digest(model_path.read_bytes()), 'typing response fingerprint mismatch')
        report = summarize(rows, response['rows'])
        by_context = {}
        for state in ('unavailable', 'empty', 'nonempty'):
            indices = [i for i,r in enumerate(rows) if ('unavailable' if record_context(r['record']) is None else
                       'empty' if record_context(r['record']) == '' else 'nonempty') == state]
            by_context[state] = summarize([rows[i] for i in indices], [response['rows'][i] for i in indices])
    return dict(schema_version=1, evaluation_kind='development_runtime_typing', partition='dev',
        dataset_sha256=data['dataset_sha256'], model_sha256=digest(model_path.read_bytes()),
        implementation_sha256={path: digest((ROOT / path).read_bytes()) for path in (
            'Core/Sources/Core/InputUtils/AutoMixed/JapanesePreferredSegmenter.swift',
            'Core/Sources/Core/InputUtils/AutoMixed/EnglishLexicon.swift',
            'Core/Tests/CoreTests/TrainingTests/AutoMixedTypingEvaluationTests.swift',
            'Tools/AutoMixedTraining/typing_evaluation.py')},
        report=report, by_context=by_context, log=str(log_path.relative_to(ROOT)), release_ready=False,
        interpretation=['Gold labels express full-sentence intent; short prefixes can be inherently ambiguous.',
                        'Exposure counts and latency samples are correlated, not independent examples.',
                        'Paste/backspace differences may include deliberate English hysteresis.',
                        'Grapheme prefixes recompute features, protections and Japanese-preferred policy.'],
        not_evaluated=['kanji/kana candidate surfaces', 'real Zenzai', 'IMK', 'independent test quality'],
        selection_role='candidate review evidence; no automatic threshold ranking or release approval')
