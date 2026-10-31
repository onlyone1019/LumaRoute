"""Run production network restoration against an in-memory preferences double."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SystemNetworkRecoveryTests(unittest.TestCase):
    def test_missing_services_protocols_and_foreign_proxy_ownership(self):
        source = (ROOT / 'Sources/LumaRouteCore/SystemNetwork.swift').read_text()
        source = source.replace('import Foundation\n', '').replace('import SystemConfiguration\n', '')
        fixture = (ROOT / 'Tests/Fixtures/system_network_recovery.swift').read_text()
        work = ROOT / 'work'
        work.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='network-recovery-', dir=work) as directory:
            folder = Path(directory)
            generated = folder / 'Recovery.swift'
            generated.write_text(fixture.replace('// PRODUCTION_SYSTEM_NETWORK', source))
            binary = folder / 'check'
            result = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors',
                                     '-parse-as-library', str(generated), '-o', str(binary)],
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(binary), str(folder)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout.count('PASS '), 7)


if __name__ == '__main__':
    unittest.main()
