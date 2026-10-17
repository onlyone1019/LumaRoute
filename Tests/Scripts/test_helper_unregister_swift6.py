"""Exercise the production unregister bridge with an older non-Sendable SDK surface."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class HelperUnregisterSwift6Tests(unittest.TestCase):
    def test_legacy_service_boundary_and_completion_results(self):
        source = (ROOT / 'Sources/LumaRoute/Support/HelperClient.swift').read_text()
        method = source[source.index('    func unregister()'):source.index('    func openApproval()')]
        fixture = (ROOT / 'Tests/Fixtures/helper_unregister_swift6.swift').read_text()
        with tempfile.TemporaryDirectory(prefix='lumaroute-unregister-swift6-') as directory:
            generated = Path(directory) / 'unregister.swift'
            generated.write_text(fixture.replace('    // PRODUCTION_UNREGISTER', method))
            binary = Path(directory) / 'check'
            compile_result = subprocess.run(
                ['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors',
                 '-parse-as-library', str(generated), '-o', str(binary)],
                capture_output=True, text=True, timeout=60)
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS Swift 6 legacy non-Sendable service', result.stdout)


if __name__ == '__main__':
    unittest.main()
