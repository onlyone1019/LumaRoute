"""Reject SDK/deployment-target mismatches in locally built Swift executables."""
from pathlib import Path
import re
import subprocess
import sys


def version(text):
    values = tuple(int(value) for value in text.split('.'))
    return values + (0,) * (3 - len(values))


def verify(path):
    output = subprocess.check_output(['/usr/bin/otool', '-l', str(path)], text=True)
    blocks = output.split('cmd LC_BUILD_VERSION')[1:]
    if not blocks:
        raise ValueError(f'{path}: missing LC_BUILD_VERSION')
    for block in blocks:
        block = block.split('Load command', 1)[0]
        sdk = re.search(r'\bsdk\s+(\S+)', block)
        minimum = re.search(r'\bminos\s+(\S+)', block)
        if not sdk or not minimum or version(sdk[1]) not in ((27, 0, 0), (27, 2, 0)) or version(minimum[1]) != (14, 0, 0):
            raise ValueError(f'{path}: expected SDK 27.0 or 27.2 / minimum macOS 14.0; found {block.strip()}')
    print(f'PASS SDK {sdk[1]} / minimum macOS 14.0: {Path(path).name}')


if __name__ == '__main__':
    for argument in sys.argv[1:]:
        verify(argument)
