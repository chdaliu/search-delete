#!/bin/bash
# tests/run_tests.sh
#
# Automated test harness for the search & delete script. Rebuilds the fixture,
# runs the script in every mode against hermetic copies under tests/out, and
# asserts the resulting state. Permanent deletion is ONLY ever exercised on
# copies; the fake $HOME keeps the real Trash and home untouched.
#
# Prints one line per check (PASS/FAIL) and exits non-zero if any check failed.

cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
TESTS="$ROOT/tests"
FIX="$TESTS/fixture"
OUT="$TESTS/out"
LOG="$TESTS/log"
SD="$ROOT/scripts/search_delete.sh"

PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
assert_ne()       { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1 (both '$2')"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1";; *) bad "$1 (missing '$3')";; esac; }
assert_exists()   { if [ -e "$2" ]; then ok "$1"; else bad "$1 (missing '$2')"; fi; }
assert_gone()     { if [ ! -e "$2" ]; then ok "$1"; else bad "$1 (still exists '$2')"; fi; }

# summary value from script output (awk handles labels containing parens)
sv() { echo "$1" | awk -F: -v k="$2" '$1==k {gsub(/^[ \t]+/,"",$2); print $2; exit}'; }

# build a hermetic copy of the fixture into $OUT/<tag>
build_copy() {
  local tag="$1"
  if [ -e "$OUT/$tag" ]; then
    find "$OUT/$tag" -depth -exec chmod u+rwx {} + 2>/dev/null
    chmod -R u+rwx "$OUT/$tag" 2>/dev/null
    rm -rf "$OUT/$tag"
  fi
  "$TESTS/create_test_fixture.sh" "$OUT/$tag" >/dev/null 2>&1
}

# run the script non-interactively with a fake HOME
run_sd() {
  local tag="$1"; shift
  HOME="$OUT/$tag" "$SD" "$@" --yes --language en --logLevel none --saveDir "$TESTS" 2>&1
}

echo "== 1. syntax checks =="
for s in "$SD" "$TESTS/create_test_fixture.sh" "$TESTS/run_tests.sh"; do
  if bash -n "$s" 2>/dev/null; then ok "syntax $s"; else bad "syntax $s"; fi
done

echo "== 2. build fixture =="
if [ -e "$OUT" ]; then
  find "$OUT" -depth -exec chmod u+rwx {} + 2>/dev/null
  chmod -R u+rwx "$OUT" 2>/dev/null
  rm -rf "$OUT"
fi
rm -rf "$LOG"
mkdir -p "$OUT"
if "$TESTS/create_test_fixture.sh" >/dev/null 2>&1; then ok "fixture built"; else bad "fixture build"; fi

echo "== 3. dry-run deletes nothing =="
RES=$(HOME="$FIX" "$SD" "$FIX" --keyword report --dry-run --yes --language en --logLevel none --saveDir "$TESTS" 2>&1)
assert_ne "dry-run Matched>0" "$(sv "$RES" "Matched")" "0"
assert_ne "dry-run Deleted>0 (would-be)" "$(sv "$RES" "Deleted")" "0"
assert_exists "dry-run leaves report.txt" "$FIX/report.txt"
assert_exists "dry-run leaves Documents/user_report.txt" "$FIX/Documents/user_report.txt"

echo "== 4. permanent delete on a copy =="
build_copy c4
RES=$(run_sd c4 "$OUT/c4" --keyword report --permanent 2>&1)
assert_ne "permanent Deleted>0" "$(sv "$RES" "Deleted")" "0"
assert_gone "report.txt removed" "$OUT/c4/report.txt"
assert_gone "dir_report removed" "$OUT/c4/dir_report"
assert_gone "AnnualReport removed" "$OUT/c4/AnnualReport"
assert_gone "nested sub/report_deep.txt removed" "$OUT/c4/sub/report_deep.txt"
assert_gone "spaces with space/report 2.txt removed" "$OUT/c4/with space/report 2.txt"
assert_gone "special report(1).txt removed" "$OUT/c4/report(1).txt"
assert_gone "hidden .hidden_report removed" "$OUT/c4/.hidden_report"
assert_gone "symlink link_report removed" "$OUT/c4/link_report"
assert_exists "keep.txt remains" "$OUT/c4/keep.txt"
assert_exists "photo.png remains" "$OUT/c4/photo.png"
assert_exists "other_nested/not_matching.txt remains" "$OUT/c4/other_nested/not_matching.txt"

echo "== 5. cache/dev contents are searched and deleted by default =="
assert_gone "Caches/report_cache.dat deleted" "$OUT/c4/Caches/report_cache.dat"
assert_gone "node_modules/report.js deleted" "$OUT/c4/node_modules/report.js"
assert_gone "Temp/report_temp.dat deleted" "$OUT/c4/Temp/report_temp.dat"

echo "== 5b. --skip-defaults yes restores built-in pruning =="
build_copy c5b
RES=$(run_sd c5b "$OUT/c5b" --keyword report --permanent --skip-defaults yes 2>&1)
assert_ne "skip-defaults run still deletes root matches" "$(sv "$RES" "Deleted")" "0"
assert_exists "Caches/report_cache.dat remains (skipped)" "$OUT/c5b/Caches/report_cache.dat"
assert_exists "node_modules/report.js remains (skipped)" "$OUT/c5b/node_modules/report.js"
assert_exists "Temp/report_temp.dat remains (skipped)" "$OUT/c5b/Temp/report_temp.dat"

echo "== 6. non-writable match skipped =="
assert_exists "noaccess_file_report remains (skipped)" "$OUT/c4/noaccess_file_report"

echo "== 7. package: own-name match vs contents pruned =="
build_copy c7a
RES=$(run_sd c7a "$OUT/c7a" --keyword legacy --permanent 2>&1)
assert_gone "Legacy.app removed (own name matches 'legacy')" "$OUT/c7a/Legacy.app"
build_copy c7b
RES=$(run_sd c7b "$OUT/c7b" --keyword report --permanent 2>&1)
assert_exists "Legacy.app untouched by 'report' (contents pruned)" "$OUT/c7b/Legacy.app"

echo "== 8. --exact matches only the exact name =="
build_copy c8
RES=$(run_sd c8 "$OUT/c8" --keyword exact_only --exact --permanent 2>&1)
assert_eq "exact Matched=1" "$(sv "$RES" "Matched")" "1"
assert_gone "exact_only deleted" "$OUT/c8/exact_only"
assert_exists "exact_other remains" "$OUT/c8/exact_other"

echo "== 9. multi-keyword union =="
build_copy c9
RES=$(run_sd c9 "$OUT/c9" --keyword "keep,photo" --permanent 2>&1)
assert_eq "union Deleted=2" "$(sv "$RES" "Deleted")" "2"
assert_gone "keep.txt deleted" "$OUT/c9/keep.txt"
assert_gone "photo.png deleted" "$OUT/c9/photo.png"
assert_exists "report.txt remains" "$OUT/c9/report.txt"

echo "== 10. multi-root: both roots searched =="
build_copy c10r1
build_copy c10r2
touch "$OUT/c10r1/dup.txt"
touch "$OUT/c10r2/dup.txt"
RES=$(run_sd c10r1 "$OUT/c10r1" "$OUT/c10r2" --keyword dup --permanent 2>&1)
assert_eq "multi-root Search roots=2" "$(sv "$RES" "Search roots")" "2"
assert_eq "multi-root Deleted=2" "$(sv "$RES" "Deleted")" "2"
assert_gone "dup in root1 deleted" "$OUT/c10r1/dup.txt"
assert_gone "dup in root2 deleted" "$OUT/c10r2/dup.txt"

echo "== 11. trash mode + collision suffixes (fake HOME) =="
build_copy c11
RES=$(run_sd c11 "$OUT/c11" --keyword same --trash 2>&1)
assert_eq "trash Deleted=2" "$(sv "$RES" "Deleted")" "2"
assert_gone "a/same.txt original gone" "$OUT/c11/a/same.txt"
assert_gone "b/same.txt original gone" "$OUT/c11/b/same.txt"
assert_exists "trash same.txt" "$OUT/c11/.Trash/same.txt"
assert_exists "trash same 2.txt (collision)" "$OUT/c11/.Trash/same 2.txt"

echo "== 12. protected zones kept under --yes =="
build_copy c12
RES=$(run_sd c12 "$OUT/c12" --keyword report --permanent 2>&1)
assert_ne "protected Protected>0" "$(sv "$RES" "Protected (kept)")" "0"
assert_ne "protected Deleted>0" "$(sv "$RES" "Deleted")" "0"
assert_exists "Documents/user_report.txt kept" "$OUT/c12/Documents/user_report.txt"
assert_exists "Downloads/dl_report.png kept" "$OUT/c12/Downloads/dl_report.png"
assert_exists "Desktop/desk_report.txt kept" "$OUT/c12/Desktop/desk_report.txt"

echo "== 13. protected interactive: pick a subset =="
IT="$OUT/protint"
rm -rf "$IT"
mkdir -p "$IT/Documents"
touch "$IT/Documents/doc_report.txt"
touch "$IT/Documents/doc_report2.txt"
RES=$(printf 'a\n1\n1\nn\n2\n' | HOME="$IT" "$SD" "$IT" --keyword report --permanent \
      --language en --skip-defaults yes --skip "" --logLevel none --saveDir "$TESTS" 2>&1)
assert_eq "protected-interactive Protected=1" "$(sv "$RES" "Protected (kept)")" "1"
assert_eq "protected-interactive Deleted=1" "$(sv "$RES" "Deleted")" "1"
NLEFT=$(find "$IT/Documents" -name '*.txt' | wc -l | tr -d ' ')
assert_eq "protected-interactive one file remains" "$NLEFT" "1"

echo "== 14. --allow-protected deletes protected matches =="
build_copy c14
RES=$(run_sd c14 "$OUT/c14" --keyword report --permanent --allow-protected 2>&1)
assert_eq "allow-protected Protected=0" "$(sv "$RES" "Protected (kept)")" "0"
assert_gone "allow-protected Documents/user_report.txt deleted" "$OUT/c14/Documents/user_report.txt"

echo "== 15. --protect none disables protection =="
build_copy c15
RES=$(run_sd c15 "$OUT/c15" --keyword report --permanent --protect none 2>&1)
assert_eq "protect-none Protected=0" "$(sv "$RES" "Protected (kept)")" "0"
assert_gone "protect-none Documents/user_report.txt deleted" "$OUT/c15/Documents/user_report.txt"

echo "== 16. custom --protect marks an extra path protected =="
build_copy c16
RES=$(run_sd c16 "$OUT/c16" --keyword report --permanent --protect "$OUT/c16/sub" 2>&1)
assert_ne "custom-protect Protected>0" "$(sv "$RES" "Protected (kept)")" "0"
assert_exists "custom-protect sub/report_deep.txt kept" "$OUT/c16/sub/report_deep.txt"
assert_gone "custom-protect report.txt deleted" "$OUT/c16/report.txt"

echo "== 17. hard block: a file used as the search root =="
build_copy c17
RES=$(run_sd c17 "$OUT/c17/single_root.txt" --keyword single_root --permanent 2>&1)
assert_eq "blocked Blocked=1" "$(sv "$RES" "Blocked")" "1"
assert_exists "blocked root file survives" "$OUT/c17/single_root.txt"

echo "== 18. no matches: exit 0, nothing changed =="
RES=$(HOME="$FIX" "$SD" "$FIX" --keyword zzznomatch --yes --language en --logLevel none --saveDir "$TESTS" 2>&1)
assert_eq "no-match Matched=0" "$(sv "$RES" "Matched")" "0"
assert_exists "no-match report.txt untouched" "$FIX/report.txt"

echo "== 19. Chinese output contains [已删] =="
build_copy c19
RES=$(HOME="$OUT/c19" "$SD" "$OUT/c19" --keyword report --permanent --yes --language zh --logLevel all --saveDir "$TESTS" 2>&1)
assert_contains "zh [已删]" "$RES" "[已删]"

echo "== 20. config round-trip via -c =="
build_copy c20
RES=$(HOME="$OUT/c20" "$SD" -c "$OUT/c20/search_delete.config.json" --yes --language en --logLevel none --saveDir "$TESTS" 2>&1)
assert_eq "config Deleted=1" "$(sv "$RES" "Deleted")" "1"
assert_gone "config single_root.txt deleted" "$OUT/c20/single_root.txt"

echo "== 21. operation log lands in tests/log and records paths =="
build_copy c21
RES=$(HOME="$OUT/c21" "$SD" "$OUT/c21" --keyword report --permanent --yes --language en --logLevel none --saveDir "$TESTS" 2>&1)
L=$(echo "$RES" | sed -n 's/^Log saved to: //p')
assert_exists "log file exists" "$L"
if [ -n "$L" ]; then
  assert_contains "log records deleted path" "$(cat "$L")" "report.txt"
fi

echo "== 22. blocked path recorded in a log =="
build_copy c22
RES=$(HOME="$OUT/c22" "$SD" "$OUT/c22/single_root.txt" --keyword single_root --permanent --yes --language en --logLevel none --saveDir "$TESTS" 2>&1)
L=$(echo "$RES" | sed -n 's/^Log saved to: //p')
assert_exists "blocked log file exists" "$L"
if [ -n "$L" ]; then
  assert_contains "blocked path recorded" "$(cat "$L")" "single_root.txt"
fi

echo "== 23. skip keyword used as search root is still searched =="
build_copy c23
RES=$(run_sd c23 "$OUT/c23/node_modules" --keyword report --permanent --skip-defaults yes 2>&1)
assert_eq "skip-kw-root Deleted=1" "$(sv "$RES" "Deleted")" "1"
assert_gone "skip-kw-root node_modules/report.js deleted" "$OUT/c23/node_modules/report.js"

echo "== 24. user skip path used as search root is still searched =="
build_copy c24
RES=$(run_sd c24 "$OUT/c24/sub" --keyword report --permanent --skip-defaults yes --skip "$OUT/c24/sub" 2>&1)
assert_eq "skip-path-root Deleted=1" "$(sv "$RES" "Deleted")" "1"
assert_gone "skip-path-root sub/report_deep.txt deleted" "$OUT/c24/sub/report_deep.txt"

echo "== 25. whole-disk search: selected results delete directly =="
if sudo -n true 2>/dev/null; then
  echo "  SKIP: passwordless sudo available (would search the real disk)"
else
  build_copy c25
  mkdir -p "$OUT/c25/zz_sd_dir"
  touch "$OUT/c25/zz_sd_dir/one.txt"
  touch "$OUT/c25/Documents/zz_sd_doc.txt"
  RES=$(HOME="$OUT/c25" "$SD" --search zz_sd --yes --permanent --language en --logLevel none --saveDir "$TESTS" 2>&1)
  assert_ne "wsd Deleted>0 (no delete keyword needed)" "$(sv "$RES" "Deleted")" "0"
  assert_ne "wsd Protected>0" "$(sv "$RES" "Protected (kept)")" "0"
  assert_gone "wsd zz_sd_dir deleted directly" "$OUT/c25/zz_sd_dir"
  assert_exists "wsd protected Documents/zz_sd_doc.txt kept" "$OUT/c25/Documents/zz_sd_doc.txt"
fi

echo "== 26. whole-disk search with --allow-protected deletes them =="
if sudo -n true 2>/dev/null; then
  echo "  SKIP: passwordless sudo available (would search the real disk)"
else
  build_copy c26
  mkdir -p "$OUT/c26/zz_sd_dir"
  touch "$OUT/c26/zz_sd_dir/one.txt"
  touch "$OUT/c26/Documents/zz_sd_doc.txt"
  RES=$(HOME="$OUT/c26" "$SD" --search zz_sd --yes --permanent --allow-protected --language en --logLevel none --saveDir "$TESTS" 2>&1)
  assert_eq "wsd-allow Protected=0" "$(sv "$RES" "Protected (kept)")" "0"
  assert_gone "wsd-allow Documents/zz_sd_doc.txt deleted" "$OUT/c26/Documents/zz_sd_doc.txt"
fi

echo "== 27. invalid selection token is rejected and re-asked =="
build_copy c27
RES=$(printf 'zz\na\nc\n1\nn\n' | HOME="$OUT/c27" "$SD" "$OUT/c27" --keyword report --permanent \
      --language en --skip-defaults yes --skip "" --logLevel none --saveDir "$TESTS" 2>&1)
assert_contains "invalid token rejected" "$RES" "Invalid input"
assert_ne "invalid-token Deleted>0" "$(sv "$RES" "Deleted")" "0"
assert_gone "invalid-token report.txt deleted" "$OUT/c27/report.txt"
assert_exists "invalid-token Documents/user_report.txt kept" "$OUT/c27/Documents/user_report.txt"

echo "== 28. mixed valid+invalid tokens keep the valid part =="
build_copy c28
RES=$(printf '1,zz\n2\n\n1\nn\n' | HOME="$OUT/c28" "$SD" "$OUT/c28" --keyword report --permanent \
      --allow-protected --language en --skip-defaults yes --skip "" --logLevel none --saveDir "$TESTS" 2>&1)
assert_contains "mixed-token warning shown" "$RES" "Invalid input(s) ignored"
assert_eq "mixed-token Deleted=2" "$(sv "$RES" "Deleted")" "2"

echo "== 29. full-width (Chinese-IME) digits and comma are accepted =="
build_copy c29
RES=$(printf '1，2\n\n1\nn\n' | HOME="$OUT/c29" "$SD" "$OUT/c29" --keyword report --permanent \
      --allow-protected --language en --skip-defaults yes --skip "" --logLevel none --saveDir "$TESTS" 2>&1)
assert_eq "fullwidth Deleted=2" "$(sv "$RES" "Deleted")" "2"
case "$RES" in *"Invalid input(s) ignored"*) bad "fullwidth should not warn";; *) ok "fullwidth no warning";; esac

echo "== 30. full-width dash range (１－３) is accepted =="
build_copy c30
RES=$(printf '１－３\n\n1\nn\n' | HOME="$OUT/c30" "$SD" "$OUT/c30" --keyword report --permanent \
      --allow-protected --language en --skip-defaults yes --skip "" --logLevel none --saveDir "$TESTS" 2>&1)
assert_eq "fullwidth-dash Deleted=3" "$(sv "$RES" "Deleted")" "3"
case "$RES" in *"Invalid input(s) ignored"*) bad "fullwidth-dash should not warn";; *) ok "fullwidth-dash no warning";; esac

echo "== 31. full-width semicolon (１；２) is accepted =="
build_copy c31
RES=$(printf '１；２\n\n1\nn\n' | HOME="$OUT/c31" "$SD" "$OUT/c31" --keyword report --permanent \
      --allow-protected --language en --skip-defaults yes --skip "" --logLevel none --saveDir "$TESTS" 2>&1)
assert_eq "fullwidth-semicolon Deleted=2" "$(sv "$RES" "Deleted")" "2"
case "$RES" in *"Invalid input(s) ignored"*) bad "fullwidth-semicolon should not warn";; *) ok "fullwidth-semicolon no warning";; esac

echo
echo "PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
