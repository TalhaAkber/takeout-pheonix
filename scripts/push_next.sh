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
#
# Failures are listed by filename at the end of a run, and kept in:
#   batch_NNN.push_failed    files that failed to push
#   batch_NNN.still_pending  files still hidden from Google Photos (is_pending=1)

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=$(cat "$DIR/ROOT.txt")
MANIFEST="$DIR/manifest.csv"
DEST="${GPHOTOS_UPLOAD_DIR:-/sdcard/Pictures/GPhotosUpload}"
DEST_NAME="$(basename "$DEST")"
DEVICE_IDS_FILE="/data/local/tmp/takeout_phoenix_pending_ids.txt"

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
        local eta_sec=$(( remaining * elapsed / current ))
        eta_str=$(printf '%dm%02ds' $((eta_sec / 60)) $((eta_sec % 60)))
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

# list_pending: prints "<id> <path>" for every MediaStore row under $DEST
# that is still is_pending=1. Only "Row:" lines are kept -- `content query`
# prints "No result found." when nothing matches, which must not be counted
# as a pending file.
# Note: MediaStore's _data column holds the resolved real path
# (/storage/emulated/0/...), not the /sdcard/... symlink, so match on the
# folder name rather than the literal $DEST prefix.
list_pending() {
    adb shell "content query --uri content://media/external/file --projection _id:_data --where \"_data LIKE '%$DEST_NAME/%' AND is_pending=1\"" < /dev/null 2>/dev/null \
        | tr -d '\r' \
        | sed -nE 's/^Row: [0-9]+ _id=([0-9]+), _data=(.*)$/\1 \2/p'
}

# print_file_list <file> <title>: prints basenames from a list file, capped.
print_file_list() {
    local file=$1 title=$2 max=50 n=0
    echo "$title"
    while IFS= read -r media_path; do
        n=$((n + 1))
        if [ "$n" -le "$max" ]; then
            echo "  - $(basename "$media_path")"
        fi
    done < "$file"
    if [ "$n" -gt "$max" ]; then
        echo "  ... and $((n - max)) more"
    fi
    echo "  (full list: $file)"
}

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
PUSH_FAILED_FILE="$DIR/$BATCH.push_failed"
STILL_PENDING_FILE="$DIR/$BATCH.still_pending"
PENDING_TMP="$DIR/.$BATCH.pending.tmp"

if [ ! -f "$BATCH_FILE" ]; then
    echo "ERROR: $BATCH_FILE not found."
    exit 1
fi

touch "$PROGRESS_FILE"
: > "$PUSH_FAILED_FILE"

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
        echo "$rel" >> "$PUSH_FAILED_FILE"
        continue
    fi

    if adb push "$src" "$dst" > /dev/null 2>&1; then
        echo "$rel" >> "$PROGRESS_FILE"
        pushed_this_run=$((pushed_this_run + 1))
        done_count=$((done_count + 1))
        print_progress "$done_count" "$TOTAL" "Push" "$push_start" "$(basename "$rel")"
    else
        printf "\n  FAILED (will retry next run): %s\n" "$rel"
        echo "$rel" >> "$PUSH_FAILED_FILE"
        failed=$((failed + 1))
    fi
done < "$BATCH_FILE"
echo ""

# adb push leaves files marked is_pending=1 in MediaStore (writes via the
# shell's identity never get finalized), which hides them from every app,
# including Google Photos' backup scanner. Clear the flag on everything
# under $DEST so newly pushed files actually get picked up.
list_pending > "$PENDING_TMP"
unpend_count=$(wc -l < "$PENDING_TMP" | tr -d ' ')
if [ "$unpend_count" -gt 0 ]; then
    echo "Clearing is_pending on $unpend_count file(s) so Google Photos can see them..."
    # Ship the id list to the phone and loop there: one adb session for the
    # whole batch, with the device echoing an OK/FAIL line per file so the
    # bar advances per file. Each `content update` still forks a process on
    # the phone -- that, not USB, is why this phase is slow.
    cut -d' ' -f1 "$PENDING_TMP" > "$PENDING_TMP.ids"
    adb push "$PENDING_TMP.ids" "$DEVICE_IDS_FILE" > /dev/null 2>&1
    rm -f "$PENDING_TMP.ids"

    clear_start=$(date +%s)
    cleared=0
    clear_failed=0
    while IFS= read -r line; do
        line="${line%$'\r'}"
        status="${line%% *}"
        id="${line#* }"
        media_path=$(awk -v id="$id" '$1 == id { sub(/^[^ ]+ /, ""); print; exit }' "$PENDING_TMP")
        name="$(basename "${media_path:-id $id}")"
        case "$status" in
            OK)
                cleared=$((cleared + 1)) ;;
            FAIL)
                clear_failed=$((clear_failed + 1))
                printf "\n  CLEAR FAILED: %s\n" "$name" ;;
            *)
                continue ;;
        esac
        print_progress $((cleared + clear_failed)) "$unpend_count" "Clear" "$clear_start" "$name"
    done < <(adb shell "for id in \$(cat $DEVICE_IDS_FILE); do out=\$(content update --uri content://media/external/file/\$id --bind is_pending:i:0 2>&1); if [ -z \"\$out\" ]; then echo \"OK \$id\"; else echo \"FAIL \$id\"; fi; done; rm -f $DEVICE_IDS_FILE" < /dev/null 2>/dev/null)
    echo ""
    echo "Cleared is_pending on $cleared/$unpend_count file(s) ($clear_failed failed)."
fi

DONE_COUNT=$(wc -l < "$PROGRESS_FILE" | tr -d ' ')
echo ""
echo "=== $BATCH: $DONE_COUNT/$TOTAL files pushed total (this run: $pushed_this_run, failed: $failed) ==="

# Re-check live state rather than trusting that the clearing loop above ran
# to completion -- a cable drop mid-clearing must not get marked done, or
# the leftover pending files would be silently skipped forever.
list_pending | cut -d' ' -f2- > "$STILL_PENDING_FILE"
rm -f "$PENDING_TMP"
still_pending=$(wc -l < "$STILL_PENDING_FILE" | tr -d ' ')

if [ -s "$PUSH_FAILED_FILE" ]; then
    print_file_list "$PUSH_FAILED_FILE" "Failed to push:"
else
    rm -f "$PUSH_FAILED_FILE"
fi

if [ "$still_pending" -gt 0 ]; then
    print_file_list "$STILL_PENDING_FILE" "Still hidden from Google Photos (is_pending=1):"
else
    rm -f "$STILL_PENDING_FILE"
fi

if [ "$DONE_COUNT" -ge "$TOTAL" ] && [ "$still_pending" -eq 0 ]; then
    # mark done in manifest
    awk -F, -v b="$BATCH" 'BEGIN{OFS=","} NR==1{print; next} {if($1==b) $4="done"; print}' "$MANIFEST" > "$MANIFEST.tmp"
    mv "$MANIFEST.tmp" "$MANIFEST"
    echo "$BATCH marked DONE in manifest.csv."
    echo "Next step: on the phone, let Google Photos finish backing this batch up,"
    echo "then use Google Photos > 'Free up space' to clear it, then run this script again."
elif [ "$DONE_COUNT" -ge "$TOTAL" ]; then
    echo "$BATCH fully pushed, but $still_pending file(s) above are still marked is_pending"
    echo "(clearing was likely interrupted, e.g. a cable disconnect). NOT marking done."
    echo "Re-run './push_next.sh $BATCH' to finish clearing before moving to the next batch."
else
    echo "$BATCH not yet complete ($((TOTAL - DONE_COUNT)) remaining). Re-run this script to continue."
fi
