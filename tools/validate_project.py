#!/usr/bin/env python3
"""Static integrity checks; NOT an Apple SDK build or XCTest substitute.
Install optional tooling: python3 -m pip install -r tools/validation-requirements.txt
"""
from pathlib import Path
import json
import plistlib
import xml.etree.ElementTree as ET
import re
import sys
from pbxproj import XcodeProject
from tree_sitter import Language, Parser
import tree_sitter_swift

root = Path(__file__).resolve().parents[1]
errors = []
parser = Parser(Language(tree_sitter_swift.language()))
files = sorted((root / 'ArhitektOffice').rglob('*.swift')) + sorted((root / 'ArhitektOfficeTests').rglob('*.swift'))
for file in files:
    tree = parser.parse(file.read_bytes())
    pending = [tree.root_node]
    while pending:
        node = pending.pop()
        if node.type == 'ERROR' or node.is_missing:
            errors.append(f'{file.relative_to(root)}:{node.start_point.row + 1}: syntax {node.type}')
        pending.extend(node.children)

pbx_path = root / 'ArhitektOffice.xcodeproj/project.pbxproj'
project = XcodeProject.load(str(pbx_path))
assert project, 'Cannot parse OpenStep project'
# Assert every Swift source is both referenced and a source-phase build member.
refs = {str(obj.get_id()): obj for obj in project.objects.get_objects_in_section('PBXFileReference')}
builds = {str(obj.get_id()): obj for obj in project.objects.get_objects_in_section('PBXBuildFile')}
source_files = set()
for phase in project.objects.get_objects_in_section('PBXSourcesBuildPhase'):
    for build_id in phase.files:
        reference = refs[str(builds[str(build_id)].fileRef)]
        source_files.add(reference.path)
for file in files:
    if file.relative_to(root).as_posix() not in source_files:
        errors.append(f'{file}: not in Xcode sources phase')
for ref in refs.values():
    if ref.sourceTree == 'SOURCE_ROOT' and not (root / ref.path).exists():
        errors.append(f'Missing Xcode resource: {ref.path}')

with (root / 'ArhitektOffice/Resources/Info.plist').open('rb') as f:
    info = plistlib.load(f)
for key in ['NSMicrophoneUsageDescription']:
    assert info.get(key), f'Missing permission {key}'
assert info['CFBundleDisplayName'] == 'Arhitekt Office'
assert 'NSSpeechRecognitionUsageDescription' not in info
assert 'audio' in info.get('UIBackgroundModes', [])
for file in (root / 'ArhitektOffice').rglob('*.swift'):
    code = file.read_text()
    for forbidden in ['URLSession', 'import Speech', 'SFSpeechRecognizer', 'CloudAIClient', 'OPENAI_API_KEY']:
        assert forbidden not in code, f'Network AI path present: {file}: {forbidden}'
ET.parse(root / 'ArhitektOffice.xcodeproj/xcshareddata/xcschemes/ArhitektOffice.xcscheme')
for path in (root / 'ArhitektOffice/Resources/Assets.xcassets').rglob('Contents.json'):
    contents = json.loads(path.read_text())
    for asset in contents.get('images', []):
        if 'filename' in asset:
            assert (path.parent / asset['filename']).is_file(), f'Missing image {asset}'
# Check the modern universal icon dimensions directly from its PNG header.
icon = (root / 'ArhitektOffice/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png').read_bytes()
assert icon[:8] == b'\x89PNG\r\n\x1a\n'
assert int.from_bytes(icon[16:20], 'big') == 1024
assert int.from_bytes(icon[20:24], 'big') == 1024
assert icon[25] == 2, 'App icon must be RGB, without alpha'
methods = sum(len(re.findall(r'func test\w+\(', p.read_text())) for p in files if 'ArhitektOfficeTests' in p.parts)
print(f'Parsed {len(files)} Swift files and Xcode project; verified source membership, resources, permission plist, shared scheme and 1024px RGB icon.')
print(f'Discovered {methods} XCTest methods; execution requires Xcode and is not performed by this script.')
if errors:
    print('\n'.join(errors))
    sys.exit(1)
print('Static validation passed. Apple SDK type checking and runtime behavior are NOT validated.')
