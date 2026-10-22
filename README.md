# 🔥📸 Takeout Phoenix

Restore a Google Takeout photo export's metadata, then relay it into
Google Photos in phone-storage-sized batches over USB. Resumable at every
step.

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

## Quickstart

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

## Options

**Step 2**
```
extract.py [--glob PATTERN] [--out DIR]

  --glob PATTERN   zip files to extract        (default: takeout-*.zip)
  --out DIR        destination folder          (default: extracted)
```

**Step 3**
```
restore-metadata.sh [path]

  path             Google Photos folder        (default: auto-detect)
```

**Step 4**
```
build_batches.py [--root DIR] [--size-gb N] [--out DIR]

  --root DIR       folder to scan              (default: auto-detect)
  --size-gb N      max batch size in GB        (default: 35)
  --out DIR        where batch files are written (default: script dir)
```

**Step 6**
```
push_next.sh [batch_name]

  batch_name       force a specific batch      (default: next pending)

  env GPHOTOS_UPLOAD_DIR   phone destination folder  (default: /sdcard/Pictures/GPhotosUpload)
  env CHUNK_SIZE           ids cleared per call       (default: 400)
```

## Notes

- Uploads land flat in one phone folder (Google Photos treats subfolders as separate backup toggles); original album path stays in the filename via `__`.
- `adb push` leaves files invisible to Google Photos until unpended -- `push_next.sh` clears that automatically after each push (slow but automatic).
- Safe to interrupt/re-run anything, any time.
