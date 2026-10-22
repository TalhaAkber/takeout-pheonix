# 🔥📸 Takeout Phoenix

Revive a Google Takeout photo export's lost metadata (dates, GPS, captions),
then relay it back into Google Photos in storage-sized batches via an
Android phone over USB — resumable at every step.

## What it does

1. **Restores metadata** Google Takeout strips into sidecar `.json` files
   back into the actual photo/video (EXIF date, GPS, description) using
   `exiftool`.
2. **Splits the library into batches** sized to fit your phone's free
   storage, so you can upload a 500GB+ library through a phone with only
   ~35GB free.
3. **Pushes each batch over `adb`** straight from the source folder (no
   duplicate copy taking up Mac disk space), flattened into one folder so
   Google Photos' "back up device folders" actually detects everything,
   and auto-fixes an Android quirk that otherwise hides freshly-pushed
   files from every app (see [Notes](#notes)).

## Prerequisites

```bash
# macOS
brew install exiftool jq android-platform-tools

# Linux
sudo apt install libimage-exiftool-perl jq android-tools-adb
```

## Step 1 — Export from Google Takeout

1. Go to [takeout.google.com](https://takeout.google.com)
2. Deselect everything except **Google Photos**
3. Choose `.zip`, pick a file-size limit (e.g. 50GB) if your library is large
4. Download all parts, extract them into one folder, e.g. `Takeout/Google Photos`

## Step 2 — Restore metadata

```bash
./scripts/restore-metadata.sh "/path/to/Takeout/Google Photos"
```

| Arg | Required | Description |
|---|---|---|
| `[path]` | No | Path to the `Google Photos` folder. If omitted, auto-detects `./extracted/Takeout/Google Photos`, `./Takeout/Google Photos`, or `./Google Photos` relative to the script. |

Runs `exiftool` in parallel (2× CPU core count). Prints a summary of files
updated / missing media / errors when done.

## Step 3 — Build upload batches

```bash
python3 scripts/build_batches.py --size-gb 35
```

| Flag | Default | Description |
|---|---|---|
| `--root` | auto-detect | Source `Google Photos` folder to scan |
| `--size-gb` | `35` | Max batch size in GB — set a few GB under your phone's free space |
| `--out` | script's own dir | Where `batch_NNN.txt` + `manifest.csv` get written |

Re-run any time with a different `--size-gb` to rebuild — this overwrites
the batch files and manifest, so only do it before you've started pushing
(or you lose progress tracking for the old plan).

## Step 4 — One-time phone setup

1. Phone: Settings → About → tap Build number ×7 → enables Developer
   options → turn on **USB debugging**
2. Connect via USB, tap **Allow** on the authorization prompt
3. Open **Google Photos** → sign in → Settings → Backup → turn it on →
   add **Device folders** → select the upload folder (default
   `Pictures/GPhotosUpload`, created automatically by the first push)

You only need to enable that one toggle once — every batch lands in the
same flat folder.

## Step 5 — Push a batch

```bash
cd scripts   # or wherever --out pointed in step 3
./push_next.sh              # pushes whichever batch is next
./push_next.sh batch_005    # force a specific batch (retry/redo)
```

| Env var | Default | Description |
|---|---|---|
| `GPHOTOS_UPLOAD_DIR` | `/sdcard/Pictures/GPhotosUpload` | Destination folder on the phone |
| `CHUNK_SIZE` | `400` | IDs processed per on-device shell call when clearing `is_pending` |

Shows a live progress bar for both phases (push, then clearing):

```
Push      [######################------] 6820/8377 ( 81%) | 42.3/s | elapsed 2m42s | ETA 0m37s | IMG_20200613...jpg
Clear     [##########--------------------] 2800/8377 ( 33%) | 1.2/s | elapsed 38m13s | ETA 1h16m | chunk of 400 ids
```

Safe to interrupt and re-run at any point — cable disconnect, crash,
anything. It tracks:
- per-file push progress (`batch_NNN.progress`)
- per-batch completion in `manifest.csv`, only marked `done` once both the
  push **and** the pending-clear are verified complete

## Step 6 — Free space & repeat

Once Google Photos shows the batch fully backed up on the phone, use
**Google Photos → Free up space**, then run `./push_next.sh` again for
the next batch.

## Notes

- **Why flatten?** Google Photos' "back up device folders" picker treats
  every subfolder as a separately-toggled bucket. One flat folder means
  you only ever flip that switch once. The original album path is still
  baked into each filename (`__`-separated) so nothing is lost.
- **Why is clearing `is_pending` slow?** `adb push` writes files as the
  `shell` user, which Android's MediaProvider marks `is_pending=1` —
  invisible to every other app, including Google Photos, until cleared.
  Each clear call forks a process on the phone itself; that's the real
  bottleneck, not the USB transfer. No root access needed, just patience.
- **Resumability** is the whole point: everything here is designed to be
  re-run blindly after any interruption without duplicating work or
  silently skipping a stuck batch.
