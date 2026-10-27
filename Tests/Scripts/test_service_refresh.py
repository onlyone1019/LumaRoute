"""Replay the real post-install retry against an XPC invalidation double."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ServiceRefreshTests(unittest.TestCase):
    def test_startup_recovery_retry_does_not_invalidate_core_owner(self):
        source = (ROOT / 'Sources/LumaRoute/Stores/AppStore.swift').read_text()
        method = source[source.index('    private func refreshInstalledService()'):source.index('    private func recoverLocalCore()')]
        fixture = (ROOT / 'Tests/Fixtures/service_refresh.swift').read_text()
        (ROOT / 'work').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='service-refresh-', dir=ROOT / 'work') as directory:
            generated = Path(directory) / 'refresh.swift'
            generated.write_text(fixture.replace('    // PRODUCTION_REFRESH', method))
            binary = Path(directory) / 'check'
            result = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors',
                                     '-parse-as-library', str(generated), '-o', str(binary)],
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS production service refresh', result.stdout)


if __name__ == '__main__':
    unittest.main()
