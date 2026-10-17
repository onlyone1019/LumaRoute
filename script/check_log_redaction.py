"""Count real redaction/regex work through the production log ingestion methods.

Instrumentation exists only in temporary source copies. No app, core process,
privileged service, build products or system network settings are used.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--source-root', type=Path, default=ROOT)
args = parser.parse_args()

models = (args.source_root / 'Sources/LumaRouteCore/Models.swift').read_text()
models = models[models.index('public struct RedactedLogMessage:'):models.index('public enum Format {')]
signature = 'public static func clean(_ text: String) -> String {'
assert models.count(signature) == 1
assert 'NSRegularExpression(pattern:' in models
models = models.replace(signature, signature + '\n        RedactionProbe.recordClean()')
models = models.replace('NSRegularExpression(pattern:', 'RedactionProbe.compile(pattern:')
store = (args.source_root / 'Sources/LumaRoute/Stores/AppStore.swift').read_text()
methods = store[store.index('    func appendLog('):store.index('    func report(')]
reader = (args.source_root / 'Sources/LumaRouteCore/CoreLogReader.swift').read_text()

with tempfile.TemporaryDirectory(prefix='lumaroute-log-redaction-') as directory:
    work = Path(directory)
    source = work / 'LogIngestion.swift'
    source.write_text('import Foundation\n' + models + '\n' + reader + '''
@MainActor final class AppStore {
    var pendingLogs: [LogEntry] = []
    var logs: [LogEntry] = []
    var logFlushTask: Task<Void,Never>?
    var coreReady = false
    var logStreamAvailable = false
''' + methods + '''
    func capture(_ message: RedactedLogMessage) { captureKernelOutput(message) }
    func flush() { flushLogs() }
}
''')
    binary = work / 'log-redaction-check'
    subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', str(source),
                    str(ROOT / 'script/check_log_redaction.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
