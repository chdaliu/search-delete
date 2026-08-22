# 搜索即删（Search & Delete）

macOS 交互式工具：**按文件名关键字搜索并删除**文件/文件夹——默认移入废纸篓
（可恢复），也可永久删除——支持中英文双语界面、多关键字与多目标（搜索根）、
全盘搜索 sudo、内置用户数据保护区、JSON 配置与自动化测试。

```
scripts/
  search_delete.sh          # 按关键字搜索并删除（废纸篓 / 永久）
docs/
  README.md                 # 英文
  README.zh-CN.md           # 中文
tests/
  create_test_fixture.sh    # 构建覆盖全部规则的测试夹具
  run_tests.sh              # 自动化断言
AGENTS.md                   # 可重现构建说明（英文）
AGENTS.zh-CN.md             # 可重现构建说明（中文）
```

## 运行环境

- macOS（依赖 `find -iname`、`mv`、`rm`、`jq`，可选 `osascript` 与 `sudo`）。
- `jq`（解析 JSON 配置）。
- 全盘搜索（`--search`）自动尝试 `sudo`；删除无写权限项需要 `--sudo`。
- 兼容 macOS 自带 bash 3.2（不使用关联数组、`${var,,}` 等写法）。

## 快速开始

```bash
# 先预览（不会删除任何内容）——真实执行前请务必先预览
./scripts/search_delete.sh ~/Downloads --keyword "draft,tmp" --dry-run

# 交互式：选择搜索根、关键字、模式，最后确认
./scripts/search_delete.sh ~/Downloads --keyword report

# 一次性无交互：把 ~/Downloads 中的命中移入废纸篓
./scripts/search_delete.sh ~/Downloads --keyword "draft" --yes

# 永久删除（不可恢复）多个搜索根中的命中，无交互
./scripts/search_delete.sh ~/Downloads ~/Desktop --keyword "old copy" \
    --permanent --yes

# 精确匹配、目录内搜索、附加保护路径
./scripts/search_delete.sh ~/Documents --keyword Legacy --exact \
    --permanent --protect "~/Documents/Important"
```

## 工作原理

1. **搜索根**是搜索发生的地方。来源为命令行（位置参数）、配置文件
   （`searchRoots` 数组）或交互式菜单：
   - `1) 输入一个或多个目录`（删除将在其内按关键字搜索），
   - `2) 全盘按关键字搜索`——选中的结果将**直接删除**（见第 4 步）。
   重叠的搜索根会折叠为**最外层覆盖集**（含 macOS firmlink/符号链接别名
   规范化）。没有「未提供搜索根即退出」——菜单会一直循环直到至少有一个
   搜索根或一个选中结果。
2. **删除关键字**（`--keyword "k1,k2"`，逗号分隔或重复指定）决定搜索根内
   哪些路径命中：**名称**包含（或 `--exact` 精确等于）任一关键字的路径即
   命中——多关键字取并集，仅匹配文件名。交互模式每行输入一个、空行结束。
   关键字只在存在搜索根时才询问。
3. 命中结果流式折叠（一个目录及其内部命中的子目录/文件只出现一次，即该
   目录），编号列出供选择（`a`=全部，`c`=取消，编号/范围；`--yes` 自动全选）。
   编号/范围可跨多轮累积，空行结束；非法 token 提示警告并忽略、同行有效项
   保留。中文输入法的全角数字/逗号会自动当作 ASCII。确认菜单在执行前会列出
   已选路径。
4. 从**全盘关键字搜索**（`--search "k1,k2"` 或菜单选项 2）选中的路径直接
   成为删除候选——不再有第二轮关键字，选中的就是最终要删的路径。同一路径的
   firmlink 别名（`/Users/...` 与 `/System/Volumes/Data/Users/...`）只显示
   一条，且用短形态。
5. 位于**用户数据目录**内的候选会被单独拆出，需再确认一轮（见下）。
   其余候选在确认菜单后按所选模式删除。

## 删除模式

- `--trash`（默认）：移入 `$HOME/.Trash`。同名冲突自动加 ` 2`/` 3` 后缀
  （Finder 风格）；跨卷移动回退到 Finder（`osascript`）。可恢复。
- `--permanent`：用 `rm -f` / `rm -rf` 移除。**不可恢复。** 交互运行会打印
  警告，且确认菜单仍然生效。

`--dry-run` 仅预览、不删除（总结与日志标 `(dry-run)`）。
`--yes` 自动确认并自动保存日志。

## 安全设计

删除工具按层级加固：

- **硬性拦截**（即使 `--yes` 也绝不删除）：搜索根本身、其祖先、`/`、`$HOME`、
  `.`/`..`，以及关键系统路径（`/System`、`/Applications`、`/Library`、`/opt`、
  `/usr`、`/private`、`/bin`、`/sbin`、`/etc`、`/var`、`/Volumes`）。
  被拦截的路径会计数并记录。
- **用户数据保护区**（默认，按 `$HOME` 解析）：`Documents`、`Downloads`、
  `Music`、`Movies`、`Pictures`、`Desktop`、`Public`。位于其中或等于其本身
  的命中，**必须先经过额外一轮确认**——列出这些保护区命中并让你逐个选择，
  未选中的保留（计入 `Protected`）。`--allow-protected` 是跳过该额外确认的
  显式开关；`--protect none` 完全关闭保护区；`--protect "p1,p2"` 追加自定义
  保护路径（绝对、`~` 或 `$HOME` 下的裸名）。
- **`--yes` 下保护区命中一律保留**，除非显式传 `--allow-protected`——自动化
  流程永远无法静默删除用户数据。
- **跳过规则**（内置缓存/开发目录 + `--skip` 清单）在**搜索阶段**生效：
  命中的目录直接剪枝，因此 `Caches`、`node_modules`、`build`、`.git`、
  `.Trash` 等内部的命中永远不会被发现。包文件夹（`.app`、`.library` 等）的
  内容同样被剪枝；**自身名字命中**关键字的包文件夹才会作为候选返回。
- **确认菜单**在交互模式下总在执行前出现：`1 确认并执行  2 修改  3 重新选择
  4 退出`。`--permanent` 额外显示警告。

## 关键字搜索（全盘搜索与删除命中）

- `--search "k1,k2"` 全盘：自动尝试 sudo（唯一的密码提示来自 sudo 本身；
  `--yes` 静默使用 `sudo -n`）。无 sudo 时回退 `$HOME`、`/opt`、`/Applications`。
  选中的结果直接删除（保护区与硬性拦截仍然生效）。
- `--sudo` 还可让无写权限项通过 sudo 删除。
- `--exact`：按完整 basename 精确匹配而非子串。
- 多关键字即**并集**（命中任一即中）。

## sudo

`ensure_sudo()`：已是 root → 直接通过；`--yes` → `sudo -n` 静默尝试；否则
`sudo -v` 弹一次密码——在交互式提示前脚本会先说明为何需要密码以及密码不会
显示。sudo 用于 (a) 全盘搜索时读取所有位置，以及 (b) 删除当前用户不可写的
项（`sudo rm` / `sudo mv`）。执行前会 `sudo -v` 刷新凭证缓存，长任务中途不会
再次弹窗。

## 配置

`search_delete.config.json` 读取/写入于 `--saveDir`（默认项目根目录）：

```json
{
  "language": "en",
  "searchRoots": ["/path"],
  "keywords": ["report"],
  "exact": false,
  "mode": "trash",
  "protect": [],
  "allowProtected": false,
  "skipDefaults": true,
  "skip": [],
  "saveDir": "",
  "logLevel": "all"
}
```

优先级：**命令行 > 配置文件 > 默认值**。选择与内置默认值相等的值不算配置
变更，因此"仅传目标、其余默认"的运行不会询问保存。`--yes` 下从不写配置。

## 非交互模式

把所有相关选项都通过命令行传入，再加 `--yes`（自动确认、自动保存日志、绝不
弹提示；保护区命中除非 `--allow-protected` 否则一律保留）。命令行未给关键字时
脚本要求至少一个（否则非 0 退出）。`--dry-run` 永远可以放心写入脚本。

## 日志

`--logLevel all|changes|none`（默认 `all`）控制控制台输出；总结始终打印。
只要发生删除**或出现任何失败/拦截/保护区保留**，就会把操作日志写入
`<saveDir 或项目根>/log/search_delete_log_<时间戳>_deleted_<N>.log`——
失败绝不静默丢失。日志记录：已删除/已入废纸篓路径、错误（删除失败）、已拦截
路径、保护区保留路径、跳过路径、总结。

## 测试

```bash
tests/create_test_fixture.sh   # 重建 tests/fixture（覆盖全部情况）
tests/run_tests.sh             # 自动化断言，失败时非 0 退出
```

夹具同时充当假的 `$HOME`（内含 `Documents`、`Downloads` 等），使保护区测试
完全隔离。永久删除只会在 `tests/out` 内的拷贝上执行。
