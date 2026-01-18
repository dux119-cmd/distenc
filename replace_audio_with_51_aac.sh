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
ENCODED_AUDIO="/dev/shm/$$.encoded_audio.m4a"
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

ffmpeg -y -hide_banner -nostats -drc_scale 2.66 -i "$SOURCE_VIDEO" -vn -map "a:$AUDIO_TRACK" \
    -af "loudnorm=I=-17:TP=-3:LRA=11:linear=true,\
         aresample=resampler=soxr:osf=flt:osr=48000,\
         firequalizer=gain_entry='entry(20,0);entry(150,1.3);entry(3000,1.3);entry(20000,0)',\
         pan=5.1|c0=c0|c1=c1|c2=1.15*c2|c3=c3|c4=c4|c5=c5,\
         aresample=resampler=soxr:osf=s16"\
    -ac 6 -channel_layout 5.1 -f wav - |\
  pv -a -T -B 120M -L 15M -D 30  |\
  fdkaac -m 3 -p 2 --afterburner 1 -w 15024 -o "$ENCODED_AUDIO" -

# Replace audio in target video
mkvmerge -o "$OUTPUT_VIDEO" --clusters-in-meta-seek --no-date \
    --aac-is-sbr 0:0 --audio-tracks 0 "$ENCODED_AUDIO" \
    --no-audio "$TARGET_VIDEO"

# Add metadata
mkvpropedit "$OUTPUT_VIDEO" --add-track-statistics-tags \
  --edit track:1 --set name="Video track" \
  --edit track:2 --set name="Audio track"

# Replace original
mv -v -f "$OUTPUT_VIDEO" "$TARGET_VIDEO"
