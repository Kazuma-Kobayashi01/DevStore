<div align="center">

# DevStore

**macOS 原生开发环境管理器：每个环境都放在独立的可挂载 APFS 卷中。**

[English](README.md) | 简体中文

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](LICENSE)
![Swift](https://img.shields.io/badge/Swift-6.2+-F05138?style=flat-square&logo=swift&logoColor=white)
![Platform](https://img.shields.io/badge/macOS-26+-000000?style=flat-square&logo=apple&logoColor=white)

</div>

SDK、包管理器和各种缓存通常散落在主目录和系统盘里。DevStore 把每个环境放进一个可写的 APFS sparse bundle，并挂载到固定路径。环境可以放在外置 SSD 上，不用时卸载，也可以作为整体压缩或归档。

DevStore 包含命令行工具、供编码 Agent 使用的 MCP Server 和 SwiftUI 桌面应用。

## 功能

- **一个环境一个卷**：SDK、工具、状态和缓存放在同一个可写 APFS 卷里，挂载到 `~/.local/dev/<kind>/<slot>`。
- **多槽位**：同类环境可以有多个槽位，并且可以同时挂载。默认槽位是 `current`。
- **回收空间**：`compact` 在 APFS 克隆上操作，内容摘要比对一致后才替换映像；只要有差异，原映像就不动。
- **检查点**：`archive` 生成压缩只读 DMG，可选 AES-256 加密。`export` 把它复制到冷备份位置并校验 SHA-256。
- **验证**：每种适配器都有验证套件，在沙箱中离线运行，结果随映像记录。
- **先计划后执行**：所有改动都先生成带摘要的计划。只有你能在交互式终端里批准，Agent 无法批准自己的计划。
- **租约**：租约防止两台主机同时使用一个映像。重启留下的残留租约会自动回收；其他主机的租约必须经你批准才能清除。

## 支持的环境

| 适配器 | 环境 | SDK 来源 |
|---|---|---|
| `miniconda` | Miniconda / conda | `install-sdk`，或 `import` 已有映像 |
| `go` | Go | `install-sdk` 配合官方 `.tar.gz` |
| `rust` | Rust / cargo | `copy-sdk` |
| `dotnet` | .NET | `copy-sdk` |
| `flutter` | Flutter / Dart | `copy-sdk` |
| `android` | Android SDK、NDK 和 Gradle | `copy-sdk` |
| `empty` | 新建的空环境 | `create` |

`copy-sdk` 只读取原有安装，不会改动它。

## 系统要求

- macOS 26 及以上
- 从源码构建需要 Swift 6.2 及以上

## 安装

```bash
git clone https://github.com/Kazuma-Kobayashi01/DevStore.git
cd DevStore
scripts/install.sh
```

这会构建发布版，并安装 `/Applications/DevStore.app`，以及 `~/.local/bin` 下的 `devstore` 和 `devstore-mcp`。如果 DevStore 正在运行，请先退出。应用只做了 ad-hoc 签名，没有公证。

为 Claude Code 和 Codex 安装 Skill 并注册 MCP Server：

```bash
scripts/install-agents.sh
```

## 快速开始

```bash
# 注册存储库：任意目录都可以，也可以放在外置 SSD 上
devstore store add /Volumes/SSD/DevStore --create

# 新建空环境并挂载
devstore create --store /Volumes/SSD/DevStore --kind go --name "Go" --size 20
devstore mount go/current

# 安装下载好的官方 SDK，并核对 SHA-256
devstore install-sdk go/current --installer go1.27.3.darwin-arm64.tar.gz --sha256 <sha256>

# 用环境变量运行命令
devstore run go/current -- go version

# 查看受管理的环境
devstore status
```

环境可以用 ID、`kind/slot` 或显示名来指定。

### 批准 Agent 的请求

Agent 只能生成计划，不能批准。请你自己在终端里运行：

```bash
devstore plans
devstore approve <planId>
```

如果允许 Agent 挂载和卸载某个环境时不用每次询问：

```bash
devstore policy allow go/current
```

## 命令

| 命令 | 用途 |
|---|---|
| `store add`、`store list` | 注册和列出存储库 |
| `create`、`import`、`delete` | 添加或移除环境；`delete` 会把文件移到废纸篓 |
| `install-sdk`、`copy-sdk` | 为已挂载的空环境安装内容 |
| `mount`、`unmount` | 挂载或卸载环境；卸载从不强制 |
| `run`、`env` | 用会话变量运行命令，或输出这些变量 |
| `verify` | 运行适配器的验证套件 |
| `compact`、`archive`、`checkpoints`、`export` | 回收空间和管理备份 |
| `status`、`inspect`、`journal` | 查看当前状态和历史 |
| `plans`、`approve`、`reject`、`apply`、`policy` | 管理计划和授权 |
| `lease clear` | 清除本机没有在用的租约 |

所有改动类命令都可以加 `--plan-only [--json]`，只打印计划，不执行。详见 [CLI 与 MCP](docs/CLI与MCP.md)。

## Agent 集成

`devstore-mcp` 通过 stdio 使用 JSON-RPC 2.0，提供只读工具、生成计划的工具，以及只有在你批准或有策略时才会执行的 `devstore_apply`。没有任何工具能批准计划。

`devstore run` 不是安全边界。`--confine` 只是禁止读取原有安装；批准检查依赖 `isatty`，只能防止 Agent 意外自批，不能防止恶意本地进程。

## 开发

```bash
swift build
swift test
DEVSTORE_INTEGRATION=1 swift test   # 额外用真实 hdiutil 测试
scripts/build-app.sh                # 生成 build/DevStore.app
```

| 路径 | 内容 |
|---|---|
| `Sources/DevStoreCore` | 数据模型、适配器、操作、授权和验证 |
| `Sources/devstore` | 命令行工具 |
| `Sources/DevStoreMCP`、`Sources/devstore-mcp` | MCP Server |
| `Sources/DevStoreApp` | SwiftUI 桌面应用 |
| `skills/devstore` | Agent Skill |
| `docs` | 设计记录、实验报告和工单 |

从[文档索引](docs/README.md)和[当前方案](docs/reports/单卷独立环境挂载方案-v3.md)开始阅读。

## 许可证

[MIT](LICENSE)
