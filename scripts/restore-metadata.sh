#!/bin/bash
# Google Takeout Metadata Restorer (macOS/Linux)
# Reads JSON metadata files and writes the metadata back to photos/videos using ExifTool
#
# PREREQUISITES:
#   macOS: brew install exiftool jq
#   Linux: sudo apt install libimage-exiftool-perl jq
#
# USAGE:
#   chmod +x restore-metadata.sh
#   ./restore-metadata.sh [path-to-google-photos]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

echo ""
echo -e "${CYAN}====================================${NC}"
echo -e "${CYAN} Google Takeout Metadata Restorer${NC}"
echo -e "${CYAN}====================================${NC}"
echo ""

# Check for required tools
if ! command -v exiftool &> /dev/null; then
    echo -e "${RED}ERROR: exiftool is not installed.${NC}"
    echo ""
    echo -e "${YELLOW}Please install exiftool:${NC}"
    echo -e "${CYAN}  macOS: brew install exiftool${NC}"
    echo -e "${CYAN}  Linux: sudo apt install libimage-exiftool-perl${NC}"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${RED}ERROR: jq is not installed.${NC}"
    echo ""
    echo -e "${YELLOW}Please install jq:${NC}"
    echo -e "${CYAN}  macOS: brew install jq${NC}"
    echo -e "${CYAN}  Linux: sudo apt install jq${NC}"
    exit 1
fi

echo -e "${GREEN}exiftool found: $(which exiftool)${NC}"
echo -e "${GREEN}jq found: $(which jq)${NC}"

# Determine photos path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHOTOS_PATH="$1"

if [ -z "$PHOTOS_PATH" ]; then
    # Try common paths
    if [ -d "$SCRIPT_DIR/extracted/Takeout/Google Photos" ]; then
        PHOTOS_PATH="$SCRIPT_DIR/extracted/Takeout/Google Photos"
    elif [ -d "$SCRIPT_DIR/Takeout/Google Photos" ]; then
        PHOTOS_PATH="$SCRIPT_DIR/Takeout/Google Photos"
    elif [ -d "$SCRIPT_DIR/Google Photos" ]; then
        PHOTOS_PATH="$SCRIPT_DIR/Google Photos"
    else
        echo -e "${RED}ERROR: Could not find Google Photos directory.${NC}"
        echo ""
        echo -e "${YELLOW}Please provide the path as an argument:${NC}"
        echo -e "${CYAN}  ./restore-metadata.sh \"/path/to/Takeout/Google Photos\"${NC}"
        exit 1
    fi
fi

if [ ! -d "$PHOTOS_PATH" ]; then
    echo -e "${RED}ERROR: Directory not found: $PHOTOS_PATH${NC}"
    exit 1
fi

echo ""
echo -e "${CYAN}Scanning: $PHOTOS_PATH${NC}"
echo ""

# Count JSON files
echo -e "${GRAY}Finding JSON metadata files...${NC}"
JSON_COUNT=$(find "$PHOTOS_PATH" -name "*.json" \( -name "*supplemental-metadata*.json" -o -name "*supplemental-met.json" \) 2>/dev/null | wc -l | tr -d ' ')

if [ "$JSON_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}No metadata JSON files found.${NC}"
    exit 0
fi

echo -e "${CYAN}Found $JSON_COUNT metadata files${NC}"
echo ""

# Get number of CPU cores for parallelization
if [[ "$OSTYPE" == "darwin"* ]]; then
    NUM_CORES=$(sysctl -n hw.ncpu)
else
    NUM_CORES=$(nproc)
fi
THREADS=$((NUM_CORES * 2))
echo -e "${GRAY}Using $THREADS parallel jobs${NC}"
echo ""

# Create temp directory for tracking
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Function to process a single JSON file
process_json() {
    local json_file="$1"
    local temp_dir="$2"

    local json_name=$(basename "$json_file")
    local json_dir=$(dirname "$json_file")

    # Determine media file name
    local media_file=""

    if [[ "$json_name" =~ ^(.+)\.supplemental-metadata(\([0-9]+\))?\.json$ ]]; then
        local base_name="${BASH_REMATCH[1]}"
        local suffix="${BASH_REMATCH[2]}"

        if [ -n "$suffix" ]; then
            # Handle numbered duplicates: photo.jpg.supplemental-metadata(1).json -> photo(1).jpg
            local ext="${base_name##*.}"
            local name_without_ext="${base_name%.*}"
            local media_name="${name_without_ext}${suffix}.${ext}"
            if [ -f "$json_dir/$media_name" ]; then
                media_file="$json_dir/$media_name"
            fi
        fi

        if [ -z "$media_file" ] && [ -f "$json_dir/$base_name" ]; then
            media_file="$json_dir/$base_name"
        fi
    elif [[ "$json_name" =~ ^(.+\.(jpg|jpeg|png|gif|mp4|mov|avi|mkv|heic|webp|bmp|tiff|3gp))\.supplemental-met\.json$ ]]; then
        local base_name="${BASH_REMATCH[1]}"
        if [ -f "$json_dir/$base_name" ]; then
            media_file="$json_dir/$base_name"
        fi
    elif [[ "$json_name" =~ ^(.+\.(jpg|jpeg|png|gif|mp4|mov|avi|mkv|heic|webp|bmp|tiff|3gp))\.json$ ]]; then
        local base_name="${BASH_REMATCH[1]}"
        if [ -f "$json_dir/$base_name" ]; then
            media_file="$json_dir/$base_name"
        fi
    fi

    if [ -z "$media_file" ]; then
        echo "1" >> "$temp_dir/no_media_count"
        return
    fi

    # Parse JSON and extract metadata
    local timestamp=$(jq -r '.photoTakenTime.timestamp // empty' "$json_file" 2>/dev/null)
    local lat=$(jq -r '.geoData.latitude // 0' "$json_file" 2>/dev/null)
    local lon=$(jq -r '.geoData.longitude // 0' "$json_file" 2>/dev/null)
    local alt=$(jq -r '.geoData.altitude // 0' "$json_file" 2>/dev/null)
    local description=$(jq -r '.description // empty' "$json_file" 2>/dev/null)

    # Build exiftool arguments
    local args=("-overwrite_original" "-ignoreMinorErrors")
    local has_args=false

    if [ -n "$timestamp" ] && [ "$timestamp" != "null" ]; then
        # macOS uses -r, Linux uses -d @
        local exif_date
        if [[ "$OSTYPE" == "darwin"* ]]; then
            exif_date=$(date -r "$timestamp" "+%Y:%m:%d %H:%M:%S" 2>/dev/null)
        else
            exif_date=$(date -d "@$timestamp" "+%Y:%m:%d %H:%M:%S" 2>/dev/null)
        fi

        if [ -n "$exif_date" ]; then
            args+=("-DateTimeOriginal=$exif_date")
            args+=("-CreateDate=$exif_date")
            args+=("-ModifyDate=$exif_date")
            has_args=true

            # Add video-specific dates
            local ext="${media_file##*.}"
            ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
            if [[ "$ext" =~ ^(mp4|mov|avi|mkv|3gp)$ ]]; then
                args+=("-MediaCreateDate=$exif_date")
                args+=("-MediaModifyDate=$exif_date")
                args+=("-TrackCreateDate=$exif_date")
                args+=("-TrackModifyDate=$exif_date")
            fi
        fi
    fi

    # GPS coordinates (skip if 0,0)
    if [ "$lat" != "0" ] || [ "$lon" != "0" ]; then
        args+=("-GPSLatitude=$lat")
        args+=("-GPSLongitude=$lon")

        if (( $(echo "$lat >= 0" | bc -l) )); then
            args+=("-GPSLatitudeRef=N")
        else
            args+=("-GPSLatitudeRef=S")
        fi

        if (( $(echo "$lon >= 0" | bc -l) )); then
            args+=("-GPSLongitudeRef=E")
        else
            args+=("-GPSLongitudeRef=W")
        fi

        if [ "$alt" != "0" ]; then
            args+=("-GPSAltitude=$alt")
            if (( $(echo "$alt >= 0" | bc -l) )); then
                args+=("-GPSAltitudeRef=0")
            else
                args+=("-GPSAltitudeRef=1")
            fi
        fi
        has_args=true
    fi

    # Description
    if [ -n "$description" ] && [ "$description" != "null" ] && [ "$description" != "" ]; then
        args+=("-ImageDescription=$description")
        args+=("-Description=$description")
        has_args=true
    fi

    # Skip if no meaningful args
    if [ "$has_args" = false ]; then
        return
    fi

    # Run exiftool
    if exiftool "${args[@]}" "$media_file" > /dev/null 2>&1; then
        echo "1" >> "$temp_dir/updated_count"
    else
        echo "1" >> "$temp_dir/error_count"
    fi

    echo "1" >> "$temp_dir/processed_count"
}

export -f process_json

echo -e "${CYAN}Processing files...${NC}"
echo ""

START_TIME=$(date +%s)

# Find and process all JSON files in parallel
find "$PHOTOS_PATH" -name "*.json" \( -name "*supplemental-metadata*.json" -o -name "*supplemental-met.json" \) -print0 2>/dev/null | \
    xargs -0 -P "$THREADS" -I {} bash -c 'process_json "$@"' _ {} "$TEMP_DIR"

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# Count results
UPDATED=$(cat "$TEMP_DIR"/updated_count 2>/dev/null | wc -l | tr -d ' ')
ERRORS=$(cat "$TEMP_DIR"/error_count 2>/dev/null | wc -l | tr -d ' ')
NO_MEDIA=$(cat "$TEMP_DIR"/no_media_count 2>/dev/null | wc -l | tr -d ' ')
PROCESSED=$(cat "$TEMP_DIR"/processed_count 2>/dev/null | wc -l | tr -d ' ')

# Calculate rate
if [ $ELAPSED -gt 0 ]; then
    RATE=$(echo "scale=1; $PROCESSED / $ELAPSED" | bc)
else
    RATE="N/A"
fi

# Print summary
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}           SUMMARY${NC}"
echo -e "${CYAN}========================================${NC}"
echo "Total JSON files:          $JSON_COUNT"
echo -e "${GREEN}Files updated:             $UPDATED${NC}"
echo -e "${YELLOW}No media file:             $NO_MEDIA${NC}"
if [ "$ERRORS" -gt 0 ]; then
    echo -e "${RED}ExifTool errors:           $ERRORS${NC}"
else
    echo "ExifTool errors:           $ERRORS"
fi
echo -e "${CYAN}----------------------------------------${NC}"
echo "Time elapsed:              ${ELAPSED}s"
echo "Processing rate:           ${RATE} files/sec"
echo -e "${CYAN}========================================${NC}"
echo ""
