#!/usr/bin/env bash
# Append (or refresh) the latest release entry in appcast.xml.
#
# Env:
#   VERSION       human version, e.g. 0.1.3
#   BUILD_NUMBER  monotonically increasing build identifier — MUST match the
#                 CFBundleVersion the workflow stamped into Info.plist, since
#                 Sparkle compares <sparkle:version> against that to decide
#                 whether an update is newer.
#   DMG_PATH      path to the freshly built dmg
#   TAG           github tag (e.g. v0.1.3) — used to compose the download URL
#   REPO          owner/name
#   SIG_LINE      the `sparkle:edSignature="..." length="..."` produced by
#                 sign_update; empty when Sparkle signing was skipped

set -euo pipefail

: "${VERSION:?missing}"
: "${BUILD_NUMBER:?missing}"
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

# Build release notes HTML from the git log since the previous tag. Use a
# placeholder text in ET so the writer doesn't escape our HTML, then swap
# in CDATA via a post-process step — Sparkle expects description HTML to
# be CDATA-wrapped (or escaped) and the stdlib ElementTree can't emit
# CDATA sections directly.
# Stable releases diff against the previous *stable* tag so their notes
# cover everything since the last release regular users actually got —
# including commits that only ever shipped in betas. Beta releases diff
# against whatever tag came before (stable or beta): beta users track
# every increment.
if [[ "$VERSION" == *-* ]]; then
  PREV_TAG="$(git describe --tags --abbrev=0 "${TAG}^" 2>/dev/null || echo '')"
else
  PREV_TAG="$(git describe --tags --abbrev=0 --exclude='*-*' "${TAG}^" 2>/dev/null || echo '')"
fi
export VERSION BUILD_NUMBER DOWNLOAD_URL PUB_DATE LENGTH SIG_LINE REPO TAG PREV_TAG

python3 - "$APPCAST" <<'PY'
import os, sys, html, re, subprocess
import xml.etree.ElementTree as ET

path          = sys.argv[1]
version       = os.environ["VERSION"]
build_number  = os.environ["BUILD_NUMBER"]
url           = os.environ["DOWNLOAD_URL"]
pub_date      = os.environ["PUB_DATE"]
length        = os.environ["LENGTH"]
sig_line      = os.environ.get("SIG_LINE", "").strip()
release_notes_link = f"https://github.com/{os.environ['REPO']}/releases/tag/{os.environ['TAG']}"
prev_tag      = os.environ.get("PREV_TAG", "").strip()
tag           = os.environ["TAG"]

# ─── Collect bilingual commit summaries between the previous tag and this one ──
#
# Convention: each commit subject is the English short description; the
# Chinese summary lives in the body as a `CN: ...` trailer (one line).
# Commits without a `CN:` trailer fall back to English-only.
#
# Example commit:
#     about: surface auto-update wiring as a Build row
#
#     CN: 关于面板:把 Sparkle 自动更新状态展示出来
#
#     Lets you eyeball whether the running build has Sparkle ...
SEP = "__GLINT_COMMIT_SEP__"
rev_range = f"{prev_tag}..{tag}" if prev_tag else tag
try:
    raw = subprocess.check_output(
        ["git", "log", rev_range, f"--pretty=format:%s%n%b%n{SEP}"],
        text=True, stderr=subprocess.DEVNULL,
    )
except subprocess.CalledProcessError:
    raw = ""

CN_RE = re.compile(r"^CN[:：]\s*(.+?)\s*$", re.MULTILINE)

entries = []  # list of (en, zh|None)
for chunk in raw.split(SEP):
    chunk = chunk.strip()
    if not chunk:
        continue
    lines = chunk.splitlines()
    en = lines[0].strip()
    if not en or en.lower().startswith("co-authored-by"):
        continue
    body = "\n".join(lines[1:])
    m = CN_RE.search(body)
    zh = m.group(1).strip() if m else None
    entries.append((en, zh))

# ─── Bucket-sort: features/changes first, fixes after, infra last ──
# git log returns newest-first; Python's sort is stable so within each
# bucket the chronological order is preserved. The bucket is derived
# from the conventional-commit prefix (feat: / fix: / polish: / etc) —
# anything we don't recognize stays in a trailing "other" bucket so it
# doesn't slip silently above the fixes.
TYPE_RE = re.compile(r"^\s*([a-zA-Z]+)(?:\([^)]*\))?\s*[:：]")
BUCKETS = {
    # 0 — new features users want to see first
    "feat": 0, "feature": 0,
    # 1 — visible behaviour/UX changes that aren't new features per se
    "polish": 1, "improve": 1, "refactor": 1, "perf": 1, "style": 1,
    "change": 1, "ux": 1,
    # 2 — bug fixes
    "fix": 2, "bugfix": 2, "hotfix": 2,
    # 3 — repo/infra hygiene; not interesting to end users, sinks to bottom
    "ci": 3, "chore": 3, "docs": 3, "build": 3, "test": 3, "deps": 3,
    "release": 3,
}
def bucket(entry):
    en = entry[0]
    m = TYPE_RE.match(en)
    typ = (m.group(1).lower() if m else "")
    return BUCKETS.get(typ, 4)
entries.sort(key=bucket)

# ─── Render notes HTML (bilingual headings + list of EN / 中文 per item) ──
def render_li(en, zh):
    en_esc = html.escape(en)
    if zh:
        zh_esc = html.escape(zh)
        return (
            f"    <li><strong>{en_esc}</strong>"
            f"<br><span style=\"color:#666\">{zh_esc}</span></li>"
        )
    return f"    <li>{en_esc}</li>"

if entries:
    lis = "\n".join(render_li(en, zh) for en, zh in entries)
    body = f"<ul>\n{lis}\n  </ul>"
else:
    body = "<p>Maintenance release · 维护更新</p>"

current_html = (
    "<div style=\"font-family:-apple-system,sans-serif;\">"
    f"<h3>更新内容 · What's new in {html.escape(version)}</h3>"
    f"{body}"
    "</div>"
)

# ─── Also emit a Markdown version of the same notes for the GitHub Release ──
# softprops/action-gh-release picks this up via `body_path:`, so the Release
# page shows the bilingual CN: trailer changelog instead of GitHub's default
# "Full Changelog: …" stub (which is empty for projects that commit straight
# to main). Keeping both renderers in one script means the appcast and the
# Release page stay in lock-step — one source of truth.
def md_li(en, zh):
    if zh:
        return f"- **{en}**  \n  {zh}"
    return f"- {en}"

if entries:
    md_body = "\n".join(md_li(en, zh) for en, zh in entries)
else:
    md_body = "_Maintenance release · 维护更新_"

md_notes = f"## 更新内容 · What's new in {version}\n\n{md_body}\n"

md_path = os.environ.get("RELEASE_NOTES_MD")
if md_path:
    with open(md_path, "w", encoding="utf-8") as f:
        f.write(md_notes)

# ─── Splice/refresh the appcast item ──
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)

tree = ET.parse(path)
root = tree.getroot()
channel = root.find("channel")
assert channel is not None, "appcast.xml missing <channel>"

# Drop any pre-existing item with the same sparkle:version (idempotent re-run).
for item in list(channel.findall("item")):
    v = item.find(f"{{{SPARKLE}}}version")
    if v is not None and v.text == build_number:
        channel.remove(item)

# Pull every remaining item's description (in the order they appear, which is
# newest-first) so we can fold the full history into THIS item's notes.
# Sparkle only renders the description of the item the user is upgrading to,
# so a user crossing several versions would otherwise miss everything between
# their installed build and the latest one. Concatenating older descriptions
# below the current one keeps a single, scrollable "what changed since you
# last updated" view.
#
# Each prior description may already contain its own history block (appended
# the last time THAT item was written). We split on the separator marker so
# we only carry each version's own notes — otherwise the latest item's
# description would grow quadratically on every release.
HISTORY_MARKER = "<!--GLINT_HISTORY_BELOW-->"
SEPARATOR_HTML = (
    "<hr style=\"border:none;border-top:1px solid #e5e5e5;margin:16px 0;\">"
)

# Cap how many prior versions we fold into the current item's notes. The
# Sparkle dialog has no native multi-version delta view, so to keep
# cross-version upgraders from missing intermediate notes we still fold
# history into the latest item — but capping at the most recent N
# prevents the dialog from growing unbounded (and reading like a wall
# of ancient changelog) as releases accumulate. 9 history entries plus
# the current version = 10 versions visible in the dialog.
HISTORY_CAP = 9

# Prerelease versions (0.2.0-beta.1, …) ship on the "beta" Sparkle channel:
# their items carry <sparkle:channel>beta</sparkle:channel> and are invisible
# to updaters that didn't opt in via SPUUpdaterDelegate.allowedChannels.
is_beta = "-" in version

history_chunks = []
for prev in channel.findall("item"):
    if len(history_chunks) >= HISTORY_CAP:
        break
    # Stable items keep beta releases out of their folded history — a
    # stable user never installed those, and their commits are already
    # covered by this item's own since-last-stable notes. Beta items fold
    # everything: beta users hop release to release.
    if not is_beta and prev.find(f"{{{SPARKLE}}}channel") is not None:
        continue
    d = prev.find("description")
    if d is None or not d.text:
        continue
    own = d.text.split(HISTORY_MARKER, 1)[0].strip()
    if own:
        history_chunks.append(own)

if history_chunks:
    history_header = (
        "<div style=\"font-family:-apple-system,sans-serif;\">"
        "<h3 style=\"color:#666;\">历史版本 · Previous releases</h3>"
        "</div>"
    )
    notes_html = (
        current_html
        + HISTORY_MARKER
        + SEPARATOR_HTML
        + history_header
        + SEPARATOR_HTML.join(history_chunks)
    )
else:
    notes_html = current_html

NOTES_PLACEHOLDER = "__GLINT_NOTES_CDATA_PLACEHOLDER__"

item = ET.Element("item")
ET.SubElement(item, "title").text = f"Glint {version}"
ET.SubElement(item, f"{{{SPARKLE}}}version").text = build_number
ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
if is_beta:
    ET.SubElement(item, f"{{{SPARKLE}}}channel").text = "beta"
ET.SubElement(item, "pubDate").text = pub_date
ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "14.0"
# Don't emit <sparkle:releaseNotesLink> — when both link and description
# are present, Sparkle prefers the link and iframes the GitHub repo page
# straight into the dialog. We want the local CDATA HTML to render.
ET.SubElement(item, "description").text = NOTES_PLACEHOLDER

enclosure = ET.Element("enclosure")
enclosure.set("url", url)
enclosure.set("length", length)
enclosure.set("type", "application/octet-stream")
# Parse `sparkle:edSignature="..." length="..."` into attrs.
if sig_line:
    for k, v in re.findall(r'(\w+:?\w+)="([^"]*)"', sig_line):
        enclosure.set(k, v)
item.append(enclosure)

# Insert as the newest item (right after <description> / <language>).
insert_at = len(list(channel))
for i, child in enumerate(list(channel)):
    if child.tag == "item":
        insert_at = i
        break
channel.insert(insert_at, item)

ET.indent(tree, space="  ")
tree.write(path, encoding="utf-8", xml_declaration=True)

# Post-process: swap the placeholder for a CDATA section, so Sparkle
# can render the HTML rather than treating &lt;ul&gt;… as literal text.
with open(path, "r", encoding="utf-8") as f:
    raw = f.read()
raw = raw.replace(NOTES_PLACEHOLDER, f"<![CDATA[{notes_html}]]>")
with open(path, "w", encoding="utf-8") as f:
    f.write(raw)
PY

echo "appcast.xml updated with v${VERSION} (build ${BUILD_NUMBER})"
