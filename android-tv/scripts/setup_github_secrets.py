"""Explicitly upload an existing signing key to the specified repository's Actions secrets."""
from pathlib import Path
import argparse
import base64
import re
import shutil
import subprocess


def read_properties(path):
    values = {}
    for line in Path(path).read_text(encoding='utf-8-sig').splitlines():
        if not line.strip() or line.lstrip().startswith(('#', '!')):
            continue
        name, delimiter, value = line.partition('=')
        if not delimiter:
            raise RuntimeError('Use key=value format in the private signing properties file')
        def unescape(match):
            item = match.group(1)
            if item.startswith('u'):
                return chr(int(item[1:], 16))
            return {'t': '\t', 'r': '\r', 'n': '\n', 'f': '\f'}.get(item, item)
        values[name.strip()] = re.sub(r'\\(u[0-9a-fA-F]{4}|.)', unescape, value.lstrip())
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--key-properties', type=Path, required=True)
    parser.add_argument('--keystore', type=Path, required=True)
    parser.add_argument('--plugin-source-file', type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo):
        raise RuntimeError('Use an explicit OWNER/REPOSITORY')
    gh = shutil.which('gh')
    if not gh:
        raise RuntimeError('Install GitHub CLI and run gh auth login')
    props = read_properties(args.key_properties)
    secrets = {
        'TV_KEYSTORE_BASE64': base64.b64encode(args.keystore.read_bytes()),
        'TV_STORE_PASSWORD': props.get('storePassword', '').encode(),
        'TV_KEY_ALIAS': props.get('keyAlias', '').encode(),
        'TV_KEY_PASSWORD': props.get('keyPassword', '').encode(),
    }
    if not all(secrets.values()):
        raise RuntimeError('Signing properties are incomplete')
    if args.plugin_source_file:
        source = args.plugin_source_file.read_text(encoding='utf-8-sig').strip()
        if not source.startswith('https://'):
            raise RuntimeError('Plugin source must use HTTPS')
        secrets['TV_PLUGIN_SOURCE_URL'] = source.encode()
    for name, value in secrets.items():
        response = subprocess.run([gh, 'secret', 'set', name, '--repo', args.repo], input=value, capture_output=True, timeout=45)
        if response.returncode:
            raise RuntimeError('Secret upload failed at ' + name + '; earlier secrets may already be set. Check gh auth and retry this command.')
        print('Configured Actions secret: ' + name)


if __name__ == '__main__':
    try: main()
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(str(error))
        raise SystemExit(1)
