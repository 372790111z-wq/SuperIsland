#!/usr/bin/env python3
"""Package a verified local Release as SuperIsland.app; never install or launch it.

The build receipt binds a successful clean build to its Git revision, tree,
source app and executable SHA-256. Keep the existing local application identity.
See docs/local-release-packaging.md for the receipt format and usage.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import stat
import struct
import subprocess
import tempfile


def run(*args):
    return subprocess.run([str(arg) for arg in args], check=True, capture_output=True, text=True)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def app_digest(app):
    """Bind resources, Info.plist, executable bits and symlink destinations too."""
    entries = []
    for path in sorted(app.rglob('*')):
        mode = stat.S_IMODE(path.lstat().st_mode)
        if path.is_symlink():
            entry = ['symlink', str(path.readlink())]
        elif path.is_file():
            entry = ['file', sha(path)]
        else:
            entry = ['directory']
        entries.append([path.relative_to(app).as_posix(), mode, *entry])
    return hashlib.sha256(json.dumps(entries, ensure_ascii=False).encode()).hexdigest()


def runtime_sections(path):
    """Fingerprint mapped Mach-O sections, excluding link-edit/debug symbols."""
    data = path.read_bytes()
    if len(data) < 32 or struct.unpack_from('<I', data)[0] != 0xfeedfacf:
        raise ValueError('Expected a thin little-endian 64-bit Mach-O: ' + str(path))
    count, command_bytes = struct.unpack_from('<II', data, 16)
    end = 32 + command_bytes
    if end > len(data):
        raise ValueError('Truncated Mach-O load commands')
    position, sections = 32, {}
    for _ in range(count):
        if position + 8 > end:
            raise ValueError('Truncated Mach-O command')
        command, size = struct.unpack_from('<II', data, position)
        if size < 8 or position + size > end:
            raise ValueError('Invalid Mach-O command size')
        if command == 0x19:  # LC_SEGMENT_64
            if size < 72:
                raise ValueError('Truncated segment command')
            segment = data[position + 8:position + 24].split(b'\0')[0].decode()
            section_count = struct.unpack_from('<I', data, position + 64)[0]
            if 72 + section_count * 80 > size:
                raise ValueError('Truncated Mach-O sections')
            for index in range(section_count):
                item = position + 72 + index * 80
                name = data[item:item + 16].split(b'\0')[0].decode()
                address, length, offset = struct.unpack_from('<QQI', data, item + 32)
                flags = struct.unpack_from('<I', data, item + 64)[0]
                if segment in ('__LINKEDIT', '__DWARF'):
                    continue
                zero_fill = flags & 0xff in (1, 0xc, 0x12)
                if not zero_fill and offset + length > len(data):
                    raise ValueError('Truncated runtime section')
                key = segment + ',' + name
                if key in sections:
                    raise ValueError('Duplicate runtime section')
                digest = None if zero_fill else hashlib.sha256(data[offset:offset + length]).hexdigest()
                sections[key] = (address, length, flags, digest)
        position += size
    if not sections:
        raise ValueError('No runtime sections found')
    return sections


def strip_release_symbols(app, command=run):
    """Strip only staged, first-party code; preserve runtime bytes and exports.

    Build outputs and dSYMs remain untouched for crash symbolication. Every
    caller must sign the staged App after this operation.
    """
    report = {}
    for name in ('SuperIsland', 'KeepAwakeHelper', 'KeepAwakeEventTool', 'BatteryManagementHelper'):
        binary = app / 'Contents/MacOS' / name
        if not binary.exists():
            continue
        if binary.is_symlink():
            raise ValueError('Refusing to strip a symlink: ' + name)
        before = binary.stat().st_size
        sections = runtime_sections(binary)
        exports = command('nm', '-g', '-U', '-j', binary).stdout
        libraries = command('otool', '-L', binary).stdout.splitlines()[1:]
        command('strip', '-S', '-x', binary)
        if (runtime_sections(binary) != sections or
                command('nm', '-g', '-U', '-j', binary).stdout != exports or
                command('otool', '-L', binary).stdout.splitlines()[1:] != libraries):
            raise ValueError('Symbol stripping changed runtime code, metadata or linkage: ' + name)
        report[name] = dict(before_bytes=before, after_bytes=binary.stat().st_size,
                            runtime_sections_identical=True, exports_identical=True,
                            linked_libraries_identical=True)
    return report


def requirement(app):
    result = run('codesign', '-d', '-r-', app)
    return next(line.split('designated => ', 1)[1]
                for line in (result.stdout + result.stderr).splitlines()
                if 'designated => ' in line)


def validate_pause_refresh_build(receipt, info, enabled):
    """An explicit opt-in must match the narrow helper build, never Review."""
    command = receipt.get('command', [])
    settings = [item for item in command if isinstance(item, str) and '=' in item]
    narrow = [item for item in settings if item.startswith('WE1_BATTERY_SWIFT_CONDITIONS=')]
    expected = ['WE1_BATTERY_SWIFT_CONDITIONS=BATTERY_PAUSE_REFRESH'] if enabled else []
    if narrow != expected:
        raise ValueError('Pause refresh package flag must match the narrow build receipt')
    if any('BATTERY_REVIEW' in item or ('BATTERY_PAUSE_REFRESH' in item and item not in expected) for item in settings):
        raise ValueError('Broad Review or undeclared pulse compilation is not allowed')
    if any(info.get(key) for key in ('BM1DiagnosticsOnly', 'BM1NativeCutoffTrial', 'BM1Preferences79Review',
                                    'BM1PauseRefreshTrial', 'WE1PauseRefreshTrial')):
        raise ValueError('Build input must not be a previously sealed experiment')
    if info.get('CFBundleIdentifier') != 'com.workview.SuperIsland.WE1Debug':
        raise ValueError('Pause refresh is restricted to the unified WE1 identity')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-receipt', required=True, type=Path)
    parser.add_argument('--reference-app', required=True, type=Path)
    parser.add_argument('--output-dir', required=True, type=Path)
    parser.add_argument('--signing-identity', default='SuperIsland WE1 Debug Local Code Signing')
    parser.add_argument('--pause-refresh-trial', action='store_true', help='Seal the authorized one-shot 79–85 percent pause trial; receipt must enable only BATTERY_PAUSE_REFRESH')
    parser.add_argument('--mission-control-diagnostics', action='store_true',
                        help='Opt this WE1 package into bounded local Mission Control state diagnostics; no window content')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    receipt = json.loads(args.build_receipt.read_text())
    head = run('git', '-C', root, 'rev-parse', 'HEAD').stdout.strip()
    tree = run('git', '-C', root, 'rev-parse', 'HEAD^{tree}').stdout.strip()
    assert not run('git', '-C', root, 'status', '--porcelain').stdout, 'Commit reviewed source first'
    assert receipt['exitCode'] == 0 and receipt['sourceUnchangedDuringBuild'] is True
    assert receipt['sourceRevision'] == head and receipt['sourceTree'] == tree
    assert Path(receipt['sourceRoot']).resolve() == root
    source = Path(receipt['sourceApp'])
    binary = source / 'Contents/MacOS/SuperIsland'
    assert sha(binary) == receipt['sourceBinarySHA256'], 'Build output changed since verification'
    assert app_digest(source) == receipt['sourceAppSHA256'], 'Build resources changed since verification'
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    validate_pause_refresh_build(receipt, info, args.pause_refresh_trial)
    for helper in ('KeepAwakeHelper', 'KeepAwakeEventTool', 'BatteryManagementHelper'):
        assert (source / 'Contents/MacOS' / helper).is_file(), 'Missing bundled helper: ' + helper
    for helper in ('KeepAwakeHelper', 'BatteryManagementHelper'):
        assert (source / 'Contents/Library/LaunchDaemons' / ('com.workview.SuperIsland.' + helper + '.plist')).is_file(), 'Missing launch declaration: ' + helper
    assert info['CFBundleIdentifier'] == 'com.workview.SuperIsland.WE1Debug'
    battery_plist = source / 'Contents/Library/LaunchDaemons/com.workview.SuperIsland.WE1Debug.BatteryControl.plist'
    battery_launch = plistlib.loads(battery_plist.read_bytes())
    assert battery_launch['Label'] == 'com.workview.SuperIsland.WE1Debug.BatteryControl'
    assert set(battery_launch['MachServices']) == {battery_launch['Label']}
    assert battery_launch['BundleProgram'] == 'Contents/MacOS/BatteryManagementHelper'
    assert battery_launch['AssociatedBundleIdentifiers'] == [info['CFBundleIdentifier']]

    assert not (source / 'Contents/MacOS/SuperIsland.debug.dylib').exists(), 'Use a Release build'
    assert not list(source.rglob('*.xctest')), 'Do not ship test bundles'
    for pattern in ['XCTest*.framework', 'Testing.framework', 'XCUnit.framework',
                    'XCTAutomationSupport.framework', 'XCUIAutomation.framework',
                    'libXCTest*.dylib']:
        assert not list(source.rglob(pattern)), 'Do not ship test runtimes'
    assert run('lipo', '-archs', binary).stdout.strip() == 'arm64'
    loads = run('xcrun', 'otool', '-l', binary).stdout
    assert '__llvm_cov' not in loads and '__llvm_prf' not in loads, 'Coverage instrumentation remains'
    reference = args.reference_app.resolve()
    reference_info = plistlib.loads((reference / 'Contents/Info.plist').read_bytes())
    assert reference_info['CFBundleIdentifier'] == info['CFBundleIdentifier']
    run('codesign', '--verify', '--deep', '--strict', reference)
    stable_requirement = requirement(reference)
    assert 'certificate' in stable_requirement and 'cdhash' not in stable_requirement
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)  # Never overwrite a previous package.
    build = datetime.datetime.now().strftime('%Y%m%d%H%M%S')
    candidate = output / 'SuperIsland.app'
    run('ditto', source, candidate)
    assert app_digest(candidate) == receipt['sourceAppSHA256'], 'Copied bundle differs from build'
    staged_binary = candidate / 'Contents/MacOS/SuperIsland'
    run('xcrun', 'strip', '-D', staged_binary)
    info.update(CFBundleName='SuperIsland', CFBundleDisplayName='SuperIsland',
                CFBundleVersion=build, WE1BuildType='Optimized',
                WE1SourceRevision=head, WE1SourceExecutableSHA256=sha(binary))
    # Branding does not transfer ownership of production OAuth/deep links.
    info.pop('CFBundleURLTypes', None)
    if args.pause_refresh_trial:
        info['WE1PauseRefreshTrial'] = True
    # Never inherit opt-in diagnostics from an input build accidentally.
    info.pop('WE1MissionControlDiagnostics', None)
    if args.mission_control_diagnostics:
        info['WE1MissionControlDiagnostics'] = True
    (candidate / 'Contents/Info.plist').write_bytes(plistlib.dumps(info, sort_keys=False))
    symbol_stripping = strip_release_symbols(candidate)
    # --deep may replace a raw nested executable's identifier with its file
    # name. First sign all nested code, then pin the IPC helper identities and
    # reseal only the outer bundle without rewriting those nested signatures.
    run('codesign', '--force', '--deep', '--sign', args.signing_identity, '--timestamp=none',
        '--entitlements', root / 'SuperIsland/SuperIsland.entitlements', candidate)
    nested_identifiers = {}
    for name in ('KeepAwakeHelper', 'KeepAwakeEventTool', 'BatteryManagementHelper'):
        nested = candidate / 'Contents/MacOS' / name
        if nested.exists():
            identifier = 'com.workview.SuperIsland.' + name
            run('codesign', '--force', '--sign', args.signing_identity, '--timestamp=none',
                '--identifier', identifier, '--options', 'runtime', nested)
            nested_identifiers[name] = identifier
    run('codesign', '--force', '--sign', args.signing_identity, '--timestamp=none',
        '--entitlements', root / 'SuperIsland/SuperIsland.entitlements', candidate)
    run('codesign', '--verify', '--deep', '--strict', candidate)
    for name, identifier in nested_identifiers.items():
        run('codesign', '--verify', '--strict', '-R', f'=identifier "{identifier}"', candidate / 'Contents/MacOS' / name)
    assert requirement(candidate) == stable_requirement, 'Application identity changed'
    archive = output / f'SuperIsland-{build}-arm64.zip'
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', candidate, archive)
    run('unzip', '-tq', archive)
    with tempfile.TemporaryDirectory(prefix='superisland-package-check-') as directory:
        extracted = Path(directory) / 'SuperIsland.app'
        run('ditto', '-x', '-k', archive, directory)
        run('codesign', '--verify', '--deep', '--strict', extracted)
        for name, identifier in nested_identifiers.items():
            run('codesign', '--verify', '--strict', '-R', f'=identifier "{identifier}"', extracted / 'Contents/MacOS' / name)
        assert sha(extracted / 'Contents/MacOS/SuperIsland') == sha(staged_binary)
        assert plistlib.loads((extracted / 'Contents/Info.plist').read_bytes()) == info
    manifest = dict(source_revision=head, source_tree=tree, build_number=build,
                    display_name='SuperIsland', app_file_name=candidate.name,
                    candidate_app=str(candidate), bundle_id=info['CFBundleIdentifier'],
                    designated_requirement=stable_requirement,
                    candidate_binary_sha256=sha(staged_binary),
                    source_binary_sha256=sha(binary), source_app_sha256=receipt['sourceAppSHA256'],
                    zip_sha256=sha(archive),
                    signed=True, installed=False, notarized=False, nested_identifiers=nested_identifiers,
                    mission_control_diagnostics=args.mission_control_diagnostics,
                    symbol_stripping=symbol_stripping)
    (output / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    (output / 'SHA256SUMS.txt').write_text(f'{sha(archive)}  {archive.name}\n')
    (output / '说明.txt').write_text(
        f'SuperIsland {build}（Apple Silicon，macOS 14+）\n'
        '应用对外名称已统一为 SuperIsland，保留原有设置与内部应用身份。\n'
        '包含主线功能及电池管理整合；功能验收结果另见交付记录。\n'
        '本包为本机证书签名，未经过 Apple 公证；尚未安装或实机验收。\n'
        '更新前须退出原应用，避免新旧版本同时运行。\n')
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
