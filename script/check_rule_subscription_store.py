"""Exercise actual AppStore rule scheduling without bootstrapping or touching user data."""
from build_environment import configure
from pathlib import Path
import subprocess
import tempfile

SDK = configure()

root = Path(__file__).resolve().parents[1]
products = root / ".build/out/Products/Release"
with tempfile.TemporaryDirectory(prefix="LumaRoute-rule-store-") as directory:
    binary = Path(directory) / "check-rule-store"
    command = ["xcrun", "swiftc", "-O", "-parse-as-library", "-target", "arm64-apple-macosx14.0", "-sdk", SDK, "-I", str(products), "-I", str(root / ".build/checkouts/Yams/Sources/CYaml/include")]
    command += [str(root / name) for name in ["script/check_rule_subscription_store.swift", "Sources/LumaRoute/Stores/AppStore.swift", "Sources/LumaRoute/Stores/RuleSubscriptionStore.swift", "Sources/LumaRoute/Stores/RuntimeData.swift", "Sources/LumaRoute/Support/HelperClient.swift"]]
    command += [str(products / name) for name in ["LumaRouteCore.o", "Yams.o", "CYaml.o"]]
    command += ["-o", str(binary)]
    subprocess.run(command, cwd=root, check=True)
    subprocess.run([str(binary), str(Path(directory) / "data"), str(root / "Resources/Core/mihomo-arm64")], cwd=root, check=True, timeout=120)
