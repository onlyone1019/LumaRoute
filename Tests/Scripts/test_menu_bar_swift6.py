"""Compile and render the production menu layout without opening an app/window."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class MenuBarSwift6Tests(unittest.TestCase):
    def test_main_actor_layout_compiles_and_renders_in_swift_6(self):
        with tempfile.TemporaryDirectory(prefix='lumaroute-menu-swift6-') as directory:
            binary = Path(directory) / 'menu-bar-check'
            compiled = subprocess.run(
                ['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
                 str(ROOT / 'Sources/LumaRoute/App/MenuBarRateLayout.swift'),
                 str(ROOT / 'Tests/Fixtures/menu_bar_swift6.swift'), '-o', str(binary)],
                capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS Swift 6 main-actor font and rate formatting', result.stdout)
            self.assertIn('PASS fixed menu width, image geometry and offscreen rendering', result.stdout)
            self.assertIn('PASS 32 concurrent callers safely read main-actor layout', result.stdout)


if __name__ == '__main__':
    unittest.main()
