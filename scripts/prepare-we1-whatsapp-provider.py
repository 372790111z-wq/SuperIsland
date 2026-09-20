#!/usr/bin/env python3
"""Build the existing WhatsApp provider from its lockfile; never launch a login.

Requires Node >= 20, npm and an existing esbuild 0.27.7 executable. Dependency
lifecycle scripts are disabled. Outputs are build artifacts, not installed apps.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def run(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--esbuild', type=Path)
    parser.add_argument('--output-dir', required=True, type=Path)
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = root / 'Extensions/whatsapp-web/provider'
    output = args.output_dir.resolve()
    if args.verify_only:
        metadata = json.loads((output / 'build.json').read_text())
        assert metadata['sourceSHA256'] == sha(source / 'index.mjs'), 'Provider source changed; prepare again'
        assert metadata['lockSHA256'] == sha(source / 'package-lock.json'), 'Provider lock changed; prepare again'
        assert metadata['bundleSHA256'] == sha(output / 'bundle.cjs'), 'Provider bundle changed; prepare again'
        assert metadata['readyWithoutNodeModules'] is True
        print('WE1 WhatsApp provider verified')
        return
    assert args.esbuild is not None, '--esbuild is required to prepare a bundle'
    bundler = args.esbuild.resolve()
    assert run([str(bundler), '--version']).stdout.strip() == '0.27.7', 'Expected esbuild 0.27.7'
    assert int(run(['node', '--version']).stdout.strip().lstrip('v').split('.')[0]) >= 20
    assert not output.exists(), 'Use a new output directory; existing output is preserved'
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='we1-provider-', suffix='.noindex', dir=output.parent) as temporary:
        work = Path(temporary)
        for name in ['index.mjs', 'package.json', 'package-lock.json']:
            shutil.copy2(source / name, work / name)
        run(['npm', 'ci', '--ignore-scripts', '--no-audit', '--no-fund', '--omit=optional'], cwd=work)
        run([str(bundler), 'index.mjs', '--bundle', '--platform=node', '--format=cjs',
             '--outfile=bundle.cjs'], cwd=work)
        # Import without node_modules and without issuing the start command.
        # This verifies packaged imports without connecting or reading accounts.
        smoke = work / 'standalone'
        smoke.mkdir()
        shutil.copy2(work / 'bundle.cjs', smoke / 'bundle.cjs')
        result = run(['node', str(smoke / 'bundle.cjs'), '--auth-dir', str(smoke / 'unused-auth')],
                     cwd=smoke, input='', timeout=10)
        assert result.stdout.strip() == '{"type":"ready"}', result.stdout
        assert not result.stderr and not (smoke / 'unused-auth').exists()
        output.mkdir()
        shutil.copy2(work / 'bundle.cjs', output / 'bundle.cjs')
        # Preserve notices for bundled dependencies alongside the generated code.
        licenses = output / 'licenses'
        dependencies = work / 'node_modules'
        for path in dependencies.rglob('*'):
            if path.is_file() and path.name.lower().startswith(('license', 'licence', 'copying', 'notice')):
                target = licenses / path.relative_to(dependencies)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)
        metadata = {
            'sourceSHA256': sha(source / 'index.mjs'),
            'lockSHA256': sha(source / 'package-lock.json'),
            'bundleSHA256': sha(output / 'bundle.cjs'),
            'esbuild': '0.27.7', 'node': run(['node', '--version']).stdout.strip(),
            'readyWithoutNodeModules': True, 'loginTested': False
        }
        (output / 'build.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(json.dumps({'provider': str(output / 'bundle.cjs'), **metadata}, indent=2))


if __name__ == '__main__':
    main()
