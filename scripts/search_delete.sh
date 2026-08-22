#!/bin/bash
# search_delete.sh
#
# Interactive macOS tool to search for files/folders by filename keyword and
# delete them — into the Trash (default) or permanently. Includes multi-keyword
# matching, multi-target (search root) support, sudo for whole-disk search and
# non-writable items, user-data protection zones (Documents/Downloads/...), and
# a bilingual (English / Chinese) interface with JSON configuration.
#
# Usage:
#   ./search_delete.sh [<searchRoot>...] --keyword "k1,k2" [options]
#
# The script is intentionally compatible with the bash 3.2 shipped with macOS
# (no associative arrays, no ${var,,} style expansions).

# LC_ALL is intentionally NOT exported globally: a global "C" locale makes the
# terminal treat multi-byte input (Chinese) byte-by-byte, so backspace cannot
# erase a whole character and leftover bytes stay on the input line. Commands
# that need byte/C semantics (find, tr, sed) set LC_ALL=C locally instead.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_CONFIG_NAME="search_delete.config.json"

# ---------------------------------------------------------------------------
# Configuration state
# ---------------------------------------------------------------------------
LANGUAGE="en"
TARGETS=()          # resolved search roots (outermost covering set)
CURRENT_TARGET=""   # search root currently being executed
KEYWORDS=()         # delete keywords (a path matches if its name matches any)
EXACT="no"          # exact basename match instead of substring
MODE="trash"        # trash | permanent
ALLOW_PROTECTED="no"  # explicit opt-in to delete protected-zone matches
PROTECT_NONE="no"     # --protect none disables all protection zones
PROTECT=()          # user extra protected paths (absolute / ~ / bare name)
PROTECTED_PATHS=()  # resolved protection zone paths
TRAVERSAL="no"      # at least one search root is a directory
SUDO_OK="no"        # sudo obtained (search or --sudo)
YES="no"            # non-interactive: auto-confirm, auto-save logs
DRY_RUN="no"        # preview only
SKIP_DEFAULTS="yes"
SKIP=()
SAVE_DIR=""
LOG_LEVEL="all"
CONFIG_FILE=""
HAS_CONFIG="no"

# Built-in defaults (used to decide whether a config change really happened).
DEF_LANGUAGE="en"
DEF_EXACT="no"
DEF_MODE="trash"
DEF_ALLOW="no"
DEF_PROTECT_NONE="no"
DEF_SD="yes"
DEF_SAVE_DIR=""
DEF_LOG="all"

# Flags and values telling what came from the command line (overrides config)
CLI_LANGUAGE="no"
CLI_TARGET="no"
CLI_SEARCH="no"
CLI_SEARCH_KW=""
CLI_KEYWORD="no"
CLI_EXACT="no"
CLI_MODE="no"
CLI_ALLOW="no"
CLI_PROTECT="no"
CLI_SKIP="no"
CLI_SD="no"
CLI_SAVEDIR="no"
CLI_LOG="no"
CLI_TARGET_VALS=()
CLI_KEYWORD_VALS=()
CLI_SKIP_VALS=()

# macOS user-data folders protected by default. Paths at/under one of these
# (resolved against $HOME) require an extra confirmation round before deletion.
DEFAULT_PROTECT_NAMES=(Documents Downloads Music Movies Pictures Desktop Public)

# Built-in skip rules: same two flavours as the time-setter project.
#   keywords - matched against the basename of any entry (case-insensitive)
#   paths    - matched against the full path
DEFAULT_SKIP_KEYWORDS=(node_modules npm .npm build dist out output target .build \
                       deriveddata pods carthage developer crashreporter crashreports \
                       diagnosticreports diagnostics debug .git .svn .hg \
                       caches cache tmp .tmp temp .trash trash temporaryitems \
                       logs .cache .caches "saved application state" \
                       .cocoapods .gradle .m2 .cargo .swiftpm .venv venv __pycache__ \
                       .pytest_cache .mypy_cache .ruff_cache .idea .terraform .yarn \
                       .pnpm-store .bundle .composer .conan)
DEFAULT_SKIP_PATHS=("~/Library/Developer/Xcode/DerivedData" \
                    "~/Library/Mobile Documents" \
                    "~/Library/CloudStorage" \
                    "~/Library/Logs/DiagnosticReports" \
                    "~/Library/Logs/CrashReporter" \
                    "~/Library/Diagnostics" \
                    "~/Library/Application Support/MobileSync/Backup" \
                    "~/Library/Group Containers/UBF8T346G9.Office/Outlook/Outlook 15 Profiles/Main Profile/Osa" \
                    "var/folders")

# Critical system paths never deletable (equal or ancestor).
SYSTEM_GUARDS=(/System /Applications /Library /opt /usr /private /bin /sbin /etc /var /Volumes)

# Counters and records
FOUND_N=0
DELETED_N=0
TRASHED_N=0
PROTECTED_N=0
SKIP_N=0
BLOCKED_N=0
ERROR_N=0
PROCESSED_N=0
CANDIDATES=()       # selected deletion candidates
DIRECT_CANDIDATES=() # paths selected from the whole-disk keyword search (deleted as-is)
PROTECTED_ITEMS=()  # selected candidates inside protection zones
PLAIN_ITEMS=()      # selected candidates outside protection zones

LOGFILE=""
TMPD=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
lower() { printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'; }

# Map full-width (Chinese-IME) digits, comma, ideographic comma, ideographic
# space and full-width lower-case letters to their ASCII equivalents, so
# numeric/selection menus accept inputs typed with a Chinese IME. Other
# multibyte characters (e.g. real full-width letters in keywords/paths) are
# left untouched. Only applied to numeric/selection/yes-no inputs, never to
# keyword or path text.
normalize_ascii() {
  printf '%s' "$1" | LC_ALL=C sed 's/０/0/g;s/１/1/g;s/２/2/g;s/３/3/g;s/４/4/g;s/５/5/g;s/６/6/g;s/７/7/g;s/８/8/g;s/９/9/g;s/，/,/g;s/、/,/g;s/；/,/g;s/：/,/g;s/　/ /g;s/－/-/g;s/–/-/g;s/—/-/g;s/ａ/a/g;s/ｂ/b/g;s/ｃ/c/g;s/ｄ/d/g;s/ｅ/e/g;s/ｆ/f/g;s/ｇ/g/g;s/ｈ/h/g;s/ｉ/i/g;s/ｊ/j/g;s/ｋ/k/g;s/ｌ/l/g;s/ｍ/m/g;s/ｎ/n/g;s/ｏ/o/g;s/ｐ/p/g;s/ｑ/q/g;s/ｒ/r/g;s/ｓ/s/g;s/ｔ/t/g;s/ｕ/u/g;s/ｖ/v/g;s/ｗ/w/g;s/ｘ/x/g;s/ｙ/y/g;s/ｚ/z/g'
}

normalize_yn() {
  case "$(lower "$1")" in
    yes|y|true|1|on)  echo "yes";;
    no|n|false|0|off) echo "no";;
    *)                echo "$1";;
  esac
}

yn_short() {
  case "$1" in
    yes) echo "y";;
    *)   echo "n";;
  esac
}

check_exit() {
  if [ "$(lower "$(normalize_ascii "$ASK_VAL")")" = "exit" ]; then
    echo "$(msg exit_msg)"
    exit 0
  fi
}

# ---------------------------------------------------------------------------
# Message tables (English / Chinese)
# ---------------------------------------------------------------------------
msg_en() {
  case "$1" in
    lang_prompt)        echo "Display language";;
    lang_supported)     echo "Supported language inputs:";;
    lang_en)            echo "English";;
    lang_zh)            echo "Chinese";;
    no_target)          echo "No search root or selected result provided.";;
    target_invalid)     echo "Path does not exist or is not readable.";;
    target_source_choice) echo "Choose a search-root source (1-2, exit = cancel)";;
    target_mode_addpath)  echo "1) Enter one or more directories (delete searches inside them)";;
    target_mode_searchdisk) echo "2) Search the whole disk by keyword (selected results are deleted directly)";;
    target_cancel)      echo "(exit = cancel)";;
    target_paths_intro) echo "Enter search root directories, one per line (paths may be relative, absolute or ~). Empty line to finish.";;
    target_path_entry)  echo "Search root";;
    target_need_one)    echo "At least one search root or one selected result is required. Keep entering.";;
    target_current)     echo "Current search roots:";;
    target_collapsed)   echo "Final search roots (outermost covering set):";;
    delete_keyword_hint) echo "Enter delete keywords (matched against file/folder names), one per line. Empty line to finish.";;
    delete_keyword_prompt) echo "Delete keyword";;
    delete_keyword_need)  echo "At least one delete keyword is required.";;
    search_keyword_prompt) echo "Keyword to search";;
    search_keyword_hint)  echo "Enter search keywords, one per line. Empty line to finish.";;
    search_running)     echo "Searching %s (may take a while)...";;
    search_sudo_ok)     echo "Sudo permission obtained.";;
    sudo_hint)          echo "Whole-disk search / sudo setting needs administrator (sudo) privileges. Enter your macOS password at the prompt (it will not be displayed).";;
    sudo_unavailable)   echo "Could not obtain sudo; non-writable items will be skipped.";;
    search_fallback)    echo "Falling back to accessible locations: %s";;
    search_no_results)  echo "No matching results.";;
    search_results)     echo "%d result(s) found (showing %d):";;
    search_truncated)   echo "... and %d more (not shown).";;
    search_select)      echo "Select results (numbers/ranges, 'a' = all, 'c' = cancel, empty = done)";;
    search_added)       echo "%d path(s) selected for deletion.";;
    search_cancelled)   echo "Cancelled.";;
    matched_show)       echo "%d path(s) match the keyword(s):";;
    matched_selected)   echo "%d path(s) selected.";;
    exact_prompt)       echo "Exact name match only (no substring)";;
    mode_prompt)        echo "Delete mode";;
    mode_trash)         echo "trash (move to Trash, recoverable)";;
    mode_permanent)     echo "permanent (rm, NOT recoverable)";;
    protect_prompt)     echo "Extra protected path ('clear' empties the list, 'none' disables protection)";;
    protect_hint)       echo "Add extra user-data paths to protect. Empty line to finish.";;
    protect_none_note)  echo "Protection zones disabled by the user.";;
    allow_protected_prompt) echo "Delete matches inside user-data directories (Documents/Downloads/...)" ;;
    protected_warn)     echo "The following match user-data directories and are protected:";;
    protected_select)   echo "Select which protected items to delete (numbers/ranges, 'a' = all, empty/'c' = keep all):";;
    protected_kept_all) echo "Kept %d protected item(s).";;
    protected_selected_all) echo "Selected all %d protected item(s).";;
    skip_defaults_prompt) echo "Skip built-in Mac cache/temp directories (Caches, tmp, .Trash, Logs, ...)";;
    skip_list_intro)    echo "Enter paths to skip (basename or absolute). Empty line to finish.";;
    skip_entry_prompt)  echo "Skip item ('clear' empties the list)";;
    skip_list_cleared)  echo "Skip list cleared.";;
    confirm_menu)       echo "1) Confirm and execute  2) Modify an option  3) Re-select  4) Exit";;
    confirm_choice)     echo "Your choice";;
    edit_prompt)        echo "Option to modify (1=language 2=keywords 3=exact 4=mode 5=protect 6=allowProtected 7=skipDefaults 8=skip 9=saveDir 10=logLevel; Enter to return)";;
    invalid_choice)     echo "Invalid choice.";;
    invalid_input)      echo "Invalid input.";;
    invalid_tokens)     echo "Invalid input(s) ignored (valid ones kept): %s";;
    retry_or_exit)      echo "Too many invalid attempts. Retry or exit? (r=retry, e=exit)";;
    exit_msg)           echo "Exiting.";;
    input_closed)       echo "Input closed (EOF). Exiting.";;
    done)               echo "Done.";;
    show_config)        echo "Current configuration:";;
    cfg_roots)          echo "Search roots";;
    cfg_candidates)     echo "Selected for deletion";;
    cfg_keywords)       echo "Keywords";;
    cfg_exact)          echo "Exact match";;
    cfg_mode)           echo "Delete mode";;
    cfg_protect)        echo "Protect list";;
    cfg_allow)          echo "Allow protected";;
    cfg_skip_defaults)  echo "Skip built-in cache/temp";;
    cfg_skip)           echo "Skip list";;
    cfg_save_dir)       echo "Config save dir";;
    cfg_log_level)      echo "Log level";;
    yn_note)            echo "y = yes, n = no";;
    save_script_dir)    echo "(script directory)";;
    skip_list_empty)    echo "(none)";;
    dry_run_on)         echo "DRY-RUN mode: nothing will be deleted.";;
    permanent_warn)     echo "WARNING: PERMANENT mode. Deleted files cannot be recovered.";;
    blocked_reason)     echo "blocked (search root / system path)";;
    log_deleted)        echo "[deleted]";;
    log_trashed)        echo "[trashed]";;
    log_error)          echo "[error]";;
    log_blocked)        echo "[blocked]";;
    log_protected)      echo "[protected]";;
    log_skipped)        echo "[skipped]";;
    summary_title)      echo "===== Execution Summary =====";;
    summary_roots)      echo "Search roots";;
    summary_keywords)   echo "Keywords";;
    summary_mode)       echo "Mode";;
    summary_matched)    echo "Matched";;
    summary_protected)  echo "Protected (kept)";;
    summary_blocked)    echo "Blocked";;
    summary_deleted)    echo "Deleted";;
    summary_trashed)    echo "Trashed";;
    summary_errors)     echo "Errors";;
    summary_skipped)    echo "Skipped";;
    summary_elapsed)    echo "Elapsed";;
    summary_dry)        echo "(dry-run, nothing modified)";;
    default_hint)       echo "[default: %s]";;
    log_ask)            echo "%d item(s) removed. Save an operation log?";;
    log_saved)          echo "Log saved to";;
    log_header)         echo "===== Operation Log =====";;
    log_completed_at)   echo "Completed at";;
    log_deleted_list)   echo "Deleted / trashed";;
    log_errors_list)    echo "Errors (failed to delete)";;
    log_blocked_list)   echo "Blocked (never deletable)";;
    log_protected_list) echo "Protected (kept)";;
    log_skipped_list)   echo "Skipped (not writable / not selected)";;
    save_ask)           echo "Configuration changed. Update or save it?";;
    save_menu)          echo "1) Update original config file  2) Save as new  3) Don't save";;
    save_menu_new)      echo "1) Save as new config  2) Don't save";;
    config_saved)       echo "Configuration saved to";;
    config_not_saved)   echo "Configuration not saved.";;
    config_no_change)   echo "Configuration unchanged - not saved.";;
    jq_missing)         echo "jq command not found. Please install jq and retry.";;
    usage_keyword)      echo "Keyword(s) to match file/folder names (comma separated or repeated)";;
  esac
}

msg_zh() {
  case "$1" in
    lang_prompt)        echo "选择显示语言";;
    lang_supported)     echo "支持的语言输入：";;
    lang_en)            echo "英语";;
    lang_zh)            echo "中文";;
    no_target)          echo "未提供搜索根目录或选中结果。";;
    target_invalid)     echo "路径不存在或不可读。";;
    target_source_choice) echo "选择搜索根来源（1-2，exit=取消）";;
    target_mode_addpath)  echo "1) 输入一个或多个目录（删除将在其内按关键字搜索）";;
    target_mode_searchdisk) echo "2) 全盘按关键字搜索（选中的结果将直接删除）";;
    target_cancel)      echo "（exit = 取消）";;
    target_paths_intro) echo "请输入搜索根目录，每行一个（可为相对/绝对/~ 路径）。空行结束。";;
    target_path_entry)  echo "搜索根目录";;
    target_need_one)    echo "至少需要一个搜索根目录或一个选中结果，请继续输入。";;
    target_current)     echo "当前搜索根目录：";;
    target_collapsed)   echo "最终搜索根目录（最外层覆盖集）：";;
    delete_keyword_hint) echo "请输入删除关键字（按文件名匹配），每行一个。空行结束。";;
    delete_keyword_prompt) echo "删除关键字";;
    delete_keyword_need)  echo "至少需要一个删除关键字。";;
    search_keyword_prompt) echo "搜索关键字";;
    search_keyword_hint)  echo "请输入搜索关键字，每行一个。空行结束。";;
    search_running)     echo "正在搜索 %s（可能需要一些时间）...";;
    search_sudo_ok)     echo "已获取 sudo 权限。";;
    sudo_hint)          echo "全盘搜索 / sudo 设置需要管理员（sudo）权限。请在出现提示时输入你的 macOS 密码（输入时不会显示）。";;
    sudo_unavailable)   echo "无法获取 sudo，无写权限项将被跳过。";;
    search_fallback)    echo "回退到有权限的位置搜索：%s";;
    search_no_results)  echo "没有匹配的结果。";;
    search_results)     echo "找到 %d 个结果（显示 %d 个）：";;
    search_truncated)   echo "... 另有 %d 个未显示。";;
    search_select)      echo "选择结果（编号/范围，a=全部，c=取消，空行=完成）";;
    search_added)       echo "已选择 %d 个待删除路径。";;
    search_cancelled)   echo "已取消。";;
    matched_show)       echo "有 %d 个路径命中关键字：";;
    matched_selected)   echo "已选中 %d 个路径。";;
    exact_prompt)       echo "仅精确匹配名称（不含子串）";;
    mode_prompt)        echo "删除模式";;
    mode_trash)         echo "trash（移入废纸篓，可恢复）";;
    mode_permanent)     echo "permanent（rm 永久删除，不可恢复）";;
    protect_prompt)     echo "额外保护路径（输入 clear 清空清单，输入 none 关闭保护）";;
    protect_hint)       echo "请输入额外的用户数据保护路径。空行结束。";;
    protect_none_note)  echo "保护区域已被用户关闭。";;
    allow_protected_prompt) echo "是否删除用户数据目录（Documents/Downloads 等）内的匹配项" ;;
    protected_warn)     echo "以下匹配项位于用户数据目录，已受保护：";;
    protected_select)   echo "选择要删除的保护区项（编号/范围，a=全部，空行/c=全部保留）：";;
    protected_kept_all) echo "已保留 %d 个保护区项。";;
    protected_selected_all) echo "已选择全部 %d 个保护区项。";;
    skip_defaults_prompt) echo "是否跳过内置的 Mac 缓存/临时目录（Caches、tmp、.Trash、Logs 等）";;
    skip_list_intro)    echo "请输入要跳过的路径（basename 或绝对路径）。空行结束。";;
    skip_entry_prompt)  echo "跳过项（输入 clear 清空清单）";;
    skip_list_cleared)  echo "跳过清单已清空。";;
    confirm_menu)       echo "1) 确认并执行  2) 修改选项  3) 重新选择  4) 退出";;
    confirm_choice)     echo "请选择";;
    edit_prompt)        echo "要修改的选项（1=语言 2=关键字 3=精确 4=模式 5=保护 6=允许保护区 7=内置跳过 8=跳过清单 9=保存目录 10=日志级别；回车返回）";;
    invalid_choice)     echo "选择无效。";;
    invalid_input)      echo "输入无效。";;
    invalid_tokens)     echo "无效输入已忽略（保留有效项）：%s";;
    retry_or_exit)      echo "连续无效次数过多。重试还是退出？（r=重试，e=退出）";;
    exit_msg)           echo "退出。";;
    input_closed)       echo "输入已关闭（EOF）。退出。";;
    done)               echo "完成。";;
    show_config)        echo "当前配置：";;
    cfg_roots)          echo "搜索根目录";;
    cfg_candidates)     echo "待删除选中项";;
    cfg_keywords)       echo "关键字";;
    cfg_exact)          echo "精确匹配";;
    cfg_mode)           echo "删除模式";;
    cfg_protect)        echo "保护清单";;
    cfg_allow)          echo "允许保护区";;
    cfg_skip_defaults)  echo "内置缓存/临时跳过";;
    cfg_skip)           echo "跳过清单";;
    cfg_save_dir)       echo "配置保存目录";;
    cfg_log_level)      echo "日志级别";;
    yn_note)            echo "y 代表 yes，n 代表 no";;
    save_script_dir)    echo "（脚本所在目录）";;
    skip_list_empty)    echo "（无）";;
    dry_run_on)         echo "DRY-RUN 模式：不会删除任何内容。";;
    permanent_warn)     echo "警告：PERMANENT 模式。删除的文件无法恢复。";;
    blocked_reason)     echo "已拦截（搜索根/系统路径）";;
    log_deleted)        echo "[已删]";;
    log_trashed)        echo "[已入废纸篓]";;
    log_error)          echo "[错误]";;
    log_blocked)        echo "[已拦截]";;
    log_protected)      echo "[保护区保留]";;
    log_skipped)        echo "[跳过]";;
    summary_title)      echo "══════ 执行总结 ══════";;
    summary_roots)      echo "搜索根目录";;
    summary_keywords)   echo "关键字";;
    summary_mode)       echo "模式";;
    summary_matched)    echo "匹配";;
    summary_protected)  echo "保护区保留";;
    summary_blocked)    echo "已拦截";;
    summary_deleted)    echo "已删除";;
    summary_trashed)    echo "已入废纸篓";;
    summary_errors)     echo "失败";;
    summary_skipped)    echo "跳过";;
    summary_elapsed)    echo "耗时";;
    summary_dry)        echo "（dry-run，未做任何修改）";;
    default_hint)       echo "[默认: %s]";;
    log_ask)            echo "已删除 %d 项。是否保存操作日志？";;
    log_saved)          echo "日志已保存到";;
    log_header)         echo "══════ 操作日志 ══════";;
    log_completed_at)   echo "完成时间";;
    log_deleted_list)   echo "已删除 / 已入废纸篓";;
    log_errors_list)    echo "失败（删除未成功）";;
    log_blocked_list)   echo "已拦截（绝不可删）";;
    log_protected_list) echo "保护区保留";;
    log_skipped_list)   echo "跳过（无写权限/未选中）";;
    save_ask)           echo "配置已变更，是否更新或保存？";;
    save_menu)          echo "1) 更新原配置文件  2) 另存为新配置  3) 不保存";;
    save_menu_new)      echo "1) 另存为新配置  2) 不保存";;
    config_saved)       echo "配置已保存到";;
    config_not_saved)   echo "配置未保存。";;
    config_no_change)   echo "配置无变更，未保存。";;
    jq_missing)         echo "未找到 jq 命令，请先安装 jq。";;
    usage_keyword)      echo "匹配文件/文件夹名称的关键字（逗号分隔或重复指定）";;
  esac
}

msg() {
  local key="$1" s
  shift
  if [ "$LANGUAGE" = "zh" ]; then s="$(msg_zh "$key")"; else s="$(msg_en "$key")"; fi
  if [ $# -gt 0 ]; then printf "$s" "$@"; else printf '%s' "$s"; fi
}

# Prompt the user; $1=message key, $2=default value. Result in $ASK_VAL.
# Exits cleanly when stdin closes (EOF).
ask() {
  local key="$1" def="$2" p
  shift 2
  p="$(msg "$key" "$@")"
  if [ -n "$def" ]; then p="$p $(msg default_hint "$def")"; fi
  p="$p: "
  if ! read -e -r -p "$p" ASK_VAL <&9; then
    echo ""
    echo "$(msg input_closed)"
    exit 1
  fi
  check_exit
}

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: search_delete.sh [<searchRoot>...] --keyword "k1,k2" [options]

Searches one or more search-root directories for files/folders whose name
matches any keyword (substring by default, exact with --exact) and deletes the
selected matches into the Trash (default) or permanently. A whole-disk keyword
search can also select paths to delete directly (no keyword round inside
them). User-data directories (Documents/Downloads/Music/Movies/Pictures/
Desktop/Public) are protected: matches inside them are only deleted after an
extra confirmation round (or with --allow-protected). Everything is
safe-guarded: the search roots themselves, their ancestors and critical system
paths are never deleted.

Options:
  -k, --keyword LIST      Delete keywords (comma separated or repeated)
  --exact                 Exact basename match (no substring)
  --trash                 Move matches to the Trash (default)
  --permanent             Permanently delete with rm (NOT recoverable)
  --search "kw1,kw2"      Whole-disk keyword search; selected results are
                          deleted directly (no second keyword round)
  --protect "p1,p2"       Extra protected paths (absolute, ~ or bare name);
                          "none" disables all protection zones
  --allow-protected       Allow deleting matches inside protected zones (explicit)
  --skip "a,b,c"          Extra paths to skip (comma separated)
  --skip-defaults yes|no  Skip built-in cache/temp dirs (default: yes)
  --sudo                  Set/delete non-writable items via sudo
  --saveDir DIR           Directory for saving the config (default: script dir)
  --logLevel all|changes|none   Log verbosity (default: all)
  --language en|zh        Display language (default: en)
  --dry-run               Preview only, delete nothing
  --yes                   Non-interactive: auto-confirm, auto-save logs
  -c, --config FILE       JSON config file to read from / write to
  -h, --help              Show this help

Search-root sources (interactive, when none given):
  1) enter one or more directories (the delete search runs inside them),
  2) whole-disk keyword search (needs sudo; falls back to accessible
     locations); the selected results are deleted directly.
Overlapping roots are collapsed to the outermost covering set.
EOF
}

# ---------------------------------------------------------------------------
# Interactive prompts
# ---------------------------------------------------------------------------
prompt_language() {
  local attempts=0 val
  while :; do
    echo "$(msg lang_supported)"
    echo "  en / english        -> $(msg lang_en)"
    echo "  zh / chinese / 中文  -> $(msg lang_zh)"
    ask lang_prompt "$LANGUAGE"
    val="$(lower "$(normalize_ascii "$ASK_VAL")")"
    case "$val" in
      "")               return 0;;
      en|english)       LANGUAGE="en"; return 0;;
      zh|chinese|中文)    LANGUAGE="zh"; return 0;;
    esac
    echo "$(msg invalid_input)"
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 3 ]; then
      ask retry_or_exit ""
      [ "$(lower "$(normalize_ascii "$ASK_VAL")")" = "e" ] && { echo "$(msg exit_msg)"; exit 0; }
      attempts=0
    fi
  done
}

prompt_keywords() {
  local kw
  while :; do
    echo "$(msg delete_keyword_hint)"
    KEYWORDS=()
    while :; do
      ask delete_keyword_prompt ""
      kw="$ASK_VAL"
      [ -z "$kw" ] && break
      KEYWORDS=("${KEYWORDS[@]}" "$kw")
    done
    [ "${#KEYWORDS[@]}" -gt 0 ] && return 0
    echo "$(msg delete_keyword_need)"
  done
}

prompt_exact() {
  local attempts=0 val
  while :; do
    ask exact_prompt "$(yn_short "$EXACT")"
    val="$(lower "$(normalize_ascii "$ASK_VAL")")"
    case "$val" in
      "")                   return 0;;
      y|yes|true|1|on)      EXACT="yes"; return 0;;
      n|no|false|0|off)     EXACT="no";  return 0;;
    esac
    echo "$(msg invalid_input)"
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 3 ]; then
      ask retry_or_exit ""
      [ "$(lower "$(normalize_ascii "$ASK_VAL")")" = "e" ] && { echo "$(msg exit_msg)"; exit 0; }
      attempts=0
    fi
  done
}

prompt_mode() {
  local attempts=0 val
  while :; do
    echo "  1) $(msg mode_trash)"
    echo "  2) $(msg mode_permanent)"
    ask mode_prompt "$MODE"
    val="$(lower "$(normalize_ascii "$ASK_VAL")")"
    case "$val" in
      "")                     return 0;;
      trash|1)                MODE="trash"; return 0;;
      permanent|2)            MODE="permanent"; return 0;;
    esac
    echo "$(msg invalid_input)"
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 3 ]; then
      ask retry_or_exit ""
      [ "$(lower "$(normalize_ascii "$ASK_VAL")")" = "e" ] && { echo "$(msg exit_msg)"; exit 0; }
      attempts=0
    fi
  done
}

prompt_protect() {
  echo "$(msg protect_hint)"
  if [ "${#PROTECT[@]}" -gt 0 ]; then
    echo "  $(msg cfg_protect): ${PROTECT[*]}"
  fi
  while :; do
    ask protect_prompt ""
    [ -z "$ASK_VAL" ] && break
    if [ "$(lower "$ASK_VAL")" = "clear" ]; then
      PROTECT=()
      echo "$(msg skip_list_cleared)"
      continue
    fi
    if [ "$(lower "$ASK_VAL")" = "none" ]; then
      PROTECT_NONE="yes"
      echo "$(msg protect_none_note)"
      continue
    fi
    PROTECT=("${PROTECT[@]}" "$ASK_VAL")
  done
}

prompt_allow_protected() {
  local attempts=0 val
  while :; do
    ask allow_protected_prompt "$(yn_short "$ALLOW_PROTECTED")"
    val="$(lower "$(normalize_ascii "$ASK_VAL")")"
    case "$val" in
      "")                   return 0;;
      y|yes|true|1|on)      ALLOW_PROTECTED="yes"; return 0;;
      n|no|false|0|off)     ALLOW_PROTECTED="no";  return 0;;
    esac
    echo "$(msg invalid_input)"
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 3 ]; then
      ask retry_or_exit ""
      [ "$(lower "$(normalize_ascii "$ASK_VAL")")" = "e" ] && { echo "$(msg exit_msg)"; exit 0; }
      attempts=0
    fi
  done
}

prompt_skip_defaults() {
  local attempts=0 val
  while :; do
    ask skip_defaults_prompt "$(yn_short "$SKIP_DEFAULTS")"
    val="$(lower "$(normalize_ascii "$ASK_VAL")")"
    case "$val" in
      "")                   return 0;;
      y|yes|true|1|on)      SKIP_DEFAULTS="yes"; return 0;;
      n|no|false|0|off)     SKIP_DEFAULTS="no";  return 0;;
    esac
    echo "$(msg invalid_input)"
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 3 ]; then
      ask retry_or_exit ""
      [ "$(lower "$(normalize_ascii "$ASK_VAL")")" = "e" ] && { echo "$(msg exit_msg)"; exit 0; }
      attempts=0
    fi
  done
}

prompt_skip_list() {
  echo "$(msg skip_list_intro)"
  if [ "${#SKIP[@]}" -gt 0 ]; then
    echo "  $(msg cfg_skip): ${SKIP[*]}"
  fi
  while :; do
    ask skip_entry_prompt ""
    [ -z "$ASK_VAL" ] && break
    if [ "$(lower "$ASK_VAL")" = "clear" ]; then
      SKIP=()
      echo "$(msg skip_list_cleared)"
      continue
    fi
    SKIP=("${SKIP[@]}" "$ASK_VAL")
  done
}

prompt_save_dir() {
  local def
  if [ -n "$SAVE_DIR" ]; then def="$SAVE_DIR"; else def="$SCRIPT_DIR"; fi
  ask save_dir_prompt "$def"
  if [ -z "$ASK_VAL" ]; then SAVE_DIR=""; else SAVE_DIR="$ASK_VAL"; fi
}

prompt_log_level() {
  local attempts=0 val
  while :; do
    ask log_prompt "$LOG_LEVEL"
    val="$(lower "$(normalize_ascii "$ASK_VAL")")"
    case "$val" in
      "")          return 0;;
      all)         LOG_LEVEL="all";    return 0;;
      changes)     LOG_LEVEL="changes"; return 0;;
      none)        LOG_LEVEL="none";   return 0;;
    esac
    echo "$(msg invalid_input)"
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 3 ]; then
      ask retry_or_exit ""
      [ "$(lower "$(normalize_ascii "$ASK_VAL")")" = "e" ] && { echo "$(msg exit_msg)"; exit 0; }
      attempts=0
    fi
  done
}

# ---------------------------------------------------------------------------
# Path normalization / canonicalization (for search roots only)
# ---------------------------------------------------------------------------
normalize_target_path() {
  local p="$1" out unesc
  case "$p" in
    "")   return 1;;
    ~*)   out="${HOME:-$(printf '%s' ~)}${p#\~}";;
    *)    out="$p";;
  esac
  out="${out%/}"
  [ -n "$out" ] || out="/"
  if [ ! -e "$out" ]; then
    unesc="$(printf '%s' "$out" | sed 's/\\\(.\)/\1/g')"
    if [ -n "$unesc" ] && [ "$unesc" != "$out" ] && [ -e "$unesc" ]; then
      out="$unesc"
    fi
  fi
  printf '%s' "$out"
}

target_is_valid() {
  [ -e "$1" ] && [ -r "$1" ]
}

canonicalize_dir() {
  local d="$1" cand rp
  case "$d" in
    /System/Volumes/Data/*)
      cand="/${d#/System/Volumes/Data/}"
      [ -e "$cand" ] && d="$cand";;
  esac
  if command -v realpath >/dev/null 2>&1; then
    rp=$(realpath "$d" 2>/dev/null) && [ -n "$rp" ] && d="$rp"
  fi
  printf '%s' "$d"
}

canonical_path() {
  local p="$1" dir bn
  if [ -d "$p" ]; then
    canonicalize_dir "$p"
  else
    dir="${p%/*}"
    bn="${p##*/}"
    [ -z "$dir" ] && dir="/"
    printf '%s/%s' "$(canonicalize_dir "$dir")" "$bn"
  fi
}

# Collapse a list of paths (one per line in $1) to the outermost covering set:
# canonicalize, drop duplicates and any path that lies inside another.
collapse_file() {
  local in="$1" out="$2"
  local line a b keep raw=() canon=() dedup=() final=()
  while IFS= read -r line; do
    raw=("${raw[@]}" "$line")
  done < "$in"
  for a in "${raw[@]}"; do
    canon=("${canon[@]}" "$(canonical_path "$a")")
  done
  for a in "${canon[@]}"; do
    keep=1
    for b in "${dedup[@]}"; do
      [ "$a" = "$b" ] && keep=0
    done
    [ "$keep" = "1" ] && dedup=("${dedup[@]}" "$a")
  done
  for a in "${dedup[@]}"; do
    keep=1
    for b in "${dedup[@]}"; do
      [ "$a" = "$b" ] && continue
      if [[ "$a" == "$b"/* ]]; then keep=0; fi
    done
    [ "$keep" = "1" ] && final=("${final[@]}" "$a")
  done
  : > "$out"
  for a in "${final[@]}"; do printf '%s\n' "$a"; done >> "$out"
}

collapse_targets() {
  local i
  : > "$TMPD/roots.in"
  for i in "${TARGETS[@]}"; do printf '%s\n' "$i"; done > "$TMPD/roots.in"
  collapse_file "$TMPD/roots.in" "$TMPD/roots.out"
  TARGETS=()
  while IFS= read -r i; do
    TARGETS=("${TARGETS[@]}" "$i")
  done < "$TMPD/roots.out"
}

set_traversal() {
  local t
  TRAVERSAL="no"
  for t in "${TARGETS[@]}"; do
    if [ -d "$t" ] && [ ! -L "$t" ]; then TRAVERSAL="yes"; fi
  done
}

# ---------------------------------------------------------------------------
# Skip tables
# ---------------------------------------------------------------------------
# A search root that is itself a skip target (its basename equals a skip
# keyword, or it is at/under a resolved skip path) is still searched: the
# covering rule is waived for that root.
is_root_covered_by_keyword() {
  [ "$(lower "${1##*/}")" = "$(lower "$2")" ]
}

is_root_covered_by_path() {
  [ "$1" = "$2" ] || [[ "$1" == "$2"/* ]]
}

build_prune_args() {
  local root="$1" parts=() p rp
  if [ "$SKIP_DEFAULTS" = "yes" ]; then
    for p in "${DEFAULT_SKIP_KEYWORDS[@]}"; do
      if [ -n "$root" ] && is_root_covered_by_keyword "$root" "$p"; then continue; fi
      [ "${#parts[@]}" -gt 0 ] && parts=("${parts[@]}" "-o")
      parts=("${parts[@]}" "-iname" "$p")
    done
    for p in "${DEFAULT_SKIP_PATHS[@]}"; do
      case "$p" in
        ~*) rp="${HOME}${p#\~}";;
        /*) rp="$p";;
        *) continue;;
      esac
      if [ -n "$root" ] && is_root_covered_by_path "$root" "$rp"; then continue; fi
      [ "${#parts[@]}" -gt 0 ] && parts=("${parts[@]}" "-o")
      parts=("${parts[@]}" "-path" "$rp")
    done
  fi
  for s in "${SKIP[@]}"; do
    case "$s" in
      */*)
        case "$s" in
          ~*) rp="${HOME}${s#\~}";;
          /*) rp="$s";;
          *) continue;;
        esac
        if [ -n "$root" ] && is_root_covered_by_path "$root" "$rp"; then continue; fi
        [ "${#parts[@]}" -gt 0 ] && parts=("${parts[@]}" "-o")
        parts=("${parts[@]}" "-path" "$rp");;
      *)
        if [ -n "$root" ] && is_root_covered_by_keyword "$root" "$s"; then continue; fi
        [ "${#parts[@]}" -gt 0 ] && parts=("${parts[@]}" "-o")
        parts=("${parts[@]}" "-iname" "$s");;
    esac
  done
  PRUNE_ARGS=("${parts[@]}")
}

prepare_search_skip() {
  local p root="$1" rp
  SEARCH_KW_LC=()
  if [ "$SKIP_DEFAULTS" = "yes" ]; then
    for p in "${DEFAULT_SKIP_KEYWORDS[@]}"; do
      if [ -n "$root" ] && is_root_covered_by_keyword "$root" "$p"; then continue; fi
      SEARCH_KW_LC=("${SEARCH_KW_LC[@]}" "$(lower "$p")")
    done
  fi
  for s in "${SKIP[@]}"; do
    case "$s" in
      */*) ;;
      *)
        if [ -n "$root" ] && is_root_covered_by_keyword "$root" "$s"; then continue; fi
        SEARCH_KW_LC=("${SEARCH_KW_LC[@]}" "$(lower "$s")");;
    esac
  done
  SEARCH_PATH_RESOLVED=()
  if [ "$SKIP_DEFAULTS" = "yes" ]; then
    for p in "${DEFAULT_SKIP_PATHS[@]}"; do
      case "$p" in
        ~*) rp="${HOME}${p#\~}";;
        /*) rp="$p";;
        *) continue;;
      esac
      if [ -n "$root" ] && is_root_covered_by_path "$root" "$rp"; then continue; fi
      SEARCH_PATH_RESOLVED=("${SEARCH_PATH_RESOLVED[@]}" "$rp")
    done
  fi
  for s in "${SKIP[@]}"; do
    case "$s" in
      ~*) rp="${HOME}${s#\~}"
          if [ -n "$root" ] && is_root_covered_by_path "$root" "$rp"; then continue; fi
          SEARCH_PATH_RESOLVED=("${SEARCH_PATH_RESOLVED[@]}" "$rp");;
      /*) rp="$s"
          if [ -n "$root" ] && is_root_covered_by_path "$root" "$rp"; then continue; fi
          SEARCH_PATH_RESOLVED=("${SEARCH_PATH_RESOLVED[@]}" "$rp");;
    esac
  done
}

is_search_skipped() {
  local path="$1" bn bn_lc k i
  bn="${path##*/}"
  [ -n "$bn" ] || bn="$path"
  bn_lc="$(lower "$bn")"
  for k in "${SEARCH_KW_LC[@]}"; do
    [ "$bn_lc" = "$k" ] && return 0
  done
  for i in "${!SEARCH_PATH_RESOLVED[@]}"; do
    if [ "$path" = "${SEARCH_PATH_RESOLVED[$i]}" ] || [[ "$path" == "${SEARCH_PATH_RESOLVED[$i]}"/* ]]; then return 0; fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Package-suffix folders (opaque during search; contents never matched)
# ---------------------------------------------------------------------------
PACKAGE_SUFFIXES=(.app .appex .framework .xcframework .bundle .plugin \
                  .qlgenerator .service .automator .workflow .kext .saver \
                  .pkg .mpkg .xcodeproj .xcworkspace .playground .xcassets \
                  .scnassets .storyboard .xib .nib .xcdatamodel .xcdatamodeld \
                  .mappingmodel .mlmodel .mlmodelc .docc .library .lproj \
                  .photoslibrary .photolibrary .musiclibrary \
                  .appbundle .xcappdata .watchkitapp .xpc .mdimporter \
                  .prefPane .stickerpack .scptd .cfbundle .snippet .driver)

build_package_prune() {
  local parts=() s
  for s in "${PACKAGE_SUFFIXES[@]}"; do
    [ "${#parts[@]}" -gt 0 ] && parts=("${parts[@]}" "-o")
    parts=("${parts[@]}" "-iname" "*${s}")
  done
  PKG_ARGS=("${parts[@]}")
}

# ---------------------------------------------------------------------------
# Sudo
# ---------------------------------------------------------------------------
ensure_sudo() {
  SUDO_OK="no"
  if [ "$(id -u)" -eq 0 ]; then
    SUDO_OK="yes"
  elif [ "$YES" = "yes" ]; then
    if sudo -n true 2>/dev/null; then SUDO_OK="yes"; fi
  else
    echo "$(msg sudo_hint)"
    if sudo -v 2>/dev/null; then
      SUDO_OK="yes"
      echo "$(msg search_sudo_ok)"
    fi
  fi
  if [ "$SUDO_OK" != "yes" ]; then
    echo "$(msg sudo_unavailable)"
  fi
  [ "$SUDO_OK" = "yes" ]
}

# ---------------------------------------------------------------------------
# Search-root discovery (whole-disk / scoped) — reuses the keyword-search model
# ---------------------------------------------------------------------------
run_search() {
  local kws="$1" use_sudo="$2" cap=200 root kw
  shift 2
  local roots=("$@") args name_parts=()
  IFS=',' read -r -a klist <<< "$kws"
  for kw in "${klist[@]}"; do
    [ -n "$kw" ] || continue
    [ "${#name_parts[@]}" -gt 0 ] && name_parts=("${name_parts[@]}" "-o")
    name_parts=("${name_parts[@]}" "-iname" "*${kw}*")
  done
  build_prune_args
  build_package_prune
  prepare_search_skip
  : > "$TMPD/search.txt"
  for root in "${roots[@]}"; do
    echo "$(msg search_running "$root")"
    [ "${#name_parts[@]}" -gt 0 ] || continue
    if [ "${#PRUNE_ARGS[@]}" -gt 0 ]; then
      args=( "$root" "(" "${PRUNE_ARGS[@]}" ")" "-prune" "-o" \
             "(" "(" "${PKG_ARGS[@]}" ")" "-prune" "(" "${name_parts[@]}" "-print" ")" ")" \
             "-o" "(" "${name_parts[@]}" ")" "-print" )
    else
      args=( "$root" \
             "(" "(" "${PKG_ARGS[@]}" ")" "-prune" "(" "${name_parts[@]}" "-print" ")" ")" \
             "-o" "(" "${name_parts[@]}" ")" "-print" )
    fi
    if [ "$use_sudo" = "yes" ]; then
      LC_ALL=C sudo find "${args[@]}" 2>/dev/null | {
        while IFS= read -r p; do
          [ -n "$p" ] || continue
          is_search_skipped "$p" && continue
          printf '%s\n' "$p"
        done
      } >> "$TMPD/search.txt"
    else
      LC_ALL=C find "${args[@]}" 2>/dev/null | {
        while IFS= read -r p; do
          [ -n "$p" ] || continue
          is_search_skipped "$p" && continue
          printf '%s\n' "$p"
        done
      } >> "$TMPD/search.txt"
    fi
  done
  select_search_results "$cap"
}

search_whole_disk() {
  local kw="$1" roots=() use_sudo="no"
  if ensure_sudo; then
    if [ "$(id -u)" -ne 0 ]; then use_sudo="yes"; fi
    roots=("/")
  else
    roots=("$HOME" "/opt" "/Applications")
    echo "$(msg search_fallback "${roots[*]}")"
  fi
  run_search "$kw" "$use_sudo" "${roots[@]}"
}

collect_keywords() {
  local kw
  KWS=""
  echo "$(msg search_keyword_hint)"
  while :; do
    ask search_keyword_prompt ""
    kw="$ASK_VAL"
    [ -z "$kw" ] && break
    [ -n "$KWS" ] && KWS="$KWS,"
    KWS="$KWS$kw"
  done
}

search_disk_interactive() {
  collect_keywords
  [ -z "$KWS" ] && return 0
  search_whole_disk "$KWS"
}

# Link-aware alias dedup for whole-disk search results: firmlink aliases
# (/Users/... vs /System/Volumes/Data/Users/...) collapse to one entry, shown
# and deleted as the short form. Symlink leaves are keyed by canonical parent
# + basename only, so the link itself is never resolved.
collapse_search_results() {
  local in="$1" out="$2"
  local line key dir bn form cand keys=() forms=() i dup
  : > "$out"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ -L "$line" ]; then
      dir="${line%/*}"; bn="${line##*/}"
      [ -z "$dir" ] && dir="/"
      key="$(canonicalize_dir "$dir")/$bn"
    else
      key="$(canonical_path "$line")"
    fi
    [ -n "$key" ] || key="$line"
    form="$line"
    case "$line" in
      /System/Volumes/Data/*)
        cand="/${line#/System/Volumes/Data/}"
        [ -e "$cand" ] && form="$cand";;
    esac
    dup=0
    for i in "${!keys[@]}"; do
      if [ "${keys[$i]}" = "$key" ]; then
        dup=1
        case "$line" in
          /System/Volumes/Data/*) ;;
          *) forms[$i]="$line";;
        esac
        break
      fi
    done
    if [ "$dup" = "0" ]; then
      keys=("${keys[@]}" "$key")
      forms=("${forms[@]}" "$form")
    fi
  done < "$in"
  for line in "${forms[@]}"; do printf '%s\n' "$line"; done >> "$out"
}

# Parse a selection line ("1,2-4 5" or "1-3"): valid indices go to
# $TMPD/sel_idx.txt (one per line), invalid/out-of-range tokens go to
# $TMPD/sel_bad.txt. A line with mixed tokens keeps its valid part.
parse_selection() {
  local picks n="$2" tok start end i
  picks="$(normalize_ascii "$1")"
  : > "$TMPD/sel_idx.txt"
  : > "$TMPD/sel_bad.txt"
  IFS=', ' read -r -a toks <<< "$picks"
  for tok in "${toks[@]}"; do
    [ -z "$tok" ] && continue
    if [[ "$tok" =~ ^([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"; end="$start"
    elif [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
    else
      printf '%s\n' "$tok" >> "$TMPD/sel_bad.txt"
      continue
    fi
    [ "$start" -gt "$end" ] && { i="$start"; start="$end"; end="$i"; }
    if [ "$start" -lt 1 ] || [ "$end" -gt "$n" ]; then
      printf '%s\n' "$tok" >> "$TMPD/sel_bad.txt"
      continue
    fi
    i="$start"
    while [ "$i" -le "$end" ]; do
      printf '%s\n' "$i" >> "$TMPD/sel_idx.txt"
      i=$((i + 1))
    done
  done
}

select_search_results() {
  local cap="$1" n=0 raw_n=0 idx=0 line picks i path
  [ -s "$TMPD/search.txt" ] && raw_n=$(wc -l < "$TMPD/search.txt" | tr -d ' ')
  if [ "$raw_n" -eq 0 ]; then
    echo "$(msg search_no_results)"
    return 0
  fi
  collapse_search_results "$TMPD/search.txt" "$TMPD/kept.txt"
  collapse_candidates "$TMPD/kept.txt" "$TMPD/collapsed.txt"
  [ -s "$TMPD/collapsed.txt" ] && n=$(wc -l < "$TMPD/collapsed.txt" | tr -d ' ')
  if [ "$n" -eq 0 ]; then
    echo "$(msg search_no_results)"
    return 0
  fi
  echo "$(msg search_results "$n" "$n")"
  if [ "$n" -ge "$cap" ]; then echo "$(msg search_truncated "?")"; fi
  while IFS= read -r line; do
    idx=$((idx + 1))
    printf '  %3d) %s\n' "$idx" "$line"
  done < "$TMPD/collapsed.txt"
  if [ "$YES" = "yes" ]; then
    while IFS= read -r line; do DIRECT_CANDIDATES=("${DIRECT_CANDIDATES[@]}" "$line"); done < "$TMPD/collapsed.txt"
    echo "$(msg search_added "$n")"
    return 0
  fi
  while :; do
    ask search_select ""
    picks="$ASK_VAL"
    [ -z "$picks" ] && break
    case "$(lower "$(normalize_ascii "$picks")")" in
      a|all)
        while IFS= read -r line; do DIRECT_CANDIDATES=("${DIRECT_CANDIDATES[@]}" "$line"); done < "$TMPD/collapsed.txt"
        echo "$(msg search_added "${#DIRECT_CANDIDATES[@]}")"
        return 0;;
      c|cancel)
        DIRECT_CANDIDATES=()
        echo "$(msg search_cancelled)"
        return 0;;
    esac
    parse_selection "$picks" "$n"
    if [ -s "$TMPD/sel_bad.txt" ]; then
      echo "$(msg invalid_tokens "$(tr '\n' ' ' < "$TMPD/sel_bad.txt")")"
    fi
    if [ ! -s "$TMPD/sel_idx.txt" ]; then
      continue
    fi
    while IFS= read -r i; do
      path="$(sed -n "${i}p" "$TMPD/collapsed.txt")"
      dup=0
      for line in "${DIRECT_CANDIDATES[@]}"; do
        [ "$line" = "$path" ] && dup=1
      done
      [ -n "$path" ] && [ "$dup" = "0" ] && DIRECT_CANDIDATES=("${DIRECT_CANDIDATES[@]}" "$path")
    done < "$TMPD/sel_idx.txt"
    echo "$(msg search_added "${#DIRECT_CANDIDATES[@]}")"
  done
}

read_target_paths() {
  local np
  echo "$(msg target_paths_intro)"
  while :; do
    ask target_path_entry ""
    [ -z "$ASK_VAL" ] && return 0
    if [ "$(lower "$ASK_VAL")" = "exit" ]; then echo "$(msg exit_msg)"; exit 0; fi
    np="$(normalize_target_path "$ASK_VAL")"
    if target_is_valid "$np"; then
      TARGETS=("${TARGETS[@]}" "$np")
    else
      echo "$(msg target_invalid)"
    fi
  done
}

read_target_paths_yes() {
  local np
  while :; do
    ask target_path_entry ""
    if [ -z "$ASK_VAL" ]; then
      [ "${#TARGETS[@]}" -gt 0 ] && return 0
      echo "$(msg target_need_one)"
      continue
    fi
    np="$(normalize_target_path "$ASK_VAL")"
    if target_is_valid "$np"; then
      TARGETS=("${TARGETS[@]}" "$np")
      return 0
    fi
    echo "$(msg target_invalid)"
  done
}

target_resolution_menu() {
  local t
  while :; do
    collapse_targets
    if [ "${#TARGETS[@]}" -gt 0 ]; then
      echo "$(msg target_current)"
      for t in "${TARGETS[@]}"; do echo "  - $t"; done
    fi
    echo "$(msg target_source_choice)"
    echo "  $(msg target_mode_addpath)"
    echo "  $(msg target_mode_searchdisk)"
    echo "  $(msg target_cancel)"
    ask target_source_choice ""
    case "$(normalize_ascii "$ASK_VAL")" in
      "") ;;
      exit)
        echo "$(msg exit_msg)"; exit 0;;
      1) read_target_paths;;
      2) search_disk_interactive;;
      *) echo "$(msg invalid_choice)";;
    esac
    if [ "${#TARGETS[@]}" -gt 0 ] || [ "${#DIRECT_CANDIDATES[@]}" -gt 0 ]; then return 0; fi
  done
}

resolve_targets() {
  local t2 np out=()
  for t2 in "${TARGETS[@]}"; do
    np="$(normalize_target_path "$t2")"
    if target_is_valid "$np"; then
      out=("${out[@]}" "$np")
    else
      echo "$(msg target_invalid): $t2"
    fi
  done
  TARGETS=("${out[@]}")
  if [ "$CLI_SEARCH" = "yes" ]; then search_whole_disk "$CLI_SEARCH_KW"; fi
  collapse_targets
  if [ "${#TARGETS[@]}" -gt 0 ] || [ "${#DIRECT_CANDIDATES[@]}" -gt 0 ]; then
    if [ "${#TARGETS[@]}" -gt 0 ]; then
      echo "$(msg target_collapsed)"
      for t2 in "${TARGETS[@]}"; do echo "  - $t2"; done
    fi
    return 0
  fi
  while :; do
    if [ "$YES" = "yes" ]; then
      read_target_paths_yes
    else
      target_resolution_menu
    fi
    collapse_targets
    if [ "${#TARGETS[@]}" -gt 0 ] || [ "${#DIRECT_CANDIDATES[@]}" -gt 0 ]; then break; fi
    echo "$(msg target_need_one)"
  done
  if [ "${#TARGETS[@]}" -gt 0 ]; then
    echo "$(msg target_collapsed)"
    for t2 in "${TARGETS[@]}"; do echo "  - $t2"; done
  fi
}

# ---------------------------------------------------------------------------
# Protection zones
# ---------------------------------------------------------------------------
prepare_protect() {
  local d
  PROTECTED_PATHS=()
  if [ "$PROTECT_NONE" != "yes" ]; then
    for d in "${DEFAULT_PROTECT_NAMES[@]}"; do
      PROTECTED_PATHS=("${PROTECTED_PATHS[@]}" "$(canonical_path "$HOME_C/$d")")
    done
  fi
  for d in "${PROTECT[@]}"; do
    case "$d" in
      ~*) PROTECTED_PATHS=("${PROTECTED_PATHS[@]}" "$(canonical_path "${HOME_C}${d#\~}")");;
      /*) PROTECTED_PATHS=("${PROTECTED_PATHS[@]}" "$(canonical_path "$d")");;
      *)  PROTECTED_PATHS=("${PROTECTED_PATHS[@]}" "$(canonical_path "$HOME_C/$d")");;
    esac
  done
}

is_protected() {
  local p="$1" cp i
  [ "${#PROTECTED_PATHS[@]}" -eq 0 ] && return 1
  cp="$(canonical_path "$p")"
  for i in "${!PROTECTED_PATHS[@]}"; do
    if [ "$p" = "${PROTECTED_PATHS[$i]}" ] || [[ "$p" == "${PROTECTED_PATHS[$i]}"/* ]]; then return 0; fi
    if [ -n "$cp" ] && { [ "$cp" = "${PROTECTED_PATHS[$i]}" ] || [[ "$cp" == "${PROTECTED_PATHS[$i]}"/* ]]; }; then return 0; fi
  done
  return 1
}

merge_direct_candidates() {
  local d i dup
  for d in "${DIRECT_CANDIDATES[@]}"; do
    dup=0
    for i in "${CANDIDATES[@]}"; do
      [ "$d" = "$i" ] && dup=1
    done
    [ "$dup" = "0" ] && CANDIDATES=("${CANDIDATES[@]}" "$d")
  done
  FOUND_N=$((FOUND_N + ${#DIRECT_CANDIDATES[@]}))
  DIRECT_CANDIDATES=()
}

partition_protected() {
  local c
  PROTECTED_ITEMS=()
  PLAIN_ITEMS=()
  for c in "${CANDIDATES[@]}"; do
    if is_protected "$c"; then
      PROTECTED_ITEMS=("${PROTECTED_ITEMS[@]}" "$c")
    else
      PLAIN_ITEMS=("${PLAIN_ITEMS[@]}" "$c")
    fi
  done
}

# Second confirmation round for matches inside protection zones. Everything not
# explicitly picked is kept (counted Protected). --yes keeps them all unless
# --allow-protected was given.
resolve_protected_selection() {
  local idx=0 line picks i path s found sel=()
  [ "${#PROTECTED_ITEMS[@]}" -eq 0 ] && return 0
  if [ "$ALLOW_PROTECTED" = "yes" ]; then
    return 0
  fi
  if [ "$YES" = "yes" ]; then
    PROTECTED_N=$((PROTECTED_N + ${#PROTECTED_ITEMS[@]}))
    for line in "${PROTECTED_ITEMS[@]}"; do printf '%s\n' "$line" >> "$TMPD/protected.txt"; done
    CANDIDATES=("${PLAIN_ITEMS[@]}")
    echo "$(msg protected_kept_all "${#PROTECTED_ITEMS[@]}")"
    return 0
  fi
  echo "$(msg protected_warn)"
  idx=0
  for line in "${PROTECTED_ITEMS[@]}"; do
    idx=$((idx + 1))
    printf '  %3d) %s\n' "$idx" "$line"
  done
  while :; do
    echo "$(msg protected_select)"
    ask search_select ""
    picks="$ASK_VAL"
    case "$(lower "$(normalize_ascii "$picks")")" in
      ""|c|cancel)
        PROTECTED_N=$((PROTECTED_N + ${#PROTECTED_ITEMS[@]}))
        for line in "${PROTECTED_ITEMS[@]}"; do printf '%s\n' "$line" >> "$TMPD/protected.txt"; done
        CANDIDATES=("${PLAIN_ITEMS[@]}")
        echo "$(msg protected_kept_all "${#PROTECTED_ITEMS[@]}")"
        return 0;;
      a|all)
        CANDIDATES=("${PLAIN_ITEMS[@]}" "${PROTECTED_ITEMS[@]}")
        echo "$(msg protected_selected_all "${#PROTECTED_ITEMS[@]}")"
        return 0;;
    esac
    parse_selection "$picks" "${#PROTECTED_ITEMS[@]}"
    if [ -s "$TMPD/sel_bad.txt" ]; then
      echo "$(msg invalid_tokens "$(tr '\n' ' ' < "$TMPD/sel_bad.txt")")"
    fi
    if [ ! -s "$TMPD/sel_idx.txt" ]; then
      continue
    fi
    while IFS= read -r i; do
      path="${PROTECTED_ITEMS[$((i - 1))]}"
      found=0
      for s in "${sel[@]}"; do
        [ "$s" = "$path" ] && found=1
      done
      [ "$found" = "0" ] && sel=("${sel[@]}" "$path")
    done < "$TMPD/sel_idx.txt"
    break
  done
  for line in "${PROTECTED_ITEMS[@]}"; do
    found=0
    for s in "${sel[@]}"; do
      [ "$s" = "$line" ] && found=1
    done
    if [ "$found" = "0" ]; then
      PROTECTED_N=$((PROTECTED_N + 1))
      printf '%s\n' "$line" >> "$TMPD/protected.txt"
    fi
  done
  CANDIDATES=("${PLAIN_ITEMS[@]}" "${sel[@]}")
}

# ---------------------------------------------------------------------------
# Delete-candidate matching (raw paths; no canonicalization of symlinks)
# ---------------------------------------------------------------------------
collapse_candidates() {
  local in="$1" out="$2"
  local line a b keep=() final=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    for a in "${keep[@]}"; do
      if [ "$line" = "$a" ] || [[ "$line" == "$a"/* ]]; then continue 2; fi
    done
    keep=("${keep[@]}" "$line")
  done < "$in"
  for a in "${keep[@]}"; do
    skip=0
    for b in "${keep[@]}"; do
      [ "$a" = "$b" ] && continue
      if [[ "$a" == "$b"/* ]]; then skip=1; break; fi
    done
    [ "$skip" = "0" ] && final=("${final[@]}" "$a")
  done
  : > "$out"
  for a in "${final[@]}"; do printf '%s\n' "$a"; done >> "$out"
}

match_and_select() {
  local kw name_parts=() args root
  build_package_prune
  : > "$TMPD/raw.txt"
  : > "$TMPD/skip_raw.txt"
  for kw in "${KEYWORDS[@]}"; do
    [ -n "$kw" ] || continue
    [ "${#name_parts[@]}" -gt 0 ] && name_parts=("${name_parts[@]}" "-o")
    if [ "$EXACT" = "yes" ]; then
      name_parts=("${name_parts[@]}" "-iname" "$kw")
    else
      name_parts=("${name_parts[@]}" "-iname" "*${kw}*")
    fi
  done
  [ "${#name_parts[@]}" -gt 0 ] || { echo "$(msg delete_keyword_need)"; exit 1; }
  for root in "${TARGETS[@]}"; do
    build_prune_args "$root"
    prepare_search_skip "$root"
    echo "$(msg search_running "$root")"
    if [ "${#PRUNE_ARGS[@]}" -gt 0 ]; then
      args=( "$root" "(" "${PRUNE_ARGS[@]}" ")" "-prune" "-o" \
             "(" "(" "${PKG_ARGS[@]}" ")" "-prune" "(" "${name_parts[@]}" "-print" ")" ")" \
             "-o" "(" "${name_parts[@]}" ")" "-print" )
    else
      args=( "$root" \
             "(" "(" "${PKG_ARGS[@]}" ")" "-prune" "(" "${name_parts[@]}" "-print" ")" ")" \
             "-o" "(" "${name_parts[@]}" ")" "-print" )
    fi
    if [ "$SUDO_OK" = "yes" ]; then
      LC_ALL=C sudo find "${args[@]}" 2>/dev/null | {
        while IFS= read -r p; do
          [ -n "$p" ] || continue
          if is_search_skipped "$p"; then printf '%s\n' "$p" >> "$TMPD/skip_raw.txt"; continue; fi
          printf '%s\n' "$p"
        done
      } >> "$TMPD/raw.txt"
    else
      LC_ALL=C find "${args[@]}" 2>/dev/null | {
        while IFS= read -r p; do
          [ -n "$p" ] || continue
          if is_search_skipped "$p"; then printf '%s\n' "$p" >> "$TMPD/skip_raw.txt"; continue; fi
          printf '%s\n' "$p"
        done
      } >> "$TMPD/raw.txt"
    fi
  done
  if [ -f "$TMPD/raw.txt" ]; then FOUND_N=$(wc -l < "$TMPD/raw.txt" | tr -d ' '); else FOUND_N=0; fi
  if [ -f "$TMPD/skip_raw.txt" ]; then SKIP_N=$(wc -l < "$TMPD/skip_raw.txt" | tr -d ' '); else SKIP_N=0; fi
  select_candidates
}

select_candidates() {
  local cap=200 n=0 raw_n=0 idx=0 line picks i path keep=()
  CANDIDATES=()
  [ -f "$TMPD/raw.txt" ] && raw_n=$(wc -l < "$TMPD/raw.txt" | tr -d ' ')
  if [ "$raw_n" -eq 0 ]; then
    echo "$(msg search_no_results)"
    return 0
  fi
  : > "$TMPD/kept.txt"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    for k in "${keep[@]}"; do
      if [ "$line" = "$k" ] || [[ "$line" == "$k"/* ]]; then continue 2; fi
    done
    keep=("${keep[@]}" "$line")
  done < "$TMPD/raw.txt"
  for line in "${keep[@]}"; do printf '%s\n' "$line"; done > "$TMPD/kept.txt"
  collapse_candidates "$TMPD/kept.txt" "$TMPD/collapsed.txt"
  [ -s "$TMPD/collapsed.txt" ] && n=$(wc -l < "$TMPD/collapsed.txt" | tr -d ' ')
  if [ "$n" -eq 0 ]; then
    echo "$(msg search_no_results)"
    return 0
  fi
  echo "$(msg matched_show "$n")"
  if [ "$n" -ge "$cap" ]; then echo "$(msg search_truncated "?")"; fi
  while IFS= read -r line; do
    idx=$((idx + 1))
    printf '  %3d) %s\n' "$idx" "$line"
  done < "$TMPD/collapsed.txt"
  if [ "$YES" = "yes" ]; then
    while IFS= read -r line; do CANDIDATES=("${CANDIDATES[@]}" "$line"); done < "$TMPD/collapsed.txt"
    echo "$(msg matched_selected "$n")"
    return 0
  fi
  while :; do
    ask search_select ""
    picks="$ASK_VAL"
    [ -z "$picks" ] && break
    case "$(lower "$(normalize_ascii "$picks")")" in
      a|all)
        while IFS= read -r line; do CANDIDATES=("${CANDIDATES[@]}" "$line"); done < "$TMPD/collapsed.txt"
        echo "$(msg matched_selected "${#CANDIDATES[@]}")"
        return 0;;
      c|cancel)
        CANDIDATES=()
        echo "$(msg search_cancelled)"
        return 0;;
    esac
    parse_selection "$picks" "$n"
    if [ -s "$TMPD/sel_bad.txt" ]; then
      echo "$(msg invalid_tokens "$(tr '\n' ' ' < "$TMPD/sel_bad.txt")")"
    fi
    if [ ! -s "$TMPD/sel_idx.txt" ]; then
      continue
    fi
    while IFS= read -r i; do
      path="$(sed -n "${i}p" "$TMPD/collapsed.txt")"
      dup=0
      for line in "${CANDIDATES[@]}"; do
        [ "$line" = "$path" ] && dup=1
      done
      [ -n "$path" ] && [ "$dup" = "0" ] && CANDIDATES=("${CANDIDATES[@]}" "$path")
    done < "$TMPD/sel_idx.txt"
    echo "$(msg matched_selected "${#CANDIDATES[@]}")"
  done
}

# ---------------------------------------------------------------------------
# Guards: never delete the search roots, their ancestors, or system paths
# ---------------------------------------------------------------------------
is_blocked() {
  local p="$1" t g
  if [ "$p" = "/" ] || [ "$p" = "." ] || [ "$p" = ".." ]; then return 0; fi
  if [ "$p" = "$HOME" ] || [ "$p" = "$HOME_C" ]; then return 0; fi
  for t in "${TARGETS[@]}"; do
    if [ "$p" = "$t" ] || [[ "$t" == "$p"/* ]]; then return 0; fi
  done
  for g in "${SYSTEM_GUARDS[@]}"; do
    if [ "$p" = "$g" ] || [[ "$g" == "$p"/* ]]; then return 0; fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Trash
# ---------------------------------------------------------------------------
collide_basename() {
  local bn="$1" n="$2" base ext
  if [[ "$bn" == *.* ]]; then
    base="${bn%.*}"; ext="${bn##*.}"
    printf '%s %s.%s' "$base" "$n" "$ext"
  else
    printf '%s %s' "$bn" "$n"
  fi
}

move_to_trash() {
  local path="$1" need_sudo="$2" bn target i=2
  bn="$(basename "$path")"
  mkdir -p "$HOME/.Trash" 2>/dev/null || return 1
  target="$HOME/.Trash/$bn"
  while [ -e "$target" ] || [ -L "$target" ]; do
    target="$HOME/.Trash/$(collide_basename "$bn" "$i")"
    i=$((i + 1))
  done
  if [ "$need_sudo" = "yes" ]; then
    sudo mv "$path" "$target" 2>/dev/null && return 0
  else
    mv "$path" "$target" 2>/dev/null && return 0
  fi
  # Finder fallback: cross-volume moves and automatic collision handling.
  if [ "$need_sudo" = "no" ] && command -v osascript >/dev/null 2>&1; then
    osascript -e 'tell application "Finder" to delete POSIX file "'"$path"'"' >/dev/null 2>&1 && return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Logging (respects LOG_LEVEL)
# ---------------------------------------------------------------------------
log_entry() {
  local kind="$1" path="$2" extra="$3" prefix
  case "$LOG_LEVEL" in
    changes)
      [ "$kind" = "deleted" ] || [ "$kind" = "trashed" ] || [ "$kind" = "error" ] || [ "$kind" = "blocked" ] || return;;
    none) return;;
    *) ;;
  esac
  case "$kind" in
    deleted)  prefix="$(msg log_deleted)";;
    trashed)  prefix="$(msg log_trashed)";;
    error)    prefix="$(msg log_error)";;
    blocked)  prefix="$(msg log_blocked)";;
    protected) prefix="$(msg log_protected)";;
    skipped)  prefix="$(msg log_skipped)";;
  esac
  if [ -n "$extra" ]; then
    printf '%s %s %s\n' "$prefix" "$path" "$extra"
  else
    printf '%s %s\n' "$prefix" "$path"
  fi
}

# ---------------------------------------------------------------------------
# Deletion
# ---------------------------------------------------------------------------
delete_one() {
  local path="$1" cmd setok needs_sudo="no"
  PROCESSED_N=$((PROCESSED_N + 1))
  if [ "$LOG_LEVEL" = "all" ] && [ -t 1 ] && [ $((PROCESSED_N % 500)) -eq 0 ]; then
    echo "... $PROCESSED_N"
  fi
  if [ "$SUDO_OK" = "yes" ] && [ ! -w "$path" ]; then needs_sudo="yes"; fi
  if [ "$DRY_RUN" = "yes" ]; then
    DELETED_N=$((DELETED_N + 1))
    printf '%s\n' "$path" >> "$TMPD/deleted.txt"
    log_entry deleted "$path" "(dry-run)"
    return
  fi
  if [ "$needs_sudo" = "no" ] && [ ! -w "$path" ]; then
    SKIP_N=$((SKIP_N + 1))
    printf '%s\n' "$path" >> "$TMPD/skipped.txt"
    log_entry skipped "$path"
    return
  fi
  if [ "$MODE" = "trash" ]; then
    if move_to_trash "$path" "$needs_sudo"; then
      TRASHED_N=$((TRASHED_N + 1))
      DELETED_N=$((DELETED_N + 1))
      printf '%s\n' "$path" >> "$TMPD/deleted.txt"
      log_entry trashed "$path"
    else
      ERROR_N=$((ERROR_N + 1))
      printf '%s\n' "$path" >> "$TMPD/errors.txt"
      log_entry error "$path"
    fi
    return
  fi
  if [ -d "$path" ] && [ ! -L "$path" ]; then cmd="rm -rf"; else cmd="rm -f"; fi
  if [ "$needs_sudo" = "yes" ]; then
    sudo $cmd "$path" 2>/dev/null
  else
    $cmd "$path" 2>/dev/null
  fi
  setok=$?
  if [ "$setok" -eq 0 ]; then
    DELETED_N=$((DELETED_N + 1))
    printf '%s\n' "$path" >> "$TMPD/deleted.txt"
    log_entry deleted "$path"
  else
    ERROR_N=$((ERROR_N + 1))
    printf '%s\n' "$path" >> "$TMPD/errors.txt"
    log_entry error "$path"
  fi
}

execute() {
  local i c
  for i in "${!CANDIDATES[@]}"; do
    c="${CANDIDATES[$i]}"
    if is_blocked "$c"; then
      BLOCKED_N=$((BLOCKED_N + 1))
      printf '%s\n' "$c" >> "$TMPD/blocked.txt"
      log_entry blocked "$c"
      continue
    fi
    delete_one "$c"
  done
}

# ---------------------------------------------------------------------------
# Confirmation / editing
# ---------------------------------------------------------------------------
show_config() {
  local t c cidx=0
  echo "$(msg show_config)"
  echo "  $(msg cfg_roots): ${#TARGETS[@]}"
  for t in "${TARGETS[@]}"; do echo "    - $t"; done
  echo "  $(msg cfg_candidates): ${#CANDIDATES[@]}"
  for c in "${CANDIDATES[@]}"; do
    cidx=$((cidx + 1))
    [ "$cidx" -le 200 ] || { echo "$(msg search_truncated "$(( ${#CANDIDATES[@]} - 200 ))")"; break; }
    printf '    %3d) %s\n' "$cidx" "$c"
  done
  echo "  $(msg cfg_keywords): ${KEYWORDS[*]}"
  echo "  $(msg cfg_exact): $(yn_short "$EXACT")"
  echo "  $(msg cfg_mode): $MODE"
  if [ "${#PROTECT[@]}" -gt 0 ]; then
    echo "  $(msg cfg_protect): ${PROTECT[*]}"
  else
    echo "  $(msg cfg_protect): $(msg skip_list_empty)"
  fi
  echo "  $(msg cfg_allow): $(yn_short "$ALLOW_PROTECTED")"
  if [ "$TRAVERSAL" = "yes" ]; then
    echo "  $(msg cfg_skip_defaults): $(yn_short "$SKIP_DEFAULTS")"
    if [ "${#SKIP[@]}" -gt 0 ]; then
      echo "  $(msg cfg_skip): ${SKIP[*]}"
    else
      echo "  $(msg cfg_skip): $(msg skip_list_empty)"
    fi
  fi
  echo "  $(msg cfg_save_dir): ${SAVE_DIR:-$(msg save_script_dir)}"
  echo "  $(msg cfg_log_level): $LOG_LEVEL"
  echo "  $(msg yn_note)"
}

edit_loop() {
  while :; do
    ask edit_prompt ""
    [ -z "$ASK_VAL" ] && return
    case "$(normalize_ascii "$ASK_VAL")" in
      1) prompt_language;;
      2) prompt_keywords; KEYWORDS_DIRTY="yes";;
      3) prompt_exact; KEYWORDS_DIRTY="yes";;
      4) prompt_mode;;
      5) prompt_protect; KEYWORDS_DIRTY="yes";;
      6) prompt_allow_protected; KEYWORDS_DIRTY="yes";;
      7) [ "$TRAVERSAL" = "yes" ] && prompt_skip_defaults;;
      8) [ "$TRAVERSAL" = "yes" ] && prompt_skip_list;;
      9) prompt_save_dir;;
      10) prompt_log_level;;
      *) echo "$(msg invalid_choice)";;
    esac
  done
}

reenter_all() {
  if [ "${#TARGETS[@]}" -gt 0 ]; then
    if [ "$CLI_KEYWORD" = "no" ] && [ "${#KEYWORDS[@]}" -eq 0 ]; then prompt_keywords; fi
    KEYWORDS_DIRTY="no"
    match_and_select
  fi
  if [ "${#DIRECT_CANDIDATES[@]}" -gt 0 ]; then merge_direct_candidates; fi
  partition_protected
  resolve_protected_selection
}

confirm_loop() {
  if [ "$YES" = "yes" ]; then return 0; fi
  while :; do
    show_config
    [ "$DRY_RUN" = "yes" ] && echo "$(msg dry_run_on)"
    if [ "$MODE" = "permanent" ]; then echo "$(msg permanent_warn)"; fi
    echo "$(msg confirm_menu)"
    ask confirm_choice ""
    case "$(normalize_ascii "$ASK_VAL")" in
      1)
        if [ "$KEYWORDS_DIRTY" = "yes" ]; then
          KEYWORDS_DIRTY="no"
          if [ "${#TARGETS[@]}" -gt 0 ]; then
            match_and_select
          fi
          if [ "${#DIRECT_CANDIDATES[@]}" -gt 0 ]; then merge_direct_candidates; fi
          partition_protected
          resolve_protected_selection
        fi
        return 0;;
      2) edit_loop;;
      3) reenter_all;;
      4) echo "$(msg exit_msg)"; exit 0;;
      *) echo "$(msg invalid_choice)";;
    esac
  done
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
show_summary() {
  local t1 sec t
  t1=$(date +%s)
  sec=$((t1 - START_SEC))
  echo "$(msg summary_title)"
  echo "$(msg summary_roots): ${#TARGETS[@]}"
  for t in "${TARGETS[@]}"; do echo "  - $t"; done
  echo "$(msg summary_keywords): ${KEYWORDS[*]}"
  echo "$(msg summary_mode): $MODE"
  echo "$(msg summary_matched): $FOUND_N"
  echo "$(msg summary_protected): $PROTECTED_N"
  echo "$(msg summary_blocked): $BLOCKED_N"
  echo "$(msg summary_deleted): $DELETED_N"
  [ "$MODE" = "trash" ] && echo "$(msg summary_trashed): $TRASHED_N"
  echo "$(msg summary_errors): $ERROR_N"
  echo "$(msg summary_elapsed): ${sec}s"
  [ "$DRY_RUN" = "yes" ] && echo "$(msg summary_dry)"
}

# ---------------------------------------------------------------------------
# Operation log file saving (when something happened)
# ---------------------------------------------------------------------------
resolve_save_dir() {
  if [ -n "$SAVE_DIR" ]; then echo "$SAVE_DIR"; else echo "$SCRIPT_DIR"; fi
}

resolve_log_dir() {
  echo "$(resolve_save_dir)/log"
}

save_log_flow() {
  [ "$DRY_RUN" = "yes" ] && return
  if [ "$DELETED_N" -le 0 ] && [ "$ERROR_N" -le 0 ] && [ "$BLOCKED_N" -le 0 ] && [ "$PROTECTED_N" -le 0 ]; then return; fi
  if [ "$YES" != "yes" ]; then
    ask log_ask "y" "$DELETED_N"
    if [ "$(lower "$(normalize_ascii "$ASK_VAL")")" = "n" ] || [ "$(lower "$(normalize_ascii "$ASK_VAL")")" = "no" ]; then
      return
    fi
  fi
  local logdir t
  logdir="$(resolve_log_dir)"
  mkdir -p "$logdir"
  LOGFILE="$logdir/search_delete_log_$(date +%Y%m%d_%H%M%S)_deleted_${DELETED_N}.log"
  {
    echo "$(msg log_header)"
    echo "$(msg summary_roots): ${#TARGETS[@]}"
    for t in "${TARGETS[@]}"; do echo "  - $t"; done
    echo "$(msg summary_keywords): ${KEYWORDS[*]}"
    echo "$(msg summary_mode): $MODE"
    echo "$(msg log_completed_at): $(date +%Y-%m-%d_%H:%M:%S)"
    echo ""
    echo "--- $(msg log_deleted_list) ($DELETED_N) ---"
    cat "$TMPD/deleted.txt" 2>/dev/null
    echo ""
    echo "--- $(msg log_errors_list) ($ERROR_N) ---"
    cat "$TMPD/errors.txt" 2>/dev/null
    echo ""
    echo "--- $(msg log_blocked_list) ($BLOCKED_N) ---"
    cat "$TMPD/blocked.txt" 2>/dev/null
    echo ""
    echo "--- $(msg log_protected_list) ($PROTECTED_N) ---"
    cat "$TMPD/protected.txt" 2>/dev/null
    echo ""
    echo "--- $(msg log_skipped_list) ($SKIP_N) ---"
    cat "$TMPD/skipped.txt" 2>/dev/null
    echo ""
    echo "$(msg summary_title)"
    echo "$(msg summary_matched): $FOUND_N"
    echo "$(msg summary_protected): $PROTECTED_N"
    echo "$(msg summary_blocked): $BLOCKED_N"
    echo "$(msg summary_deleted): $DELETED_N"
    [ "$MODE" = "trash" ] && echo "$(msg summary_trashed): $TRASHED_N"
    echo "$(msg summary_errors): $ERROR_N"
  } > "$LOGFILE"
  echo "$(msg log_saved): $LOGFILE"
}

# ---------------------------------------------------------------------------
# Config file handling
# ---------------------------------------------------------------------------
load_config() {
  [ -n "$CONFIG_FILE" ] || return 1
  [ -f "$CONFIG_FILE" ] || return 1
  HAS_CONFIG="yes"
  local v s
  v=$(jq -r '.language // empty' "$CONFIG_FILE" 2>/dev/null);        [ -n "$v" ] && LANGUAGE="$v"
  v=$(jq -r '.exact // empty' "$CONFIG_FILE" 2>/dev/null);           [ -n "$v" ] && EXACT="$(normalize_yn "$v")"
  v=$(jq -r '.mode // empty' "$CONFIG_FILE" 2>/dev/null);            [ -n "$v" ] && MODE="$v"
  v=$(jq -r '.allowProtected // empty' "$CONFIG_FILE" 2>/dev/null);  [ -n "$v" ] && ALLOW_PROTECTED="$(normalize_yn "$v")"
  v=$(jq -r '.skipDefaults // empty' "$CONFIG_FILE" 2>/dev/null);    [ -n "$v" ] && SKIP_DEFAULTS="$(normalize_yn "$v")"
  v=$(jq -r '.saveDir // empty' "$CONFIG_FILE" 2>/dev/null);         [ -n "$v" ] && SAVE_DIR="$v"
  v=$(jq -r '.logLevel // empty' "$CONFIG_FILE" 2>/dev/null);        [ -n "$v" ] && LOG_LEVEL="$(lower "$v")"
  PROTECT=()
  while IFS= read -r s; do
    [ -n "$s" ] && PROTECT=("${PROTECT[@]}" "$s")
  done < <(jq -r '.protect[]? // empty' "$CONFIG_FILE" 2>/dev/null)
  SKIP=()
  while IFS= read -r s; do
    [ -n "$s" ] && SKIP=("${SKIP[@]}" "$s")
  done < <(jq -r '.skip[]? // empty' "$CONFIG_FILE" 2>/dev/null)
  KEYWORDS=()
  while IFS= read -r s; do
    [ -n "$s" ] && KEYWORDS=("${KEYWORDS[@]}" "$s")
  done < <(jq -r '.keywords[]? // empty' "$CONFIG_FILE" 2>/dev/null)
  TARGETS=()
  while IFS= read -r s; do
    [ -n "$s" ] && TARGETS=("${TARGETS[@]}" "${s%/}")
  done < <(jq -r '.searchRoots[]? // empty' "$CONFIG_FILE" 2>/dev/null)
  return 0
}

jq_bool() {
  if [ "$1" = "yes" ]; then echo "true"; else echo "false"; fi
}

list_json() {
  local i
  for i in "$@"; do printf '%s\n' "$i"; done | jq -R . | jq -s -c .
}

write_config() {
  local path="$1" tmp
  tmp="$(mktemp)" || return 1
  if ! jq -n \
        --arg language "$LANGUAGE" \
        --argjson searchRoots "$(list_json "${TARGETS[@]}")" \
        --argjson keywords "$(list_json "${KEYWORDS[@]}")" \
        --argjson exact "$(jq_bool "$EXACT")" \
        --arg mode "$MODE" \
        --argjson protect "$(list_json "${PROTECT[@]}")" \
        --argjson allowProtected "$(jq_bool "$ALLOW_PROTECTED")" \
        --argjson skipDefaults "$(jq_bool "$SKIP_DEFAULTS")" \
        --argjson skip "$(list_json "${SKIP[@]}")" \
        --arg saveDir "$SAVE_DIR" \
        --arg logLevel "$LOG_LEVEL" \
        '{language:$language,searchRoots:$searchRoots,keywords:$keywords,exact:$exact,mode:$mode,protect:$protect,allowProtected:$allowProtected,skipDefaults:$skipDefaults,skip:$skip,saveDir:$saveDir,logLevel:$logLevel}' > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$path"
}

# Re-apply command line values after the config file has been loaded.
apply_cli() {
  [ "$CLI_LANGUAGE" = "yes" ] && LANGUAGE="$CLI_LANGUAGE_VAL"
  if [ "$CLI_TARGET" = "yes" ]; then
    TARGETS=("${CLI_TARGET_VALS[@]}")
  fi
  if [ "$CLI_KEYWORD" = "yes" ]; then
    KEYWORDS=("${CLI_KEYWORD_VALS[@]}")
  fi
  [ "$CLI_EXACT" = "yes" ] && EXACT="yes"
  [ "$CLI_MODE" = "yes" ] && MODE="$CLI_MODE_VAL"
  [ "$CLI_ALLOW" = "yes" ] && ALLOW_PROTECTED="yes"
  [ "$CLI_SD" = "yes" ] && SKIP_DEFAULTS="$CLI_SD_VAL"
  [ "$CLI_SAVEDIR" = "yes" ] && SAVE_DIR="$CLI_SAVEDIR_VAL"
  [ "$CLI_LOG" = "yes" ] && LOG_LEVEL="$CLI_LOG_VAL"
  if [ "$CLI_SKIP" = "yes" ]; then
    SKIP=("${CLI_SKIP_VALS[@]}")
  fi
  if [ "$CLI_PROTECT" = "yes" ]; then
    PROTECT=("${CLI_PROTECT_VALS[@]}")
  fi
}

# Snapshot of the config values right after load (for change detection)
SNAP_LANGUAGE=""
SNAP_EXACT=""
SNAP_MODE=""
SNAP_ALLOW=""
SNAP_SD=""
SNAP_SAVEDIR=""
SNAP_LOG=""
SNAP_TARGETS=()
SNAP_KEYWORDS=()
SNAP_PROTECT=()
SNAP_SKIP=()

snapshot() {
  SNAP_LANGUAGE="$LANGUAGE"
  SNAP_EXACT="$EXACT"
  SNAP_MODE="$MODE"
  SNAP_ALLOW="$ALLOW_PROTECTED"
  SNAP_SD="$SKIP_DEFAULTS"
  SNAP_SAVEDIR="$SAVE_DIR"
  SNAP_LOG="$LOG_LEVEL"
  SNAP_TARGETS=("${TARGETS[@]}")
  SNAP_KEYWORDS=("${KEYWORDS[@]}")
  SNAP_PROTECT=("${PROTECT[@]}")
  SNAP_SKIP=("${SKIP[@]}")
}

all_defaults() {
  [ "$LANGUAGE" != "$DEF_LANGUAGE" ] && return 1
  [ "$EXACT" != "$DEF_EXACT" ] && return 1
  [ "$MODE" != "$DEF_MODE" ] && return 1
  [ "$ALLOW_PROTECTED" != "$DEF_ALLOW" ] && return 1
  [ "$PROTECT_NONE" != "$DEF_PROTECT_NONE" ] && return 1
  [ "$SKIP_DEFAULTS" != "$DEF_SD" ] && return 1
  [ "$SAVE_DIR" != "$DEF_SAVE_DIR" ] && return 1
  [ "$LOG_LEVEL" != "$DEF_LOG" ] && return 1
  [ "${#PROTECT[@]}" -ne 0 ] && return 1
  [ "${#SKIP[@]}" -ne 0 ] && return 1
  return 0
}

config_changed() {
  if all_defaults; then return 1; fi
  [ "$SNAP_LANGUAGE" != "$LANGUAGE" ] && return 0
  [ "$SNAP_EXACT" != "$EXACT" ] && return 0
  [ "$SNAP_MODE" != "$MODE" ] && return 0
  [ "$SNAP_ALLOW" != "$ALLOW_PROTECTED" ] && return 0
  [ "$SNAP_SD" != "$SKIP_DEFAULTS" ] && return 0
  [ "$SNAP_SAVEDIR" != "$SAVE_DIR" ] && return 0
  [ "$SNAP_LOG" != "$LOG_LEVEL" ] && return 0
  [ "${#SNAP_TARGETS[@]}" -ne "${#TARGETS[@]}" ] && return 0
  local i
  for i in "${!SNAP_TARGETS[@]}"; do
    [ "${SNAP_TARGETS[$i]}" != "${TARGETS[$i]}" ] && return 0
  done
  [ "${#SNAP_KEYWORDS[@]}" -ne "${#KEYWORDS[@]}" ] && return 0
  for i in "${!SNAP_KEYWORDS[@]}"; do
    [ "${SNAP_KEYWORDS[$i]}" != "${KEYWORDS[$i]}" ] && return 0
  done
  [ "${#SNAP_PROTECT[@]}" -ne "${#PROTECT[@]}" ] && return 0
  for i in "${!SNAP_PROTECT[@]}"; do
    [ "${SNAP_PROTECT[$i]}" != "${PROTECT[$i]}" ] && return 0
  done
  [ "${#SNAP_SKIP[@]}" -ne "${#SKIP[@]}" ] && return 0
  for i in "${!SNAP_SKIP[@]}"; do
    [ "${SNAP_SKIP[$i]}" != "${SKIP[$i]}" ] && return 0
  done
  return 1
}

save_config_new() {
  local dir fname target
  prompt_save_dir
  if [ -n "$SAVE_DIR" ]; then dir="$SAVE_DIR"; else dir="$SCRIPT_DIR"; fi
  if [ -n "$CONFIG_FILE" ]; then
    fname="$(basename "$CONFIG_FILE")"
  else
    fname="$DEFAULT_CONFIG_NAME"
  fi
  target="$dir/$fname"
  if write_config "$target"; then
    echo "$(msg config_saved): $target"
  else
    echo "$(msg config_not_saved)"
  fi
}

save_config_flow() {
  [ "$YES" = "yes" ] && return 0
  if ! config_changed; then
    echo "$(msg config_no_change)"
    return
  fi
  echo "$(msg save_ask)"
  if [ "$HAS_CONFIG" = "yes" ]; then
    echo "$(msg save_menu)"
    while :; do
      ask confirm_choice ""
      case "$(normalize_ascii "$ASK_VAL")" in
        1)
          if write_config "$CONFIG_FILE"; then
            echo "$(msg config_saved): $CONFIG_FILE"
          else
            echo "$(msg config_not_saved)"
          fi
          return;;
        2)
          save_config_new
          return;;
        3)
          echo "$(msg config_not_saved)"
          return;;
        *) echo "$(msg invalid_choice)";;
      esac
    done
  else
    echo "$(msg save_menu_new)"
    while :; do
      ask confirm_choice ""
      case "$(normalize_ascii "$ASK_VAL")" in
        1)
          save_config_new
          return;;
        2)
          echo "$(msg config_not_saved)"
          return;;
        *) echo "$(msg invalid_choice)";;
      esac
    done
  fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -c|--config)
        CONFIG_FILE="$2"
        shift 2;;
      --language)
        LANGUAGE="$2"
        CLI_LANGUAGE="yes"
        CLI_LANGUAGE_VAL="$2"
        shift 2;;
      -k|--keyword)
        IFS=',' read -r -a parts <<< "$2"
        for p in "${parts[@]}"; do
          [ -n "$p" ] && KEYWORDS=("${KEYWORDS[@]}" "$p")
          [ -n "$p" ] && CLI_KEYWORD_VALS=("${CLI_KEYWORD_VALS[@]}" "$p")
        done
        CLI_KEYWORD="yes"
        shift 2;;
      --exact)
        EXACT="yes"
        CLI_EXACT="yes"
        shift;;
      --trash)
        MODE="trash"
        CLI_MODE="yes"
        CLI_MODE_VAL="trash"
        shift;;
      --permanent)
        MODE="permanent"
        CLI_MODE="yes"
        CLI_MODE_VAL="permanent"
        shift;;
      --search)
        CLI_SEARCH="yes"
        CLI_SEARCH_KW="$2"
        shift 2;;
      --protect)
        CLI_PROTECT="yes"
        CLI_PROTECT_VALS=()
        if [ "$(lower "$2")" = "none" ]; then
          PROTECT_NONE="yes"
        else
          IFS=',' read -r -a parts <<< "$2"
          for p in "${parts[@]}"; do
            [ -n "$p" ] && PROTECT=("${PROTECT[@]}" "$p")
            [ -n "$p" ] && CLI_PROTECT_VALS=("${CLI_PROTECT_VALS[@]}" "$p")
          done
        fi
        shift 2;;
      --allow-protected)
        ALLOW_PROTECTED="yes"
        CLI_ALLOW="yes"
        shift;;
      --skip)
        IFS=',' read -r -a parts <<< "$2"
        for p in "${parts[@]}"; do
          [ -n "$p" ] && SKIP=("${SKIP[@]}" "$p")
          [ -n "$p" ] && CLI_SKIP_VALS=("${CLI_SKIP_VALS[@]}" "$p")
        done
        CLI_SKIP="yes"
        shift 2;;
      --skip-defaults)
        SKIP_DEFAULTS="$(normalize_yn "$2")"
        CLI_SD="yes"
        CLI_SD_VAL="$SKIP_DEFAULTS"
        shift 2;;
      --sudo)
        CLI_SUDO="yes"
        shift;;
      --dry-run)
        DRY_RUN="yes"
        shift;;
      --saveDir)
        SAVE_DIR="$2"
        CLI_SAVEDIR="yes"
        CLI_SAVEDIR_VAL="$2"
        shift 2;;
      --logLevel)
        LOG_LEVEL="$(lower "$2")"
        CLI_LOG="yes"
        CLI_LOG_VAL="$LOG_LEVEL"
        shift 2;;
      --yes)
        YES="yes"
        shift;;
      -h|--help)
        usage
        exit 0;;
      -*)
        if [ "$CLI_TARGET" = "no" ]; then
          CLI_TARGET="yes"
          CLI_TARGET_VALS=("${CLI_TARGET_VALS[@]}" "$1")
          shift
        else
          echo "Unknown option: $1"
          exit 1
        fi;;
      *)
        CLI_TARGET="yes"
        CLI_TARGET_VALS=("${CLI_TARGET_VALS[@]}" "$1")
        shift;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------
main() {
  exec 9<&0
  TMPD="$(mktemp -d 2>/dev/null)" || TMPD="/tmp/search_delete_$$"
  trap 'rm -rf "$TMPD"' EXIT
  HOME_C="$(canonicalize_dir "$HOME")"
  HOME_C="${HOME_C%/}"
  [ -n "$HOME_C" ] || HOME_C="/"
  if ! command -v jq >/dev/null 2>&1; then
    echo "$(msg jq_missing)"
    exit 1
  fi

  KEYWORDS_DIRTY="no"

  parse_args "$@"

  load_config
  apply_cli
  snapshot

  if [ "$CLI_LANGUAGE" = "no" ] && [ "$YES" != "yes" ]; then prompt_language; fi

  resolve_targets

  if [ "$CLI_SUDO" = "yes" ] && [ "$SUDO_OK" != "yes" ]; then ensure_sudo; fi

  if [ "${#TARGETS[@]}" -gt 0 ]; then
    if [ "$CLI_KEYWORD" = "no" ] && [ "$YES" != "yes" ]; then prompt_keywords; fi
    if [ "${#KEYWORDS[@]}" -eq 0 ]; then
      echo "$(msg delete_keyword_need)"
      exit 1
    fi
  fi

  set_traversal

  if [ "$TRAVERSAL" = "yes" ]; then
    if [ "$CLI_SD" = "no" ] && [ "$YES" != "yes" ]; then prompt_skip_defaults; fi
    if [ "$CLI_SKIP" = "no" ] && [ "$YES" != "yes" ]; then prompt_skip_list; fi
  fi
  if [ "$CLI_MODE" = "no" ] && [ "$YES" != "yes" ]; then prompt_mode; fi

  prepare_protect

  if [ "${#TARGETS[@]}" -gt 0 ]; then
    match_and_select
  fi
  if [ "${#DIRECT_CANDIDATES[@]}" -gt 0 ]; then
    merge_direct_candidates
  fi
  partition_protected
  resolve_protected_selection

  confirm_loop

  if [ "$SUDO_OK" = "yes" ] && [ "$(id -u)" -ne 0 ]; then
    sudo -v 2>/dev/null || true
  fi

  START_SEC=$(date +%s)
  execute
  show_summary

  save_log_flow
  save_config_flow

  echo "$(msg done)"
}

main "$@"
