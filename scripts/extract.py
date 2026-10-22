#!/usr/bin/env python3
# Extracts all Google Takeout zip parts into one destination folder.
#
# Why not plain `unzip`? Google Photos album names are often full of
# emoji and other special characters. On macOS, generic unzip can
# mis-handle those names against HFS+/APFS's Unicode *normalization*
# (the filesystem silently rewrites how multi-byte characters are
# composed) -- folders can come out mangled, or later tools fail to
# find them by the name they appear to have. Apple's own `ditto` is
# normalization-aware and avoids this, so this script shells out to it
# on macOS. Linux filesystems don't impose that normalization, so a
# straight Python zipfile extraction is reliable there.
#
# Usage:
#   python3 extract.py                              # looks for takeout-*.zip in cwd
#   python3 extract.py --glob "/path/to/takeout-*.zip" --out extracted

import argparse
import glob
import os
import platform
import subprocess
import sys
import zipfile


def extract_macos(path, out_dir):
    # ditto -x -k: extract (-x) a PKZip archive (-k) -- Apple's native,
    # normalization-aware extractor.
    subprocess.run(["ditto", "-x", "-k", path, out_dir], check=True)


def extract_generic(path, out_dir):
    with zipfile.ZipFile(path) as zf:
        for name in zf.namelist():
            zf.extract(name, out_dir)


def main():
    parser = argparse.ArgumentParser(description="Extract Google Takeout zip parts with correct special-character filename handling.")
    parser.add_argument("--glob", default="takeout-*.zip", help="Glob pattern matching the downloaded zip parts (default: takeout-*.zip in cwd)")
    parser.add_argument("--out", default="extracted", help="Destination folder (default: ./extracted)")
    args = parser.parse_args()

    parts = sorted(glob.glob(args.glob))
    if not parts:
        print(f"No zip files matched: {args.glob}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(args.out, exist_ok=True)
    is_macos = platform.system() == "Darwin"
    method = "ditto (native, normalization-aware)" if is_macos else "python zipfile"
    print(f"Found {len(parts)} zip part(s). Extracting into {args.out}/ via {method} ...")

    for i, path in enumerate(parts, start=1):
        print(f"  [{i}/{len(parts)}] {os.path.basename(path)}")
        if is_macos:
            extract_macos(path, args.out)
        else:
            extract_generic(path, args.out)

    print("Done.")


if __name__ == "__main__":
    main()
