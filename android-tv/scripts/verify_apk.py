"""Inspect the APK itself; publish metadata only after signature and ABI checks."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import subprocess
import zipfile


def command(args):
    args = list(map(str, args))
    if os.name == 'nt' and args[0].lower().endswith('.bat'):
        args = [os.environ.get('COMSPEC', 'cmd.exe'), '/d', '/c', *args]
    result = subprocess.run(args, capture_output=True, timeout=90)
    if result.returncode:
        raise RuntimeError(f'{Path(args[0]).name} failed ({result.returncode})')
    return result.stdout.decode('utf-8', errors='replace')


def signing_certificate(output):
    # SDK tools may identify v3 signers by SDK range instead of signer number.
    digests = {value.lower() for value in re.findall(
        r'^Signer[^\r\n]* certificate SHA-256 digest:\s*([0-9a-fA-F]{64})\s*$',
        output, re.MULTILINE)}
    if len(digests) != 1:
        raise RuntimeError('Expected one verified APK signing certificate')
    return digests.pop()


def select_build_tools(sdk):
    candidates = [p for p in (Path(sdk) / 'build-tools').glob('*') if re.fullmatch(r'\d+(\.\d+)+', p.name)]
    if not candidates:
        raise RuntimeError('Android SDK build-tools missing; configure ANDROID_HOME or sdkPath')
    pinned = Path(sdk) / 'build-tools/36.0.0'
    return pinned if pinned in candidates else max(candidates, key=lambda p: tuple(map(int, p.name.split('.'))))


def inspect(apk, sdk=None):
    apk = Path(apk).resolve()
    sdk = Path(sdk or os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT') or '')
    tools = select_build_tools(sdk)
    win = os.name == 'nt'
    badging = command([tools / ('aapt2.exe' if win else 'aapt2'), 'dump', 'badging', apk])
    signing = command([tools / ('apksigner.bat' if win else 'apksigner'), 'verify', '--print-certs', apk])
    command([tools / ('zipalign.exe' if win else 'zipalign'), '-c', '-P', '16', '4', apk])
    def field(pattern):
        match = re.search(pattern, badging)
        if not match:
            raise RuntimeError('Required APK metadata is missing')
        return match.group(1)
    try:
        certificate = signing_certificate(signing)
    except RuntimeError as error:
        # Certificate digests are public; omit subject names from diagnostics.
        digest_lines = [line for line in signing.splitlines() if 'digest' in line.lower()]
        raise RuntimeError(f'{error}; build-tools={tools.name}; digest output={digest_lines!r}') from error
    with zipfile.ZipFile(apk) as archive:
        if archive.testzip():
            raise RuntimeError('APK ZIP CRC failed')
        names = set(archive.namelist())
        abis = sorted({name.split('/')[1] for name in names if name.startswith('lib/')})
        if abis != ['arm64-v8a', 'armeabi-v7a']:
            raise RuntimeError(f'Unexpected APK ABIs: {abis}')
        for abi in abis:
            for library in ['libapp.so', 'libflutter.so', 'libmpv.so']:
                if f'lib/{abi}/{library}' not in names:
                    raise RuntimeError('Required native library is missing')
    if 'leanback-launchable-activity:' not in badging:
        raise RuntimeError('Android TV launcher entry is missing')
    return {
        'file': apk.name, 'sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
        'packageId': field(r"package: name='([^']+)'"),
        'activity': field(r"launchable-activity: name='([^']+)'"),
        'versionName': field(r"versionName='([^']+)'"),
        'versionCode': int(field(r"versionCode='(\d+)'")),
        'minSdk': int(field(r"(?:minSdkVersion|sdkVersion):'(\d+)'")),
        'abis': abis, 'certificateSha256': certificate,
        'sourceCommit': os.environ.get('GITHUB_SHA', ''),
        'runId': os.environ.get('GITHUB_RUN_ID', ''),
        'signatureVerified': True, 'zipAligned': True,
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    parser.add_argument('--sdk')
    parser.add_argument('--expected-package', help='Fail if the built package does not match the selected build mode')
    parser.add_argument('--output', type=Path, required=True)
    options = parser.parse_args()
    metadata = inspect(options.apk, options.sdk)
    if options.expected_package and metadata['packageId'] != options.expected_package:
        raise RuntimeError('APK package does not match the selected build mode')
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(metadata, ensure_ascii=False))
