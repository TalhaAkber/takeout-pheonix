#!/usr/bin/env python3
# Scans a Google Takeout "Google Photos" folder and splits all media files
# into batches no larger than --size-gb each, for pushing to a phone over adb.
# Writes batch_NNN.txt (file lists) + manifest.csv into --out.
#
# Usage:
#   python3 build_batches.py                        # auto-detect root, default 35 GB batches
#   python3 build_batches.py --size-gb 25            # custom batch size
#   python3 build_batches.py --root "/path/to/Takeout/Google Photos"
#   python3 build_batches.py --out ./my-batches

import os, csv, sys, argparse

CANDIDATE_ROOTS = [
    "extracted/Takeout/Google Photos",
    "Takeout/Google Photos",
    "Google Photos",
]

MEDIA_EXTS = {
    "jpg", "jpeg", "png", "gif", "heic", "dng", "webp", "bmp", "tiff", "tif",
    "mp4", "mov", "avi", "mkv", "3gp", "m4v", "nef", "cr2", "arw",
}


def autodetect_root():
    for candidate in CANDIDATE_ROOTS:
        if os.path.isdir(candidate):
            return os.path.abspath(candidate)
    return None


def warn_if_long_paths_disabled():
    if os.name != "nt":
        return
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Control\FileSystem") as key:
            if winreg.QueryValueEx(key, "LongPathsEnabled")[0] == 1:
                return
    except OSError:
        pass
    print("WARNING: Windows long path support is off -- files deeper than 260 characters\n"
          "will be skipped. Run setup-windows.ps1 once to enable it.\n", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description="Build adb-push batches from a Google Takeout photo library.")
    parser.add_argument("--root", default=None, help="Source folder to scan (default: auto-detect ./extracted/Takeout/Google Photos, ./Takeout/Google Photos, or ./Google Photos)")
    parser.add_argument("--size-gb", type=float, default=35.0, help="Max batch size in GB (default: 35 -- match your phone's free space minus a safety margin)")
    parser.add_argument("--out", default=None, help="Output dir for batch files + manifest (default: this script's dir)")
    args = parser.parse_args()

    root = args.root or autodetect_root()
    if not root:
        print("ERROR: couldn't auto-detect a Google Photos folder. Pass --root \"/path/to/Takeout/Google Photos\".", file=sys.stderr)
        sys.exit(1)
    if not os.path.isdir(root):
        print(f"ERROR: root not found: {root}", file=sys.stderr)
        sys.exit(1)
    # Absolute, so push_next works no matter which folder it's run from.
    root = os.path.abspath(root)
    warn_if_long_paths_disabled()

    out_dir = args.out or os.path.dirname(os.path.abspath(__file__))
    batch_size = int(args.size_gb * 1024 * 1024 * 1024)

    os.makedirs(out_dir, exist_ok=True)

    files = []
    unreadable = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for fn in sorted(filenames):
            ext = fn.rsplit(".", 1)[-1].lower() if "." in fn else ""
            if ext in MEDIA_EXTS:
                full = os.path.join(dirpath, fn)
                try:
                    size = os.path.getsize(full)
                except OSError:
                    unreadable.append(full)
                    continue
                # Always "/"-separated, so batch files read the same on every OS.
                rel = os.path.relpath(full, root).replace(os.sep, "/")
                files.append((rel, size))

    total_size = sum(s for _, s in files)
    print(f"Root: {root}", file=sys.stderr)
    print(f"Total media files: {len(files)}", file=sys.stderr)
    print(f"Total size: {total_size / (1024**3):.1f} GB", file=sys.stderr)
    print(f"Batch size: {args.size_gb} GB", file=sys.stderr)
    if unreadable:
        print(f"WARNING: skipped {len(unreadable)} unreadable file(s), e.g.:", file=sys.stderr)
        for path in unreadable[:10]:
            print(f"  - {path}", file=sys.stderr)

    batches = []
    current = []
    current_size = 0
    for rel, size in files:
        if current and current_size + size > batch_size:
            batches.append(current)
            current = []
            current_size = 0
        current.append((rel, size))
        current_size += size
    if current:
        batches.append(current)

    print(f"Batches created: {len(batches)}", file=sys.stderr)

    manifest_rows = []
    for i, batch in enumerate(batches, start=1):
        batch_name = f"batch_{i:03d}"
        batch_file = os.path.join(out_dir, f"{batch_name}.txt")
        # Explicit UTF-8: Windows' default (cp1252) can't encode emoji album names.
        with open(batch_file, "w", encoding="utf-8", newline="\n") as f:
            for rel, size in batch:
                f.write(rel + "\n")
        size_gb = sum(s for _, s in batch) / (1024**3)
        manifest_rows.append({
            "batch": batch_name,
            "file_count": len(batch),
            "size_gb": f"{size_gb:.2f}",
            "status": "pending",
        })
        print(f"  {batch_name}: {len(batch)} files, {size_gb:.2f} GB", file=sys.stderr)

    manifest_path = os.path.join(out_dir, "manifest.csv")
    with open(manifest_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=["batch", "file_count", "size_gb", "status"], lineterminator="\n")
        writer.writeheader()
        writer.writerows(manifest_rows)

    with open(os.path.join(out_dir, "ROOT.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write(root + "\n")

    print(f"\nWrote manifest to {manifest_path}", file=sys.stderr)
    print(f"Batch file lists in {out_dir}/batch_NNN.txt", file=sys.stderr)


if __name__ == "__main__":
    main()
