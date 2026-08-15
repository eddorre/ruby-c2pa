#!/usr/bin/env bash
#
# Regenerate the media fixtures used by the test suite.
#
# The fixtures are committed, so you only need this to change or add one.
# Requires: ffmpeg, cjxl (jpeg-xl), exiftool.
#
#     brew install ffmpeg jpeg-xl exiftool
#     ./test/fixtures/generate.sh
#
# Everything here is synthesised from ffmpeg's built-in generators, so the
# fixtures carry no third-party content and no licence obligations.
#
# They are deliberately not 1x1 placeholders. C2PA embeds manifests into real
# container structures — APP11 segments in JPEG, iTXt chunks in PNG, IFD
# entries in TIFF, uuid boxes in BMFF, RIFF chunks in WAV, ID3 frames in MP3 —
# and a file with no actual content exercises almost none of that. These carry
# real image detail, real audio samples, real video frames and real EXIF, while
# staying small enough not to weigh down the repository.

set -euo pipefail
cd "$(dirname "$0")"

SIZE=160x120       # small, but real pictures rather than a single pixel
RATE=10            # frames per second
DURATION=0.5       # seconds of video
AUDIO_RATE=22050   # Hz
TONE=440           # Hz

say() { printf '  %-12s' "$1"; }
size_of() { printf '%s bytes\n' "$(stat -f%z "$1")"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "Generating source material"
# testsrc2 is a colour pattern with gradients, shapes and moving elements, so
# the encoders have genuine detail to work with rather than a flat field.
ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=$SIZE:rate=$RATE" \
  -frames:v 1 "$work/still.png"
ffmpeg -loglevel error -y -f lavfi \
  -i "sine=frequency=$TONE:duration=$DURATION:sample_rate=$AUDIO_RATE" \
  -ac 1 "$work/tone.wav"

echo "Images"
say "tiny.jpg"
ffmpeg -loglevel error -y -i "$work/still.png" -q:v 6 tiny.jpg
# Real EXIF, so signing is exercised against a file that already carries
# metadata rather than an empty container.
exiftool -q -overwrite_original \
  -Make="ruby-c2pa" \
  -Model="Fixture Generator" \
  -Artist="ruby-c2pa test suite" \
  -DateTimeOriginal="2026:01:01 00:00:00" \
  tiny.jpg
size_of tiny.jpg

say "tiny.png";  ffmpeg -loglevel error -y -i "$work/still.png" -compression_level 9 tiny.png; size_of tiny.png
# webp and jpeg-xl come from their own encoders; Homebrew's ffmpeg is built
# without libwebp, and cjxl is the reference JPEG XL encoder.
say "tiny.webp"; cwebp -quiet -q 70 "$work/still.png" -o tiny.webp;                           size_of tiny.webp
say "tiny.tiff"; ffmpeg -loglevel error -y -i "$work/still.png" -compression_algo deflate tiny.tiff; size_of tiny.tiff
# SVT-AV1 logs through its own writer and ignores -loglevel, hence the filter.
say "tiny.avif"; ffmpeg -loglevel error -y -i "$work/still.png" -c:v libsvtav1 -crf 40 -f avif tiny.avif 2>&1 | grep -v '^Svt\[' || true; size_of tiny.avif
# --container=1 forces the ISOBMFF container form. cjxl otherwise emits a bare
# codestream, which c2pa-rs rejects with "Not a valid JPEG XL container" as
# there are no boxes to put a manifest in.
say "tiny.jxl";  cjxl --quiet --container=1 -q 80 "$work/still.png" tiny.jxl >/dev/null 2>&1; size_of tiny.jxl

echo "Audio"
say "tiny.wav";  cp "$work/tone.wav" tiny.wav;                                                size_of tiny.wav
say "tiny.mp3";  ffmpeg -loglevel error -y -i "$work/tone.wav" -c:a libmp3lame -b:a 64k tiny.mp3; size_of tiny.mp3

echo "Video (real frames plus an audio track)"
for spec in "tiny.mp4 mp4" "tiny.mov mov"; do
  set -- $spec
  say "$1"
  ffmpeg -loglevel error -y \
    -f lavfi -i "testsrc2=size=$SIZE:rate=$RATE:duration=$DURATION" \
    -f lavfi -i "sine=frequency=$TONE:duration=$DURATION:sample_rate=$AUDIO_RATE" \
    -c:v libx264 -pix_fmt yuv420p -crf 32 -preset veryslow \
    -c:a aac -b:a 32k -ac 1 \
    -movflags +faststart -f "$2" "$1"
  size_of "$1"
done

echo
printf 'Total: %s\n' "$(du -sh . | cut -f1)"
