#!/usr/bin/env python3
"""Report LLVM coverage for every production Swift source; never filter hard files."""
import argparse
import json
from pathlib import Path
parser=argparse.ArgumentParser()
parser.add_argument('--input',type=Path)
parser.add_argument('--label',default='Synthetic test suite')
args=parser.parse_args()
root=Path(__file__).resolve().parent.parent
(root/'outputs').mkdir(parents=True,exist_ok=True)
coverage=args.input or root/'work/build-native/arm64-apple-macosx/debug/codecov/PickupPilot.json'
if not coverage.exists():
    raise SystemExit('Coverage missing. Run scripts/test.sh first on this Apple Silicon Mac.')
data=json.loads(coverage.read_text())
files=[f for item in data['data'] for f in item['files'] if str(root/'Sources')+'/' in f['filename']]
reported={str(Path(f['filename']).relative_to(root)) for f in files}
expected={str(p.relative_to(root)) for p in (root/'Sources').rglob('*.swift')}
static_assets={'Sources/PickupPilot/AppleCheckoutScripts.swift':'Embedded JavaScript constant: LLVM emits no Swift counters; JavaScript coverage is unmeasured.'}
for path in static_assets:
    source=(root/path).read_text()
    if source.count('#"""') != 1 or source.count('"""#') != 1 or source.split('"""#',1)[1].strip() != '}':
        raise SystemExit(f'Static asset changed shape; audit coverage inventory: {path}')
if reported | set(static_assets) != expected or reported - expected:
    raise SystemExit(f'Coverage file inventory mismatch: missing={expected-reported-set(static_assets)}, unexpected={reported-expected}')
rows=[]
for entry in files:
    summary=entry['summary']
    rows.append({'path':str(Path(entry['filename']).relative_to(root)),**{metric:{key:summary[metric][key] for key in ('covered','count')} for metric in ('lines','regions','functions')}})
totals={metric:{key:sum(r[metric][key] for r in rows) for key in ('covered','count')} for metric in ('lines','regions','functions')}
for path,reason in static_assets.items():
    if path not in reported:
        rows.append({'path':path,'kind':reason,**{metric:{'covered':0,'count':0} for metric in ('lines','regions','functions')}})
covered=totals['lines']['covered']; count=totals['lines']['count']
text=['# Pickup Pilot coverage','',f'Measurement: **{args.label}**.', '',f'Whole production Swift app: **{covered}/{count} executable lines ({covered/count*100:.2f}%)**. The requested 100% whole-app target is '+('met for executable lines.' if covered==count else '**not yet met**.'),'']
for name,metric in [('Regions','regions'),('Functions','functions')]:
    c,n=totals[metric]['covered'],totals[metric]['count']
    text.append(f'{name}: **{c}/{n} ({c/n*100:.2f}%)**.')
text += ['', 'Scope: every production Swift file under Sources/PilotCore and Sources/PickupPilot is listed and checked against the filesystem inventory. Executable-line totals cover all counters emitted by LLVM; the static JavaScript literal has no Swift counters and is explicitly listed as an unmeasured asset. No production file exclusions. SwiftUI, platform wrappers, lifecycle and checkout integration remain in the denominator. Test code, SDK code and build scripts are outside this Swift production scope. Swift regions are not a JavaScript or browser branch metric.', '', 'Embedded checkout JavaScript is exercised separately in native WebKit fixtures. LLVM emits no source-counter entry for its static string-literal file and does not measure JavaScript branches. This asset is listed below rather than assigned a fabricated denominator or a 100% score; no JavaScript coverage percentage is claimed.', '', '| File | Covered lines | Executable lines | Percent |','|---|---:|---:|---:|']
for row in sorted(rows,key=lambda r:r['path']):
    c,n=row['lines']['covered'],row['lines']['count']
    percentage=f'{c/n*100:.2f}%' if n else 'Unmeasured JS asset'
    text.append(f"| {row['path']} | {c if n else 'n/a'} | {n if n else 'n/a'} | {percentage} |")
text += ['', 'Remaining gaps include native SwiftUI control callbacks and app lifecycle/error presentation paths. Offscreen rendering, state-machine tests and a launch check do not prove desktop interactions. The computer-use bridge could inspect Finder but closed its native pipe whenever targeting Pickup Pilot. In-process SwiftUI accessibility/input experiments were unreliable and were not reported as passing UI tests.', '', 'This metric does not prove live paid checkout. See VALIDATION.md for read-only Apple integration, synthetic Keychain/checkout tests and limitations.', '']
(root/'outputs/COVERAGE.md').write_text('\n'.join(text))
(root/'outputs/coverage-summary.json').write_text(json.dumps({'measurement':args.label,'covered_lines':covered,'executable_lines':count,'percent':covered/count*100,'totals':totals,'unmeasured_assets':static_assets,'files':rows},indent=2)+'\n')
print(f'Whole app: {covered}/{count} executable lines ({covered/count*100:.2f}%).')
