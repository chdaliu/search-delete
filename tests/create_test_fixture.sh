#!/bin/bash
# tests/create_test_fixture.sh
#
# Builds a comprehensive directory tree under tests/fixture that exercises
# every rule of the search & delete script:
#   - matching files: plain, case-insensitive, versioned, special chars, hidden,
#     nested, spaces, symlink, exact-match pair, collision pair
#   - directory matches: dir_report/, AnnualReport/
#   - searched by default: Caches/, node_modules/, Temp/ (findable; opt out
#     with --skip-defaults yes)
#   - package folder: Legacy.app (own name must match; contents pruned)
#   - protection zones: Documents/Downloads/Music/Movies/Pictures/Desktop/Public
#     (the fixture doubles as a fake $HOME so protection resolves hermetically)
#   - non-matching files, non-writable items, a config pointing at the tree
#
# Usage: tests/create_test_fixture.sh [output_dir]
#   output_dir defaults to tests/fixture.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIXTURE_DIR="${1:-$SCRIPT_DIR/fixture}"

mkdir() { /bin/mkdir -p "$1"; }
touchf() { printf 'x\n' > "$1"; }

echo "Building test fixture at: $FIXTURE_DIR"
if [ -e "$FIXTURE_DIR" ]; then
  echo "Removing existing fixture..."
  find "$FIXTURE_DIR" -depth -exec chmod u+rwx {} + 2>/dev/null
  chmod -R u+rwx "$FIXTURE_DIR" 2>/dev/null
  rm -rf "$FIXTURE_DIR"
fi

# --- root ----------------------------------------------------------------
mkdir "$FIXTURE_DIR"
touchf "$FIXTURE_DIR/report.txt"
touchf "$FIXTURE_DIR/Report 2026.docx"
touchf "$FIXTURE_DIR/report_v2.pdf"
touchf "$FIXTURE_DIR/report(1).txt"
touchf "$FIXTURE_DIR/keep.txt"
touchf "$FIXTURE_DIR/photo.png"
touchf "$FIXTURE_DIR/single_root.txt"

# hidden files
touchf "$FIXTURE_DIR/.hidden_report"

# directory matches
mkdir "$FIXTURE_DIR/dir_report"
touchf "$FIXTURE_DIR/dir_report/inner.txt"
mkdir "$FIXTURE_DIR/AnnualReport"
touchf "$FIXTURE_DIR/AnnualReport/summary.docx"

# nested + spaces
mkdir "$FIXTURE_DIR/sub"
touchf "$FIXTURE_DIR/sub/report_deep.txt"
mkdir "$FIXTURE_DIR/with space"
touchf "$FIXTURE_DIR/with space/report 2.txt"

# collision pair for the Trash test
mkdir "$FIXTURE_DIR/a"
mkdir "$FIXTURE_DIR/b"
touchf "$FIXTURE_DIR/a/same.txt"
touchf "$FIXTURE_DIR/b/same.txt"

# package folder (own name must match to become a candidate)
mkdir "$FIXTURE_DIR/Legacy.app/Contents"
touchf "$FIXTURE_DIR/Legacy.app/Contents/info.plist"

# exact-match pair
touchf "$FIXTURE_DIR/exact_only"
touchf "$FIXTURE_DIR/exact_other"

# symlink match
ln -s report.txt "$FIXTURE_DIR/link_report"

# cache/dev dirs (searched by default; only pruned with --skip-defaults yes)
mkdir "$FIXTURE_DIR/Caches"
touchf "$FIXTURE_DIR/Caches/report_cache.dat"
mkdir "$FIXTURE_DIR/node_modules"
touchf "$FIXTURE_DIR/node_modules/report.js"
mkdir "$FIXTURE_DIR/Temp"
touchf "$FIXTURE_DIR/Temp/report_temp.dat"

# non-matching nested
mkdir "$FIXTURE_DIR/other_nested"
touchf "$FIXTURE_DIR/other_nested/not_matching.txt"

# protection zones (fake $HOME)
for d in Documents Downloads Music Movies Pictures Desktop Public; do
  mkdir "$FIXTURE_DIR/$d"
done
touchf "$FIXTURE_DIR/Documents/user_report.txt"
touchf "$FIXTURE_DIR/Downloads/dl_report.png"
touchf "$FIXTURE_DIR/Desktop/desk_report.txt"
touchf "$FIXTURE_DIR/Public/pub_report.txt"
touchf "$FIXTURE_DIR/Music/music_report.mp3"
touchf "$FIXTURE_DIR/Movies/movie_report.mov"
touchf "$FIXTURE_DIR/Pictures/pic_report.jpg"

# non-writable items (found but skipped without sudo)
mkdir "$FIXTURE_DIR/noaccess_dir"
touchf "$FIXTURE_DIR/noaccess_dir/secret.txt"
chmod 000 "$FIXTURE_DIR/noaccess_dir"
touchf "$FIXTURE_DIR/noaccess_file_report"
chmod 000 "$FIXTURE_DIR/noaccess_file_report"

# --- config --------------------------------------------------------------
cat > "$FIXTURE_DIR/search_delete.config.json" <<EOF
{
  "language": "en",
  "searchRoots": ["$FIXTURE_DIR"],
  "keywords": ["single_root"],
  "exact": false,
  "mode": "trash",
  "protect": [],
  "allowProtected": false,
  "skipDefaults": false,
  "skip": [],
  "saveDir": "",
  "logLevel": "all"
}
EOF

echo
echo "Fixture created at: $FIXTURE_DIR"
echo "Config: search_delete.config.json"
