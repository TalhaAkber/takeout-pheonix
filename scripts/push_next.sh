#!/bin/bash
# Resumable adb-push of the next pending batch to the phone.
# Safe to re-run any time: skips files already pushed successfully,
# skips whole batches already marked "done" in manifest.csv, and
# re-verifies pending state before marking a batch done.
#
# Usage:
#   ./push_next.sh            # push whichever batch comes next
#   ./push_next.sh batch_005  # force a specific batch (e.g. to retry/redo)
#
# Env overrides:
#   GPHOTOS_UPLOAD_DIR   Destination folder on the phone (default: /sdcard/Pictures/GPhotosUpload)
#   CHUNK_SIZE           How many MediaStore rows to unpend per on-device call (default: 400)

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=$(cat "$DIR/ROOT.txt")
MANIFEST="$DIR/manifest.csv"
DEST="${GPHOTOS_UPLOAD_DIR:-/sdcard/Pictures/GPhotosUpload}"
CHUNK_SIZE="${CHUNK_SIZE:-400}"

# ---- progress bar helper -----------------------------------------------
# print_progress <current> <total> <label> <start_epoch> <detail>
# Draws a single self-overwriting line: a bar, count, %, rate, elapsed, ETA.
print_progress() {
    local current=$1 total=$2 label=$3 start=$4 detail="${5:-}"
    local width=30
    (( total <= 0 )) && total=1
    local percent=$(( current * 100 / total ))
    (( percent > 100 )) && percent=100
    local filled=$(( width * percent / 100 ))
    local empty=$(( width - filled ))
    local bar
    bar=$(printf '%*s' "$filled" '' | tr ' ' '#')
    bar+=$(printf '%*s' "$empty" '')

    local now elapsed rate_str eta_str
    now=$(date +%s)
    elapsed=$(( now - start ))
    rate_str="--"
    eta_str="--"
    if [ "$elapsed" -gt 0 ] && [ "$current" -gt 0 ]; then
        local rate_per_sec=$(( current * 10 / elapsed ))   # x10 for one decimal
        rate_str=$(printf '%d.%d' $((rate_per_sec / 10)) $((rate_per_sec % 10)))
        local remaining=$(( total - current ))
        if [ "$current" -gt 0 ]; then
            local eta_sec=$(( remaining * elapsed / current ))
            eta_str=$(printf '%dm%02ds' $((eta_sec / 60)) $((eta_sec % 60)))
        fi
    fi
    local elapsed_str
    elapsed_str=$(printf '%dm%02ds' $((elapsed / 60)) $((elapsed % 60)))

    # truncate detail so the line doesn't wrap
    local maxdet=36
    if [ -n "$detail" ] && [ "${#detail}" -gt "$maxdet" ]; then
        detail="...${detail: -$((maxdet - 3))}"
    fi

    printf "\r%-9s [%s] %d/%d (%3d%%) | %s/s | elapsed %s | ETA %s | %s%-${maxdet}s" \
        "$label" "$bar" "$current" "$total" "$percent" "$rate_str" "$elapsed_str" "$eta_str" "" "$detail"
}
# -------------------------------------------------------------------------

if ! command -v adb &> /dev/null; then
    echo "ERROR: adb not found. Install with: brew install android-platform-tools"
    exit 1
fi

if ! adb get-state &> /dev/null; then
    echo "ERROR: no phone detected over adb. Check USB cable / USB debugging authorization."
    exit 1
fi

# Pick batch: arg, or first non-done one in manifest
BATCH="${1:-}"
if [ -z "$BATCH" ]; then
    BATCH=$(awk -F, 'NR>1 && $4!="done" {print $1; exit}' "$MANIFEST")
fi

if [ -z "$BATCH" ]; then
    echo "All batches are marked done in manifest.csv. Nothing to push."
    exit 0
fi

BATCH_FILE="$DIR/$BATCH.txt"
PROGRESS_FILE="$DIR/$BATCH.progress"

if [ ! -f "$BATCH_FILE" ]; then
    echo "ERROR: $BATCH_FILE not found."
    exit 1
fi

touch "$PROGRESS_FILE"

TOTAL=$(wc -l < "$BATCH_FILE" | tr -d ' ')
ALREADY=$(wc -l < "$PROGRESS_FILE" | tr -d ' ')
echo "=== $BATCH: $ALREADY/$TOTAL files already pushed, resuming ==="
echo "Destination on phone: $DEST"

pushed_this_run=0
failed=0
push_start=$(date +%s)
done_count=$ALREADY

while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    # Skip if already recorded as pushed
    if grep -qxF "$rel" "$PROGRESS_FILE" 2>/dev/null; then
        continue
    fi

    src="$ROOT/$rel"
    # Flatten: Google Photos' "back up device folders" doesn't recurse into
    # subfolders, so drop everything directly into $DEST with the original
    # path baked into the filename (keeps names unique, keeps origin visible).
    flat="${rel//\//__}"
    dst="$DEST/$flat"

    if [ ! -f "$src" ]; then
        printf "\n  MISSING SOURCE, skipping: %s\n" "$rel"
        continue
    fi

    if adb push "$src" "$dst" > /dev/null 2>&1; then
        echo "$rel" >> "$PROGRESS_FILE"
        pushed_this_run=$((pushed_this_run + 1))
        done_count=$((done_count + 1))
        print_progress "$done_count" "$TOTAL" "Push" "$push_start" "$(basename "$rel")"
    else
        printf "\n  FAILED (will retry next run): %s\n" "$rel"
        failed=$((failed + 1))
    fi
done < "$BATCH_FILE"
echo ""

# adb push leaves files marked is_pending=1 in MediaStore (writes via the
# shell's identity never get finalized), which hides them from every app,
# including Google Photos' backup scanner. Clear the flag on everything
# under $DEST so newly pushed files actually get picked up.
# Note: MediaStore's _data column holds the resolved real path
# (/storage/emulated/0/...), not the /sdcard/... symlink, so match on the
# folder name rather than the literal $DEST prefix.
DEST_NAME="$(basename "$DEST")"
pending_ids=$(adb shell "content query --uri content://media/external/file --projection _id --where \"_data LIKE '%$DEST_NAME/%' AND is_pending=1\"" < /dev/null 2>/dev/null | sed -E 's/Row: [0-9]+ _id=//')
if [ -n "$pending_ids" ]; then
    unpend_count=$(echo "$pending_ids" | grep -c .)
    echo "Clearing is_pending on $unpend_count file(s) so Google Photos can see them (on-device, chunked)..."
    clear_start=$(date +%s)
    cleared_so_far=0
    # Run the updates in one on-device shell loop per chunk instead of one
    # adb round-trip per file -- thousands of individual round-trips is far
    # too slow for a 5-10k file batch. Each content-update call still forks
    # a process on the device, so this is inherently slower than the push
    # itself; it's just the least-slow option without root access.
    echo "$pending_ids" | xargs -n "$CHUNK_SIZE" | while IFS= read -r chunk; do
        remote_cmd=""
        chunk_n=0
        for id in $chunk; do
            remote_cmd+="content update --uri content://media/external/file/$id --bind is_pending:i:0; "
            chunk_n=$((chunk_n + 1))
        done
        adb shell "$remote_cmd" < /dev/null > /dev/null 2>&1
        cleared_so_far=$((cleared_so_far + chunk_n))
        print_progress "$cleared_so_far" "$unpend_count" "Clear" "$clear_start" "chunk of $chunk_n ids"
    done
    echo ""
    echo "Cleared is_pending on $unpend_count file(s)."
fi

DONE_COUNT=$(wc -l < "$PROGRESS_FILE" | tr -d ' ')
echo ""
echo "=== $BATCH: $DONE_COUNT/$TOTAL files pushed total (this run: $pushed_this_run, failed: $failed) ==="

# Re-check live state rather than trusting that the clearing loop above ran
# to completion -- a cable drop mid-clearing must not get marked done, or
# the leftover pending files would be silently skipped forever.
still_pending=$(adb shell "content query --uri content://media/external/file --projection _id --where \"_data LIKE '%$DEST_NAME/%' AND is_pending=1\"" < /dev/null 2>/dev/null | grep -c . || true)

if [ "$DONE_COUNT" -ge "$TOTAL" ] && [ "${still_pending:-0}" -eq 0 ]; then
    # mark done in manifest
    awk -F, -v b="$BATCH" 'BEGIN{OFS=","} NR==1{print; next} {if($1==b) $4="done"; print}' "$MANIFEST" > "$MANIFEST.tmp"
    mv "$MANIFEST.tmp" "$MANIFEST"
    echo "$BATCH marked DONE in manifest.csv."
    echo "Next step: on the phone, let Google Photos finish backing this batch up,"
    echo "then use Google Photos > 'Free up space' to clear it, then run this script again."
elif [ "$DONE_COUNT" -ge "$TOTAL" ]; then
    echo "$BATCH fully pushed, but $still_pending file(s) are still marked is_pending"
    echo "(clearing was likely interrupted, e.g. a cable disconnect). NOT marking done."
    echo "Re-run './push_next.sh $BATCH' to finish clearing before moving to the next batch."
else
    echo "$BATCH not yet complete ($((TOTAL - DONE_COUNT)) remaining). Re-run this script to continue."
fi
