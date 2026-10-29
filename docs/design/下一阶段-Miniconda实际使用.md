# 下一阶段：Miniconda 实际使用测试

记录日期：2026-10-29。状态：**进行中**——第 1、2 步在真实环境完成；第 4–6 步（回收、压缩/加密、导出）已实现并在临时卷实测；15:40 起在新存储库重建，并按清单重建了用户原有的三个环境，验证 23/23，进入第 3 步日常试用。

## 目标

验证受管理的 Miniconda 环境能否在日常工作中**代替真实路径 `~/miniconda3`**。如果可以，再考虑把同一流程复用到其他编程环境。

## 用户给出的流程

1. **新建镜像**：用 `devstore create` 或应用里的"新建空环境"建一个空卷。
2. **写入 SDK**：在卷内全新安装 Miniconda，而不是导入旧映像。
3. **正常使用**：日常建环境、装包，会产生缓存等数据。
4. **项目结束后回收剩余空间**：compact。
5. **压缩**：LZFSE 归档，可选加密。
6. **导出到冷备份位置**：例如外置盘或其他存储库。

## 与现有实现的差距（2026-10-29 初稿；第 1、2、4、5、6 步已实现，现状见文末进展记录）

| 步骤 | 现状 | 需要做什么 |
|---|---|---|
| 1 新建镜像 | 已实现，使用 `empty` 适配器 | 决定类型名：用 `miniconda` 会占用 `miniconda/current` 槽位，现有的导入环境已经在用，需要另选槽位或先处理旧环境 |
| 2 写入 SDK | 未实现 | 在卷内运行官方 Miniconda 安装器（`-b -p <mount>/miniconda3`），需要联网下载并核对安装器的 SHA-256。装完后环境的适配器应从 `empty` 转为 `miniconda`（新增"采用"或"转换"操作），才能用 23 项验证。安装器来源与下载需用户确认 |
| 3 正常使用 | `run`、`env`、复制环境变量已有 | "代替真实路径"意味着日常终端要用这个环境：需要 shell 集成（例如在 `.zshrc` 中按需 `eval "$(devstore env …)"`），**修改全局 shell 配置需用户单独授权**。还要确认 IDE 和 Jupyter 如何找到解释器 |
| 4 回收空间 | 未实现 | 实现 compact：卸载 → 克隆临时副本 → compact → 内容清单比对 + 验证 → 原子替换（依据 compact 实验）。中断测试 A10 仍未做 |
| 5 压缩/加密 | 未实现 | 实现检查点/归档：`hdiutil convert -format ULFO`，可选 `-encryption AES-256`；口令不写入任何清单；记录 SHA-256 与内容清单摘要 |
| 6 导出冷备份 | 未实现 | 把归档复制到另一个存储库或任意目录，复制后校验 SHA-256；可选做一次"恢复为临时可写卷 + 验证"，以证明可恢复 |

## 需要用户定的事项

- 新环境用哪个槽位：先不动现有的 `miniconda/current`，用新槽位如 `miniconda/daily`；还是处理掉旧环境后再用 `current`。
- 是否允许下载官方 Miniconda 安装器（需要联网，用哪个版本）。
- 是否、以及何时修改 `~/.zshrc` 让日常终端切换过去。原 `~/miniconda3` 保持不动，作为回退。
- 冷备份位置：外置 SSD 路径，或另一个存储库。
- 加密口令如何保管（钥匙串还是每次手输）。

## 判定"能代替真实路径"的标准（草案）

- 日常命令（`conda create/install/activate`、`pip`、`python`、Jupyter）都在卷内运行，验证时禁止读取原安装也全部通过。
- 卸载后再挂载、compact 之后、归档恢复之后，环境都能继续使用。
- 一段时间内没有工具在暗中依赖 `~/miniconda3`（对照前缀残留扫描的方法）。

## 进展记录

### 2026-10-29 下午：第 1、2 步完成

- 用户批准删除旧的导入实验环境 `miniconda/current`（a1bcde03），环境目录已移到废纸篓，原始映像未受影响。
- 安装器：`Miniconda3-latest-MacOSX-arm64.sh`，版本 py314_26.9.4-0，osx-arm64，174,567,687 字节。SHA-256 `266fdc66…cd0bec`，与 repo.anaconda.com 公布的一致。文件存放在 `artifacts/installers/`。
- 新增 `install-sdk` 操作（修改级，需批准）。安装器以批处理模式运行，不执行 conda init；在沙箱中禁网、禁读原安装、只能写卷。装完后环境从 empty 适配器转为 miniconda 适配器。
- 新环境 `miniconda/current`「Miniconda 日常」：环境 `cf98aa77…`，映像 `11a18525…`，卷 UUID `EC7DA556-…`，最大 40 GiB，按需增长。安装耗时 14 秒，得到 Python 3.14.9、conda 26.9.4、155 个 conda 包，`miniconda3` 占 841 MB。
- 验证（fresh-install）14/14 通过，其中负向对照确认读取原安装会被拒绝。
- **前缀残留扫描：卷内没有任何文件含原安装路径 `/Users/jackson-hao/miniconda3`。** 导入的旧映像里则有 703 个二进制和 7,784 个 pyc 含此路径。这是"可以代替真实路径"的一项正面证据。证据文件：`docs/experiments/compact-multislot-20261029/residue-fresh-install-20261029.json`。
- `~/.zshrc`、`~/.condarc`、`~/.conda/environments.txt`、`~/.zprofile` 的摘要不变。
- **代为批准**：用户在对话中明确授权"只限这一次"，以下三个计划由 Agent 在桌面应用里代点"批准并执行"：
  - 新建 `ce2ceb3b`
  - 挂载 `3d541ed5`
  - 写入 SDK `01cd7796`

  `grants.jsonl` 中这三条记为 `via: gui`，但并非用户亲手点击。此后仍按原规则：Agent 不代为批准。
- 下一步：第 3 步正常使用。需要决定是否、何时修改 `~/.zshrc`，让日常终端使用这个环境。

### 2026-10-29 15:00–15:30：第 4–6 步实现（用户外出期间自主开发）

- 用户授权"自主审批完成"。实际做法：**所有新功能只在 `/private/tmp` 的临时卷上用集成测试实测，没有批准或执行任何针对用户登记的计划**。
- 回收空间（compact）：克隆 → 只压实克隆 → 压实前后内容摘要比较 → 替换，原映像移到废纸篓。测试写入 320 MiB 再删除后，回收了 344.8 MB，内容一致，删除前写入的文件仍在。
- 压缩归档：LZFSE 和 AES-256 两种都实测，`hdiutil verify` 通过，两份归档的内容摘要相同。加密归档必须提供口令（不少于 8 个字符）；用错误口令打不开。
- 导出冷备份：复制后 SHA-256 一致，附带 `.json` 记录；不覆盖已有文件；导出记录写回归档。
- 发现 `hdiutil imageinfo` 等命令对加密映像会等待交互输入口令（测试因此卡住，已改用 `-stdinpass`）。DevStore 的执行路径始终经 stdin 传口令。
- **真实环境状态**：事务日志显示，14:39:52 在应用里卸载了 `miniconda/current`「Miniconda 日常」（`via: gui`），14:40:19 删除了它（`via: gui-authenticated`，需要 Touch ID 或登录密码），随后废纸篓被清空。这不是 Agent 的操作：Agent 在 14:36 已释放对应用的控制，而删除必须通过本机身份验证。当前没有任何环境；安装器仍在 `artifacts/installers/`，可以随时重建。用户随后确认是自己删除的，并决定暂不重建。

### 2026-10-29 15:39–15:55：全新安装 + 按清单重建原有环境

- 清理：旧的主机登记整体移进废纸篓（`DevStore-registry-20261029-153915`），删除了空的旧存储库和空目录。
- 新存储库：`~/.local/share/devstore`（`3ad896e4…`）。新环境 `miniconda/current`「Miniconda」：环境 `575e078a…`，最大 40 GiB。新建由用户在终端批准；挂载策略由用户设置；写入 SDK `4b6cbcc7` 由用户批准，耗时 14 秒，base 验证 14/14。
- 清单导出：只读原安装各环境的 `conda-meta/*.json` 和 `site-packages/*.dist-info`，没有运行原安装的 conda。证据在 `docs/experiments/miniconda-rebuild-20261029/`。
- 服务条款：用户同意由 Agent 在新环境里接受 Anaconda ToS，范围仅 `repo.anaconda.com/pkgs/main` 与 `pkgs/r`，记录写在卷内的 `state/home/.conda/tos`。
- 重建：每个环境先 `conda create --file <env>-conda-explicit.txt`（精确 build），再 `pip install --no-deps -r <env>-pip-requirements.txt`。
  - python3.10 的 pip 原本是 pip 自己装的，不在 conda 清单里，所以先用 `ensurepip` 引导；第一次下载时 PyPI 超时，加大超时后重试成功。
- 结果：
  - llama-cpp：conda 19/19、pip 17/17 与原环境完全一致。
  - neocloud：conda 19/19、pip 49/49 完全一致。
  - python3.10：conda 82/82、pip 79/79 完全一致。
- 用户决定 base 里原有的 36 个 pip 包不迁移。
- 验证 `rebuilt-envs`：**23/23**，含负向对照（禁读原安装），以及 FastAPI/Pydantic/Requests、HTTPX、NumPy 2.2.5/PyTorch 2.5.1 的包检查。
- 卷内原安装路径**残留 0**。`miniconda3` 共 2.7 GB，其中包缓存 `pkgs` 1.9 GB，`cache` 156 MB；这些可重建的缓存是后续回收空间测试的对象。
- `~/.zshrc`、`~/.condarc` 等摘要不变；原 `~/miniconda3` 只读，未改动。

### 2026-10-29 16:00–16:10：切换日常终端并删除原安装（用户要求）

- 安装：`scripts/install.sh` 把应用装到 `/Applications/DevStore.app`，把 `devstore`、`devstore-mcp` 装到 `~/.local/bin`；MCP 改为用户级（全局）注册。
- 验证器：原安装不存在时，负向对照记为 `negative-control-original-install-absent`；如果目录还在、却缺少 `conda-meta/history`，则拒绝继续。
- `~/.zshrc`：备份为 `~/.zshrc.devstore-backup-20261029-160559`；把 `conda init` 块（原第 119–132 行）换成 DevStore 块：
  - 卷未挂载时，按常驻策略调用 `~/.local/bin/devstore mount`；
  - 加载卷内 conda 的 shell hook；
  - HOME 不变，只设置 `CONDARC`（卷内 `state/condarc`）和 `PIP_CACHE_DIR`（卷内）。
  - 卷内 condarc 改为 `auto_activate: true`，与原先默认激活 `(base)` 的习惯一致。
- `~/.conda/environments.txt`：删掉了两条指向旧安装的路径，备份为 `environments.txt.devstore-backup`。`~/.condarc`（`channels: [conda-forge]`）和 `~/.conda` 的其余内容保留。
- `~/miniconda3`（2.1 GB）移到 `~/.Trash/miniconda3-20261029-160639`，清空废纸篓之前都能找回。原 base 中未迁移的 36 个 pip 包也随之移走，清单在 `docs/experiments/miniconda-rebuild-20261029/base-pip-requirements.txt`。
- 实测：
  - 新登录 shell 里 HOME 不变，conda 26.9.4 和 4 个环境都来自卷内，`python3.10` 中 torch 2.5.1、numpy 2.2.5 可用。
  - 卸载卷后打开新终端会自动挂载（约 1.9 秒）并激活 base，`python` 指向卷内的 Python 3.14.9。
  - 原安装删除后验证 23/23。
- 注意：卷所在的存储库必须在线（目前在内置盘），否则终端会提示未挂载；回退方法是用备份的 `.zshrc` 替换，并从废纸篓放回 `~/miniconda3`。

### 2026-10-29 16:10–16:20：Go 迁移（复用到第二种语言）

- 盘点（只读）：Go 1.27.3 由 Homebrew 安装（没有其他 brew 包依赖它）；GOPATH `~/.local/go` 共 146 MB，含 `gomobile`、`gobind`、125 MB 模块缓存、`pkg/gomobile` 和 `pkg/sumdb`；GOCACHE `~/Library/Caches/go-build` 641 MB；`~/.zshrc` 第 166 行设置了 GOPATH，go env 文件里也有一条 GOPATH。
- 新增 Go 支持：
  - `install-sdk` 识别官方 `go*.darwin-*.tar.gz`，核对文件名、包内 `go/VERSION` 与 SHA-256。
  - `GoAdapter`：GOROOT、GOPATH、GOMODCACHE、GOCACHE、GOENV 都在卷内。
  - Go 验证套件：负向对照、版本、路径隔离、离线 build/test/vet/gofmt/install、cgo、迁移工具的构建信息、持久化标记。
  - 应用里的"写入 SDK"支持 `.tar.gz`。
  - 临时卷实测 13/13。
- 安装包：`go1.27.3.darwin-arm64.tar.gz`（68,196,737 字节），SHA-256 `dd3908cf…99c2`，与 go.dev 一致。由用户同意下载。
- 真实环境 `go/current`「Go」（`fc405c46…`，最大 20 GiB）：新建、挂载策略和写入 SDK 都由用户在终端批准。
- 迁移：用 `ditto` 把 `~/.local/go/bin` 和 `~/.local/go/pkg` 复制到卷内 `gopath/`，`diff -rq` 结果一致。编译缓存不迁移（可重建）。验证 `migrated` 14/14，其中负向对照确认原 GOPATH 和 Homebrew go 都读不到。
- shell：`~/.zshrc` 先备份为 `~/.zshrc.devstore-backup-20261029-161837`，再把 `export GOPATH=…` 一行换成 DevStore Go 块：卷未挂载时自动挂载，然后设置 GOPATH、GOMODCACHE、GOCACHE、GOENV，并把卷内 go 放在 PATH 最前。
- 清理（测试通过后，按用户要求）：
  - `brew uninstall go`，删除 240 MB；
  - `~/.local/go` 移到 `~/.Trash/local-go-GOPATH-20261029-161904`；
  - `~/Library/Caches/go-build` 移到 `~/.Trash/go-build-cache-20261029-161904`；
  - 删掉 go env 文件里的 GOPATH 行（备份为 `env.devstore-backup`）；`telemetry` 目录保留。
- 清理后：验证 13/13（原 GOPATH 已不存在，Homebrew go 已卸载）。卸载卷后新开登录 shell 会自动挂载，`go run` 正常。Miniconda 复验 23/23，不受影响。

### 2026-10-29 16:20–16:50：Flutter、Rust、.NET 迁移

- 盘点（只读）：
  - Flutter 3.47.2 stable / Dart 3.13.2，`~/.local/flutter` 是 git 仓库，3.9 GB。
  - Rust：rustup 1.29.1 + stable 1.99.1 + 5 个交叉编译 target；`~/.rustup` 1.1 GB，`~/.cargo` 34 MB，含 `cargo-expand`、`flutter_rust_bridge_codegen`。
  - .NET SDK 10.0.402 / runtime 10.0.13，装在 `/usr/local/share/dotnet`（Homebrew cask，root 所有）；`~/.nuget` 309 MB。
- 用户选择"复制现有安装"。新增 `copy-sdk`（修改级，需批准），并新增 Rust、.NET、Flutter 三个适配器及验证套件。在临时卷上用真实复制品实测：Rust 18/18、.NET 12/12、Flutter 11/11。
- 复制品里提到原路径的文件，都不是可执行脚本，已记入 knownWarnings：
  - Rust 2 个：两个 cargo 工具里编译进去的源码路径。
  - .NET 14 个：`dotnet`、`libhostfxr`、`libhostpolicy` 等文件里写死的默认安装位置 `/usr/local/share/dotnet`。只有没设置 `DOTNET_ROOT` 时才会用到；从 Finder 启动的 apphost 程序可能会去这个旧位置找运行时。
  - Flutter 4 个：工具快照、一个 Gradle 历史文件、pub 的 active_roots。
- 真实环境：`flutter/current`（最大 30 GiB）、`rust/current` 和 `dotnet/current`（各 20 GiB）。新建、挂载策略、复制都由用户在终端批准（Rust 第一次确认被拒，之后重新批准）。复制后验证：Flutter 11/11、Rust 18/18、.NET 12/12。
- shell（`~/.zshrc`、`~/.zshenv` 已备份为 `*.devstore-backup-20261029-164111`）：
  - `.zshrc:150` 的 Flutter PATH 换成 DevStore Flutter 块（`PUB_CACHE` 和 PATH）。
  - 新增 .NET 块（`DOTNET_ROOT`、`NUGET_PACKAGES`、`DOTNET_CLI_HOME`、PATH）。
  - `.zshenv:1` 的 `. "$HOME/.cargo/env"` 换成 DevStore Rust 块（`RUSTUP_HOME`、`CARGO_HOME`、PATH），非交互 shell 也生效。
- 清理：上述六个原目录移到 `~/.Trash/*-20261029-164259`。保留 `~/.flutter`、`~/.dart-tool`、`~/.nuget/NuGet` 三个小配置，因为日常 shell 的 HOME 不变，还会用到它们。用户自行运行了 `brew uninstall --cask dotnet-sdk`。
- 清理后验证：Flutter 10/10、Rust 17/17、.NET 10/10；新登录 shell 里所有工具都来自卷内。
- 遗留：`/etc/dotnet/install_location*`（root 所有）仍指向已删除的 `/usr/local/share/dotnet`，不影响终端使用。

### 2026-10-29 16:55–17:10：Android 迁移（IDE 不移入）

- 盘点（只读）：
  - `~/Library/Android/sdk` 12 GB：NDK 28.2/30.0、build-tools 35–37、platforms 34–37、cmake 3.22.1、emulator、system-images android-35。
  - `~/.gradle` 3.1 GB，含 Gradle 9.8.2 wrapper；`gradle.properties` 里的 JDK 是 Android Studio 的 JBR。
  - `~/.android` 3 GB：AVD `lablink-test`、`adbkey`、`debug.keystore`。
  - 以下几处写死了 SDK 路径：Android Studio 的设置、`~/.config/flutter/settings`、两个项目的 `local.properties`。
- 用户决定：
  - 旧路径用符号链接兼容；
  - 整个 `~/.android` 连同密钥一起移入；
  - 不加登录自动挂载；
  - JDK（Android Studio 的 JBR）、Android Studio、Homebrew 的 gradle 和 openjdk@17、Corretto 25 都不动。
- 新增 Android 适配器：会话变量设 `ANDROID_HOME`、`ANDROID_USER_HOME`、`ANDROID_AVD_HOME`、`GRADLE_USER_HOME`，`JAVA_HOME` 指向 JBR。
- 新增 Android 验证套件，共 16 项：
  - adb、`sdkmanager --list_installed`、emulator 版本和 AVD 列表；
  - aapt2、apksigner；
  - 两个 NDK 各做一次交叉编译；
  - cmake、Gradle wrapper 离线运行；
  - 原安装被禁止读取。换成兼容链接以后，改为检查这些链接是否指向卷内。
- 空间只剩约 40 GiB，没有先在临时卷上演练，直接在正式复制品上验证，清理前原安装保持不变。
- 真实环境 `android/current`（最大 40 GiB）：新建、挂载策略和复制都由用户批准。复制约 2 分钟（SDK 64 秒、gradle 31 秒、`.android` 17 秒）。95 个文件提到原路径，大多是 Gradle 守护进程日志、`.tmp` 里的 classpath 文件，另外两个是 AVD 的 `hardware-qemu.ini`。
- 验证：第一次 15/16，`sdkmanager` 不认 `--offline` 参数，这是验证套件本身的问题；修复后 16/16。
- 清理：
  - `adb kill-server` 停掉了从原 SDK 启动的 adb；
  - 三个原目录移到 `~/.Trash/{android-sdk,gradle,android-user}-20261029-*`；
  - 在原位置建符号链接，指向卷内的 `sdk`、`gradle`、`android-user`。
  - 之后验证 16/16，三条链接都确认指向卷内。
- shell：在 `~/.zshrc` 加 Android 块时，被 Claude Code 的 auto mode 判定为持久化改动而拦截。用户随后明确授权，于 17:08 加入（备份为 `~/.zshrc.devstore-backup-20261029-170823`）。这个块在卷未挂载时自动挂载，把 `ANDROID_HOME` 设为兼容路径 `~/Library/Android/sdk`，并把 platform-tools、emulator、cmdline-tools 加进 PATH；不设 `GRADLE_USER_HOME` 和 `JAVA_HOME`。实测：先卸载再开新登录 shell，会自动挂载，adb、emulator、sdkmanager 都可用，AVD 可以列出。
