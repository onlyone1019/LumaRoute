"""Exercise production registration flow without calling ServiceManagement."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class HelperRegistrationTests(unittest.TestCase):
    def test_registration_migration_order_and_failure_handling(self):
        source = (ROOT / 'Sources/LumaRoute/Support/HelperClient.swift').read_text()
        register = source[source.index('    func register('):source.index('    func unregister()')]
        unregister = source[source.index('    private func unregisterManagedService('):source.index('    func openApproval()')]
        fixture = (ROOT / 'Tests/Fixtures/helper_registration.swift').read_text()
        (ROOT / 'work').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='helper-registration-', dir=ROOT / 'work') as directory:
            work = Path(directory)
            generated = work / 'registration.swift'
            generated.write_text(fixture.replace('    // PRODUCTION_REGISTER', register)
                                 .replace('    // PRODUCTION_MANAGED_UNREGISTER', unregister))
            binary = work / 'check'
            result = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors',
                                     '-parse-as-library', str(generated), '-o', str(binary)],
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS registration migration', result.stdout)


if __name__ == '__main__':
    unittest.main()
