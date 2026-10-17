"""Exercise only the bundle metadata fragment, without building/installing an app."""
from pathlib import Path
import json
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class VersionMetadataTests(unittest.TestCase):
    def generate(self, version, change_app=False):
        script = (ROOT / 'script/build_and_run.sh').read_text()
        start = script.index('cat > "$APP_BUNDLE/Contents/Info.plist"')
        end = script.index('cat > "$APP_BUNDLE/Contents/Library/LaunchDaemons/', start)
        fragment = script[start:end]
        if change_app:
            original = plistlib.loads(fragment.split("<<'PLIST'\n", 1)[1].split('\nPLIST', 1)[0].encode())
            fragment = fragment.replace('<string>'+original['CFBundleShortVersionString']+'</string>', '<string>9.8.7</string>')
            fragment = fragment.replace('<string>'+original['CFBundleVersion']+'</string>', '<string>123</string>')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / 'Example App.app'
            (app / 'Contents').mkdir(parents=True)
            (root / 'Resources/Core').mkdir(parents=True)
            (root / 'Resources/Core/release.json').write_text(json.dumps({'version': version}))
            (root / 'Resources/Sparkle').mkdir(parents=True)
            (root / 'Resources/Sparkle/public-key.txt').write_text((ROOT / 'Resources/Sparkle/public-key.txt').read_text())
            result = subprocess.run(['/bin/bash', '-euo', 'pipefail', '-c',
                                     'APP_BUNDLE="$1"\nROOT_DIR="$2"\nARCH=arm64\n'+fragment,
                                     'version-metadata-test', str(app), str(root)], capture_output=True, text=True)
            return result, plistlib.loads((app / 'Contents/Info.plist').read_bytes())

    def test_core_version_comes_from_lock_and_tracks_changes(self):
        for version in ['v1.88.4', 'v2.4.6']:
            result, info = self.generate(version)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(info['LumaRouteCoreVersion'], version)

    def test_build_metadata_preserves_app_version_and_build(self):
        result, info = self.generate('v2.4.6', change_app=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(info['CFBundleShortVersionString'], '9.8.7')
        self.assertEqual(info['CFBundleVersion'], '123')
        self.assertEqual(info['CFBundleDevelopmentRegion'], 'zh_CN')
        self.assertEqual(info['CFBundleLocalizations'], ['zh_CN'])
        self.assertTrue(info['SURequireSignedFeed'])
        self.assertTrue(info['SUVerifyUpdateBeforeExtraction'])
        self.assertFalse(info['SUEnableAutomaticChecks'])
        self.assertFalse(info['SUAllowsAutomaticUpdates'])
        self.assertTrue(info['SUFeedURL'].endswith('/appcast-arm64.xml'))

    def test_invalid_core_metadata_fails_packaging(self):
        for version in ['v1.2.3\nInjected: value', 'not-a-version', None]:
            result, info = self.generate(version)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('LumaRouteCoreVersion', info)


if __name__ == '__main__':
    unittest.main()
