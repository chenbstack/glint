#!/usr/bin/env bash
# Append (or refresh) the latest release entry in appcast.xml.
#
# Env:
#   VERSION    e.g. 0.1.3
#   DMG_PATH   path to the freshly built dmg
#   TAG        github tag (e.g. v0.1.3) — used to compose the download URL
#   REPO       owner/name
#   SIG_LINE   the `sparkle:edSignature="..." length="..."` produced by
#              sign_update; empty when Sparkle signing was skipped

set -euo pipefail

: "${VERSION:?missing}"
: "${DMG_PATH:?missing}"
: "${TAG:?missing}"
: "${REPO:?missing}"
SIG_LINE="${SIG_LINE:-}"

DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${TAG}/$(basename "$DMG_PATH")"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
LENGTH="$(stat -f%z "$DMG_PATH")"

APPCAST="appcast.xml"

# Bootstrap appcast.xml if it doesn't exist yet.
if [ ! -f "$APPCAST" ]; then
  cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Glint</title>
    <link>https://github.com/${REPO}</link>
    <description>Most recent Glint changes.</description>
    <language>en</language>
  </channel>
</rss>
XML
fi

# Use python3 (preinstalled on macOS runners) to splice a new <item> in.
# We use stdlib ElementTree instead of defusedxml because:
#   1. The appcast is our own artifact — there's no untrusted producer.
#   2. macos runners ship a PEP-668-managed Python that refuses pip
#      installs without a venv, so adding defusedxml would mean spinning
#      up a venv on every release for no real security gain.

python3 - "$APPCAST" <<PY
import os, sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
version    = os.environ["VERSION"]
url        = "${DOWNLOAD_URL}"
pub_date   = "${PUB_DATE}"
length     = "${LENGTH}"
sig_line   = """${SIG_LINE}""".strip()
release_notes_link = f"https://github.com/${REPO}/releases/tag/${TAG}"

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)

tree = ET.parse(path)
root = tree.getroot()
channel = root.find("channel")
assert channel is not None, "appcast.xml missing <channel>"

# Drop any pre-existing item with the same sparkle:version (idempotent re-run).
for item in list(channel.findall("item")):
    v = item.find("{%s}version" % SPARKLE)
    if v is not None and v.text == version:
        channel.remove(item)

item = ET.Element("item")
ET.SubElement(item, "title").text = f"Glint {version}"
ET.SubElement(item, "{%s}version" % SPARKLE).text = version
ET.SubElement(item, "{%s}shortVersionString" % SPARKLE).text = version
ET.SubElement(item, "pubDate").text = pub_date
ET.SubElement(item, "{%s}minimumSystemVersion" % SPARKLE).text = "14.0"
ET.SubElement(item, "{%s}releaseNotesLink" % SPARKLE).text = release_notes_link

enclosure = ET.Element("enclosure")
enclosure.set("url", url)
enclosure.set("length", length)
enclosure.set("type", "application/octet-stream")
# Parse "sparkle:edSignature=\"...\" length=\"...\"" into attrs.
if sig_line:
    import re
    for k, v in re.findall(r'(\w+:?\w+)="([^"]*)"', sig_line):
        enclosure.set(k, v)
item.append(enclosure)

# Insert as the newest item (right after <description> / <language>).
insert_at = 0
for i, child in enumerate(list(channel)):
    if child.tag == "item":
        insert_at = i
        break
else:
    insert_at = len(list(channel))
channel.insert(insert_at, item)

ET.indent(tree, space="  ")
tree.write(path, encoding="utf-8", xml_declaration=True)
PY

echo "appcast.xml updated with v${VERSION}"
