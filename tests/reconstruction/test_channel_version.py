"""Exercise real version generation in disposable copies of production consumers."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(os.environ.get('OPTISHADE_TEST_ROOT', Path(__file__).resolve().parents[2]))
CHANNEL = ROOT / 'Beta'
spec = importlib.util.spec_from_file_location('channel_version', CHANNEL / 'reconstruction/channel_version.py')
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class ChannelVersion(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='optishade-version-fixture-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / 'Beta'
        for path in generator.render_outputs(CHANNEL):
            target = self.root / path.relative_to(CHANNEL)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)

    def apply(self, channel=None):
        for path, content in generator.render_outputs(self.root, channel).items():
            path.write_bytes(content)

    def check(self):
        return subprocess.run([sys.executable, str(CHANNEL / 'reconstruction/channel_version.py'),
                               '--root', str(self.root), '--check'], text=True, capture_output=True, timeout=20)

    def test_canonical_consumers_are_current(self):
        self.assertEqual(0, self.check().returncode)

    def test_windows_crlf_generated_json_consumers_remain_current(self):
        for relative in ('installer/versioninfo.json', 'shared/build-version.json'):
            path = self.root / relative
            original = path.read_bytes()
            bom = b'\xef\xbb\xbf' if original.startswith(b'\xef\xbb\xbf') else b''
            text = original[len(bom):].decode('utf-8').replace('\r\n', '\n').replace('\n', '\r\n')
            path.write_bytes(bom + text.encode('utf-8'))

        checked = self.check()
        self.assertEqual(0, checked.returncode, checked.stdout + checked.stderr)
        for relative in ('installer/versioninfo.json', 'shared/build-version.json'):
            path = self.root / relative
            self.assertIn(b'\r\n', path.read_bytes())

        definition_path = self.root / 'shared/build-version.json'
        definition = json.loads(definition_path.read_text(encoding='utf-8-sig'))
        definition['version'] = '1.0.78'
        definition_path.write_text(json.dumps(definition, indent=2) + '\n', encoding='utf-8')
        self.apply()
        self.assertTrue((self.root / 'installer/versioninfo.json').read_bytes().count(b'\r\n'))
        self.assertTrue(definition_path.read_bytes().count(b'\r\n'))
        checked = self.check()
        self.assertEqual(0, checked.returncode, checked.stdout + checked.stderr)

    def test_beta_and_stable_use_current_structured_version(self):
        for channel in ('stable', 'beta'):
            self.apply(channel)
            self.assertEqual(0, self.check().returncode)
            resources = json.loads((self.root / 'installer/versioninfo.json').read_text())
            definition = json.loads((self.root / 'shared/build-version.json').read_text())
            version = definition['version'] + (f'-beta.{definition["betaRevision"]}' if channel == 'beta' else '')
            self.assertEqual(version, resources['StringFileInfo']['FileVersion'])
            self.assertEqual(version, resources['StringFileInfo']['ProductVersion'])
            self.assertEqual(definition['betaRevision'] if channel == 'beta' else 0, resources['FixedFileInfo']['FileVersion']['Build'])
            self.assertIn(f"'P{version}'", (self.root / 'installer/ownership.ps1').read_text(encoding='utf-8-sig'))
            self.assertIn(f'OPTISHADE_BUILD_CHANNEL "{channel}"', (self.root / 'shared/OptiShadeVersion.h').read_text())

    def test_new_version_does_not_need_old_version_literals(self):
        path = self.root / 'shared/build-version.json'
        definition = json.loads(path.read_text())
        definition.update(version='2.16.8', betaRevision=12)
        path.write_text(json.dumps(definition))
        self.apply('beta')
        self.assertEqual(0, self.check().returncode)
        self.assertIn("$buildVersion='2.16.8-beta.12'", (self.root / 'package.ps1').read_text())
        self.apply('stable')
        self.assertIn("$buildVersion='2.16.8'", (self.root / 'package.ps1').read_text())

    def test_stale_consumer_is_reported_and_not_rewritten_by_check(self):
        path = self.root / 'shared/OptiShadeVersion.h'
        data = path.read_bytes().replace(b'OPTISHADE_VERSION_MAJOR 1', b'OPTISHADE_VERSION_MAJOR 7')
        path.write_bytes(data)
        process = self.check()
        self.assertNotEqual(0, process.returncode)
        self.assertIn('Stale channel/version', process.stdout)
        self.assertEqual(data, path.read_bytes())

    def test_missing_or_ambiguous_consumer_is_rejected_before_writing(self):
        path = self.root / 'installer/ownership.ps1'
        before = path.read_bytes()
        path.write_bytes(before + b"\nfunction GetBundledOptiShadeVersion { 'P9.9.9' }\n")
        with self.assertRaisesRegex(ValueError, 'expected one field'):
            generator.render_outputs(self.root)
        path.unlink()
        with self.assertRaises(FileNotFoundError):
            generator.render_outputs(self.root)

    def test_provider_policy_keeps_distinct_channel_rules_and_rejects_stale_copy(self):
        repo = Path(self.temporary.name)
        for relative in ('reconstruction/generate_provider_policy.py', 'shared/provider-policy.json', 'installer/provider-policy.ps1',
                         'shared/neural-model-policy.json', 'installer/gpu-identity.ps1', 'installer/GpuIdentityClient.cs',
                         'shared/qualification-policy.json', 'shared/qualified-plan-ranking.ps1'):
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(CHANNEL / relative, target)
        (repo / 'Stable/installer').mkdir(parents=True)
        script = self.root / 'reconstruction/generate_provider_policy.py'
        def run(*args):
            return subprocess.run([sys.executable, str(script), *args], text=True, capture_output=True, timeout=20)
        generated = run()
        self.assertEqual(0, generated.returncode, generated.stdout + generated.stderr)
        checked = run('--check')
        self.assertEqual(0, checked.returncode, checked.stdout + checked.stderr)
        beta = json.loads((self.root / 'installer/provider-policy.json').read_text())
        stable = json.loads((repo / 'Stable/installer/provider-policy.json').read_text())
        self.assertEqual(beta, stable)
        self.assertNotEqual(beta['channels']['stable'], beta['channels']['beta'])
        (repo / 'Stable/installer/provider-policy.ps1').write_text('deliberately stale fixture')
        failed = run('--check')
        self.assertNotEqual(0, failed.returncode)
        self.assertIn('Stale provider policy', failed.stderr + failed.stdout)
        for name in ('qualification-policy.json', 'qualified-plan-ranking.ps1'):
            for channel in ('Beta', 'Stable'):
                with self.subTest(qualification_input=name, channel=channel):
                    regenerated = run()
                    self.assertEqual(0, regenerated.returncode, regenerated.stdout + regenerated.stderr)
                    original = (self.root / 'shared' / name).read_bytes()
                    mirror = repo / channel / 'installer' / name
                    self.assertEqual(original, mirror.read_bytes())
                    if b'\n' in original:
                        mirror.write_bytes(original.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n'))
                        newline_only = run('--check')
                        self.assertEqual(0, newline_only.returncode, newline_only.stdout + newline_only.stderr)
                    changed = original + b'\nfixture drift\n'
                    mirror.write_bytes(changed)
                    failed = run('--check')
                    self.assertNotEqual(0, failed.returncode)
                    self.assertIn('Stale provider policy', failed.stderr + failed.stdout)
                    self.assertEqual(changed, mirror.read_bytes(), '--check must not repair the drift')


if __name__ == '__main__':
    unittest.main()
