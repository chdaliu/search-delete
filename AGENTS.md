# AGENTS.md — Reproducible build spec (可重现构建说明)

This document is the authoritative spec for **rebuilding the Search & Delete
（搜索即删）project from scratch** with an AI agent. A capable agent can
reproduce the script and the test suite by following the layout, behaviors, and
conventions below, then verify with `tests/run_tests.sh`.

> The Chinese README is `docs/README.zh-CN.md`; English is `docs/README.md`.
> A Chinese translation of this spec is provided in `AGENTS.zh-CN.md`.

## 1. Project layout

```
keyword-search-delete/            (repo root; project: Search & Delete)
├── scripts/
│   └── search_delete.sh         # search by keyword and delete (trash / permanent)
├── docs/
│   ├── README.md                # English
│   └── README.zh-CN.md          # Chinese
├── tests/
│   ├── create_test_fixture.sh   # builds tests/fixture covering every rule
│   └── run_tests.sh             # automated checks (must pass)
├── AGENTS.md                    # this spec (English)
├── AGENTS.zh-CN.md              # this spec (Chinese)
└── opencode.json                # registers AGENTS.zh-CN.md as instructions
```

The script lives in `scripts/`. It computes `SCRIPT_DIR` as the **project root**
(one level above `scripts/`) so config and log defaults stay in the project
root.

## 2. Hard constraints

- **bash 3.2 compatible** (macOS `/bin/bash`): no associative arrays, no
  `${var,,}` / `${var^^}`, no `mapfile`; use `tr` for case, `while read` loops,
  and `[[ =~ ]]`.
- **Bilingual UI**: `msg()` dispatches to `msg_en <key>` / `msg_zh <key>`, each
  a `case` returning strings; `msg key [args]` printf-formats. `LANGUAGE` is
  `en` (default) or `zh`. Every key must exist in both tables.
- **Prompt helper** `ask <msgkey> [default]`: prints `msg + " [default: X]"`,
  reads a line from a duplicated stdin (fd 9), exits cleanly (message
  `input_closed`) on EOF so scripted runs never loop forever, and `check_exit`
  aborts when the user types `exit`.
- **Dependencies**: `jq` (config), `find -iname`/`-path` (matching & pruning),
  `mv` + `rm` (deletion), `osascript` (optional Trash fallback), `sudo`
  (whole-disk search & non-writable items). `export LC_ALL=C` at the top.
- **No code comments beyond the file header and section markers**; keep the
  script self-documenting via `--help`.

## 3. Model

The tool searches **search roots** for paths whose **name** matches any delete
keyword, then deletes the selected matches. Roots, whole-disk search
selections, and matches are distinct concepts:

- **Search roots** (`TARGETS`): directories (or files) where the search runs.
  Sources: positional CLI args, config `searchRoots`, or an interactive menu:
  `1) enter one or more directories` (the delete search runs inside them),
  `2) whole-disk search`. Overlapping roots are collapsed to the **outermost
  covering set** with canonicalization (`/System/Volumes/Data` firmlink prefix
  dropped when the firmlink form exists; symlink dirs resolved via `realpath`
  through `collapse_file`). No "no target" exit — the menu loops until at
  least one root or one selected result exists.
- **Whole-disk keyword search** (`--search "k1,k2"`, attempts sudo, falls
  back to `$HOME` `/opt` `/Applications`; menu option 2): the selected
  results become **direct deletion candidates** (`DIRECT_CANDIDATES`) — they
  are deleted as-is (protection split and hard blocks still apply), with **no
  delete-keyword round**. Results are deduped by canonical key
  (`collapse_search_results`: firmlink aliases like `/Users/...` vs
  `/System/Volumes/Data/Users/...` collapse to one entry, shown/deleted as
  the short form; symlink leaves are keyed by canonical parent + basename
  only, never resolved), then covering-collapsed on raw paths
  (`collapse_candidates` — a matched symlink must be deleted as the link,
  never its target).
- **Delete keywords** (`KEYWORDS`): `--keyword "k1,k2"` (comma separated or
  repeated). A path is a match if its **basename** contains (or with
  `--exact` equals) any keyword (case-insensitive `-iname`). Union semantics.
  At least one keyword is required **only when search roots exist**;
  interactive entry is one per line.
- **Match discovery** (`match_and_select`): `find` per root, matching basename
  via `-iname "*kw*"` (or `-iname kw` for exact), with skip rules and package
  folders pruned during the find. Raw matches stream-collapse to a covering set
  on **raw paths** (`collapse_candidates`, deliberately NO canonicalization —
  a matched symlink-dir must be deleted as the link, never its target). Then
  numbered selection (`a`/`c`/numbers/ranges; auto-all under `--yes`).
  Selection input is validated: invalid tokens or out-of-range numbers print
  a warning and are ignored while valid tokens in the same line are kept;
  numbers/ranges accumulate over rounds until an empty line finishes.
  Full-width digits (`１`), comma (`，`), ideographic comma (`、`) and
  ideographic space typed with a Chinese IME are normalised to ASCII on
  numeric, selection and yes/no prompts (never on keyword or path text).
  The confirmation menu lists the selected candidates (count + paths, capped
  at 200).
- **Deletion candidates** (`CANDIDATES`): root-search selections plus merged
  direct candidates (`merge_direct_candidates`, deduped, counted into
  `FOUND_N`) go through a protection split, a confirmation menu, then
  execution.

## 4. Safety (mandatory)

1. **Hard blocks** (`is_blocked`, enforced in `execute()`): candidate equal to
   `/`, `.`, `..`, `$HOME` (canonical form `HOME_C` too), equal to or an
   ancestor of any search root (`p == root` or `root == p/*`), or equal to /
   ancestor of any `SYSTEM_GUARDS` path (`/System /Applications /Library /opt
   /usr /private /bin /sbin /etc /var /Volumes`). Blocked → counted `BLOCKED_N`,
   recorded in `$TMPD/blocked.txt`, logged, never deleted (even with `--yes`).
2. **Protection zones** (`prepare_protect`): default zones are the seven
   macOS user-data dirs under `$HOME_C` (`Documents Downloads Music Movies
   Pictures Desktop Public`) plus user `PROTECT` entries (absolute / `~` / bare
   name under `$HOME`). `--protect none` (`PROTECT_NONE=yes`) disables defaults
   and user entries. Every zone path is canonicalized (`canonical_path`) so
   `/var/...` vs `/private/var/...` aliases match the canonical find output.
   `is_protected` returns true when a candidate equals a zone or is under it
   (the candidate's **raw and canonical forms** are both compared, so
   `/var/...` vs `/private/var/...` and firmlink aliases of candidates found
   by the whole-disk search still match the canonical zones).
   `partition_protected` splits `CANDIDATES` into `PROTECTED_ITEMS` /
   `PLAIN_ITEMS`. `resolve_protected_selection`:
   - `--allow-protected` → keep all in the delete list (no extra prompt);
   - `--yes` (no allow) → keep all protected (counted `PROTECTED_N`, recorded);
   - interactive → list numbered and ask which to delete (`a`=all,
     empty/`c`=keep all, numbers/ranges); unselected stay, counted and recorded.
3. **`--yes` never deletes protected zones** unless `--allow-protected` was
   passed.
4. **The search descends into every directory by default** (caches, temp,
   logs, `node_modules`, `build`, `.git`, `.Trash`, …) — the user picks the
   matches, so nothing is pre-filtered. Built-in pruning is **opt-in** via
   `--skip-defaults yes`: then `build_prune_args` builds a `find` prune
   expression from default cache/dev keywords (`-iname`, case-insensitive —
   required because BSD `find -name` is case-sensitive) and default path
   entries (`-path`); a user `--skip` list (basename or absolute path) is
   always honored when provided. `prepare_search_skip` + `is_search_skipped`
   additionally filter results (basename equals a skip keyword, or at/under a
   resolved skip path). `build_package_prune` prunes package-folder contents
   regardless (a package whose own name matches is still printed). A search
   root that is itself a skip target (its basename equals a skip keyword, or it
   is at/under a resolved skip path) is still searched: the covering rule is
   waived for that root (skip tables are rebuilt per root in `match_and_select`
   via `build_prune_args "$root"` / `prepare_search_skip "$root"`).
5. **Confirmation menu** (`confirm_loop`) always precedes execution when not
   `--yes`: `1 confirm 2 modify 3 re-select 4 exit`. `--permanent` prints a
   warning. `--dry-run` never executes.
6. **Non-writable items**: without sudo they are skipped (counted `SKIP_N`,
   recorded); with `SUDO_OK` they are deleted via `sudo rm`/`sudo mv`.

## 5. Deletion

`delete_one()`: dry-run counts and logs `(dry-run)`; trash mode calls
`move_to_trash` (mkdir `$HOME/.Trash`, `mv`, Finder-style collision suffixes
`name 2.ext` via `collide_basename`, `sudo mv` when needed, `osascript` Finder
fallback for cross-volume); permanent mode uses `rm -f` for files/symlinks and
`rm -rf` for directories. Success → `DELETED_N` (and `TRASHED_N` in trash
mode) + `$TMPD/deleted.txt` + log; failure → `ERROR_N` + `$TMPD/errors.txt`.

## 6. sudo

`ensure_sudo()`: root → `SUDO_OK=yes`; `--yes` → `sudo -n true` silently;
otherwise `sudo -v` prompts once, and before the interactive prompt the script
prints a bilingual explanation (`sudo_hint`: why the password is needed and that
it is not displayed; the prompt itself comes from sudo). `SUDO_OK` is used for
whole-disk search (`sudo find /`) and for non-writable items. `--sudo` forces it
without a whole-disk search. Before `execute()`, `sudo -v` refreshes the
credential cache.

## 7. Logging, summary, operation log

- `--logLevel all|changes|none` (default `all`): `all` prints deleted/trashed/
  error/blocked; `changes` prints those minus protected/skipped details;
  `none` prints nothing. The summary is always printed.
- Summary labels: `Search roots`, `Keywords`, `Mode`, `Matched`, `Protected
  (kept)`, `Blocked`, `Deleted`, `Trashed` (trash mode only), `Errors`,
  `Elapsed`, plus `(dry-run, nothing modified)` under `--dry-run`. The English
  label text starts with the key word on its own line (`Deleted: N`) so tests
  can parse with `sed`.
- Operation log: written only when NOT `--dry-run` and when
  `DELETED_N > 0` **or** `ERROR_N > 0` **or** `BLOCKED_N > 0` **or**
  `PROTECTED_N > 0` — failures are never lost. `--yes` auto-saves; interactive
  asks. Path = `$(resolve_save_dir)/log/search_delete_log_YYYYMMDD_HHMMSS_
  deleted_<N>.log`. Sections: deleted, errors, blocked, protected, skipped,
  summary.

## 8. Config

`search_delete.config.json`, saved to `--saveDir` or the project root.
Schema: `{ "language","searchRoots":[], "keywords":[], "exact", "mode",
"protect":[], "allowProtected", "skipDefaults", "skip":[], "saveDir",
"logLevel" }`. `load_config` reads `.searchRoots[]` / `.keywords[]` /
`.protect[]` / `.skip[]`; `write_config` writes them via `jq -n --arg --argjson`.
Snapshot + `config_changed` (diff vs snapshot) + `all_defaults` (a value equal
to a built-in default is not a change) drive the save prompt. Precedence:
CLI > config > defaults. Under `--yes` config is never saved.

## 9. Tests (reproducibility gate)

`tests/create_test_fixture.sh [dir]` (default `tests/fixture`) builds a tree
that is also a **fake `$HOME`** (so protection zones resolve hermetically). It
must clean permissions before `rm -rf`. Coverage:
- matches: `report.txt`, `Report 2026.docx` (case-insensitive), `report_v2.pdf`,
  `report(1).txt` (special chars), `.hidden_report` (hidden), `dir_report/`,
  `AnnualReport/`, nested `sub/report_deep.txt`, `"with space/report 2.txt"`,
  `a/same.txt` + `b/same.txt` (Trash collision pair), `exact_only`/`exact_other`
  (exact-match), a symlink `link_report`, `single_root.txt`;
- searched by default: `Caches/report_cache.dat`, `node_modules/report.js`,
  `Temp/report_temp.dat` (found by default; only pruned with `--skip-defaults
  yes`);
- package: `Legacy.app/Contents/info.plist` (own name must match to be a
  candidate; contents pruned);
- protection zones: `Documents/user_report.txt`, `Downloads/dl_report.png`,
  `Desktop/desk_report.txt`, `Public/pub_report.txt`;
- non-matching: `keep.txt`, `photo.png`, `keep_nested/not_report.txt`;
- non-writable: `noaccess_dir/` (chmod 000) and `noaccess_file` (chmod 000);
- configs: `search_delete.config.json` pointing at the fixture.

`tests/run_tests.sh` (must pass; permanent deletion only on copies under
`tests/out/`, fake `HOME=$FIX` for trash/protect so nothing touches the real
Trash or home):
1. `bash -n` on the script and both test scripts;
2. fixture builds;
3. dry-run: `"$FIX" --keyword report --dry-run --yes` reports `Matched>0`,
   `Deleted>0` (would-be) and **deletes nothing**;
4. permanent delete on a copy: `report*` matches removed, `keep.txt`/`photo.png`
   remain;
5. directory match deletes the whole folder (`AnnualReport` gone, contents gone);
6. nested match (`sub/report_deep.txt`) deleted;
7. special chars / spaces: `report(1).txt`, `with space/report 2.txt` deleted;
8. hidden file `.hidden_report` matched and deleted;
9. cache/dev contents: after a default real run, `Caches/report_cache.dat`,
   `node_modules/report.js`, `Temp/report_temp.dat` are all deleted; with
   `--skip-defaults yes` they remain (pruned);
10. package: keyword `legacy` deletes `Legacy.app` (own name), keyword `report`
    leaves `Legacy.app` untouched (contents pruned);
11. `--exact` on a copy: only `exact_only` deleted, `exact_other` remains;
12. multi-keyword union: `keep,photo` deletes `keep.txt` and `photo.png`;
13. multi-root: two roots both searched, matches in each deleted;
14. Trash mode with `HOME=$FIX`: matches moved to `$FIX/.Trash`, originals
    gone, collision pair becomes `same.txt` + `same 2.txt`;
15. protected default: matches only in `Documents/Downloads` with `--yes` are
    kept (`Protected>0`, `Deleted=0`, files remain);
16. protected interactive (pipe stdin): selecting a subset deletes only those
    (`Protected=N`, chosen ones deleted, others remain);
17. `--allow-protected` deletes protected matches (`Protected=0`);
18. `--protect none` disables protection (`Deleted=N`);
19. custom `--protect ABS` marks an extra path protected;
20. hard block: a file used as the search root that matches the keyword is
    counted `Blocked=1` and survives (`--yes` does not override);
21. no matches: exit 0, `Matched=0`, nothing changed;
22. `--language zh` output contains `[已删]`;
23. config round-trip: `-c` config supplies roots+keywords, deletion works;
24. log file lands in `tests/log/` and contains the deleted paths.
25. whole-disk search direct delete (skip the test when passwordless sudo is
    available): fake `HOME=$OUT/c25` containing a `zz_sd_dir/` and
    `Documents/zz_sd_doc.txt`; `--search zz_sd --yes --permanent` without any
    `--keyword` deletes `zz_sd_dir` directly (no delete-keyword round) while
    `Documents/zz_sd_doc.txt` is kept (`Protected>0`);
26. same flow with `--allow-protected` deletes the protected file
    (`Protected=0`);
27. invalid selection token (piped stdin: `zz` then `a`) is rejected with
    `Invalid input` and re-asked; the run then deletes the selected matches;
28. mixed valid+invalid tokens (`1,zz` then `2`) keep the valid part
    (`Invalid input(s) ignored` warning, `Deleted=2`);
29. full-width (Chinese-IME) digits and comma (`1，2`) are accepted
    (`Deleted=2`, no warning).

## 10. Known macOS behaviors to encode/expect

- **BSD `find -name` is case-sensitive** regardless of filesystem case
  sensitivity — always use `-iname` for keyword pruning/matching.
- **`/var` → `/private/var`**: `realpath` canonicalization changes path forms;
  protection zones and `$HOME` guards must be canonicalized (`HOME_C`,
  `canonical_path`) to compare against canonical `find` output.
- **Firmlinks**: `/opt`, `/Applications`, `/Users`, `/Library` are APFS
  firmlinks into `/System/Volumes/Data`; root collapse drops the prefix, and
  whole-disk search results dedupe the aliases by canonical key (short form
  shown/deleted).
- **TCC**: folders like `~/Pictures`, `~/Desktop`, `~/Documents` may be
  TCC-protected; a terminal without Full Disk Access can fail to read them.
- **Trash**: `$HOME/.Trash` may not exist (tests create a fake HOME);
  cross-volume moves need the `osascript` Finder fallback.

## 11. Reproduce checklist

1. Write `scripts/search_delete.sh` per sections 2–8.
2. Write `tests/create_test_fixture.sh` and `tests/run_tests.sh` per section 9.
3. `chmod +x` all scripts; run `bash -n` on every file.
4. `tests/run_tests.sh` must report all `PASS` and no `FAIL`.
5. `./scripts/search_delete.sh --help` must render.
