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


def requirement(app):
    result = run('codesign', '-d', '-r-', app)
    return next(line.split('designated => ', 1)[1]
                for line in (result.stdout + result.stderr).splitlines()
                if 'designated => ' in line)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-receipt', required=True, type=Path)
    parser.add_argument('--reference-app', required=True, type=Path)
    parser.add_argument('--output-dir', required=True, type=Path)
    parser.add_argument('--signing-identity', default='SuperIsland WE1 Debug Local Code Signing')
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
    assert info['CFBundleIdentifier'] == 'com.workview.SuperIsland.WE1Debug'
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
    (candidate / 'Contents/Info.plist').write_bytes(plistlib.dumps(info, sort_keys=False))
    run('codesign', '--force', '--deep', '--sign', args.signing_identity, '--timestamp=none',
        '--entitlements', root / 'SuperIsland/SuperIsland.entitlements', candidate)
    run('codesign', '--verify', '--deep', '--strict', candidate)
    assert requirement(candidate) == stable_requirement, 'Application identity changed'
    archive = output / f'SuperIsland-{build}-arm64.zip'
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', candidate, archive)
    run('unzip', '-tq', archive)
    with tempfile.TemporaryDirectory(prefix='superisland-package-check-') as directory:
        extracted = Path(directory) / 'SuperIsland.app'
        run('ditto', '-x', '-k', archive, directory)
        run('codesign', '--verify', '--deep', '--strict', extracted)
        assert sha(extracted / 'Contents/MacOS/SuperIsland') == sha(staged_binary)
        assert plistlib.loads((extracted / 'Contents/Info.plist').read_bytes()) == info
    manifest = dict(source_revision=head, source_tree=tree, build_number=build,
                    display_name='SuperIsland', app_file_name=candidate.name,
                    candidate_app=str(candidate), bundle_id=info['CFBundleIdentifier'],
                    designated_requirement=stable_requirement,
                    candidate_binary_sha256=sha(staged_binary),
                    source_binary_sha256=sha(binary), source_app_sha256=receipt['sourceAppSHA256'],
                    zip_sha256=sha(archive),
                    signed=True, installed=False, notarized=False)
    (output / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    (output / 'SHA256SUMS.txt').write_text(f'{sha(archive)}  {archive.name}\n')
    (output / '说明.txt').write_text(
        f'SuperIsland {build}（Apple Silicon，macOS 14+）\n'
        '应用对外名称已统一为 SuperIsland，保留原有设置与内部应用身份。\n'
        '包含 Codex 用量刷新修复；Claude 功能保留。\n'
        '本包为本机证书签名，未经过 Apple 公证；尚未安装或实机验收。\n'
        '更新前须退出原应用，避免新旧版本同时运行。\n')
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
