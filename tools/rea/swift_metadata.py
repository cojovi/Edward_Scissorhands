#!/usr/bin/env python3
"""Read supported Swift nominal field descriptors without loading target code.

Layout reference: swiftlang/swift include/swift/RemoteInspection/Records.h and
include/swift/ABI/Metadata.h. Relative pointers remain source-bound; unsupported
indirect parents are marked instead of guessed. This is supplemental analysis,
not an authenticated REA Evidence record or recovered source code.
"""
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / 'research/evidence/Cloth.arm64'
image = TARGET.read_bytes()
metadata = json.loads((ROOT / 'research/evidence/macho.json').read_text())['normalized_result']
segments = metadata['segments']['items']
section = next(s for g in segments for s in g['sections']['items'] if s['name'] == '__swift5_types')

def offset(address):
    for segment in segments:
        start = int(segment['vm_address'], 16)
        if start <= address < start + segment['file_size']:
            return segment['file_offset'] + address - start
    raise ValueError(f'Unmapped address: {address:#x}')

def uint32(address):
    return struct.unpack_from('<I', image, offset(address))[0]

def relative(address):
    value = struct.unpack_from('<i', image, offset(address))[0]
    return address + value if value else None

def string(address):
    if address is None:
        return None
    start = offset(address)
    return image[start:image.index(b'\0', start)].decode('utf-8', 'strict')

def context(address, visited=()):
    if not address:
        return None
    if address in visited:
        raise ValueError('Cyclic context descriptor')
    kind = uint32(address) & 31
    if kind in (0, 3, 16, 17, 18):
        name = string(relative(address + 8))
    elif kind == 1:
        name = 'extension'
    else:
        name = 'anonymous'
    parent = relative(address + 4)
    if parent and parent & 1:
        return 'indirect-parent.' + str(name)
    prefix = context(parent, (*visited, address))
    return (prefix + '.' if prefix else '') + str(name)

rows, errors, skipped = [], [], []
start = int(section['address'], 16)
for location in range(start, start + section['size'], 4):
    try:
        descriptor = relative(location)
        if descriptor is None or descriptor & 1:
            skipped.append({'at': hex(location), 'reason': 'null or indirect descriptor'})
            continue
        name = context(descriptor)
        if not name.startswith('Cloth.'):
            continue
        field_descriptor = relative(descriptor + 16)
        fields = []
        if field_descriptor:
            kind, record_size, count = struct.unpack_from('<HHI', image, offset(field_descriptor) + 8)
            if record_size != 12:
                raise ValueError(f'Unsupported field record size: {record_size}')
            for ordinal in range(count):
                record = field_descriptor + 16 + ordinal * record_size
                fields.append(string(relative(record + 8)))
        accessor = relative(descriptor + 12)
        rows.append({'name': name, 'descriptor': hex(descriptor), 'metadata_accessor': hex(accessor) if accessor else None, 'fields': fields})
    except Exception as error:
        errors.append({'at': hex(location), 'error': str(error)})

result = {
    'authority': 'Derived from Swift nominal type/field metadata in the hashed arm64 slice; not original source; property runtime behavior unverified',
    'source_sha256': hashlib.sha256(image).hexdigest(),
    'layout_references': ['https://github.com/swiftlang/swift/blob/main/include/swift/RemoteInspection/Records.h', 'https://github.com/swiftlang/swift/blob/main/include/swift/ABI/Metadata.h'],
    'type_table_entries': section['size'] // 4,
    'module_filter': 'Cloth',
    'types': rows,
    'errors': errors,
    'skipped': skipped,
}
(ROOT / 'research/swift-type-fields.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'types': len(rows), 'errors': len(errors), 'skipped': len(skipped)}))
