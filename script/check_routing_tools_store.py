"""Check routing metadata with the actual AppStore and a private SQLite database."""
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT/'work/routing-tools-2026-10-15'
WORK.mkdir(parents=True, exist_ok=True, mode=0o700)
products = ROOT/'.build/out/Products/Release'
binary = WORK/'appstore-check'
sdk = '/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk'
command = ['xcrun', 'swiftc', '-O', '-g', '-parse-as-library', '-target', 'arm64-apple-macosx14.0', '-sdk', sdk, '-I', str(products), '-I', str(ROOT/'.build/checkouts/Yams/Sources/CYaml/include')]
command += [str(ROOT/name) for name in ['script/check_routing_tools_store.swift', 'Sources/LumaRoute/Stores/AppStore.swift', 'Sources/LumaRoute/Stores/RoutingStore.swift', 'Sources/LumaRoute/Stores/RuleSubscriptionStore.swift', 'Sources/LumaRoute/Stores/RuntimeData.swift', 'Sources/LumaRoute/Support/HelperClient.swift']]
command += [str(products/name) for name in ['LumaRouteCore.o', 'Yams.o', 'CYaml.o']]
command += ['-o', str(binary)]
subprocess.run(command, cwd=ROOT, check=True)
subprocess.run([str(binary), str(WORK/('store-'+str(time.time_ns()))), str(ROOT/'Resources/Core/mihomo-arm64')], cwd=ROOT, check=True, timeout=60)
