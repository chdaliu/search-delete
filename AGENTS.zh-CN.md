# AGENTS.md — 可重现构建说明（Reproducible build spec）

本文档是**从零重建「搜索即删」（Search & Delete）项目**的权威规范。一个有
能力的 AI 代理可以依据下列布局、行为与约定复现脚本与测试套件，再用
`tests/run_tests.sh` 验证。

> 中文 README 是 `docs/README.zh-CN.md`；英文是 `docs/README.md`。
> 本规范的英文翻译见 `AGENTS.md`。

## 1. 项目布局

```
keyword-search-delete/            （仓库根；项目：Search & Delete）
├── scripts/
│   └── search_delete.sh         # 按关键字搜索并删除（废纸篓 / 永久）
├── docs/
│   ├── README.md                # 英文
│   └── README.zh-CN.md          # 中文
├── tests/
│   ├── create_test_fixture.sh   # 构建覆盖全部规则的 tests/fixture
│   └── run_tests.sh             # 自动化断言（必须通过）
├── AGENTS.md                    # 本规范（英文）
├── AGENTS.zh-CN.md              # 本规范（中文）
└── opencode.json                # 注册 AGENTS.zh-CN.md 为 instructions
```

脚本位于 `scripts/`。它把 `SCRIPT_DIR` 计算为**项目根目录**（`scripts/` 上一
级），使配置与日志默认落在项目根目录。

## 2. 硬约束

- **bash 3.2 兼容**（macOS `/bin/bash`）：不用关联数组、`${var,,}`/`${var^^}`、
  `mapfile`；用 `tr` 处理大小写、`while read` 循环、`[[ =~ ]]`。
- **双语 UI**：`msg()` 分发到 `msg_en <key>` / `msg_zh <key>`，各自是返回
  字符串的 `case`；`msg key [args]` 做 printf 格式化。`LANGUAGE` 为 `en`
  （默认）或 `zh`。每个 key 必须同时存在于两张表。
- **提示助手** `ask <msgkey> [default]`：打印 `msg + " [default: X]"`，从
  复制的 stdin（fd 9）读一行，EOF 时干净退出（消息 `input_closed`），脚本化
  运行不会死循环；`check_exit` 在用户输入 `exit` 时中止。
- **依赖**：`jq`（配置）、`find -iname`/`-path`（匹配与剪枝）、`mv` + `rm`
  （删除）、`osascript`（可选的废纸篓回退）、`sudo`（全盘搜索与不可写项）。
  顶部 `export LC_ALL=C`。
- **除文件头与分节标记外不写代码注释**；脚本通过 `--help` 自述。

## 3. 模型

工具在**搜索根**内查找**名称**命中任一删除关键字的路径，然后删除所选命中。
搜索根、全盘搜索选中项与命中是三个不同的概念：

- **搜索根**（`TARGETS`）：搜索发生的目录（或文件）。来源：命令行位置参数、
  配置 `searchRoots`、或交互式菜单：`1) 输入一个或多个目录`（删除将在其内按
  关键字搜索）、`2) 全盘搜索`。重叠根折叠为**最外层覆盖集**并规范化
  （`/System/Volumes/Data` firmlink 前缀存在时去掉；符号链接目录经
  `collapse_file` 用 `realpath` 解析）。没有「无目标退出」——菜单循环直到至少
  有一个搜索根或一个选中结果。
- **全盘关键字搜索**（`--search "k1,k2"`，尝试 sudo，否则回退 `$HOME` `/opt`
  `/Applications`；菜单选项 2）：选中的结果成为**直接删除候选**
  （`DIRECT_CANDIDATES`）——按原样删除（保护区拆分与硬性拦截仍然生效），
  **不再有删除关键字轮次**。结果先按规范化键去重（`collapse_search_results`：
  `/Users/...` 与 `/System/Volumes/Data/Users/...` 之类的 firmlink 别名收敛为
  一条，以短形态显示/删除；符号链接叶子只按规范化父目录 + basename 作键，
  绝不解析链接自身），再在原始路径上做覆盖集折叠（`collapse_candidates`，
  刻意不做规范化——命中的符号链接必须以链接身份删除，绝不删除其目标）。
- **删除关键字**（`KEYWORDS`）：`--keyword "k1,k2"`（逗号分隔或重复）。路径的
  **basename** 包含（或 `--exact` 等于）任一关键字即命中（大小写不敏感
  `-iname`）。并集语义。**仅当存在搜索根时**才要求至少一个关键字；交互模式
  每行一个。
- **命中发现**（`match_and_select`）：对每个根运行 `find`，用 `-iname "*kw*"`
  （精确为 `-iname kw`）匹配 basename，搜索时剪掉跳过规则与包文件夹。原始命中
  在**原始路径**上流式折叠为覆盖集（`collapse_candidates`，刻意不做规范化——
  命中的符号链接目录必须以链接身份删除，绝不删除其目标）。然后编号选择
  （`a`/`c`/编号/范围；`--yes` 自动全选）。选择输入会校验：非法 token 或越界
  编号提示警告并忽略，同行中的有效 token 保留；编号/范围跨轮累积，空行结束。
  全角数字（`１`）、逗号（`，`）、顿号（`、`）和表意空格（中文输入法下常见）
  在数字、选择与 y/n 提示处自动归一化为 ASCII（关键字与路径文本不做归一化）。
  确认菜单列出已选候选（数量 + 路径，上限 200）。
- **删除候选**（`CANDIDATES`）：根搜索选中项加合并进来的直接候选
  （`merge_direct_candidates`，去重，计入 `FOUND_N`）经保护区拆分、确认菜单，
  再执行。

## 4. 安全（必须）

1. **硬性拦截**（`is_blocked`，在 `execute()` 中强制）：候选等于 `/`、`.`、
   `..`、`$HOME`（含规范化形式 `HOME_C`）、等于或为任一搜索根的祖先
   （`p == root` 或 `root == p/*`），或等于/为任一 `SYSTEM_GUARDS` 路径
   （`/System /Applications /Library /opt /usr /private /bin /sbin /etc /var
   /Volumes`）的祖先。拦截 → 计入 `BLOCKED_N`、写入 `$TMPD/blocked.txt`、
   记录日志，绝不删除（即使 `--yes`）。
2. **保护区**（`prepare_protect`）：默认区是 `$HOME_C` 下七个 macOS 用户数据
   目录（`Documents Downloads Music Movies Pictures Desktop Public`）加用户
   `PROTECT` 条目（绝对 / `~` / `$HOME` 下裸名）。`--protect none`
   （`PROTECT_NONE=yes`）同时关闭默认区与用户条目。每个区路径都规范化
   （`canonical_path`），使 `/var/...` 与 `/private/var/...` 别名能匹配规范化
   后的 find 输出。   `is_protected` 在候选等于某区或位于其下时返回真（候选的**原始与规范化两种
   形态**都会比较，使全盘搜索找到的候选的 `/var/...` 与 `/private/var/...`、
   firmlink 别名仍能命中规范化后的保护区）。
   `partition_protected` 把 `CANDIDATES` 拆成 `PROTECTED_ITEMS` /
   `PLAIN_ITEMS`。`resolve_protected_selection`：
   - `--allow-protected` → 全部留在删除清单（无额外提示）；
   - `--yes`（无 allow）→ 全部保留（计入 `PROTECTED_N`，记录）；
   - 交互 → 编号列出并询问删除哪些（`a`=全部，空/`c`=全部保留，编号/范围）；
     未选中的保留并计数、记录。
3. **`--yes` 绝不删除保护区**，除非传了 `--allow-protected`。
4. **跳过规则作用于搜索**：`build_prune_args` 从默认缓存/开发关键字（`-iname`，
   大小写不敏感——因为 BSD `find -name` 区分大小写）与默认/用户路径条目
   （`-path`）构建 `find` 剪枝表达式；`build_package_prune` 剪掉包文件夹内容，
   但名字命中关键字的包本身仍会打印。`prepare_search_skip` + `is_search_skipped`
   再对结果过滤（basename 等于跳过关键字，或位于某解析后的跳过路径内/下）。
   因此 `Caches`/`node_modules`/`build`/`.git`/`.Trash`/… 内部的命中永远不会
   被发现。
   当搜索根本身就是一个跳过目标（其 basename 等于某个跳过关键字，或位于某
   解析后的跳过路径内/下）时，该根仍会被搜索：覆盖它的那条规则对该根豁免
   （`match_and_select` 中按根重建跳过表：`build_prune_args "$root"` /
   `prepare_search_skip "$root"`）。
5. **确认菜单**（`confirm_loop`）在非 `--yes` 时总在执行前出现：
   `1 确认 2 修改 3 重新选择 4 退出`。`--permanent` 打印警告。`--dry-run`
   永不执行。
6. **不可写项**：无 sudo 时跳过（计入 `SKIP_N`，记录）；有 `SUDO_OK` 时用
   `sudo rm`/`sudo mv` 删除。

## 5. 删除

`delete_one()`：dry-run 计数并记 `(dry-run)`；废纸篓模式调用 `move_to_trash`
（mkdir `$HOME/.Trash`、`mv`、经 `collide_basename` 的 Finder 式冲突后缀
`name 2.ext`、需要时 `sudo mv`、跨卷 `osascript` Finder 回退）；永久模式文件/
符号链接用 `rm -f`、目录用 `rm -rf`。成功 → `DELETED_N`（废纸篓模式另计
`TRASHED_N`）+ `$TMPD/deleted.txt` + 日志；失败 → `ERROR_N` + `$TMPD/errors.txt`。

## 6. sudo

`ensure_sudo()`：root → `SUDO_OK=yes`；`--yes` → 静默 `sudo -n true`；否则
`sudo -v` 弹一次密码，且在交互式提示前脚本先打印双语解释（`sudo_hint`：
说明为何需要密码及密码不会显示；提示本身来自 sudo）。`SUDO_OK` 用于全盘搜索
（`sudo find /`）与删除不可写项。`--sudo` 在不做全盘搜索时也可强制。
`execute()` 前 `sudo -v` 刷新凭证缓存。

## 7. 日志、总结、操作日志

- `--logLevel all|changes|none`（默认 `all`）：`all` 打印删除/废纸篓/错误/拦截；
  `changes` 去掉保护区/跳过细节；`none` 不打印。总结始终打印。
- 总结标签：`Search roots`、`Keywords`、`Mode`、`Matched`、`Protected (kept)`、
  `Blocked`、`Deleted`、`Trashed`（仅废纸篓模式）、`Errors`、`Elapsed`，外加
  `--dry-run` 下的 `(dry-run, nothing modified)`。英文标签文本以关键词独占一行
  开头（`Deleted: N`），便于测试用 `sed` 解析。
- 操作日志：仅当非 `--dry-run` 且 `DELETED_N > 0` **或** `ERROR_N > 0` **或**
  `BLOCKED_N > 0` **或** `PROTECTED_N > 0` 时写入——失败绝不丢失。`--yes`
  自动保存；交互询问。路径 =
  `$(resolve_save_dir)/log/search_delete_log_YYYYMMDD_HHMMSS_deleted_<N>.log`。
  分区：deleted、errors、blocked、protected、skipped、summary。

## 8. 配置

`search_delete.config.json`，保存到 `--saveDir` 或项目根目录。Schema：
`{ "language","searchRoots":[], "keywords":[], "exact", "mode", "protect":[],
"allowProtected", "skipDefaults", "skip":[], "saveDir", "logLevel" }`。
`load_config` 读取 `.searchRoots[]` / `.keywords[]` / `.protect[]` / `.skip[]`；
`write_config` 用 `jq -n --arg --argjson` 写出。快照 + `config_changed`
（与快照比对）+ `all_defaults`（等于内置默认值的值不算变更）驱动保存提示。
优先级：CLI > 配置 > 默认值。`--yes` 下从不保存配置。

## 9. 测试（可重现关卡）

`tests/create_test_fixture.sh [dir]`（默认 `tests/fixture`）构建一个同时充当
**假 `$HOME`** 的目录树（使保护区能隔离解析）。`rm -rf` 前必须先清理权限。
覆盖：
- 命中：`report.txt`、`Report 2026.docx`（大小写不敏感）、`report_v2.pdf`、
  `report(1).txt`（特殊字符）、`.hidden_report`（隐藏）、`dir_report/`、
  `AnnualReport/`、嵌套 `sub/report_deep.txt`、`"with space/report 2.txt"`、
  `a/same.txt` + `b/same.txt`（废纸篓冲突对）、`exact_only`/`exact_other`
  （精确匹配）、符号链接 `link_report`、`single_root.txt`；
- 跳过剪枝：`Caches/report_cache.dat`、`node_modules/report.js`、
  `Temp/report_temp.dat`（绝不能被发现）；
- 包：`Legacy.app/Contents/info.plist`（自身名字命中才成为候选；内容剪枝）；
- 保护区：`Documents/user_report.txt`、`Downloads/dl_report.png`、
  `Desktop/desk_report.txt`、`Public/pub_report.txt`；
- 不命中：`keep.txt`、`photo.png`、`keep_nested/not_report.txt`；
- 无写权限：`noaccess_dir/`（chmod 000）与 `noaccess_file`（chmod 000）；
- 配置：指向夹具的 `search_delete.config.json`。

`tests/run_tests.sh`（必须通过；永久删除只在 `tests/out/` 下的拷贝上执行，
废纸篓/保护区用假 `HOME=$FIX`，绝不触碰真实废纸篓或家目录）：
1. 对脚本与两个测试脚本运行 `bash -n`；
2. 夹具构建；
3. dry-run：`"$FIX" --keyword report --dry-run --yes` 报告 `Matched>0`、
   `Deleted>0`（将要删）且**什么都没删**；
4. 拷贝上永久删除：`report*` 命中被移除，`keep.txt`/`photo.png` 保留；
5. 目录命中删除整个文件夹（`AnnualReport` 及其内容消失）；
6. 嵌套命中（`sub/report_deep.txt`）被删除；
7. 特殊字符/空格：`report(1).txt`、`with space/report 2.txt` 被删除；
8. 隐藏文件 `.hidden_report` 命中并删除；
9. 跳过剪枝：真实运行后 `Caches/report_cache.dat`、`node_modules/report.js`、
   `Temp/report_temp.dat` 全部仍在；
10. 包：关键字 `legacy` 删除 `Legacy.app`（自身名字），关键字 `report` 时
    `Legacy.app` 原封不动（内容被剪枝）；
11. 拷贝上 `--exact`：只删 `exact_only`，`exact_other` 保留；
12. 多关键字并集：`keep,photo` 删除 `keep.txt` 与 `photo.png`；
13. 多根：两个根都被搜索，各根命中都被删除；
14. 废纸篓模式且 `HOME=$FIX`：命中移入 `$FIX/.Trash`，原位置消失，冲突对变为
    `same.txt` + `same 2.txt`；
15. 默认保护：仅 `Documents/Downloads` 内的命中且 `--yes` 时全部保留
    （`Protected>0`、`Deleted=0`，文件仍在）；
16. 保护区交互（管道 stdin）：选择子集只删所选（`Protected=N`，被选删除、
    其余保留）；
17. `--allow-protected` 删除保护区命中（`Protected=0`）；
18. `--protect none` 关闭保护（`Deleted=N`）；
19. 自定义 `--protect ABS` 把额外路径标为受保护；
20. 硬性拦截：作为搜索根且命中关键字的文件计 `Blocked=1` 并幸存（`--yes`
    不能覆盖）；
21. 无命中：exit 0、`Matched=0`、无任何变化；
22. `--language zh` 输出包含 `[已删]`；
23. 配置往返：`-c` 配置提供根+关键字，删除生效；
24. 日志落在 `tests/log/` 且包含已删除路径。
25. 全盘搜索直接删除（当有无密码 sudo 时跳过该测试）：假 `HOME=$OUT/c25` 内含
   `zz_sd_dir/` 与 `Documents/zz_sd_doc.txt`；不带任何 `--keyword` 运行
   `--search zz_sd --yes --permanent` 直接删除 `zz_sd_dir`（无删除关键字轮次），
   而 `Documents/zz_sd_doc.txt` 被保留（`Protected>0`）；
26. 同一流程加 `--allow-protected` 时删除保护区文件（`Protected=0`）。
27. 非法选择 token（管道 stdin：先 `zz` 后 `a`）被拒绝并提示 `输入无效` 后重问，
    随后运行删除选中的命中。
28. 混合有效+非法 token（`1,zz` 后 `2`）保留有效部分（提示 `无效输入已忽略`，
    `Deleted=2`）。
29. 全角（中文输入法）数字与逗号（`1，2`）被接受（`Deleted=2`，无警告）。

## 10. 需要编码/预期的 macOS 已知行为

- **BSD `find -name` 区分大小写**，与文件系统大小写敏感性无关——关键字剪枝/
  匹配一律用 `-iname`。
- **`/var` → `/private/var`**：`realpath` 规范化会改变路径形态；保护区与
  `$HOME` 护栏必须规范化（`HOME_C`、`canonical_path`）才能与规范化后的 find
  输出比较。
- **Firmlinks**：`/opt`、`/Applications`、`/Users`、`/Library` 是 APFS 指向
  `/System/Volumes/Data` 的 firmlink；根折叠会去掉该前缀，全盘搜索结果按规范
  化键去重别名（以短形态显示/删除）。
- **TCC**：`~/Pictures`、`~/Desktop`、`~/Documents` 等目录可能受 TCC 保护；
  无「完全磁盘访问」权限的终端可能读不到它们。
- **废纸篓**：`$HOME/.Trash` 可能不存在（测试会创建假 HOME）；跨卷移动需要
  `osascript` Finder 回退。

## 11. 复现清单

1. 按第 2–8 节编写 `scripts/search_delete.sh`。
2. 按第 9 节编写 `tests/create_test_fixture.sh` 与 `tests/run_tests.sh`。
3. 所有脚本 `chmod +x`；对每个文件运行 `bash -n`。
4. `tests/run_tests.sh` 必须全部 `PASS`、无 `FAIL`。
5. `./scripts/search_delete.sh --help` 必须正常渲染。
