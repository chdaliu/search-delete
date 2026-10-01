# Search & Delete（搜索即删）

macOS interactive tool to **search for files/folders by filename keyword and
delete them** — into the Trash (default, recoverable) or permanently — with a
bilingual (English / Chinese) interface, multi-keyword and multi-root support,
sudo for whole-disk search, built-in user-data protection zones, JSON
configuration, and automated testing.

```
scripts/
  search_delete.sh          # search by keyword and delete (trash / permanent)
docs/
  README.md                 # English
  README.zh-CN.md           # Chinese
tests/
  create_test_fixture.sh    # build a fixture covering every rule
  run_tests.sh              # automated assertions
AGENTS.md                   # reproducible build spec (English)
AGENTS.zh-CN.md             # reproducible build spec (Chinese)
```

## Requirements

- macOS (uses `find -iname`, `mv`, `rm`, `jq`, optionally `osascript` and
  `sudo`).
- `jq` (JSON config parsing).
- Whole-disk search (`--search`) automatically attempts `sudo`; deleting
  non-writable items needs `--sudo`.
- Compatible with the bash 3.2 shipped with macOS (no associative arrays, no
  `${var,,}` expansions).

## Quick start

```bash
# dry-run preview first (deletes nothing) — always do this before a real run
./scripts/search_delete.sh ~/Downloads --keyword "draft,tmp" --dry-run

# interactive: choose search root, keywords, mode, then confirm
./scripts/search_delete.sh ~/Downloads --keyword report

# one-shot non-interactive: move matches in ~/Downloads to the Trash
./scripts/search_delete.sh ~/Downloads --keyword "draft" --yes

# permanently delete (NOT recoverable) matches in several roots, non-interactive
./scripts/search_delete.sh ~/Downloads ~/Desktop --keyword "old copy" \
    --permanent --yes

# exact basename match, inside a directory, with extra protected path
./scripts/search_delete.sh ~/Documents --keyword Legacy --exact \
    --permanent --protect "~/Documents/Important"
```

## How it works

1. **Search roots** are where the search looks. They come from the command
   line (positional args), the config file (`searchRoots` array), or the
   interactive menu:
   - `1) enter one or more directories` (the delete search runs inside them),
   - `2) search the whole disk by keyword` — the results you select are
     **deleted directly** (see step 4).
   Overlapping roots are collapsed to the **outermost covering set** (with
   macOS firmlink/symlink alias canonicalization). There is no "no target"
   exit — the menu loops until at least one root or one selected result is
   given.
2. **Delete keywords** (`--keyword "k1,k2"`, comma separated or repeated)
   select the paths inside the search roots: a path whose **name** contains
   (or, with `--exact`, equals) any keyword is a match — a union across
   keywords, filename only. Interactive keywords are entered one per line.
   Keywords are only asked for when search roots exist.
3. The matches are stream-collapsed (a folder and everything inside it that
   matched appears once, as the folder), listed numbered, and you select
   (`a` = all, `c` = cancel, numbers/ranges; auto-selected under `--yes`).
   Numbers and ranges accumulate over several rounds until an empty line;
   invalid tokens are ignored with a warning while valid ones in the same
   line are kept. Full-width digits/comma typed with a Chinese IME are
   accepted as ASCII. The confirmation menu lists the selected paths before
   anything is deleted.
4. Paths selected from a **whole-disk keyword search** (`--search "k1,k2"`
   or menu option 2) become deletion candidates directly — no second
   keyword round, the selected paths are exactly what gets deleted.
   Firmlink aliases of the same path (`/Users/...` vs
   `/System/Volumes/Data/Users/...`) are shown as one entry, in the short
   form.
5. Candidates inside **user-data directories** are split out and need an
   extra confirmation round (see below). Everything else is deleted in the
   chosen mode after the confirmation menu.

## Delete modes

- `--trash` (default): moves items to `$HOME/.Trash`. Name collisions get a
  ` 2`/` 3` suffix (Finder style); cross-volume moves fall back to the Finder
  (`osascript`). Recoverable.
- `--permanent`: removes items with `rm -f` / `rm -rf`. **NOT recoverable.**
  An interactive run prints a warning and the confirmation menu still applies.

`--dry-run` previews everything and deletes nothing (the summary and log show
`(dry-run)`). `--yes` auto-confirms and auto-saves logs.

## Safety

A destructive tool is guarded by layers:

- **Hard blocks** (never deleted, even with `--yes`): the search roots
  themselves, their ancestors, `/`, `$HOME`, `.`/`..`, and critical system
  paths (`/System`, `/Applications`, `/Library`, `/opt`, `/usr`, `/private`,
  `/bin`, `/sbin`, `/etc`, `/var`, `/Volumes`). Blocked paths are counted and
  recorded.
- **User-data protection zones** (default, resolved against `$HOME`):
  `Documents`, `Downloads`, `Music`, `Movies`, `Pictures`, `Desktop`, `Public`.
  A match at or under one of these is only deleted after an **extra round**
  that lists the protected matches and asks you to pick which ones to delete —
  unselected ones are kept (counted `Protected`). `--allow-protected` is the
  explicit opt-in that skips the extra round; `--protect none` disables the
  zones entirely. `--protect "p1,p2"` adds extra protected paths (absolute,
  `~`, or a bare name under `$HOME`).
- Under **`--yes`** protected-zone matches are **always kept unless**
  `--allow-protected` was passed — automation can never silently delete user
  data.
- **The search descends into every directory by default** (caches, temp,
  logs, `node_modules`, `build`, `.git`, `.Trash`, ...): matches are shown so
  you can pick them, nothing is pre-filtered. Built-in cache/dev skipping is
  **opt-in** via `--skip-defaults yes`; `--skip "p1,p2"` adds extra
  basename/absolute paths to skip. Package folders (`.app`, `.library`, ...)
  have their contents pruned; a package whose **own name** matches is returned
  as a candidate.
- **Confirmation menu** always precedes execution in interactive mode:
  `1 confirm 2 modify 3 re-select 4 exit`. `--permanent` shows an extra warning.

## Keyword search (whole-disk search and matches)

- `--search "k1,k2"` whole-disk: attempts sudo automatically (the only
  password prompt is sudo's own; `--yes` uses `sudo -n`). Without sudo it
  falls back to `$HOME`, `/opt` and `/Applications`. The selected results are
  deleted directly (protection zones and hard blocks still apply).
- `--sudo` also enables deleting non-writable items via sudo.
- `--exact` matches the full basename instead of a substring.
- Multi-keyword means **union** (a path matches any keyword).

## sudo

`ensure_sudo()`: already root → ok; `--yes` → `sudo -n` silently; otherwise
`sudo -v` prompts once — before the interactive prompt the script explains why
the password is needed and that it is not displayed. Sudo is used to (a) read
all locations during a whole-disk search and (b) delete items the current user
cannot write to (`sudo rm` / `sudo mv`). Before execution the credential cache
is refreshed with `sudo -v` so a long run does not re-prompt mid-way.

## Config

`search_delete.config.json` is read from / written to `--saveDir` (default:
project root). Schema:

```json
{
  "language": "en",
  "searchRoots": ["/path"],
  "keywords": ["report"],
  "exact": false,
  "mode": "trash",
  "protect": [],
  "allowProtected": false,
  "skipDefaults": false,
  "skip": [],
  "saveDir": "",
  "logLevel": "all"
}
```

Precedence: **command line > config file > defaults**. Choosing a value equal
to a built-in default is not a config change, so a target-only run never asks
to save. Under `--yes` config is never written.

## Non-interactive mode

Pass everything on the command line and add `--yes` (auto-confirm, auto-save
logs, never prompt; protected matches are kept unless `--allow-protected`).
With no keyword on the command line the script requires at least one (exit
non-zero otherwise). `--dry-run` is always safe to script.

## Logging

`--logLevel all|changes|none` (default `all`) controls console output; the
summary is always printed. An operation log is written to
`<saveDir or project root>/log/search_delete_log_<timestamp>_deleted_<N>.log`
whenever anything was deleted **or** any failure/block/protected-keep happened
— failures are never lost silently. The log records: deleted/trashed paths,
errors (failed to delete), blocked paths, protected (kept) paths, skipped
paths, and the summary.

## Testing

```bash
tests/create_test_fixture.sh   # rebuild tests/fixture (all cases)
tests/run_tests.sh             # automated checks, non-zero exit on failure
```

The fixture is also a fake `$HOME` (contains `Documents`, `Downloads`, ...)
so protection-zone tests run hermetically. Permanent deletion is only ever
exercised on copies inside `tests/out`.
