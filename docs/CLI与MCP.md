# devstore CLI、MCP Server 与桌面应用

版本 0.1.0，2026-10-29。实现 [v3 数据模型](design/v3数据模型.md) 的一个子集。适配器：`miniconda`（导入、23 项验证）与 `empty`（新建空环境、4 项基础验证）。代码在 `Sources/`，测试在 `Tests/`。

## 构建

```bash
swift build            # 调试版：.build/debug/devstore、.build/debug/devstore-mcp
swift build -c release # 发布版：.build/release/…
swift test             # 18 个测试；DEVSTORE_INTEGRATION=1 时额外用真实 hdiutil 跑新建→挂载→验证→卸载→删除
scripts/build-app.sh   # 生成 build/DevStore.app（ad-hoc 签名，未公证），内含 Contents/Helpers/devstore 与 devstore-mcp
```

依赖：Swift 6.2、macOS 14+、swift-argument-parser 1.5.0（MCP Server 不依赖它）。

## 文件位置

| 内容 | 位置 |
|---|---|
| 主机登记 | `~/Library/Application Support/DevStore/`：`registry.json`、`journal.jsonl`、`grants.jsonl`、`plans/` |
| 存储库 | 任意目录，含 `store.json`；本机测试用 `artifacts/store` |
| 环境 | `<store>/environments/<kind>/<environmentId>/environment.json` |
| 映像 | `…/images/<imageId>/environment.sparsebundle`，旁注 `image.json`、挂载期间的 `lease.json`、`verifications/<runId>.json` |
| 卷内清单 | `<挂载点>/.devstore/manifest.json` |
| 挂载槽 | `~/.local/dev/<kind>/<slot>` |

与数据模型草案的差异：映像放在 `images/<imageId>/` 下（草案写的是环境目录下单个 `environment.sparsebundle`），这样同一环境的 standby 映像不会冲突；租约也按映像存放。`DEVSTORE_HOME`、`DEVSTORE_SLOT_ROOT` 两个环境变量只用于测试。

## 命令

| 命令 | 级别 | 说明 |
|---|---|---|
| `store add <path> [--create]`、`store list` | 登记 | 注册存储库 |
| `status [--json]`、`inspect <env>`、`journal` | inspect | 只读 |
| `install-sdk <env> --installer <sh> --sha256 <hex>` | mutate | 环境须已挂载且使用 empty 适配器。安装器名称/平台/SHA-256 核对通过后，以批处理模式在沙箱中安装（禁网、禁读原安装、只写卷）；装完写入卷内 condarc，转为 miniconda 适配器 |
| `create --store <s> --kind <k> --name <n> [--slot current] [--size 20]` | mutate | 新建空的 APFS sparse bundle（按需增长），建立 `bin deps state/{home,config,share} cache tmp` 布局与卷内清单，登记槽位 |
| `delete <env>` | destructive | 环境必须未挂载、无租约。把整个环境目录（所有映像、记录、验证结果）**移到废纸篓**，解除槽位，删除空占位目录。终端确认需输入 `kind/slot` |
| `plans`、`reject <planId>` | — | 列出未执行的计划；拒绝后计划永远不能执行（拒绝仅限交互式终端或应用） |
| `import <bundle> --store <s> --name <n> [--kind miniconda] [--slot current]` | mutate | 把未挂载的映像 APFS 克隆进存储库，写入卷内清单，登记槽位。内容必须是为该槽位路径构建的 |
| `mount <env>`、`unmount <env>` | mount | 挂载前检查占位目录、租约、同 UUID 卷和主机绑定；挂载后核对卷 UUID 与清单，不符则立即卸载回滚。卸载从不强制 |
| `approve <planId>` | — | **只能在交互式终端**中批准计划；授权 10 分钟内有效，一次有效 |
| `apply <planId>` | — | 执行已批准的计划，或由策略覆盖的挂载/卸载 |
| `policy allow\|revoke\|show <env>` | — | 为单个环境设置常驻挂载/卸载策略；修改只能在交互式终端 |
| `run <env> [--confine] [--deny-network] -- <cmd>` | session | 只把会话变量注入子进程；`--confine` 用 sandbox-exec 禁读原安装、Homebrew 和 `/usr/local` |
| `env <env> [--json]` | session | 输出会话变量 |
| `verify <env> [--stage s]` | session | 运行 23 项 Miniconda 验证（沙箱、禁网），结果记入映像 |

`<env>` 可以是环境 id（或前缀）、`kind/slot`，或显示名。

所有改动类命令都可以加 `--plan-only [--json]`，只生成并打印计划。

## 授权模型

1. 任何改动都先生成**计划**，包括目标、前置条件、影响和"不触碰"清单，并计算 SHA-256 摘要保存下来。加载计划时会重算摘要，计划文件被改过就拒绝。
2. 执行前需要以下任一项：
   - 未使用、未过期、摘要匹配的**授权**，只能由 `approve` 在交互式终端产生；
   - 覆盖该环境和该动作的**策略**，只限 mount/unmount。

   计划一旦执行就不能重放，无论授权来自哪里。
3. 执行时重新检查全部前置条件，每一步写入 `journal.jsonl`。失败时只做安全回滚：卸载、删除本次新建且未登记的副本、删除本次写入的租约。
4. 在交互式终端里直接运行 `import`、`mount`、`unmount`，会显示计划并当场确认，相当于 approve 和 apply 一起做。

局限：判断"交互式"依赖 `isatty`。能伪造终端的程序可以冒充用户确认，所以这只能防止 Agent 意外自批，不能防止恶意本地进程。将来 GUI 的批准界面应改用系统级确认，例如本地身份验证。

## MCP Server

`devstore-mcp` 是 stdio 上的 JSON-RPC 2.0（每行一条消息），协议版本 `2025-06-18`。工具：

| 工具 | 说明 |
|---|---|
| `devstore_status`、`devstore_inspect`、`devstore_env`、`devstore_journal` | 只读 |
| `devstore_plan_mount`、`devstore_plan_unmount`、`devstore_plan_import` | 只生成计划，并告诉 Agent 需要用户执行什么 |
| `devstore_plan_create`、`devstore_plan_delete`、`devstore_plans` | 新建/删除计划与待批准列表；删除为破坏性，任何策略都不覆盖 |
| `devstore_apply` | 只在有用户授权或策略时执行，返回 `authorizedBy` |
| `devstore_run` | 捕获输出（各取最后 64 KB），默认 `confine: true` |
| `devstore_verify` | 运行验证并记录 |

没有批准工具，任何工具参数里也没有"确认"字段（有测试保证）。在 Claude Code 中注册：

```bash
claude mcp add devstore -- /Users/jackson-hao/Documents/Code/DevStore/.build/release/devstore-mcp
```

## 2026-10-29 实机测试

对象：`artifacts/miniconda-20261029/miniconda.sparsebundle` 的 APFS 克隆，以 `miniconda/current` 导入到 `artifacts/store`（环境 `a1bcde03…`，映像 `27dd2ef9…`，卷 UUID `91FF58B2-…`）。

- 导入：无终端时被拒；用户在终端批准后执行成功。发现的 4 个环境和包数（113/19/19/82）与实验报告一致。
- 授权：已用过的导入计划被拒；篡改过的计划因摘要不符被拒；用户设置策略后挂载和卸载无需逐次批准；执行过的计划在卸载后重放被拒。
- 挂载：重复挂载被前置条件拦下（占位目录、租约、同 UUID）；占位目录里有杂物时拒绝；把映像记录的卷 UUID 改成错误值后，挂载被核对发现，立即卸载回滚，没有残留租约或挂载。
- 卸载：卷被占用时失败，不强制，租约保留；正常卸载后租约删除，占位目录为空。
- 会话：`run` 下 Python 和 conda 都指向卷内；退出码原样传递；`--confine` 下读原安装返回 `Operation not permitted`；卸载后拒绝运行。
- 验证：CLI 与 MCP 各跑一轮 Swift 版套件，都是 23/23。
- MCP：用驱动脚本走完"计划 → 执行（策略）→ 运行 → 验证 → 卸载"全流程。
- 原安装 103,075 项与 shell/conda 配置摘要不变；源映像未修改。

## 桌面应用（SwiftUI）

`build/DevStore.app`，与 CLI/MCP 共用 `DevStoreCore`，每 4 秒刷新一次。

- 侧栏：环境（状态点：绿=已挂载且身份核实，红=挂载但身份不符，灰=未挂载，橙=存储库离线）、待批准计划（带角标）、存储库、事务日志。
- 环境详情：挂载/卸载、运行验证（逐项进度）、复制会话环境变量（export 语句）、在 Finder 中显示、挂载策略开关、删除；位置与身份、组件、最近验证、已知警告。
- 工具栏：新建空环境、导入映像（只支持 Miniconda）、刷新；存储库页可登记文件夹为存储库。
- 计划确认页展示核心生成的原始计划（目标、前置条件、影响、不触碰清单、摘要）。按钮：取消；对 Agent/CLI 生成的计划还有"拒绝""仅批准"（交给 Agent 用 `devstore_apply` 执行）。
- 授权：应用里的挂载/卸载按钮本身即用户操作（授权 `via: gui`）；新建与导入先显示计划，确认后执行；**删除和其他破坏性计划额外要求 Touch ID 或登录密码**（LocalAuthentication），授权记为 `gui-authenticated`。

界面文字为中文；计划内容（目标、影响等）来自核心层，目前是英文。

### 2026-10-29 检查

- 用真实 hdiutil 的集成测试覆盖了新建、挂载、身份核对、基础验证、确认会话变量、卸载、删除（移到测试用废纸篓），以及"挂载中不能删除""同槽位不能重复新建""计划不能执行两次"。全程在 `/private/tmp`，不碰 `~/.local/dev`。
- 集成测试发现 `isMountPoint` 用 `standardizedFileURL` 会把 `/private/tmp` 改写成 `/tmp`，导致挂载判断失败、回滚时卸载不掉，已改为 `realpath` 比较。真实槽位 `~/.local/dev` 不受影响。
- 打包时发现 APFS 不区分大小写，`devstore` 会覆盖 `DevStore` 可执行文件，所以 CLI/MCP 放在 `Contents/Helpers/`。
- 启动应用并截图：侧栏、存储库表、新建表单（字段不完整时"生成计划"不可用、实时显示挂载路径）、计划确认页渲染正常。生成的 `uitest/current` 新建计划只取消、未批准，留在待批准列表中。后台辅助功能操作无法切换 SwiftUI 侧栏选中项，因此环境详情页和待批准页没有截图检查，需用户确认。

## 尚未实现

检查点与归档恢复、compact（需走临时副本流程）、转移、跨槽重定位、导入已受管的副本、多存储库切换 active、陈旧租约接管、数据分类清理、Miniconda 以外的导入适配器、应用图标与公证。
