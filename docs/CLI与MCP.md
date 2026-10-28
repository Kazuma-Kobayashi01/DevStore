# devstore CLI 与 MCP Server

版本 0.1.0，2026-10-29。实现 [v3 数据模型](design/v3数据模型.md) 的一个子集，只带 Miniconda 适配器。代码在 `Sources/`，测试在 `Tests/`。

## 构建

```bash
swift build            # 调试版：.build/debug/devstore、.build/debug/devstore-mcp
swift build -c release # 发布版：.build/release/…
swift test             # 14 个单元测试
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

## 尚未实现

检查点与归档恢复、compact（需走临时副本流程）、转移、跨槽重定位、导入已受管的副本、多存储库切换 active、陈旧租约接管、数据分类清理、其他语言适配器、SwiftUI GUI。
