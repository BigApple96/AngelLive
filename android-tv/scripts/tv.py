"""Local ADB installation and evidence collection. Never uninstalls or clears data."""
from pathlib import Path
from datetime import datetime, timezone
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import time
from verify_apk import inspect

ROOT = Path(__file__).resolve().parent.parent
KEYS = {'up': 19, 'down': 20, 'left': 21, 'right': 22, 'select': 23, 'back': 4, 'playpause': 85, 'home': 3}


def redact(text):
    lines = []
    for line in text.splitlines():
        if re.search(r'cookie|authorization|password|access.?token|refresh.?token|session.?id|csrf|qrcontent|qrimage', line, re.I):
            lines.append('[sensitive log line removed]')
        else:
            lines.append(re.sub(r'https?://[^\s<>\"]+', '[network URL removed]', line))
    return '\n'.join(lines)


def validate_apk(apk, metadata, observed, config):
    """No device mutation is allowed before all checks below pass."""
    if Path(metadata['file']).name != metadata['file'] or Path(apk).name != metadata['file']:
        raise RuntimeError('APK filename does not match metadata')
    if hashlib.sha256(Path(apk).read_bytes()).hexdigest() != metadata['sha256']:
        raise RuntimeError('APK checksum does not match metadata')
    for name in ['sha256', 'certificateSha256', 'packageId', 'activity', 'versionCode', 'abis', 'minSdk']:
        if observed.get(name) != metadata.get(name):
            raise RuntimeError(f'APK inspection does not match metadata: {name}')
    expected = re.sub(r'[:\s]', '', config.get('expectedCertificateSha256', '')).lower()
    if not re.fullmatch(r'[a-f0-9]{64}', expected):
        raise RuntimeError('Set expectedCertificateSha256 after reviewing the signing certificate')
    if observed['certificateSha256'] != expected:
        raise RuntimeError('Signing certificate mismatch; stopped without uninstalling')
    if observed['packageId'] != config.get('packageId'):
        raise RuntimeError('Unexpected application package ID')


class TV:
    def __init__(self, config):
        self.config = config
        self.serial = config.get('serial', '')
        if not self.serial or self.serial.startswith('-') or not re.fullmatch(r'[A-Za-z0-9_.:\[\]-]+', self.serial):
            raise RuntimeError('Configure the exact TV ADB serial or address')
        self.adb = config.get('adbPath') or shutil.which('adb')
        if not self.adb:
            raise RuntimeError('adb not found; install Android SDK platform-tools')
        self.package = config.get('packageId', 'works.angel.angel_live_android_tv')
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_.]+', self.package):
            raise RuntimeError('Invalid package ID')

    def run(self, *args, binary=False, timeout=30, allow_absent=False):
        process = subprocess.run([self.adb, '-s', self.serial, *map(str, args)], capture_output=True, timeout=timeout)
        absent = allow_absent and process.returncode == 1 and not process.stdout.strip() and not process.stderr.strip()
        if process.returncode and not absent:
            raise RuntimeError(f'ADB operation failed ({process.returncode}): ' + redact(process.stderr.decode(errors='replace'))[:200])
        return process.stdout if binary else process.stdout.decode('utf-8', errors='replace').strip()

    def connect(self):
        if ':' in self.serial:
            process = subprocess.run([self.adb, 'connect', self.serial], capture_output=True, timeout=20)
            if process.returncode:
                raise RuntimeError('ADB connection failed')
        if self.run('get-state') != 'device':
            raise RuntimeError('TV is not authorized; accept the ADB authorization on the television')

    def doctor(self):
        if self.run('get-state') != 'device':
            raise RuntimeError('TV is offline or unauthorized')
        model = self.run('shell', 'getprop', 'ro.product.model')
        api = int(self.run('shell', 'getprop', 'ro.build.version.sdk'))
        abis = self.run('shell', 'getprop', 'ro.product.cpu.abilist').split(',')
        return {'model': model, 'api': api, 'abis': abis,
                'webview': redact(self.run('shell', 'dumpsys', 'webviewupdate')),
                'installed': redact(self.run('shell', 'pm', 'path', self.package, allow_absent=True))}

    def install(self, apk, metadata):
        observed = inspect(apk, self.config.get('sdkPath'))
        validate_apk(apk, metadata, observed, self.config)
        facts = self.doctor()
        expected = self.config.get('expectedModel', '')
        if not expected or facts['model'] != expected:
            raise RuntimeError('Device model differs from expectedModel; review doctor output')
        if facts['api'] < observed['minSdk'] or not set(facts['abis']).intersection(observed['abis']):
            raise RuntimeError('Android API or ABI is incompatible with this APK')
        outcome = self.run('install', '-r', str(Path(apk).resolve()), timeout=180)
        if 'Success' not in outcome:
            raise RuntimeError('Installation did not report Success: ' + redact(outcome)[:300])
        details = self.run('shell', 'dumpsys', 'package', self.package)
        version = re.search(r'versionCode=(\d+)', details)
        if not version or int(version.group(1)) != observed['versionCode']:
            raise RuntimeError('Installed version could not be verified')
        return {'installed': True, 'versionCode': observed['versionCode'], 'certificateSha256': observed['certificateSha256']}

    def launch(self, activity='works.angel.angel_live_android_tv.MainActivity'):
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_.$]+', activity):
            raise RuntimeError('Invalid activity name')
        result = self.run('shell', 'am', 'start', '-W', '-n', f'{self.package}/{activity}')
        if not re.search(r'Status:\s*ok\b', result):
            raise RuntimeError('Activity launch did not report Status: ok')
        for _ in range(12):
            pid = self.run('shell', 'pidof', self.package, allow_absent=True)
            if pid:
                return {'launched': True, 'pid': pid.split()[0]}
            time.sleep(0.5)
        raise RuntimeError('No application process appeared after launch')

    def capture(self, note='manual'):
        stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        folder = ROOT / 'runs' / stamp
        folder.mkdir(parents=True)
        facts = self.doctor()
        (folder / 'device.json').write_text(json.dumps(facts, ensure_ascii=False, indent=2), encoding='utf-8')
        image = self.run('exec-out', 'screencap', '-p', binary=True)
        if not image.startswith(b'\x89PNG\r\n\x1a\n'):
            raise RuntimeError('Screenshot did not return PNG data')
        (folder / 'screen.png').write_bytes(image)
        pid = self.run('shell', 'pidof', self.package, allow_absent=True).split()
        if pid:
            logs = self.run('logcat', '-d', '-t', '4000', '--pid=' + pid[0])
            (folder / 'app-log.txt').write_text(redact(logs), encoding='utf-8')
        else:
            (folder / 'app-log.txt').write_text('Application process is not running; no unrelated process logs collected.\n', encoding='utf-8')
        memory = self.run('shell', 'dumpsys', 'meminfo', self.package)
        (folder / 'memory.txt').write_text(redact(memory), encoding='utf-8')
        (folder / 'observation.md').write_text(f'# Device observation\n\nReason: {redact(note)}\n\nUI state: not yet reviewed\nPlayback: not yet verified\n', encoding='utf-8')
        return {'evidenceDirectory': str(folder), 'uiReviewed': False, 'playbackVerified': False}


def download_run(config, run_id):
    repo = config.get('githubRepository', '')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo) or not run_id.isdigit():
        raise RuntimeError('Configure githubRepository and an explicit numeric --run-id')
    gh = shutil.which('gh')
    if not gh:
        raise RuntimeError('GitHub CLI not installed or not on PATH')
    def github(*args):
        response = subprocess.run([gh, *args], capture_output=True, timeout=180)
        if response.returncode:
            raise RuntimeError('GitHub artifact access failed; check gh auth status')
        return response.stdout.decode('utf-8')
    run = json.loads(github('run', 'view', run_id, '-R', repo, '--json', 'conclusion,headSha,event,headBranch,workflowName,status'))
    if run['conclusion'] != 'success' or run['status'] != 'completed' or run['workflowName'] != 'Android TV APK' or run['event'] not in ['push', 'workflow_dispatch'] or run['headBranch'] != config.get('trustedBranch', 'main'):
        raise RuntimeError('Run is not a successful trusted Android TV build')
    cache = ROOT / '.local' / 'downloads'
    cache.mkdir(parents=True, exist_ok=True)
    folder = Path(tempfile.mkdtemp(prefix=run_id + '-', dir=cache))
    github('run', 'download', run_id, '-R', repo, '--name', 'android-tv-apk', '--dir', str(folder))
    metadata = json.loads((folder / 'artifact.json').read_text(encoding='utf-8'))
    if metadata.get('sourceCommit') != run['headSha'] or str(metadata.get('runId')) != run_id:
        raise RuntimeError('Artifact metadata does not match the selected workflow run')
    filename = metadata.get('file', '')
    if not filename or Path(filename).name != filename:
        raise RuntimeError('Invalid artifact filename')
    return folder / filename, metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / 'tv.local.json')
    commands = parser.add_subparsers(dest='action', required=True)
    for action in ['connect', 'doctor', 'launch', 'capture']:
        commands.add_parser(action)
    key = commands.add_parser('key'); key.add_argument('key', choices=KEYS)
    install = commands.add_parser('install'); install.add_argument('--apk', type=Path, required=True); install.add_argument('--metadata', type=Path, required=True)
    github = commands.add_parser('github-install'); github.add_argument('--run-id', required=True)
    options = parser.parse_args()
    config = json.loads(options.config.read_text(encoding='utf-8'))
    tv = TV(config)
    if options.action == 'connect':
        tv.connect(); result = tv.doctor()
    elif options.action == 'doctor': result = tv.doctor()
    elif options.action == 'install': result = tv.install(options.apk, json.loads(options.metadata.read_text(encoding='utf-8')))
    elif options.action == 'launch': result = tv.launch()
    elif options.action == 'capture': result = tv.capture()
    elif options.action == 'key':
        tv.run('shell', 'input', 'keyevent', str(KEYS[options.key])); result = tv.capture('after remote key: ' + options.key)
    else:
        apk, metadata = download_run(config, options.run_id)
        tv.connect(); result = tv.install(apk, metadata)
        result['launch'] = tv.launch(metadata['activity']); result['evidence'] = tv.capture('after GitHub artifact install')
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    try: main()
    except (RuntimeError, OSError, KeyError, ValueError, subprocess.TimeoutExpired) as error:
        print(redact(str(error)), file=sys.stderr)
        raise SystemExit(1)
