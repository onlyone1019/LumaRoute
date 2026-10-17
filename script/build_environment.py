"""Use the same SDK and developer directory as the shell build entry point."""
from pathlib import Path
import os
import subprocess


def configure(sdk=None):
    environment = os.environ.copy()
    if sdk is not None:
        environment['LUMAROUTE_SDK'] = str(sdk)
    script = Path(__file__).with_suffix('.sh')
    result = subprocess.run(
        ['/bin/bash', '-euo', 'pipefail', '-c',
         'source "$1"\nprintf "%s\\0%s\\0" "$DEVELOPER_DIR" "$SDKROOT"',
         'lumaroute-build-environment', str(script)],
        env=environment, capture_output=True, text=True, check=True)
    developer, selected_sdk, _ = result.stdout.split('\0')
    os.environ.update(DEVELOPER_DIR=developer, SDKROOT=selected_sdk)
    return selected_sdk
