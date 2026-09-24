import copy
import json
import unittest

from learning import rows_for
from pipeline import parser
from pipeline_io import PipelineError
from typing_evaluation import frame_labels, summarize


def frame(labels):
    spans = []
    for i, kind in enumerate(labels):
        if spans and spans[-1]['kind'] == kind:
            spans[-1]['end'] = i + 1
        else:
            spans.append(dict(start=i, end=i+1, kind=kind))
    return dict(end=len(labels), milliseconds=1.0, spans=spans)


class TypingEvaluationTests(unittest.TestCase):
    def example(self):
        row = dict(augmentation='original', record=dict(raw='noteg', split='dev',
            spans=[dict(start=0, end=4, label='RAW'), dict(start=4, end=5, label='JA_ROMAN')]))
        forward = [frame([]), frame(['japaneseKana'])] + [frame(['raw']*n) for n in range(2,5)]
        forward.append(frame(['japaneseKana']*5))
        paste = copy.deepcopy(forward)
        paste[-1] = frame(['raw']*4+['japaneseKana'])
        return [row], [dict(forward=forward, backward=list(reversed(forward[:-1])), paste=paste)]

    def test_complete_english_exposure_waits_for_full_spelling(self):
        report = summarize(*self.example())
        forward = report['phases']['forward']
        self.assertEqual(forward['counts']['complete_english_span_exposures'], 2)
        self.assertEqual(forward['counts']['damaged_complete_english_span_exposures'], 1)
        self.assertEqual(forward['complete_english_span_damage_rate'], .5)
        self.assertEqual(report['phases']['backward']['counts'].get('damaged_complete_english_span_exposures', 0), 0)
        self.assertEqual(report['phases']['paste']['complete_english_span_damage_rate'], 0)
        self.assertEqual(report['consistency']['paste_span_differences'], 1)
        self.assertEqual(report['consistency']['backward_span_differences'], 0)
        self.assertEqual(forward['counts']['changed_existing_kind_positions'], 5)
        self.assertNotIn('noteg', json.dumps(report))

    def test_unicode_offsets_and_kanji_reading_boundaries_are_distinct(self):
        row = dict(record=dict(raw='👩‍💻ka', spans=[dict(start=0, end=3, label='LITERAL'),
                        dict(start=3, end=5, label='JA_ROMAN')]))
        forward = [frame([]), frame(['literal']*3), frame(['literal']*3+['japaneseKana']),
                   frame(['literal']*3+['japaneseRoman']*2)]
        paste = copy.deepcopy(forward)
        paste[-1] = frame(['literal']*3+['japaneseKana']*2)
        result = summarize([row], [dict(forward=forward, backward=list(reversed(forward[:-1])), paste=paste)])
        self.assertEqual(result['phases']['forward']['ja_recall'], 1)
        self.assertEqual(result['consistency']['paste_span_differences'], 1)
        self.assertIsNone(result['phases']['forward']['complete_english_span_damage_rate'])

    def test_refuses_broken_coverage_or_trace_alignment(self):
        for bad in [dict(end=2, spans=[dict(start=1,end=2,kind='raw')]),
                    dict(end=1, spans=[dict(start=0,end=1,kind='unknown')])]:
            with self.assertRaises(PipelineError): frame_labels(bad)
        rows, result = self.example()
        result[0]['backward'].reverse()
        with self.assertRaises(PipelineError): summarize(rows, result)

    def test_empty_context_category_has_null_metrics(self):
        result = summarize([], [])
        self.assertEqual(result['originals'], 0)
        self.assertIsNone(result['phases']['forward']['ja_recall'])

    def test_development_selection_excludes_other_partitions_and_augmentations(self):
        rows = [dict(record=dict(split=split), augmentation=kind) for split in
                ('train','dev','calibration','test') for kind in ('original','prefix','context_variant')]
        self.assertEqual(rows_for(dict(rows=rows), 'dev', True), [rows[3]])
        args = parser().parse_args(['evaluate-typing','--model','model.json','--data','dataset.json','--output','out.json'])
        self.assertFalse(hasattr(args, 'test'))


if __name__ == '__main__': unittest.main()
