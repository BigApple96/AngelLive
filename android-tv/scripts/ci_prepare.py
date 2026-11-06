"""Create ignored build configuration; never print credentials or private URLs."""
from pathlib import Path
import base64
import json
import os

ROOT = Path(__file__).resolve().parent.parent


def prepare(env):
    requested = env.get('REQUESTED_BUILD', 'auto')
    if requested not in ['auto', 'preview', 'signed']:
        raise RuntimeError('Unknown build mode')
    names = ['TV_KEYSTORE_BASE64', 'TV_STORE_PASSWORD', 'TV_KEY_ALIAS', 'TV_KEY_PASSWORD']
    supplied = [bool(env.get(name)) for name in names]
    if any(supplied) and not all(supplied) and requested != 'preview':
        raise RuntimeError('Signing configuration is incomplete; configure all four signing secrets')
    signed = requested != 'preview' and all(supplied)
    if requested == 'signed' and not signed:
        raise RuntimeError('Signed build requested but signing secrets are missing')
    keyfile = ROOT / 'android/ci-release.jks'
    props = ROOT / 'android/key.properties'
    if signed:
        keyfile.write_bytes(base64.b64decode(env['TV_KEYSTORE_BASE64'], validate=True))
        keyfile.chmod(0o600)
        def escape(value):
            return value.replace('\\', '\\\\').replace('\r', '\\r').replace('\n', '\\n').replace('=', '\\=').replace(':', '\\:')
        text = '\n'.join([
            'storeFile=../ci-release.jks',
            'storePassword=' + escape(env['TV_STORE_PASSWORD']),
            'keyAlias=' + escape(env['TV_KEY_ALIAS']),
            'keyPassword=' + escape(env['TV_KEY_PASSWORD']),
        ]) + '\n'
        props.write_text(text, encoding='utf-8')
        props.chmod(0o600)
    elif props.exists() or keyfile.exists():
        raise RuntimeError('Preview build must start without a local signing configuration')
    source = env.get('TV_PLUGIN_SOURCE_URL', '').strip()
    if source and not source.startswith('https://'):
        raise RuntimeError('Plugin source must use HTTPS')
    (ROOT / 'assets/bootstrap.json').write_text(json.dumps({'sourceURL': source}) + '\n', encoding='utf-8')
    mode = 'signed' if signed else 'preview'
    if env.get('GITHUB_ENV'):
        with open(env['GITHUB_ENV'], 'a', encoding='utf-8') as output:
            package_id = 'works.angel.angel_live_android_tv' + ('' if signed else '.preview')
            output.write(f'CI_BUILD_MODE={mode}\nANGEL_TV_CI_PREVIEW={str(not signed).lower()}\nCI_PACKAGE_ID={package_id}\n')
    print('Prepared ' + mode + ' build; private configuration values are not logged.')
    return mode


if __name__ == '__main__':
    prepare(os.environ)
