#!/usr/bin/env python3
# Cross-platform Google Takeout metadata restorer (macOS / Linux / Windows).
#
# Same job as restore-metadata.sh -- reads each sidecar .json and writes the
# taken date, GPS and description back into the photo/video with exiftool --
# but needs no bash/jq/bc, so it also runs on Windows. Uses one long-running
# exiftool per worker (-stay_open) instead of one process per file.
#
# Windows specifics handled here:
#   - File names reach exiftool through a UTF-8 argfile with
#     "-charset filename=utf8" (exiftool's documented way to handle Unicode
#     names on Windows; plain command-line args lose emoji).
#   - exiftool still can't open names containing characters above U+FFFF
#     (most emoji) or very long paths on Windows, so those files are moved to
#     a short ASCII staging path, written there, and moved back. A journal
#     lets the next run put them back if a run is interrupted mid-file.
#
# Usage:
#   python3 restore_metadata.py                          # auto-detect the Google Photos folder
#   python3 restore_metadata.py "/path/to/Takeout/Google Photos"
#   python3 restore_metadata.py --jobs 4 --exiftool "C:\Tools\exiftool.exe"

import argparse
import json
import os
import queue
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timedelta

IS_WINDOWS = os.name == "nt"
# Testing hook: exercise the Windows staging path on any OS.
FORCE_STAGING = os.environ.get("TAKEOUT_PHOENIX_FORCE_STAGING") == "1"

CANDIDATE_ROOTS = [
    "extracted/Takeout/Google Photos",
    "Takeout/Google Photos",
    "Google Photos",
]

MEDIA_EXTS = {
    "jpg", "jpeg", "png", "gif", "heic", "dng", "webp", "bmp", "tiff", "tif",
    "mp4", "mov", "avi", "mkv", "3gp", "m4v", "nef", "cr2", "arw",
}
VIDEO_EXTS = {"mp4", "mov", "avi", "mkv", "3gp", "m4v"}

# Takeout truncates long sidecar names, e.g. "x.jpg.supplemental-metad.json"
# or "x.jpg.supp.json", so accept any prefix of the full tag.
SIDECAR_TAG = "supplemental-metadata"
SIDECAR_RE = re.compile(r"^(?P<base>.+)\.(?P<tag>[A-Za-z-]+)(?P<num>\(\d+\))?\.json$")
# Older exports: "x.jpg.json" / "x.jpg(1).json"
OLD_STYLE_RE = re.compile(r"^(?P<base>.+?)(?P<num>\(\d+\))?\.json$")

STAGING_DIRNAME = ".takeout-phoenix-staging"
STAGING_MAX_PATH = 240


def ext_of(name):
    return name.rsplit(".", 1)[-1].lower() if "." in name else ""


def media_candidates(json_name):
    """Possible media file names for a sidecar, best match first.
    Returns None if the file doesn't look like a media sidecar at all
    (e.g. an album's metadata.json)."""
    m = SIDECAR_RE.match(json_name)
    if m and SIDECAR_TAG.startswith(m.group("tag").lower()):
        base, num = m.group("base"), m.group("num") or ""
    else:
        m = OLD_STYLE_RE.match(json_name)
        if not m or ext_of(m.group("base")) not in MEDIA_EXTS:
            return None
        base, num = m.group("base"), m.group("num") or ""
    candidates = []
    if num and "." in base:
        # photo.jpg.supplemental-metadata(1).json -> photo(1).jpg
        stem, ext = base.rsplit(".", 1)
        candidates.append(f"{stem}{num}.{ext}")
    candidates.append(base)
    return candidates


def to_number(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def format_number(value):
    # The exact JSON value (like jq prints it), but never "1e-05"-style
    # notation, which exiftool doesn't read as a coordinate.
    text = repr(value)
    if "e" in text or "E" in text:
        text = f"{value:.12f}".rstrip("0").rstrip(".")
    return text


def local_exif_date(timestamp):
    """Unix timestamp -> 'YYYY:MM:DD HH:MM:SS' in this machine's local time
    (same as restore-metadata.sh's `date -r`)."""
    ts = int(timestamp)
    try:
        dt = datetime.fromtimestamp(ts)
    except (OverflowError, OSError, ValueError):
        # Windows can't convert pre-1970 timestamps to local time; offset
        # from the epoch's local time instead (ignores historic DST changes).
        dt = datetime.fromtimestamp(0) + timedelta(seconds=ts)
    return dt.strftime("%Y:%m:%d %H:%M:%S")


def build_tag_args(data, media_path):
    """exiftool tag assignments for one sidecar. Each item is (arg, is_text)
    where is_text marks free-text values that may need escaping."""
    args = []

    timestamp = (data.get("photoTakenTime") or {}).get("timestamp")
    if timestamp not in (None, "", "null"):
        try:
            exif_date = local_exif_date(timestamp)
        except (TypeError, ValueError):
            exif_date = None
        if exif_date:
            for tag in ("DateTimeOriginal", "CreateDate", "ModifyDate"):
                args.append((f"-{tag}={exif_date}", False))
            if ext_of(media_path) in VIDEO_EXTS:
                for tag in ("MediaCreateDate", "MediaModifyDate", "TrackCreateDate", "TrackModifyDate"):
                    args.append((f"-{tag}={exif_date}", False))

    geo = data.get("geoData") or {}
    lat, lon, alt = (to_number(geo.get(k)) for k in ("latitude", "longitude", "altitude"))
    # 0,0 is Takeout's "no location" placeholder -- never write it.
    if lat != 0 or lon != 0:
        args.append((f"-GPSLatitude={format_number(lat)}", False))
        args.append((f"-GPSLongitude={format_number(lon)}", False))
        args.append((f"-GPSLatitudeRef={'N' if lat >= 0 else 'S'}", False))
        args.append((f"-GPSLongitudeRef={'E' if lon >= 0 else 'W'}", False))
        if alt != 0:
            args.append((f"-GPSAltitude={format_number(alt)}", False))
            args.append((f"-GPSAltitudeRef={'0' if alt >= 0 else '1'}", False))

    description = data.get("description")
    if isinstance(description, str) and description:
        args.append((f"-ImageDescription={description}", True))
        args.append((f"-Description={description}", True))

    return args


def argfile_lines(tag_args, temp_files):
    """Encode tag assignments as exiftool argfile lines (see `exiftool -@`).
    Values with line breaks can't go on an argfile line (and "#[CSTR]"
    lines mangle "$" and "@"), so those are written to a temp file and
    passed as -TAG<=FILE, which exiftool reads verbatim."""
    lines = []
    for arg, is_text in tag_args:
        name, value = arg.split("=", 1)
        if is_text and ("\n" in value or "\r" in value):
            fd, path = tempfile.mkstemp(prefix="takeout_phoenix_", suffix=".txt")
            with os.fdopen(fd, "wb") as f:
                f.write(value.encode("utf-8"))
            temp_files.append(path)
            lines.append(f"{name}<={path}")
        elif value.startswith(" "):
            # Plain lines drop one space after "=", so pad to keep a leading space.
            lines.append(f"{name}= {value}")
        else:
            lines.append(arg)
    return lines


class ExifTool:
    """One persistent exiftool process driven through -stay_open."""

    def __init__(self, exe):
        cmd = [exe]
        if IS_WINDOWS:
            # Must come before -@ to apply to the argfile's file names.
            cmd += ["-charset", "filename=utf8"]
        cmd += ["-stay_open", "True", "-@", "-",
                "-common_args", "-overwrite_original", "-ignoreMinorErrors"]
        if IS_WINDOWS:
            cmd += ["-api", "WindowsLongPath=1"]
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT)
        self.seq = 0

    def run(self, tag_args, file_path):
        """Write tags to one file. Returns (ok, message)."""
        self.seq += 1
        marker = f"{{ready{self.seq}}}"
        temp_files = []
        try:
            lines = argfile_lines(tag_args, temp_files) + [file_path, f"-execute{self.seq}"]
            self.proc.stdin.write(("\n".join(lines) + "\n").encode("utf-8"))
            self.proc.stdin.flush()
            output = []
            while True:
                raw = self.proc.stdout.readline()
                if not raw:
                    raise RuntimeError("exiftool exited unexpectedly")
                line = raw.decode("utf-8", "replace").rstrip("\r\n")
                if line.endswith(marker):
                    before = line[:-len(marker)].strip()
                    if before:
                        output.append(before)
                    break
                output.append(line)
        finally:
            for path in temp_files:
                os.remove(path)
        ok = any(re.match(r"\s*[1-9]\d* image files (updated|unchanged)", l) for l in output)
        if ok:
            return True, ""
        problems = [l.strip() for l in output if l.strip().startswith(("Error", "Warning"))]
        return False, (problems[0] if problems else " / ".join(l.strip() for l in output if l.strip()) or "unknown error")

    def close(self):
        try:
            self.proc.stdin.write(b"-stay_open\nFalse\n")
            self.proc.stdin.flush()
            self.proc.wait(timeout=30)
        except Exception:
            self.proc.kill()


# ---- Windows staging ------------------------------------------------------

def needs_staging(path):
    if not (IS_WINDOWS or FORCE_STAGING):
        return False
    return len(path) >= STAGING_MAX_PATH or any(ord(c) > 0xFFFF for c in path)


def is_safe_dir(path):
    return len(path) < 200 and not any(ord(c) > 0xFFFF for c in path)


def pick_staging_dir(root):
    candidates = [os.path.join(os.path.dirname(os.path.abspath(root)), STAGING_DIRNAME),
                  os.path.join(tempfile.gettempdir(), STAGING_DIRNAME)]
    root_drive = os.path.splitdrive(os.path.abspath(root))[0].lower()
    for c in candidates:
        # Must be on the same drive: files are moved there, not copied.
        if is_safe_dir(c) and os.path.splitdrive(c)[0].lower() == root_drive:
            return c
    return None


def recover_staging(staging):
    """Move back any files a previous, interrupted run left in staging."""
    if not os.path.isdir(staging):
        return 0
    restored = 0
    for fn in sorted(os.listdir(staging)):
        full = os.path.join(staging, fn)
        if fn.endswith("_exiftool_tmp"):
            os.remove(full)  # exiftool's own partial output; original is intact
            continue
        if not fn.endswith(".journal"):
            continue
        with open(full, encoding="utf-8") as f:
            staged, original = f.read().split("\n")[:2]
        if os.path.exists(staged) and not os.path.exists(original):
            os.replace(staged, original)
            restored += 1
        elif os.path.exists(staged):
            print(f"WARNING: both {staged} and {original} exist -- left untouched, please check", file=sys.stderr)
            continue
        os.remove(full)
    return restored


class Stager:
    def __init__(self, staging_dir):
        self.dir = staging_dir
        self.lock = threading.Lock()
        self.counter = 0

    def stage(self, media):
        with self.lock:
            self.counter += 1
            token = f"{os.getpid()}_{self.counter}"
        os.makedirs(self.dir, exist_ok=True)
        staged = os.path.join(self.dir, f"{token}.{ext_of(media) or 'bin'}")
        journal = os.path.join(self.dir, f"{token}.journal")
        with open(journal, "w", encoding="utf-8") as f:
            f.write(f"{staged}\n{media}\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(media, staged)
        return staged, journal

    @staticmethod
    def unstage(staged, media, journal):
        os.replace(staged, media)
        os.remove(journal)


# ---- scanning ---------------------------------------------------------------

def find_jobs(root):
    """Returns (jobs, sidecar_count, no_media) where jobs are (json, media) pairs."""
    jobs, sidecars, no_media = [], 0, []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d != STAGING_DIRNAME)
        names = set(filenames)
        # APFS and NTFS are case-insensitive, so fall back to that if needed.
        names_lower = {n.lower(): n for n in filenames}
        for fn in sorted(filenames):
            if not fn.lower().endswith(".json"):
                continue
            candidates = media_candidates(fn)
            if candidates is None:
                continue
            sidecars += 1
            media = next((c for c in candidates if c in names), None)
            if media is None:
                media = next((names_lower[c.lower()] for c in candidates if c.lower() in names_lower), None)
            if media is None:
                no_media.append(os.path.join(dirpath, fn))
            else:
                jobs.append((os.path.join(dirpath, fn), os.path.abspath(os.path.join(dirpath, media))))
    return jobs, sidecars, no_media


def find_exiftool(explicit):
    if explicit:
        return explicit
    found = shutil.which("exiftool")
    if found:
        return found
    if IS_WINDOWS:
        for base, sub in ((os.environ.get("LOCALAPPDATA"), ("Programs", "ExifTool")),
                          (os.environ.get("ProgramFiles"), ("ExifTool",)),
                          (os.environ.get("ProgramFiles(x86)"), ("ExifTool",))):
            if base:
                exe = os.path.join(base, *sub, "ExifTool.exe")
                if os.path.isfile(exe):
                    return exe
    return None


def autodetect_root():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    for base in (os.getcwd(), script_dir):
        for candidate in CANDIDATE_ROOTS:
            path = os.path.join(base, candidate)
            if os.path.isdir(path):
                return path
    return None


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
    print("WARNING: Windows long path support is off -- files deeper than 260 characters\n"
          "will fail. Run setup-windows.ps1 once to enable it.\n", file=sys.stderr)


def fmt_duration(seconds):
    seconds = int(seconds)
    return f"{seconds // 60}m{seconds % 60:02d}s"


def print_progress(done, total, start, updated, errors):
    width = 30
    pct = done * 100 // total if total else 100
    filled = width * pct // 100
    elapsed = time.time() - start
    rate = done / elapsed if elapsed > 0 else 0
    eta = fmt_duration((total - done) / rate) if rate > 0 else "--"
    line = (f"\rRestore   [{'#' * filled}{' ' * (width - filled)}] {done}/{total} ({pct:3d}%)"
            f" | {rate:.1f}/s | elapsed {fmt_duration(elapsed)} | ETA {eta}"
            f" | updated {updated}, errors {errors}   ")
    sys.stdout.write(line)
    sys.stdout.flush()


def main():
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="replace")
        except AttributeError:
            pass

    parser = argparse.ArgumentParser(description="Write Google Takeout sidecar metadata (date, GPS, description) back into photos/videos.")
    parser.add_argument("path", nargs="?", help="Google Photos folder (default: auto-detect extracted/Takeout/Google Photos)")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4, help="parallel exiftool workers (default: CPU count)")
    parser.add_argument("--exiftool", help="path to exiftool (default: from PATH, or the standard Windows install folders)")
    parser.add_argument("--errors-file", default="restore-metadata-errors.txt", help="where failed files are listed (default: ./restore-metadata-errors.txt)")
    args = parser.parse_args()

    root = args.path or autodetect_root()
    if not root or not os.path.isdir(root):
        print("ERROR: Google Photos folder not found. Pass it explicitly, e.g.\n"
              "  restore_metadata.py \"/path/to/Takeout/Google Photos\"", file=sys.stderr)
        sys.exit(1)
    root = os.path.abspath(root)
    warn_if_long_paths_disabled()

    exe = find_exiftool(args.exiftool)
    if not exe:
        print("ERROR: exiftool not found.\n"
              "  macOS:   brew install exiftool\n"
              "  Linux:   sudo apt install libimage-exiftool-perl\n"
              "  Windows: run setup-windows.ps1, or winget install --id OliverBetz.ExifTool -e",
              file=sys.stderr)
        sys.exit(1)
    version = subprocess.run([exe, "-ver"], capture_output=True, text=True).stdout.strip()
    print(f"exiftool: {exe} ({version})")
    print(f"Scanning: {root}")

    stager = None
    if IS_WINDOWS or FORCE_STAGING:
        staging = pick_staging_dir(root)
        if staging is None:
            print("ERROR: no usable staging folder on the same drive as the photos (needed for\n"
                  "emoji / long file names on Windows). Move the photos to a shorter path, e.g. C:\\Photos.",
                  file=sys.stderr)
            sys.exit(1)
        restored = recover_staging(staging)
        if restored:
            print(f"Recovered {restored} file(s) left in staging by an interrupted run.")
        stager = Stager(staging)

    jobs, sidecar_count, no_media = find_jobs(root)
    print(f"Found {sidecar_count} metadata files, {len(jobs)} with a matching photo/video")
    workers = max(1, min(args.jobs, len(jobs) or 1))
    print(f"Using {workers} parallel exiftool workers\n")

    work = queue.Queue()
    for job in jobs:
        work.put(job)
    stop = threading.Event()
    lock = threading.Lock()
    stats = {"done": 0, "updated": 0, "nothing": 0}
    failures = []  # (path, message)

    def worker():
        et = ExifTool(exe)
        try:
            while not stop.is_set():
                try:
                    json_path, media = work.get_nowait()
                except queue.Empty:
                    return
                if et.proc.poll() is not None:
                    et = ExifTool(exe)  # previous file crashed exiftool; start a fresh one
                try:
                    with open(json_path, encoding="utf-8") as f:
                        tag_args = build_tag_args(json.load(f), media)
                    if not tag_args:
                        result = "nothing"
                    else:
                        target, staged = media, None
                        if stager and needs_staging(media):
                            staged, journal = stager.stage(media)
                            target = staged
                        try:
                            ok, message = et.run(tag_args, target)
                        finally:
                            if staged:
                                Stager.unstage(staged, media, journal)
                        result = "updated" if ok else message
                except Exception as e:  # bad JSON, I/O error, exiftool crash, ...
                    result = f"{type(e).__name__}: {e}"
                with lock:
                    stats["done"] += 1
                    if result in ("updated", "nothing"):
                        stats[result] += 1
                    else:
                        failures.append((media, result))
        finally:
            et.close()

    start = time.time()
    threads = [threading.Thread(target=worker) for _ in range(workers)]
    for t in threads:
        t.start()
    interrupted = False
    try:
        while any(t.is_alive() for t in threads):
            with lock:
                print_progress(stats["done"], len(jobs), start, stats["updated"], len(failures))
            time.sleep(0.25)
    except KeyboardInterrupt:
        interrupted = True
        stop.set()
        print("\nStopping after the files in progress (staged files are moved back)...")
    for t in threads:
        t.join()
    print_progress(stats["done"], len(jobs), start, stats["updated"], len(failures))
    print()

    elapsed = max(time.time() - start, 0.001)
    if failures or no_media:
        with open(args.errors_file, "w", encoding="utf-8", newline="\n") as f:
            for path, message in failures:
                f.write(f"{path}\t{message}\n")
            for path in no_media:
                f.write(f"{path}\tno matching photo/video for this metadata file\n")

    print()
    print("========================================")
    print("           SUMMARY")
    print("========================================")
    print(f"Total JSON files:          {sidecar_count}")
    print(f"Files updated:             {stats['updated']}")
    print(f"Nothing to write:          {stats['nothing']}")
    print(f"No media file:             {len(no_media)}")
    print(f"ExifTool errors:           {len(failures)}")
    print("----------------------------------------")
    print(f"Time elapsed:              {int(elapsed)}s")
    print(f"Processing rate:           {stats['done'] / elapsed:.1f} files/sec")
    print("========================================")
    if failures:
        print("\nFailed files:")
        for path, message in failures[:20]:
            print(f"  - {os.path.relpath(path, root)}: {message}")
        if len(failures) > 20:
            print(f"  ... and {len(failures) - 20} more")
    if failures or no_media:
        print(f"\nFull list: {os.path.abspath(args.errors_file)}")
    if interrupted:
        print("\nInterrupted -- re-run to finish (already-written files are simply rewritten).")
        sys.exit(130)


if __name__ == "__main__":
    main()
