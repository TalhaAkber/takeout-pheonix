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
# on macOS. Linux and Windows filesystems don't impose that
# normalization, so a straight Python zipfile extraction is reliable
# there (on Windows via \\?\ paths, so deep folders don't hit the
# 260-character limit).
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
import time
import zipfile

IS_WINDOWS = os.name == "nt"


def warn_if_long_paths_disabled():
    if not IS_WINDOWS:
        return
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Control\FileSystem") as key:
            if winreg.QueryValueEx(key, "LongPathsEnabled")[0] == 1:
                return
    except OSError:
        pass
    print("WARNING: Windows long path support is off -- later steps will fail on files deeper\n"
          "than 260 characters. Run setup-windows.ps1 once to enable it.\n", file=sys.stderr)


def extended_path(path):
    """On Windows, an absolute \\\\?\\ path, which isn't limited to 260 chars."""
    path = os.path.abspath(path)
    if not IS_WINDOWS or path.startswith("\\\\?\\"):
        return path
    if path.startswith("\\\\"):
        return "\\\\?\\UNC\\" + path[2:]
    return "\\\\?\\" + path


def fmt_size(n):
    return f"{n / 1024**3:.1f} GB" if n >= 1024**3 else f"{n / 1024**2:.0f} MB"


def fix_name_encoding(info):
    """Entries without the zip UTF-8 flag are decoded as cp437 (DOS), which
    garbles emoji names; re-decode them as UTF-8 when the bytes are valid."""
    if info.flag_bits & 0x800:
        return
    try:
        info.filename = info.orig_filename.encode("cp437").decode("utf-8")
    except UnicodeError:
        pass


def fmt_duration(seconds):
    seconds = int(seconds)
    return f"{seconds // 60}m{seconds % 60:02d}s"


def print_progress(done, total, start, label):
    width = 30
    pct = done * 100 // total if total else 100
    filled = width * pct // 100
    elapsed = time.time() - start
    rate = done / elapsed if elapsed > 0 else 0
    eta = fmt_duration((total - done) / rate) if rate > 0 else "--"
    sys.stdout.write(f"\rExtract   [{'#' * filled}{' ' * (width - filled)}] {fmt_size(done)}/{fmt_size(total)} ({pct:3d}%)"
                     f" | elapsed {fmt_duration(elapsed)} | ETA {eta} | {label}   ")
    sys.stdout.flush()


def extract_macos(path, out_dir):
    # ditto -x -k: extract (-x) a PKZip archive (-k) -- Apple's native,
    # normalization-aware extractor.
    subprocess.run(["ditto", "-x", "-k", path, out_dir], check=True)


def extract_generic(parts, out_dir, errors):
    totals = []
    for path in parts:
        with zipfile.ZipFile(path) as zf:
            totals.append(sum(i.file_size for i in zf.infolist()))
    total, done, start, last = sum(totals), 0, time.time(), 0.0
    target = extended_path(out_dir)
    for n, path in enumerate(parts, start=1):
        label = f"part {n}/{len(parts)}"
        with zipfile.ZipFile(path) as zf:
            for info in zf.infolist():
                fix_name_encoding(info)
                try:
                    zf.extract(info, target)
                except Exception as e:  # keep going; report every failed entry at the end
                    errors.append((os.path.basename(path), info.filename, f"{type(e).__name__}: {e}"))
                done += info.file_size
                if time.time() - last > 0.25:
                    print_progress(done, total, start, label)
                    last = time.time()
    print_progress(done, total, start, "done")
    print()


def main():
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="replace")
        except AttributeError:
            pass

    parser = argparse.ArgumentParser(description="Extract Google Takeout zip parts with correct special-character filename handling.")
    parser.add_argument("--glob", default="takeout-*.zip", help="Glob pattern matching the downloaded zip parts (default: takeout-*.zip in cwd)")
    parser.add_argument("--out", default="extracted", help="Destination folder (default: ./extracted)")
    args = parser.parse_args()

    parts = sorted(glob.glob(args.glob))
    if not parts:
        print(f"No zip files matched: {args.glob}", file=sys.stderr)
        sys.exit(1)

    warn_if_long_paths_disabled()
    os.makedirs(args.out, exist_ok=True)
    is_macos = platform.system() == "Darwin"
    method = "ditto (native, normalization-aware)" if is_macos else "python zipfile"
    print(f"Found {len(parts)} zip part(s). Extracting into {args.out}/ via {method} ...")

    errors = []
    if is_macos:
        for i, path in enumerate(parts, start=1):
            print(f"  [{i}/{len(parts)}] {os.path.basename(path)}")
            extract_macos(path, args.out)
    else:
        extract_generic(parts, args.out, errors)

    if errors:
        with open("extract-errors.txt", "w", encoding="utf-8", newline="\n") as f:
            for part, member, message in errors:
                f.write(f"{part}\t{member}\t{message}\n")
        print(f"\n{len(errors)} file(s) failed to extract:")
        for part, member, message in errors[:20]:
            print(f"  - {member} ({part}): {message}")
        if len(errors) > 20:
            print(f"  ... and {len(errors) - 20} more")
        print(f"Full list: {os.path.abspath('extract-errors.txt')}")
        sys.exit(1)
    print("Done.")


if __name__ == "__main__":
    main()
