"""Check production export/version methods in temporary bundles, without a UI.

Build the package first; --products points to isolated Debug/Release products.
Only the surrounding AppStore fields/network effects are replaced by a fixture.
"""
from build_environment import configure
from pathlib import Path
import argparse
import plistlib
import subprocess
import tempfile

SDK = configure()

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--products', type=Path, default=ROOT / '.build/out/Products/Release')
args = parser.parse_args()
store = (ROOT / 'Sources/LumaRoute/Stores/AppStore.swift').read_text()
versions = store[store.index('    var applicationVersion:'):store.index('    @Published var canRollbackCore')]
export = store[store.index('    func exportDiagnostics('):store.index('    func shutdown(')]
page = (ROOT / 'Sources/LumaRoute/Views/LogsPage.swift').read_text()
state = page[page.index('@Observable @MainActor final class LogsPageState'):page.index('\nstruct LogsPage:View')]
document = page[page.index('struct DiagnosticsDocument:'):]

with tempfile.TemporaryDirectory(prefix='lumaroute-version-check-') as directory:
    work = Path(directory)
    source = work / 'VersionExports.swift'
    source.write_text('''import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import LumaRouteCore
@MainActor final class AppStore {
    var logs: [LogEntry] = []
    var coreVersion = "v4.6.8"
    var coreReady = false
    var coreUpdates: CoreUpdates!
    var flushes = 0
    func flushLogs() { flushes += 1 }
''' + versions + export + '''
    func subscriptionInfo() -> VersionInfo { subscriptionVersionInfo }
}
''' + state + document)
    binary = work / 'version-check'
    products = args.products.resolve()
    command = ['xcrun', 'swiftc', '-sdk', SDK, '-O', '-parse-as-library', '-I', str(products),
               '-I', str(ROOT / '.build/checkouts/Yams/Sources/CYaml/include'),
               str(source), str(ROOT / 'script/check_version_info.swift')]
    command += [str(products / name) for name in ['LumaRouteCore.o', 'Yams.o', 'CYaml.o']]
    subprocess.run(command + ['-o', str(binary)], check=True)
    for version, build, core in [('9.8.7', '123', 'v1.88.4'), ('10.2.3', '456', 'v2.4.6')]:
        app = work / (version + '.app')
        executable = app / 'Contents/MacOS/version-check'
        executable.parent.mkdir(parents=True)
        executable.write_bytes(binary.read_bytes())
        executable.chmod(0o700)
        info = {'CFBundleExecutable': 'version-check', 'CFBundleIdentifier': 'test.lumaroute.'+build,
                'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': version,
                'CFBundleVersion': build, 'LumaRouteCoreVersion': core}
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        subprocess.run([str(executable), str(work / (build+'-main')), version, build, core], check=True, timeout=15)
        helper = app / 'Contents/Library/LaunchServices/version-helper'
        helper.parent.mkdir(parents=True)
        helper.write_bytes(binary.read_bytes())
        helper.chmod(0o700)
        subprocess.run([str(helper), str(work / (build+'-helper')), version, build, core], check=True, timeout=15)
