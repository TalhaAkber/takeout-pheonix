# 🔥📸 Takeout Phoenix

Restore a Google Takeout photo export's metadata, then relay it into
Google Photos in phone-storage-sized batches over USB. Resumable at every
step. Works on macOS, Linux and Windows.

## What it does

1. **Extracts the Takeout zip parts** using the right tool per OS — plain
   `unzip`/Finder can mangle emoji-heavy album names against macOS's
   filesystem-level Unicode normalization.
2. **Restores metadata** Google Takeout strips into sidecar `.json` files
   back into the actual photo/video (EXIF date, GPS, description) using
   `exiftool`.
3. **Splits the library into batches** sized to fit your phone's free
   storage, so you can upload a 500GB+ library through a phone with only
   ~35GB free.
4. **Pushes each batch over `adb`** straight from the source folder (no
   duplicate copy taking up Mac disk space), flattened into one folder so
   Google Photos' "back up device folders" actually detects everything,
   and auto-fixes an Android quirk that otherwise hides freshly-pushed
   files from every app (see [Notes](#notes)).

## Install

```bash
brew install exiftool jq android-platform-tools          # macOS
sudo apt install libimage-exiftool-perl jq android-tools-adb   # Linux
```

Windows: `setup-windows.ps1` installs everything -- see
[Quickstart (Windows)](#quickstart-windows).

## Quickstart (macOS / Linux)

Assumes the Takeout `.zip` parts live in `~/Pictures`.

```bash
cd ~/Pictures

# 0. Get the scripts
git clone https://github.com/TalhaAkber/takeout-pheonix.git

# 1. Download from takeout.google.com (select only Google Photos, .zip)
#    into this folder: takeout-...-001.zip, -002.zip, ...

# 2. Extract (handles special characters in album names)
python3 takeout-pheonix/scripts/extract.py
# macOS manual equivalent: for f in takeout-*.zip; do ditto -x -k "$f" extracted; done

# 3. Restore EXIF date / GPS / caption from the sidecar .json files
takeout-pheonix/scripts/restore-metadata.sh

# 4. Split into batches sized for your phone's free space
python3 takeout-pheonix/scripts/build_batches.py --size-gb 35

# 5. One-time on phone: enable USB debugging, connect, authorize;
#    in Google Photos, sign in -> Settings -> Backup -> on -> add
#    device folder "Pictures/GPhotosUpload"

# 6. Push a batch
takeout-pheonix/scripts/push_next.sh
# -> wait for Google Photos to back it up, then on the phone:
#    Google Photos -> Free up space
# -> repeat until manifest.csv shows every batch "done"
takeout-pheonix/scripts/push_next.sh
```

## Quickstart (Windows)

In **PowerShell** (not cmd). Assumes the Takeout `.zip` parts live in
`C:\Photos` -- a short folder outside OneDrive (`Pictures` is often synced
by OneDrive, and short paths stay clear of Windows' 260-character limit).

```powershell
mkdir C:\Photos; cd C:\Photos

# 0. Get the scripts (no git? winget install --id Git.Git -e, then reopen
#    PowerShell -- or download the ZIP from GitHub and extract it here)
git clone https://github.com/TalhaAkber/takeout-pheonix.git

# One-time setup: installs Python, ExifTool and adb, enables long paths
# (one UAC prompt), allows local scripts. Then open a NEW PowerShell window.
powershell -ExecutionPolicy Bypass -File .\takeout-pheonix\scripts\setup-windows.ps1
cd C:\Photos

# 1. Download from takeout.google.com (select only Google Photos, .zip)
#    into this folder: takeout-...-001.zip, -002.zip, ...

# 2. Extract (handles special characters and long paths)
py takeout-pheonix\scripts\extract.py

# 3. Restore EXIF date / GPS / caption from the sidecar .json files
py takeout-pheonix\scripts\restore_metadata.py

# 4. Split into batches sized for your phone's free space
py takeout-pheonix\scripts\build_batches.py --size-gb 35

# 5. One-time on phone: same as macOS. If `adb devices` lists nothing,
#    install your phone's USB driver (Pixel: Google USB Driver), replug.

# 6. Push a batch
.\takeout-pheonix\scripts\push_next.ps1
# -> wait for Google Photos to back it up, then on the phone:
#    Google Photos -> Free up space
# -> repeat until manifest.csv shows every batch "done"
.\takeout-pheonix\scripts\push_next.ps1
```

## Options

**Setup (Windows)**
```
setup-windows.ps1 [-SkipInstall]

  -SkipInstall     only configure long paths / script policy, install nothing
```

**Step 2**
```
extract.py [--glob PATTERN] [--out DIR]

  --glob PATTERN   zip files to extract        (default: takeout-*.zip)
  --out DIR        destination folder          (default: extracted)
```

**Step 3** -- `restore-metadata.sh` (macOS / Linux) or `restore_metadata.py`
(any OS, required on Windows; also faster)
```
restore-metadata.sh [path]

  path             Google Photos folder        (default: auto-detect)

restore_metadata.py [path] [--jobs N] [--exiftool PATH] [--errors-file FILE]

  path             Google Photos folder        (default: auto-detect)
  --jobs N         parallel exiftool workers   (default: CPU count)
  --exiftool PATH  exiftool to use             (default: PATH / standard install)
  --errors-file F  failed files listed here    (default: restore-metadata-errors.txt)
```

**Step 4**
```
build_batches.py [--root DIR] [--size-gb N] [--out DIR]

  --root DIR       folder to scan              (default: auto-detect)
  --size-gb N      max batch size in GB        (default: 35)
  --out DIR        where batch files are written (default: script dir)
```

**Step 6** -- `push_next.sh` (macOS / Linux) or `push_next.ps1` (Windows), same options
```
push_next.sh [batch_name]

  batch_name       force a specific batch      (default: next pending)

  env GPHOTOS_UPLOAD_DIR   phone destination folder  (default: /sdcard/Pictures/GPhotosUpload)
```

Failed files are listed by name at the end of each run and saved to
`batch_NNN.push_failed` / `batch_NNN.still_pending` (extract and restore
failures: `extract-errors.txt` / `restore-metadata-errors.txt`).

## Notes

- Uploads land flat in one phone folder (Google Photos treats subfolders as separate backup toggles); original album path stays in the filename via `__`.
- `adb push` leaves files invisible to Google Photos until unpended -- `push_next` clears that automatically after each push (slow but automatic).
- Safe to interrupt/re-run anything, any time.
- Windows: admin rights are only needed once, for the long-path setting (`setup-windows.ps1` asks via UAC); everything else runs as your normal user.
- Windows: exiftool can't open file names with most emoji or very long paths, so `restore_metadata.py` briefly moves those files to a short staging folder next to the photos and back. It's journaled -- an interrupted run is repaired on the next run.
