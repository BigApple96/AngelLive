from pathlib import Path
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tv
import ci_prepare
import verify_apk


class SigningToolContract(unittest.TestCase):
    def test_numbered_and_sdk_range_signer_formats_are_supported(self):
        for label in ['Signer #1', 'Signer (minSdkVersion=24, maxSdkVersion=2147483647)']:
            with self.subTest(label=label):
                output = label + ' certificate SHA-256 digest: ' + 'A' * 64 + '\n'
                self.assertEqual(verify_apk.signing_certificate(output), 'a' * 64)

    def test_distinct_signing_certificates_are_rejected(self):
        output = 'Signer #1 certificate SHA-256 digest: ' + 'a' * 64 + '\n'
        output += 'Signer #2 certificate SHA-256 digest: ' + 'b' * 64 + '\n'
        with self.assertRaises(RuntimeError):
            verify_apk.signing_certificate(output)

    def test_source_stamp_cannot_replace_application_signer(self):
        output = 'Source Stamp Signer certificate SHA-256 digest: ' + 'a' * 64 + '\n'
        with self.assertRaises(RuntimeError):
            verify_apk.signing_certificate(output)


class InstallContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.apk = Path(self.temp.name) / 'app.apk'
        self.apk.write_bytes(b'fixture apk')
        self.metadata = {'file': 'app.apk', 'sha256': hashlib.sha256(self.apk.read_bytes()).hexdigest(),
                         'certificateSha256': 'a' * 64, 'packageId': 'fixture.client',
                         'activity': 'fixture.client.MainActivity', 'versionCode': 4,
                         'abis': ['arm64-v8a', 'armeabi-v7a'], 'minSdk': 24}
        self.config = {'serial': '192.0.2.10:5555', 'adbPath': 'fixture-adb', 'expectedModel': 'Fixture TV',
                       'packageId': 'fixture.client', 'expectedCertificateSha256': 'a' * 64}

    def test_matching_artifact_is_accepted(self):
        tv.validate_apk(self.apk, self.metadata, dict(self.metadata), self.config)

    def test_tampered_bytes_rejected_before_inspection_metadata_can_authorize(self):
        self.apk.write_bytes(b'tampered apk')
        with self.assertRaisesRegex(RuntimeError, 'checksum'):
            tv.validate_apk(self.apk, self.metadata, dict(self.metadata), self.config)

    def test_certificate_pinning_is_mandatory(self):
        for value in ['', 'b' * 64]:
            with self.subTest(value=value):
                config = {**self.config, 'expectedCertificateSha256': value}
                with self.assertRaises(RuntimeError):
                    tv.validate_apk(self.apk, self.metadata, dict(self.metadata), config)

    def test_actual_apk_metadata_must_match_sidecar(self):
        for field, value in [('packageId', 'fixture.other'), ('versionCode', 8), ('certificateSha256', 'b' * 64)]:
            with self.subTest(field=field):
                with self.assertRaises(RuntimeError):
                    tv.validate_apk(self.apk, self.metadata, {**self.metadata, field: value}, self.config)

    def test_wrong_tv_never_triggers_install(self):
        target = tv.TV(self.config)
        with patch('tv.inspect', return_value=dict(self.metadata)), patch.object(target, 'doctor', return_value={'model': 'Other TV', 'api': 30, 'abis': ['arm64-v8a']}), patch.object(target, 'run') as adb:
            with self.assertRaisesRegex(RuntimeError, 'model'):
                target.install(self.apk, self.metadata)
            adb.assert_not_called()

    def test_success_uses_replace_without_downgrade_uninstall_or_clear(self):
        target = tv.TV(self.config)
        with patch('tv.inspect', return_value=dict(self.metadata)), patch.object(target, 'doctor', return_value={'model': 'Fixture TV', 'api': 30, 'abis': ['arm64-v8a']}), patch.object(target, 'run', side_effect=['Success', 'versionCode=4 minSdk=24']) as adb:
            self.assertTrue(target.install(self.apk, self.metadata)['installed'])
            self.assertEqual(adb.call_args_list[0].args[:2], ('install', '-r'))
            for call in adb.call_args_list:
                self.assertFalse({'uninstall', 'clear', '-d'}.intersection(map(str, call.args)))

    def test_absent_package_is_not_treated_as_adb_failure(self):
        target = tv.TV(self.config)
        response = subprocess.CompletedProcess([], 1, b'', b'')
        with patch('tv.subprocess.run', return_value=response):
            self.assertEqual(target.run('shell', 'pidof', 'fixture.client', allow_absent=True), '')
            with self.assertRaises(RuntimeError):
                target.run('shell', 'getprop', 'ro.product.model')

    def test_logs_remove_credentials_and_network_urls(self):
        text = tv.redact('Cookie: fixture-secret\nhttps://login.example.invalid/path?token=secret\nnormal playback state')
        self.assertNotIn('fixture-secret', text)
        self.assertNotIn('token=secret', text)
        self.assertIn('normal playback state', text)

    def test_invalid_serial_does_not_execute_subprocess(self):
        with patch('tv.subprocess.run') as run:
            with self.assertRaises(RuntimeError):
                tv.TV({**self.config, 'serial': '-Hattacker'})
            run.assert_not_called()


class BuildConfiguration(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / 'android').mkdir()
        (self.root / 'assets').mkdir()
        self.patch = patch.object(ci_prepare, 'ROOT', self.root)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def test_missing_secrets_produce_separate_preview_mode(self):
        envfile = self.root / 'github-env'
        self.assertEqual(ci_prepare.prepare({'GITHUB_ENV': str(envfile)}), 'preview')
        exported = dict(line.split('=', 1) for line in envfile.read_text().splitlines())
        self.assertEqual(exported['ANGEL_TV_CI_PREVIEW'], 'true')
        self.assertEqual(exported['CI_PACKAGE_ID'], 'works.angel.angel_live_android_tv.preview')
        self.assertFalse((self.root / 'android/key.properties').exists())
        self.assertEqual(json.loads((self.root / 'assets/bootstrap.json').read_text())['sourceURL'], '')

    def test_partial_signing_secrets_fail_instead_of_silently_falling_back(self):
        with self.assertRaises(RuntimeError):
            ci_prepare.prepare({'TV_KEY_ALIAS': 'fixture'})

    def test_signed_mode_requires_all_secrets(self):
        with self.assertRaises(RuntimeError):
            ci_prepare.prepare({'REQUESTED_BUILD': 'signed'})

    def test_complete_signing_configuration_is_written_only_to_ignored_files(self):
        self.assertEqual(ci_prepare.prepare({'REQUESTED_BUILD': 'signed', 'TV_KEYSTORE_BASE64': 'Zml4dHVyZQ==',
                                           'TV_STORE_PASSWORD': 'fixture=store', 'TV_KEY_ALIAS': 'fixture', 'TV_KEY_PASSWORD': 'fixture:key'}), 'signed')
        self.assertEqual((self.root / 'android/ci-release.jks').read_bytes(), b'fixture')
        properties = (self.root / 'android/key.properties').read_text()
        self.assertIn('storePassword=fixture\\=store', properties)
        self.assertIn('keyPassword=fixture\\:key', properties)


if __name__ == '__main__':
    unittest.main()
