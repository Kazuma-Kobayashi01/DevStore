---
name: devstore
description: "Manage this Mac's development environments with DevStore (Miniconda/conda, Go, Flutter/Dart, Rust/cargo, .NET/C#). Each environment is a writable APFS volume mounted at ~/.local/dev/<kind>/<slot>. Use for: checking environment state, installing packages or tools, running commands inside an environment, mounting/unmounting, verifying, creating a new language environment, reclaiming space, archiving/encrypting, exporting cold backups, or anything touching conda/go/cargo/flutter/dotnet installs, caches or PATH."
metadata:
  version: "0.1.0"
  cli: "~/.local/bin/devstore"
  mcp: "~/.local/bin/devstore-mcp"
---

# DevStore

每个开发环境是一个独立的可写 APFS 卷：SDK、工具管理器、包/模块缓存和状态都在卷里。卷固定挂载到 `~/.local/dev/<kind>/<slot>`，映像存放在存储库 `~/.local/share/devstore`。用户的终端在启动时自动挂载并使用这些卷里的工具。

当前环境（`devstore status` 为准）：

| 环境 | 内容 | 日常 shell 中的变量 |
|---|---|---|
| `miniconda/current` | Miniconda（base + llama-cpp、neocloud、python3.10） | conda hook、`CONDARC`、`PIP_CACHE_DIR` |
| `go/current` | Go 1.27.3、GOPATH（gomobile、gobind） | `GOPATH`、`GOMODCACHE`、`GOCACHE`、`GOENV` |
| `flutter/current` | Flutter 3.47.2 / Dart | `PUB_CACHE`、PATH |
| `rust/current` | rustup + stable、交叉 target、cargo 工具 | `RUSTUP_HOME`、`CARGO_HOME`（在 `.zshenv`） |
| `dotnet/current` | .NET SDK 10.0.402 | `DOTNET_ROOT`、`NUGET_PACKAGES`、`DOTNET_CLI_HOME` |

## 基本原则

1. **日常用法不变。** 在用户的终端里，`conda install`、`pip install`、`go get`/`go install`、`cargo add`/`cargo install`、`flutter pub get`、`dotnet add package` 都直接可用，结果自动落在对应卷里。不需要 DevStore 命令。
2. **不要绕开 DevStore 重装 SDK。** 不要 `brew install go/rust/dotnet`、不要运行 Miniconda/rustup 安装器到 `~`、不要 `conda init`、不要重建 `~/miniconda3`、`~/.cargo`、`~/.rustup`、`~/.local/go`、`~/.local/flutter`。不要修改 `~/.zshrc` / `~/.zshenv` 里 `# >>> devstore … >>>` 到 `# <<< devstore … <<<` 之间的块。
3. **改动走计划，批准属于用户。** 新建、写入 SDK、复制 SDK、回收空间、归档、导出、导入、删除都会先生成计划。Agent 只生成计划，然后把批准命令交给用户。**绝不**伪造 TTY（`script`、`expect`、管道喂 `y`）、绝不改写 `~/Library/Application Support/DevStore/`（`grants.jsonl`、`plans/`、`registry.json`）或映像记录、绝不替用户点 DevStore 应用里的"批准"按钮。
4. **挂载/卸载**：五个环境都设了常驻挂载策略，`devstore mount|unmount <env>` 可直接执行。卸载从不强制；卷忙时会失败，先结束占用它的进程。
5. **`devstore run` 只是选择环境，不是隔离。** 加 `--confine` 会禁止读取原安装、Homebrew 和 `/usr/local`；加 `--deny-network` 禁网。

## 常用命令

```bash
devstore status                      # 所有环境：挂载、身份、验证状态
devstore inspect rust/current        # 记录 JSON（组件、SDK、已知警告、最近验证）
devstore verify go/current           # 运行该环境的验证套件（沙箱、禁网、禁读原安装）
devstore run miniconda/current -- python -V      # 在环境的会话变量中运行（HOME 指向卷内）
devstore env dotnet/current          # 输出 export 语句
devstore mount flutter/current       # 常驻策略允许，直接执行
devstore plans                       # 待批准的计划
devstore journal --limit 20          # 事务日志
devstore checkpoints                 # 归档列表
```

`<env>` 可以是 `kind/slot`、环境 id 前缀或显示名。

## 需要用户批准的操作

先用 `--plan-only` 生成计划，再把命令交给用户在终端运行（或请用户在 DevStore 应用的"待批准计划"里批准）：

```bash
devstore <command> … --plan-only          # 输出 Plan <id>
# 交给用户：
devstore approve <id> && devstore apply <id>
```

| 目的 | 命令 | 前提 |
|---|---|---|
| 新建空环境 | `create --store ~/.local/share/devstore --kind <k> --slot current --name <n> --size <GiB>` | 槽位空闲 |
| 写入官方 SDK | `install-sdk <env> --installer <file> --sha256 <hex>` | 已挂载、空环境；支持 Miniconda `.sh`、Go `go*.darwin-*.tar.gz` |
| 复制本机已有 SDK | `copy-sdk <env> --adapter rust\|dotnet\|flutter` | 已挂载、空环境 |
| 回收剩余空间 | `compact <env>` | 已卸载；在克隆上压实、比对内容后替换 |
| 压缩归档 | `archive <env> [--encrypt] [--lzma]` | 已卸载；**加密归档只能由用户在终端/应用执行**（口令） |
| 导出冷备份 | `export <checkpointId> --to <dir>` | 复制后校验 SHA-256 |
| 删除环境 | `delete <env>` | 已卸载；移到废纸篓；破坏性，终端确认需输入 `kind/slot`，应用需 Touch ID |

安装包必须来自官方渠道，并用官方公布的校验值；下载前先告诉用户文件名、来源和大小并取得同意。

## 典型流程

**环境不可用（终端提示"未挂载"）**：`devstore status` → `devstore mount <env>` → 仍失败看 `devstore journal`；存储库离线时提示用户接上存储库所在的盘。

**新增一种语言环境**：`create` → 用户批准 → 请用户 `devstore policy allow <env>` → `mount` → `install-sdk` 或 `copy-sdk` → 用户批准 → `verify` → 再讨论 shell 接入（修改 shell 配置前先给用户看要加的内容）。

**项目结束、整理空间**：`unmount` → `compact`（批准）→ `archive [--encrypt]`（批准）→ `export --to <冷备份目录>`（批准）。

**确认环境健康**：`devstore verify <env>`；失败时把失败项和 `stderr` 报给用户，不要自行删除或重建环境。

## MCP

同一套能力也通过 MCP Server `devstore`（`~/.local/bin/devstore-mcp`）提供：`devstore_status`、`devstore_inspect`、`devstore_run`、`devstore_env`、`devstore_verify`、`devstore_plans`、`devstore_checkpoints`、`devstore_journal`，以及 `devstore_plan_{create,install_sdk,copy_sdk,mount,unmount,compact,archive,export,import,delete}` 和 `devstore_apply`。MCP 可用时优先用 MCP；`devstore_apply` 只有在用户已批准（或常驻策略覆盖挂载/卸载）时才会执行。

## 不要做

- 不要删除 `~/.Trash` 中的旧安装或清空废纸篓。
- 不要同时挂载同一映像的两个副本，也不要把映像挂到别的路径（前缀固定）。
- 不要把加密口令写进命令行参数、文件或对话。
