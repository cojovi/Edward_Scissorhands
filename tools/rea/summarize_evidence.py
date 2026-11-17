#!/usr/bin/env python3
"""Make a compact provenance index without copying pseudocode or target literals."""
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
RESEARCH = ROOT / 'research'
RAW = RESEARCH / 'evidence'

def unwrap(path):
    data = json.loads(path.read_text())
    if 'structuredContent' in data:
        return data['structuredContent']
    if 'content' in data:
        for item in data['content']:
            if item.get('type') == 'text':
                try:
                    return json.loads(item['text'])
                except json.JSONDecodeError:
                    continue
    return data

records = {}
for path in sorted(RAW.glob('*.json')):
    if not (re.match(r'^\d{3}-', path.name) or path.name in {
        'artifact-inspection.json', 'macho.json', 'signature.json',
        'dylib-resolution.json', 'dispatch-full.json',
    }):
        continue
    envelope = unwrap(path)
    identity = envelope.get('evidence_id')
    if not identity:
        continue
    records[identity] = {
        'evidence_id': identity,
        'operation': envelope.get('operation'),
        'authority': envelope.get('authority'),
        'confidence': envelope.get('confidence'),
        'limitation_count': len(envelope.get('limitations', [])),
        'limitation_examples': [str(value)[:400] for value in envelope.get('limitations', [])[:6]],
        'full_limitations_retained_in_source_file': True,
        'file': str(path.relative_to(RESEARCH)),
        'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
    }

traces = []
for path in sorted(RAW.glob('22?-trace-*.json')):
    envelope = unwrap(path)
    result = envelope.get('normalized_result', {})
    traces.append({
        'file': str(path.relative_to(RESEARCH)),
        'evidence_id': envelope.get('evidence_id'),
        'start': result.get('start'),
        'nodes': len(result.get('nodes', [])),
        'edges': len(result.get('edges', [])),
        'unresolved': len(result.get('unresolved', [])),
        'truncated': result.get('truncated'),
        'reason': result.get('reason'),
        'coverage': result.get('coverage'),
        'limitation_count': len(result.get('limitations', [])),
        'limitation_examples': [str(value)[:400] for value in result.get('limitations', [])[:6]],
    })

index = {
    'rea_records': list(records.values()),
    'bounded_native_traces': traces,
    'supplemental_records': [
        'cloth-manifest.json', 'cloth-metadata.json', 'sample-data-schemas.json',
        'swift-type-fields.json', 'caption-safearea-facts.json',
        'runtime-observations.md', 'analysis-target.json', 'toolchain.json',
        'native-findings.md', 'implementation-gap-audit.md',
    ],
    'caveat': 'Supplemental records are not authenticated REA Evidence. Native graphs are bounded static traces, not controlled replay. No original paid-service replay occurred.',
}
(RESEARCH / 'evidence-index.json').write_text(json.dumps(index, indent=2) + '\n')
print(json.dumps({'indexed_evidence_records': len(records), 'bounded_traces': len(traces)}))
