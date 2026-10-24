#!/usr/bin/env python3
"""Archive without FileProvider/Finder xattrs and verify the extracted signed app."""
import argparse
import json
import shutil
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile
root=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser()
parser.add_argument('--app',type=Path,default=root/'outputs/Pickup Pilot.app')
args=parser.parse_args()
app=args.app.resolve()
output_app=root/'outputs/Pickup Pilot.app'
archive=root/'outputs/Pickup Pilot.app.zip'
archive.parent.mkdir(parents=True,exist_ok=True)
(root/'work').mkdir(parents=True,exist_ok=True)
with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as bundle:
    bundle.write(app,app.name)
    for path in sorted(app.rglob('*')):
        if path.name=='.DS_Store' or path.name.startswith('._'):
            continue
        bundle.write(path,str(Path(app.name)/path.relative_to(app)))
validation_directory=tempfile.TemporaryDirectory(prefix='pickup-pilot-artifact-',dir='/private/tmp')
stage=Path(validation_directory.name)
with zipfile.ZipFile(archive) as bundle:
    bundle.extractall(stage)
    for entry in bundle.infolist():
        mode=(entry.external_attr>>16)&0o777
        if mode:
            os.chmod(stage/entry.filename,mode)
extracted=stage/app.name
subprocess.run(['codesign','--verify','--strict',str(extracted)],check=True)
if app != output_app.resolve():
    if output_app.exists():
        shutil.rmtree(output_app)
    shutil.copytree(app,output_app)
result={'archive':str(archive),'verified_extracted_app':str(extracted),'strict_signature_verified':True,'validation_copy_retained':False}
(root/'work/package-validation.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result))
validation_directory.cleanup()
