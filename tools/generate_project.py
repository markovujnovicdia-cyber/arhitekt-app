#!/usr/bin/env python3
"""Regenerate the checked-in Xcode project with Python 3 (no packages needed)."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'ArhitektOffice.xcodeproj'
PROJECT.mkdir(exist_ok=True)
objects = {}

def ident(label):
    return hashlib.sha1(label.encode()).hexdigest()[:24].upper()

def q(value):
    return json.dumps(str(value), ensure_ascii=False)

def add(label, body):
    key = ident(label)
    objects[key] = body
    return key

def array(values):
    return '(' + ', '.join(values) + (',' if values else '') + ')'

def settings(values):
    return '{' + ''.join(f'{key} = {q(value)}; ' for key, value in values.items()) + '}'

app_files = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / 'ArhitektOffice').rglob('*.swift'))
test_files = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / 'ArhitektOfficeTests').glob('*.swift'))
if not app_files or not test_files:
    raise SystemExit('Application and test sources must exist before generation.')
app_refs, test_refs, app_build, test_build = [], [], [], []
for paths, refs, builds in [(app_files, app_refs, app_build), (test_files, test_refs, test_build)]:
    for path in paths:
        ref = add('ref:' + path, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(path)}; sourceTree = SOURCE_ROOT;')
        refs.append(ref)
        builds.append(add('build:' + path, f'isa = PBXBuildFile; fileRef = {ref};'))
assets = add('assets', 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = ArhitektOffice/Resources/Assets.xcassets; sourceTree = SOURCE_ROOT;')
info = add('info', 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = ArhitektOffice/Resources/Info.plist; sourceTree = SOURCE_ROOT;')
asset_build = add('assets:build', f'isa = PBXBuildFile; fileRef = {assets};')
app_product = add('product:app', 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = ArhitektOffice.app; sourceTree = BUILT_PRODUCTS_DIR;')
test_product = add('product:test', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = ArhitektOfficeTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
app_group = add('group:app', f'isa = PBXGroup; children = {array(app_refs + [assets, info])}; name = ArhitektOffice; sourceTree = "<group>";')
test_group = add('group:test', f'isa = PBXGroup; children = {array(test_refs)}; name = ArhitektOfficeTests; sourceTree = "<group>";')
products = add('group:products', f'isa = PBXGroup; children = {array([app_product, test_product])}; name = Products; sourceTree = "<group>";')
main_group = add('group:main', f'isa = PBXGroup; children = {array([app_group, test_group, products])}; sourceTree = "<group>";')

def phase(label, kind, files):
    return add(label, f'isa = {kind}; buildActionMask = 2147483647; files = {array(files)}; runOnlyForDeploymentPostprocessing = 0;')
app_phases = [phase('app:sources', 'PBXSourcesBuildPhase', app_build), phase('app:frameworks', 'PBXFrameworksBuildPhase', []), phase('app:resources', 'PBXResourcesBuildPhase', [asset_build])]
test_phases = [phase('test:sources', 'PBXSourcesBuildPhase', test_build), phase('test:frameworks', 'PBXFrameworksBuildPhase', []), phase('test:resources', 'PBXResourcesBuildPhase', [])]

project_common = {'IPHONEOS_DEPLOYMENT_TARGET': '17.0', 'SDKROOT': 'iphoneos', 'SWIFT_VERSION': '5.0', 'CLANG_ENABLE_MODULES': 'YES', 'CLANG_ENABLE_OBJC_ARC': 'YES', 'ENABLE_USER_SCRIPT_SANDBOXING': 'YES', 'GCC_C_LANGUAGE_STANDARD': 'gnu17', 'CLANG_CXX_LANGUAGE_STANDARD': 'gnu++20', 'GCC_WARN_ABOUT_RETURN_TYPE': 'YES_ERROR', 'CLANG_WARN_UNREACHABLE_CODE': 'YES', 'SWIFT_STRICT_CONCURRENCY': 'targeted'}
app_common = {'PRODUCT_NAME': '$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.arhitektoffice.app', 'INFOPLIST_FILE': 'ArhitektOffice/Resources/Info.plist', 'GENERATE_INFOPLIST_FILE': 'NO', 'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon', 'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME': 'AccentColor', 'MARKETING_VERSION': '2.0', 'CURRENT_PROJECT_VERSION': '2', 'TARGETED_DEVICE_FAMILY': '1', 'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator', 'CODE_SIGN_STYLE': 'Automatic', 'SUPPORTS_MACCATALYST': 'NO', 'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/Frameworks'}
test_common = {'PRODUCT_NAME': '$(TARGET_NAME)', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.arhitektoffice.app.tests', 'GENERATE_INFOPLIST_FILE': 'YES', 'TARGETED_DEVICE_FAMILY': '1', 'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator', 'CODE_SIGN_STYLE': 'Automatic', 'TEST_HOST': '$(BUILT_PRODUCTS_DIR)/ArhitektOffice.app/ArhitektOffice', 'BUNDLE_LOADER': '$(TEST_HOST)', 'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/Frameworks @loader_path/Frameworks'}

def configurations(label, common):
    configs = []
    for name in ['Debug', 'Release']:
        values = dict(common)
        if label == 'project':
            values.update({'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if name == 'Debug' else '-O', 'DEBUG_INFORMATION_FORMAT': 'dwarf' if name == 'Debug' else 'dwarf-with-dsym', 'ENABLE_TESTABILITY': 'YES' if name == 'Debug' else 'NO', 'ONLY_ACTIVE_ARCH': 'YES' if name == 'Debug' else 'NO'})
            if name == 'Debug':
                values['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG $(inherited)'
        configs.append(add(label + ':' + name, f'isa = XCBuildConfiguration; buildSettings = {settings(values)}; name = {name};'))
    return add(label + ':configs', f'isa = XCConfigurationList; buildConfigurations = {array(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

project_configs = configurations('project', project_common)
app_configs = configurations('app', app_common)
test_configs = configurations('test', test_common)
app_target = ident('target:app')
proxy = add('test:proxy', f'isa = PBXContainerItemProxy; containerPortal = {ident("project")}; proxyType = 1; remoteGlobalIDString = {app_target}; remoteInfo = ArhitektOffice;')
dependency = add('test:dependency', f'isa = PBXTargetDependency; target = {app_target}; targetProxy = {proxy};')
add('target:app', f'isa = PBXNativeTarget; buildConfigurationList = {app_configs}; buildPhases = {array(app_phases)}; buildRules = (); dependencies = (); name = ArhitektOffice; productName = ArhitektOffice; productReference = {app_product}; productType = "com.apple.product-type.application";')
test_target = add('target:test', f'isa = PBXNativeTarget; buildConfigurationList = {test_configs}; buildPhases = {array(test_phases)}; buildRules = (); dependencies = {array([dependency])}; name = ArhitektOfficeTests; productName = ArhitektOfficeTests; productReference = {test_product}; productType = "com.apple.product-type.bundle.unit-test";')
root = add('project', f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; TargetAttributes = {{ {app_target} = {{CreatedOnToolsVersion = 16.0; }}; {test_target} = {{CreatedOnToolsVersion = 16.0; TestTargetID = {app_target}; }}; }}; }}; buildConfigurationList = {project_configs}; compatibilityVersion = "Xcode 14.0"; developmentRegion = hr; hasScannedForEncodings = 0; knownRegions = (hr, en, Base); mainGroup = {main_group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = {array([app_target, test_target])};')
text = '// !$*UTF8*$!\n{\narchiveVersion = 1;\nclasses = {};\nobjectVersion = 56;\nobjects = {\n'
text += ''.join(f'{key} = {{ {value} }};\n' for key, value in sorted(objects.items()))
text += f'}};\nrootObject = {root};\n}}\n'
(PROJECT / 'project.pbxproj').write_text(text)
schemes = PROJECT / 'xcshareddata' / 'xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
app_reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="ArhitektOffice.app" BlueprintName="ArhitektOffice" ReferencedContainer="container:ArhitektOffice.xcodeproj"/>'
test_reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="ArhitektOfficeTests.xctest" BlueprintName="ArhitektOfficeTests" ReferencedContainer="container:ArhitektOffice.xcodeproj"/>'
(schemes / 'ArhitektOffice.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{test_reference}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_reference}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/>
<ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(f'Generated Xcode project: {len(app_files)} app sources, {len(test_files)} test sources.')
