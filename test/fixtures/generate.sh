#!/usr/bin/env bash
#
# Regenerate the media fixtures used by the test suite.
#
# THE FIXTURES ARE COMMITTED. Running the tests needs none of the tools below —
# only regenerating does. `bundle exec rake test` works from a clean checkout
# with nothing installed.
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
#
# Regeneration is byte-identical on the same toolchain — re-running this on the
# machine that produced the committed fixtures leaves git clean. Across
# different encoder versions or platforms expect the bytes to move, so review
# the diff rather than assuming a no-op.

set -euo pipefail
cd "$(dirname "$0")"

SIZE=160x120       # small, but real pictures rather than a single pixel
RATE=10            # frames per second
DURATION=0.5       # seconds of video
AUDIO_RATE=22050   # Hz
TONE=440           # Hz

say() { printf '  %-12s' "$1"; }

# stat takes different flags on BSD and GNU, and this script should run on both.
size_of() {
  local bytes
  bytes=$(stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo "?")
  printf '%s bytes\n' "$bytes"
}

# Fail with something actionable rather than "command not found" from halfway
# through a run that has already overwritten some fixtures.
missing=()
for tool in ffmpeg cwebp cjxl exiftool zip; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ ${#missing[@]} -gt 0 ]; then
  cat >&2 <<MSG
Missing: ${missing[*]}

  macOS   brew install ffmpeg webp jpeg-xl exiftool   (zip ships with macOS)
  Debian  sudo apt install ffmpeg webp libjxl-tools libimage-exiftool-perl zip

The fixtures are committed, so this is only needed to regenerate them.
Running the test suite requires none of it.
MSG
  exit 1
fi

# ffmpeg builds vary in which encoders they carry — Homebrew's ships without
# libwebp and libaom-av1, which is why webp and JPEG XL use their own tools.
# Check up front rather than failing partway through.
missing_encoders=()
for encoder in libx264 libsvtav1 libmp3lame aac png tiff mjpeg; do
  ffmpeg -hide_banner -encoders 2>/dev/null | grep -qE "^ [A-Z.]+ $encoder " \
    || missing_encoders+=("$encoder")
done
if [ ${#missing_encoders[@]} -gt 0 ]; then
  echo "This ffmpeg lacks required encoders: ${missing_encoders[*]}" >&2
  echo "Install a fuller build, e.g. 'brew install ffmpeg' on macOS." >&2
  exit 1
fi

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

echo "Document"
# Written by hand rather than through a tool: no PDF generator is portable
# across macOS and Linux, and a minimal file is all the read path needs. The
# cross-reference table must carry correct byte offsets or lopdf rejects the
# file, so each object's offset is measured as it is appended.
say "tiny.pdf"
{
  pdf=tiny.pdf
  printf '%%PDF-1.4\n' > "$pdf"
  offsets=()
  add_object() {
    offsets+=("$(wc -c < "$pdf" | tr -d ' ')")
    printf '%s\n' "$1" >> "$pdf"
  }
  add_object '1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj'
  add_object '2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj'
  add_object '3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >> endobj'
  content='BT /F1 18 Tf 20 40 Td (ruby-c2pa) Tj ET'
  add_object "4 0 obj << /Length ${#content} >> stream
${content}
endstream endobj"
  add_object '5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj'
  xref=$(wc -c < "$pdf" | tr -d ' ')
  {
    printf 'xref\n0 6\n0000000000 65535 f \n'
    for o in "${offsets[@]}"; do printf '%010d 00000 n \n' "$o"; done
    printf 'trailer << /Size 6 /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' "$xref"
  } >> "$pdf"
}
size_of tiny.pdf

echo "ZIP-based documents"
# Also written by hand, for the same portability reason as the PDF. Each is
# the smallest package its format accepts, and every part is deflated, as in
# real documents: c2pa-rs's zip dependency reads only stored entries unless
# the deflate feature is enabled, and stored-only fixtures would hide that.
# Timestamps are pinned so zip output is byte-identical between runs.
# Where a format has a mimetype entry it goes first and uncompressed, as EPUB
# and OpenDocument require.
pack() { # output, source dir, parts in order
  local out=$PWD/$1 dir=$2; shift 2
  find "$dir" -exec touch -t 202601010000 {} +
  rm -f "$out"
  ( cd "$dir"
    if [ "$1" = mimetype ]; then zip -q -X -0 "$out" mimetype; shift; fi
    zip -q -X -9 "$out" "$@" )
}
text="Content credentials fixture, synthesised for the ruby-c2pa test suite."

say "tiny.epub"
d=$work/epub; mkdir -p "$d/META-INF" "$d/OEBPS"
printf 'application/epub+zip' > "$d/mimetype"
cat > "$d/META-INF/container.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
XML
cat > "$d/OEBPS/content.opf" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:uuid:3f1c2b1e-0000-4000-8000-000000000001</dc:identifier>
    <dc:title>Tiny</dc:title>
    <dc:language>en</dc:language>
    <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ch1" href="chapter.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="ch1"/></spine>
</package>
XML
cat > "$d/OEBPS/nav.xhtml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Tiny</title></head>
<body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">Chapter</a></li></ol></nav></body></html>
XML
cat > "$d/OEBPS/chapter.xhtml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter</title></head><body><p>$text</p></body></html>
XML
pack tiny.epub "$d" mimetype META-INF/container.xml OEBPS/content.opf OEBPS/nav.xhtml OEBPS/chapter.xhtml
size_of tiny.epub

say "tiny.docx"
d=$work/docx; mkdir -p "$d/_rels" "$d/word"
cat > "$d/[Content_Types].xml" <<XML
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>
XML
cat > "$d/_rels/.rels" <<XML
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>
XML
cat > "$d/word/document.xml" <<XML
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body><w:p><w:r><w:t>$text</w:t></w:r></w:p></w:body>
</w:document>
XML
pack tiny.docx "$d" "[Content_Types].xml" _rels/.rels word/document.xml
size_of tiny.docx

say "tiny.odt"
d=$work/odt; mkdir -p "$d/META-INF"
printf 'application/vnd.oasis.opendocument.text' > "$d/mimetype"
cat > "$d/META-INF/manifest.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3">
  <manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.text"/>
  <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
</manifest:manifest>
XML
cat > "$d/content.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.3">
  <office:body><office:text><text:p>$text</text:p></office:text></office:body>
</office:document-content>
XML
pack tiny.odt "$d" mimetype META-INF/manifest.xml content.xml
size_of tiny.odt

say "tiny.oxps"
d=$work/oxps; mkdir -p "$d/_rels" "$d/Documents/1/Pages"
cat > "$d/[Content_Types].xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="fdseq" ContentType="application/vnd.ms-package.xps-fixeddocumentsequence+xml"/>
  <Default Extension="fdoc" ContentType="application/vnd.ms-package.xps-fixeddocument+xml"/>
  <Default Extension="fpage" ContentType="application/vnd.ms-package.xps-fixedpage+xml"/>
</Types>
XML
cat > "$d/_rels/.rels" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="R0" Type="http://schemas.openxps.org/oxps/v1.0/fixedrepresentation" Target="/FixedDocumentSequence.fdseq"/>
</Relationships>
XML
cat > "$d/FixedDocumentSequence.fdseq" <<XML
<FixedDocumentSequence xmlns="http://schemas.openxps.org/oxps/v1.0"><DocumentReference Source="/Documents/1/FixedDocument.fdoc"/></FixedDocumentSequence>
XML
cat > "$d/Documents/1/FixedDocument.fdoc" <<XML
<FixedDocument xmlns="http://schemas.openxps.org/oxps/v1.0"><PageContent Source="/Documents/1/Pages/1.fpage"/></FixedDocument>
XML
cat > "$d/Documents/1/Pages/1.fpage" <<XML
<FixedPage xmlns="http://schemas.openxps.org/oxps/v1.0" Width="816" Height="1056" xml:lang="en-US">
  <Path Data="M 96,96 L 720,96 L 720,160 L 96,160 Z" Fill="#FF336699"/>
</FixedPage>
XML
pack tiny.oxps "$d" "[Content_Types].xml" _rels/.rels FixedDocumentSequence.fdseq Documents/1/FixedDocument.fdoc Documents/1/Pages/1.fpage
size_of tiny.oxps

echo
printf 'Total: %s\n' "$(du -sh . | cut -f1)"
