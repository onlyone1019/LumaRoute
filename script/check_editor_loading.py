"""Build an isolated native host for manual/CUA loading-state acceptance; never opens the live app."""
from pathlib import Path
import plistlib
import subprocess

ROOT=Path(__file__).resolve().parents[1]
WORK=ROOT/'work/editor-load-fix-2026-10-15'
WORK.mkdir(parents=True,exist_ok=True,mode=0o700)
app=WORK/'EditorLoadingQA.app'
(app/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
products=ROOT/'.build/out/Products/Release'
# Compile the actual shared controls without pulling in the production RootView.
components=WORK/'EditorComponents.swift'
components.write_text((ROOT/'Sources/LumaRoute/Views/Components.swift').read_text().split('struct RootView:View')[0])
command=['xcrun','swiftc','-O','-parse-as-library','-target','arm64-apple-macosx14.0','-sdk','/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk','-I',str(products),'-I',str(ROOT/'.build/checkouts/Yams/Sources/CYaml/include')]
command += [str(ROOT/p) for p in ['script/check_editor_loading.swift','Sources/LumaRoute/Views/CompositionRoutingEditor.swift','Sources/LumaRoute/Stores/AppStore.swift','Sources/LumaRoute/Stores/RoutingStore.swift','Sources/LumaRoute/Stores/RuleSubscriptionStore.swift','Sources/LumaRoute/Stores/RuntimeData.swift','Sources/LumaRoute/Support/HelperClient.swift']]
command += [str(components),str(ROOT/'Sources/LumaRoute/Views/Controls.swift')]
command += [str(products/name) for name in ['LumaRouteCore.o','Yams.o','CYaml.o']]
command += ['-o',str(app/'Contents/MacOS/EditorLoadingQA')]
subprocess.run(command,cwd=ROOT,check=True)
with (app/'Contents/Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleIdentifier':'app.lumaroute.editor-loading-qa','CFBundleExecutable':'EditorLoadingQA','CFBundleName':'EditorLoadingQA','CFBundlePackageType':'APPL','LSMinimumSystemVersion':'14.0','NSPrincipalClass':'NSApplication'},f)
subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(app)],check=True)
print(app)
