#!/bin/zsh
# Issue #139: render the Hands-Free quick ack clips with Kokoro af_bella, on this Mac only.
# Reads one line per clip from the text list. Writes ack-<slug>.m4a (mono AAC, 48 kbps) next to it.
# The app finds a clip by the same slug rule (VoiceModeAckClips.fileName in HermesKit).
# Usage: scripts/render_ack_clips.sh [text list]
set -euo pipefail
cd "${0:A:h}/.."
LIST=${1:-HermesConnect/Resources/AckClips/ack_lines.txt}
OUT=${LIST:h}
NARRATE=${NARRATE:-$HOME/.local/bin/narrate}
VOICE=af_bella
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

slug() {
  print -r -- "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# afconvert writes the time of the render into the movie, track and media headers. Zero them, so the same
# text list makes the same bytes.
zero_times() {
  /usr/bin/python3 -I - "$1" <<'PYEOF'
import struct, sys
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
for tag in (b"mvhd", b"tkhd", b"mdhd"):
    at = data.find(tag)
    while at >= 4:
        size = 8 if data[at + 4] == 1 else 4
        start = at + 8
        data[start:start + 2 * size] = bytes(2 * size)
        at = data.find(tag, at + 4)
open(path, "wb").write(bytes(data))
PYEOF
}

while IFS= read -r line || [[ -n $line ]]; do
  line=${line## #}; line=${line%% #}
  [[ -z $line ]] && continue
  name="ack-$(slug "$line")"
  print -r -- "$line" > "$WORK/$name.txt"
  "$NARRATE" "$WORK/$name.txt" -o "$WORK/$name.wav" --voice "$VOICE" > /dev/null
  afconvert -f m4af -d aac -c 1 -b 48000 "$WORK/$name.wav" "$OUT/$name.m4a"
  zero_times "$OUT/$name.m4a"
  print -r -- "$OUT/$name.m4a"
done < "$LIST"
