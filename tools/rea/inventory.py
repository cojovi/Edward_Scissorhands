#!/usr/bin/env python3
"""Retain reproducible read-only inventories without copying proprietary assets."""
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[2]
REA = Path('/Volumes/FastSSD/github/clones/rea')
CLOTH = Path('/Applications/Setapp/Cloth.app')
OUT = ROOT / 'research'
EVIDENCE = OUT / 'evidence'

def category(path):
    first = path.split('/')[0]
    if first == '.git': return 'vcs-internals'
    if first in ('node_modules', 'third_party'): return 'dependency-or-third-party'
    if first in ('dist', '.cache', '.turbo', 'skills'): return 'generated-or-cache'
    if first in ('tests', 'experiments') or '.test.' in path: return 'test-or-experiment'
    if first in ('docs', 'licenses') or path.endswith('.md'): return 'documentation-or-license'
    if first == 'website': return 'website'
    return 'authored-source-or-configuration'

def paths(root, hashes=False):
    items=[]
    for base, dirs, files in os.walk(root, followlinks=False):
        for name in sorted(dirs+files):
            p=Path(base)/name; rel=p.relative_to(root).as_posix()
            if p.is_symlink():
                items.append({'path':rel,'kind':'symlink','target':os.readlink(p)})
            elif p.is_dir(): items.append({'path':rel,'kind':'directory'})
            else:
                row={'path':rel,'kind':'file','size':p.stat().st_size}
                if hashes:
                    with p.open('rb') as f: row['sha256']=hashlib.file_digest(f,'sha256').hexdigest()
                items.append(row)
    return sorted(items,key=lambda x:x['path'])

def shape(v):
    if isinstance(v,dict): return {k:shape(x) for k,x in v.items()}
    if isinstance(v,list):
        schemas=[]
        for x in v:
            s=shape(x)
            if s not in schemas: schemas.append(s)
        return {'type':'array','length':len(v),'item_schemas':schemas}
    if isinstance(v,bool):return 'boolean'
    if isinstance(v,(int,float)):return 'number'
    if isinstance(v,str):return 'string'
    return 'null'

if __name__ == '__main__':
    EVIDENCE.mkdir(parents=True,exist_ok=True)
    rea=paths(REA)
    for row in rea:row['classification']=category(row['path'])
    (EVIDENCE/'rea-tree.json').write_text(json.dumps(rea,indent=2)+'\n')
    cloth=paths(CLOTH,True)
    (OUT/'cloth-manifest.json').write_text(json.dumps({'root':str(CLOTH),'recorded_at':datetime.now(timezone.utc).isoformat(),'entries':cloth},indent=2)+'\n')
    plist=plistlib.loads((CLOTH/'Contents/Info.plist').read_bytes())
    allowed=['CFBundleName','CFBundleIdentifier','CFBundleExecutable','CFBundleShortVersionString','CFBundleVersion','LSMinimumSystemVersion','CFBundleDocumentTypes','MPSupportedArchitectures','CFBundleURLTypes','MDItemKeywords']
    metadata={k:plist[k] for k in allowed if k in plist}
    (OUT/'cloth-metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
    schemas={}
    for name in ['demo.json','onboarding-source.json','onboarding-clip-1.json','onboarding-clip-2.json','onboarding-clip-3.json']:
        schemas[name]=shape(json.loads((CLOTH/'Contents/Resources'/name).read_text()))
    (OUT/'sample-data-schemas.json').write_text(json.dumps({'authority':'packaged example data; not yet established as production persistence schema','schemas':schemas},indent=2)+'\n')
    revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=REA,text=True).strip()
    summary={'rea_root':str(REA),'rea_revision':revision,'rea_entries':len(rea),'rea_classifications':dict(Counter(r['classification'] for r in rea)),'cloth_file_count':sum(r['kind']=='file' for r in cloth),'cloth_directory_count':sum(r['kind']=='directory' for r in cloth),'cloth_symlink_count':sum(r['kind']=='symlink' for r in cloth),'limitations':['REA inventory classifies every path but does not claim semantic review of every dependency/generated file.','Cloth manifest hashes every regular file; hashing is not semantic analysis.','Secrets are excluded from the selected plist projection.']}
    (OUT/'inventory-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps(summary,indent=2))
