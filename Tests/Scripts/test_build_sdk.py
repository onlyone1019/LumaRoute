"""Exercise SDK selection and real Mach-O build metadata without building the app."""
from pathlib import Path
import importlib.util
import json
import os
import plistlib
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('verify_macos_sdk', ROOT / 'script/verify_macos_sdk.py')
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class BuildSDKTests(unittest.TestCase):
    def select(self, override=None):
        environment = os.environ.copy()
        environment.pop('LUMAROUTE_SDK', None)
        # Model the prior failure: the launcher/inherited environment chose 26.5.
        environment['SDKROOT'] = '/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk'
        if override is not None:
            environment['LUMAROUTE_SDK'] = str(override)
        return subprocess.run(
            ['/bin/bash', '-euo', 'pipefail', '-c',
             'source "$1"\nprintf "%s\\0%s\\0" "$DEVELOPER_DIR" "$SDKROOT"',
             'sdk-regression', str(ROOT / 'script/build_environment.sh')],
            env=environment, capture_output=True, text=True, timeout=20)

    def test_inherited_sdkroot_cannot_override_pinned_sdk(self):
        result = self.select()
        self.assertEqual(result.returncode, 0, result.stderr)
        developer, sdk, _ = result.stdout.split('\0')
        version = subprocess.check_output(
            ['xcrun', '--sdk', sdk, '--show-sdk-version'],
            env={**os.environ, 'DEVELOPER_DIR': developer, 'SDKROOT': sdk}, text=True).strip()
        self.assertEqual(version, '27.2')

    def fake_sdk(self, directory, version):
        sdk = Path(directory) / 'Developer/SDKs' / ('MacOSX'+version+'.sdk')
        sdk.mkdir(parents=True)
        settings = {
            'Version': version, 'CanonicalName': 'macosx'+version,
            'DisplayName': 'macOS '+version, 'DefaultProperties': {'PLATFORM_NAME': 'macosx'}}
        (sdk / 'SDKSettings.json').write_text(json.dumps(settings))
        (sdk / 'SDKSettings.plist').write_bytes(plistlib.dumps(settings))
        return sdk

    def test_older_or_newer_sdk_is_rejected_without_fallback(self):
        for version in ['27.0', '27.3']:
            with self.subTest(version=version), tempfile.TemporaryDirectory() as directory:
                result = self.select(self.fake_sdk(directory, version))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('固定使用 macOS 27.2 SDK', result.stderr)

    def test_missing_swiftui_plugin_is_rejected_without_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.select(self.fake_sdk(directory, '27.2'))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('缺少 SwiftUI 宏插件', result.stderr)

    def patch_build_version(self, path, field, value):
        data = bytearray(path.read_bytes())
        self.assertEqual(struct.unpack_from('<I', data)[0], 0xfeedfacf)
        offset = 32
        for _ in range(struct.unpack_from('<I', data, 16)[0]):
            command, size = struct.unpack_from('<II', data, offset)
            if command == 0x32:
                struct.pack_into('<I', data, offset+field, value)
                path.write_bytes(data)
                return
            offset += size
        self.fail('missing build version in real compiler output')

    def test_real_objects_and_executables_use_sdk27_and_minimum14(self):
        selected = self.select()
        self.assertEqual(selected.returncode, 0, selected.stderr)
        developer, sdk, _ = selected.stdout.split('\0')
        environment = {**os.environ, 'DEVELOPER_DIR': developer, 'SDKROOT': sdk}
        with tempfile.TemporaryDirectory(prefix='lumaroute-sdk27-') as directory:
            root = Path(directory)
            source = root / 'main.swift'
            source.write_text('print("sdk27-regression")\n')
            for arch in ['arm64', 'x86_64']:
                with self.subTest(arch=arch):
                    binary = root / arch
                    obj = root / (arch+'.o')
                    common = ['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors',
                              '-sdk', sdk, '-target', arch+'-apple-macosx14.0']
                    subprocess.run(common+['-c', str(source), '-o', str(obj)],
                                   env=environment, capture_output=True, check=True, timeout=60)
                    subprocess.run(common+[str(obj), '-o', str(binary)],
                                   env=environment, capture_output=True, check=True, timeout=60)
                    verifier.verify(obj)
                    verifier.verify(binary)
                    bad_sdk = root / (arch+'-wrong-sdk')
                    bad_sdk.write_bytes(binary.read_bytes())
                    self.patch_build_version(bad_sdk, 16, (26 << 16) | (5 << 8))
                    with self.assertRaisesRegex(ValueError, 'expected SDK 27.2'):
                        verifier.verify(bad_sdk)
                    bad_minimum = root / (arch+'-wrong-minimum')
                    bad_minimum.write_bytes(binary.read_bytes())
                    self.patch_build_version(bad_minimum, 12, 15 << 16)
                    with self.assertRaisesRegex(ValueError, 'minimum macOS 14.0'):
                        verifier.verify(bad_minimum)


if __name__ == '__main__':
    unittest.main()
