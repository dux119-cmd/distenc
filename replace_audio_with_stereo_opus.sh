#!/bin/bash
set -euo pipefail

# Check dependencies
command -v ffmpeg >/dev/null || { echo "ffmpeg not found"; exit 1; }
command -v mkvmerge >/dev/null || { echo "mkvmerge not found"; exit 1; }
command -v mkvpropedit >/dev/null || { echo "mkvpropedit not found"; exit 1; }

# Parse arguments
if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 <donor_video.mkv> <recipient_video.mkv> [audio_track_index]"
    echo "  audio_track_index: defaults to 0 (first audio track)"
    exit 1
fi

if [[ -d "$1" ]]; then
  SOURCE_DIR="$1"
else
  SOURCE_VIDEO="$1"
fi

TARGET_VIDEO="$2"
AUDIO_TRACK="${3:-0}"

# Validate audio track is a number
if ! [[ "$AUDIO_TRACK" =~ ^[0-9]+$ ]]; then
    echo "Error: audio_track_index must be a number"
    exit 1
fi

# Temp files
DECODED_AUDIO="/dev/shm/$$.decoded_audio.wav"
ENCODED_AUDIO="/dev/shm/$$.encoded_audio.mka"
TEMP_JSON="/dev/shm/$$.json"
OUTPUT_VIDEO="/dev/shm/$$.output_with_new_audio.mkv"

cleanup() {
 rm -f "$ENCODED_AUDIO" "$TEMP_JSON"
}
trap cleanup EXIT

# Extract JSON value from grep output
get_json_value() {
    grep "$1" "$TEMP_JSON" | awk -F ':' '{print $2}' | tr -d ' ",'
}

if [[ -d "${SOURCE_DIR:-}" ]]; then
  lc_target="${TARGET_VIDEO,,}"
  found=""
  shopt -s nullglob
  for f in "$SOURCE_DIR"/*; do
    name=${f##*/}                     # strip directory
    if [[ "${name,,}" == "$lc_target" ]]; then
      SOURCE_VIDEO="$SOURCE_DIR/$name"
      break
    fi
  done
  shopt -u nullglob
fi

# Apply normalization (audio-only)
if [[ ! -f "${SOURCE_VIDEO:-}" ]]; then
  echo "Could not find source for $TARGET_VIDEO using case-insensitive matching in the source directory $SOURCE_DIR"
  exit 1
fi

ffmpeg -y -hide_banner -nostats -i "$SOURCE_VIDEO" -vn -map "a:$AUDIO_TRACK" \
       -af "surround=flx=4:frx=4:fc_out=1.3, \
       speechnorm,
       loudnorm=I=-18:LRA=3:TP=-1, \
       aresample=resampler=soxr:osf=flt" \
  -c:a libopus -ac 2 -b:a 112k -frame_duration 40 "$ENCODED_AUDIO"


# Replace audio in target video
mkvmerge -o "$OUTPUT_VIDEO" --clusters-in-meta-seek --no-date \
    --aac-is-sbr 0:0 --audio-tracks 0 "$ENCODED_AUDIO" \
    --no-audio "$TARGET_VIDEO"

# Add metadata
mkvpropedit "$OUTPUT_VIDEO" --add-track-statistics-tags

# Replace original
mv -v -f "$OUTPUT_VIDEO" "$TARGET_VIDEO"
