"""Generate one signed, architecture-specific Sparkle feed for a stable Release.

The private key stays in the login Keychain (account app.lumaroute.desktop), or
is read by sign_update from LUMAROUTE_SPARKLE_KEY_FILE. Never prints private keys.
"""
from pathlib import Path
import argparse
import base64
import datetime
import os
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)


def generate(app, archive, tag, output, tools):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'[1-9]\d*', build):
        raise ValueError('Invalid application version')
    if tag not in (f'v{version}', f'v{version}-build.{build}'):
        raise ValueError('Tag does not match the application version')
    match = re.fullmatch(rf'LumaRoute-{re.escape(version)}-build\.{build}-macos-(arm64|x86_64)\.zip', archive.name)
    if not match:
        raise ValueError('Archive name does not match the application version and architecture')
    arch = match[1]
    feed_name = f'appcast-{arch}.xml'
    if not info['SUFeedURL'].endswith('/' + feed_name):
        raise ValueError('Feed architecture does not match the application')
    key = info['SUPublicEDKey']
    if len(base64.b64decode(key, validate=True)) != 32:
        raise ValueError('Invalid public key')
    signer = [str(tools / 'sign_update')]
    key_file = os.environ.get('LUMAROUTE_SPARKLE_KEY_FILE')
    signer += ['--ed-key-file', key_file] if key_file else ['--account', 'app.lumaroute.desktop']
    signature = subprocess.check_output(signer + ['-p', str(archive)], text=True).strip()
    # Prevent generating a release that current clients cannot authenticate.
    subprocess.run(['xcrun', 'swift', str(ROOT / 'script/verify_sparkle_signature.swift'),
                    str(archive), key, signature], check=True)
    rss = ET.Element('rss', version='2.0')
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = 'LumaRoute'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'LumaRoute {version} · Build {build}'
    ET.SubElement(item, 'pubDate').text = datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000')
    ET.SubElement(item, f'{{{SPARKLE}}}version').text = build
    ET.SubElement(item, f'{{{SPARKLE}}}shortVersionString').text = version
    ET.SubElement(item, f'{{{SPARKLE}}}minimumSystemVersion').text = info['LSMinimumSystemVersion']
    ET.SubElement(item, 'link').text = f'https://github.com/onlyone1019/LumaRoute/releases/tag/{tag}'
    ET.SubElement(item, 'description').text = '下载完成后点击“安装并重新启动”。更新会保留配置；如需同步后台服务，请在 macOS 授权窗口中确认。'
    ET.SubElement(item, 'enclosure', {
        'url': f'https://github.com/onlyone1019/LumaRoute/releases/download/{tag}/{archive.name}',
        'length': str(archive.stat().st_size), 'type': 'application/octet-stream',
        f'{{{SPARKLE}}}edSignature': signature,
    })
    output.mkdir(parents=True, exist_ok=True)
    destination = output / feed_name
    temporary = output / (feed_name + '.tmp.xml')
    ET.ElementTree(rss).write(temporary, encoding='utf-8', xml_declaration=True)
    subprocess.run(signer + [str(temporary)], check=True, capture_output=True)
    temporary.replace(destination)
    print(f'Signed update feed: {destination}')
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--tools', type=Path, default=ROOT / '.build/artifacts/sparkle/Sparkle/bin')
    args = parser.parse_args()
    generate(args.app.resolve(), args.archive.resolve(), args.tag, args.output.resolve(), args.tools.resolve())
