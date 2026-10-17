"""Check SwiftPM's evaluated manifest without resolving dependencies or building."""
from pathlib import Path
import json
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SwiftLanguageModeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Evaluate a copy so SwiftPM's manifest cache stays outside the checkout.
        with tempfile.TemporaryDirectory(prefix='lumaroute-language-modes-') as directory:
            package = Path(directory)
            (package / 'Package.swift').write_bytes((ROOT / 'Package.swift').read_bytes())
            result = subprocess.run(
                ['swift', 'package', '--package-path', str(package), 'dump-package'],
                capture_output=True, text=True, check=True, timeout=60)
            cls.targets = {target['name']: target for target in json.loads(result.stdout)['targets']}

    def assert_language_mode(self, target, mode):
        settings = self.targets[target]['settings']
        modes = [setting for setting in settings if 'swiftLanguageMode' in setting['kind']]
        # Require an unconditional mode, including when tools-version defaults change.
        self.assertEqual(modes, [{'kind': {'swiftLanguageMode': {'_0': mode}}, 'tool': 'swift'}])

    def test_core_and_helper_use_swift_6_in_all_configurations(self):
        for target in ['LumaRouteCore', 'LumaRouteHelper']:
            with self.subTest(target=target):
                self.assert_language_mode(target, '6')

    def test_application_uses_swift_6(self):
        self.assert_language_mode('LumaRoute', '6')

    def test_cli_and_tests_use_swift_6(self):
        for target in ['LumaRouteCLI', 'LumaRouteCoreTests']:
            with self.subTest(target=target):
                self.assert_language_mode(target, '6')


if __name__ == '__main__':
    unittest.main()
