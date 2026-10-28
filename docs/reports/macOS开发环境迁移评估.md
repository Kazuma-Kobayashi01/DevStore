# macOS 开发环境迁移评估

评估时间：2026-10-28，本机时间（UTC+8）。本报告基于只读扫描和文件元数据；没有创建磁盘映像、修改现有环境或执行迁移。用户要求暂不编写代码，先前新建的 Swift 项目文件已删除。

## 结论与建议

APFS 磁盘映像适合把各 SDK 作为可挂载、可复制的文件集合管理，但它不是隔离运行的容器：仍使用宿主 macOS、系统库、Xcode/JDK、用户配置和网络。镜像移到另一台 Mac 后也必须验证 CPU 架构、系统版本、许可证与宿主依赖。

建议先为 **Flutter 或独立的 Go 副本**做单项验证，再扩展到其他 SDK。Go 需要和 Homebrew 管理边界分开；Rust 需要考虑 rustup 代理和用户工具；.NET 需要处理 root 所有权、安装器与宿主发现机制；Android 涉及体积、IDE 配置、JDK、模拟器和许可证。最终只在用户确认后逐项迁移与切换，原环境保留至回滚验证完成。

五个当前 SDK 根目录合计约 **18.37 GiB**，不包括独立的用户数据和缓存，也不代表可直接释放的空间。内置数据卷当时可用约 **42.84 GiB**；没有发现已挂载的外置 SSD，磁盘管理查询也受当前环境限制，故无法确认外置盘容量、格式或连接状态。实际复制、备份和增量更新需要更大的额外空间。

## 扫描方法与边界

- 主机：macOS 15.7.9，Apple Silicon `arm64`；当前 Xcode 路径 `/Applications/Xcode.app/Contents/Developer`。
- 只读取常见安装路径、当前进程环境变量、PATH 命令位置、部分 shell 配置、SDK 元数据、目录权限、磁盘占用、二进制架构及部分动态链接信息。版本来自文件或目录，没有执行 SDK 命令，以免触发初始化、下载或更新。
- 大小采用 `du -sk` 的已分配空间，换算为 GiB（1 GiB = 1,048,576 KiB）。APFS 克隆、稀疏文件、快照、硬链接及复制到不同文件系统可能使实际空间与这些数字不同；嵌套目录单列时已经包含在父目录内，不能重复相加。扫描期间目录可能变化。
- 检查了当前 shell 的相关环境变量、`~/.zshrc`、`~/.zprofile`、`~/.profile`、常见版本管理器位置及已知安装路径；没有遍历所有项目、全部用户账户、所有 IDE 配置或磁盘，因此不能断言没有其他安装或硬编码路径。当前进程环境不代表所有终端或 GUI 启动环境。
- 顶层权限和部分符号链接已核对；没有完整审计每个文件的 ACL、扩展属性、代码签名或全部外部依赖。系统进程列表查询受限，无法确认 SDK、IDE、模拟器和构建任务是否正在运行。迁移前应在有权限的本机会话复查。
- 本次没有读取凭据、密钥和配置文件的敏感内容；报告中只记录相关文件和目录的存在。

## SDK 迁移清单

| SDK | 安装位置与版本 | 主机架构证据 | 已分配 | 来源与权限 | 初步判断 |
|---|---|---|---:|---|---|
| Go | `/opt/homebrew/Cellar/go/1.27.3/libexec`；`go1.27.3` | `go` 是 arm64 | 0.26 GiB | Homebrew；根目录 `jackson-hao:admin`，755 | 可准备副本，但不能把 Homebrew 的 Cellar 目录当成独立安装直接移走 |
| Rust | `~/.rustup`，stable toolchain `stable-aarch64-apple-darwin`，Rust 1.99.1 | `rustc` 是 arm64 | 1.13 GiB | rustup；`jackson-hao:staff`，755 | 可候选；需保持 rustup 数据结构与本机 Cargo 代理、用户工具之间的关系 |
| .NET/C# | `/usr/local/share/dotnet`；SDK 10.0.402，`Microsoft.NETCore.App` 与 `Microsoft.AspNetCore.App` 均为 10.0.13 | `dotnet` 是 arm64 | 0.63 GiB | root:wheel，755；存在 Microsoft 安装收据和 Homebrew Cask 目录 | 有条件候选；权限、安装器更新和应用宿主发现需要特别验证 |
| Flutter/Dart | `~/.local/flutter`；Flutter 3.47.2 stable，Dart 3.13.2 | Dart 是 arm64，Flutter 入口是 shell 脚本 | 3.88 GiB | `jackson-hao:staff`，755；根目录有 `com.apple.provenance` 扩展属性 | 优先试验候选；这是 Git 工作树，内含 SDK 缓存 |
| Android SDK | `~/Library/Android/sdk` | `adb`、所检查的 NDK clang 为 arm64/x86_64 通用，emulator 是 arm64 | 12.46 GiB | `jackson-hao:staff`，755 | 有条件候选；需保留组件、链接和许可证，并验证 IDE、JDK 与项目设置 |

Rust 的工具链还包括 `aarch64-linux-android`、`armv7-linux-androideabi`、`i686-linux-android`、`x86_64-linux-android` 和 `x86_64-apple-darwin` 目标标准库；它们不意味着相应宿主编译器一定可在另一种架构运行。

Android SDK 包含 Build Tools 35.0.0、36.0.0、36.1.0、37.0.0；平台 API 34、35、36、36.1、37.0；Platform Tools 37.0.0；Command-line Tools 20.0；NDK 28.2.13676358 与 30.0.14904198；CMake 3.22.1；Emulator 37.2.12；Android 35 Google APIs arm64 系统映像。SDK 内 NDK 约 5.52 GiB、system-images 约 3.78 GiB、emulator 约 1.22 GiB；这些均已包含在 12.46 GiB 中。目录名 `darwin-x86_64` 不应单独被当作架构判断：抽查的两个 NDK clang 都是通用二进制。

## 缓存、工作区与用户数据

这些目录默认不放入 SDK 镜像；后续可分别制定策略。原始数字保留嵌套关系，不应与父目录重复相加。

| 类别 | 位置与占用 | 判断 |
|---|---|---|
| Go 工作区 | `~/.local/go` 约 0.14 GiB，其中 `pkg/mod` 约 0.12 GiB；`bin` 有 `gomobile`、`gobind` | 当前 `GOPATH` 指向这里；是工作区和模块缓存，不是 Homebrew Go SDK。保留在原处，确认用户工具的路径和用途 |
| Go 构建缓存 | `~/Library/Caches/go-build` 约 0.63 GiB | 可重建缓存；不默认打包。Go 可能按 `GOTOOLCHAIN` 和项目要求下载其他工具链，需确认实际设置与离线需求 |
| Cargo | `~/.cargo` 约 0.03 GiB | `bin` 包括 rustup 及代理链接，也有 `cargo-expand`、`flutter_rust_bridge_codegen` 等用户安装工具。可能还有配置和凭据；不整体打包或披露内容 |
| rustup | `~/.rustup` 约 1.13 GiB，其中 `toolchains` 占几乎全部 | 另有设置、更新记录、下载和临时目录。计划应明确镜像中各项是否保留；不能把 `~/.cargo` 一并视作 SDK |
| .NET 用户数据 | `~/.dotnet` 约 0.00005 GiB；`~/.nuget` 约 0.30 GiB，其中 packages 占绝大部分 | 可能包含用户工具、首次运行状态与包缓存；保持本机。实际 `DOTNET_CLI_HOME` 和 NuGet 配置在其他会话可能不同 |
| Flutter SDK 内缓存 | `~/.local/flutter/bin/cache` 约 3.34 GiB，**已计入 Flutter 的 3.88 GiB**；`.git` 约 0.35 GiB | 首次迁移建议保留以支持离线验证；Flutter 的更新与工具运行需要对 SDK 树写入，移除缓存会增加下载和兼容性风险 |
| Dart 包缓存 | `~/.pub-cache` 约 0.00006 GiB | 独立于 Flutter SDK；保持本机 |
| Android 用户数据 | `~/.android` 约 3.05 GiB，其中 `avd` 约 3.04 GiB；发现一个 AVD | AVD 数据、ADB 密钥与 debug keystore 属于用户数据，默认不打包；不读取或复制密钥。AVD 配置中可能有绝对路径，切换时需单独验证 |
| Gradle | `~/.gradle` 约 3.06 GiB，其中 `caches` 约 2.87 GiB，`wrapper` 约 0.16 GiB | 独立缓存和用户配置，可能含私有仓库凭据；不默认打包或清理 |

## 路径、链接与依赖风险

- **现有路径选择**：`~/.zshrc` 将 `~/.local/flutter/bin` 加入 PATH，并将 `GOPATH` 设为 `~/.local/go`；`~/.profile` 加载 `~/.cargo/env`。当前进程没有观察到 `GOROOT`、`RUSTUP_HOME`、`CARGO_HOME`、`DOTNET_ROOT`、`ANDROID_HOME`、`JAVA_HOME` 等目标变量。GUI、其他 shell 或项目配置可能不同。
- **Homebrew Go**：`/opt/homebrew/bin/go` 指向 Cellar 版本的 `bin/go`，后者再指向 `../libexec/bin/go`；`/opt/homebrew/opt/go` 也指向该 Cellar。Homebrew 升级、清理或重装可改变这些链接。只复制 `libexec` 作独立候选，避免让 Homebrew 误以为镜像仍由其管理；最终应验证 Go 内部的根目录发现和项目选择行为。
- **Rust**：`~/.cargo/bin/rustc`、`cargo` 等链接到 `rustup`，而用户安装的其他程序也在同一 `bin` 中。若把 rustup 数据放进镜像，需设计 `RUSTUP_HOME`、`CARGO_HOME`、PATH 和未挂载时的行为；按项目目录生效的工具链覆盖也需另查。Cargo Home 包含用户配置、凭据及缓存，不能默认整体迁移。[rustup 安装文档](https://rust-lang.github.io/rustup/installation/)、[Cargo Home](https://doc.rust-lang.org/cargo/guide/cargo-home.html)。
- **.NET**：主目录属于 root，`/opt/homebrew/bin/dotnet` 指向该目录；Microsoft 安装收据登记了该路径，且 `/opt/homebrew/Caskroom/dotnet-sdk/10.0.402` 存在。存在多种管理痕迹，并不代表可以无风险改变它们。`/etc/dotnet/install_location*` 等宿主发现配置、现有 apphost、工作负载、签名和权限均需验证。`DOTNET_ROOT` 对生成的 apphost 有特定作用，不保证所有场景都仅靠它完成切换。[Microsoft 环境变量说明](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-environment-variables)。
- **Flutter**：现有路径是完整 Git 工作树，且包含可再生成的缓存。项目、IDE 或脚本可能记录旧绝对路径。镜像需要可写；迁移后的更新应在独立版本副本中进行，不能覆盖唯一可回滚副本。[Flutter 手动安装说明](https://docs.flutter.dev/install/manual)。
- **Android 与宿主依赖**：Android Studio 2026.1 自带 arm64 JDK 21.0.10；本机另有 Homebrew OpenJDK 17.0.20、Amazon Corretto 25.0.3。Android Studio、项目 JDK 和 Gradle 实际选择尚未查明。Flutter iOS 开发依赖宿主 Xcode；Android 构建可能依赖 JDK、Gradle 和项目配置。`ANDROID_HOME` 是建议的 SDK 变量，旧 `ANDROID_SDK_ROOT` 若仍设置必须一致；AVD 和用户目录另行管理。[Android 环境变量说明](https://developer.android.com/tools/variables/)。
- **链接和元数据**：Android SDK 发现 48 个、Flutter 发现 17 个符号链接；所见目标均为相对链接，按 `find -L` 未发现失效链接。Go SDK、Rust toolchain 和 .NET SDK 树未发现符号链接。检查不等于对所有链接依赖、跨卷关系或未来复制结果的保证；Android 的 `platforms/android-37 → android-37.0`、NDK 工具链和 Flutter Framework 链接必须保留。Flutter 根目录有扩展属性；根目录 `ls -ldeO@` 没有显示额外 ACL，但子项未完整审计。
- 抽样动态链接依赖包含 macOS 系统库和框架，Rust 还依赖工具链内的 `@rpath` 库。这不是完整依赖闭包。迁移后还需检验代码签名、可执行权限、扩展属性、路径引用、架构和 SDK 版本。

## APFS 映像方案（尚未执行）

### 存储与挂载约定

推荐每个 SDK 一个可写的、内含单个 APFS 卷的 sparse bundle，镜像文件放在用户选定的外置 SSD 上；物理磁盘格式、剩余空间、所有权支持、可靠断连表现与速度需在接入后检查。外层文件系统是否支持大文件、元数据、加密和安全复制也必须验证。Sparse bundle 随写入增长，但仍有预设虚拟容量；不保证缩容或备份一定高效。初始选用常规大小写不敏感 APFS，除非特定工具验证需要大小写敏感。是否加密由用户选择，密钥不进入命令行参数或普通日志。[Apple 磁盘映像文档](https://support.apple.com/en-gb/guide/disk-utility/dskutl11888/mac)。

每个 `current` 是实际挂载点；不要同时把它定义成版本符号链接。卸载某个版本后，可将该 SDK 的另一个已验证镜像挂到同一位置。每个 SDK 同时只能有一个当前挂载的卷；多版本文件通过镜像名和登记信息区分。

| SDK | 计划挂载点 | 挂载后内容或配置方向 |
|---|---|---|
| Go | `~/.local/dev/go/current` | `bin/go` 与 Go SDK 内容；保持 `GOPATH` 原位，待验证 PATH 和 Go 根目录发现 |
| Rust | `~/.local/dev/rust/current` | 镜像根目录作为候选 `RUSTUP_HOME`，含 `toolchains` 和所需设置；Cargo Home 与代理保留本机，切换前验证覆盖及工具 |
| .NET | `~/.local/dev/dotnet/current` | `dotnet`、`sdk`、`shared`、`packs` 等；验证 PATH、`DOTNET_ROOT`、apphost 与安装器行为 |
| Flutter | `~/.local/dev/flutter/current` | 完整 Flutter 根目录及 `bin`；保留独立的 `PUB_CACHE` 和宿主工具链 |
| Android | `~/.local/dev/android/current` | 原 SDK 根目录结构；验证 `ANDROID_HOME`、IDE、许可证和每个项目的 SDK 配置 |

`~/.local/dev` 目前不存在。未来创建挂载点之前必须检查每级真实路径、符号链接、所有者和目录内容；目标必须为空且不是意外的已挂载卷。挂载完成后应以卷 UUID、设备标识、镜像路径和挂载点四者核对身份，而不是只检查目录存在。未挂载时，该目录仍可能存在；入口必须明确失败，避免应用在底层空目录写入导致数据被后续挂载遮住。

建议先根据实际选中的 SDK 分别评估虚拟上限、宿主剩余空间、更新余量、备份和并存空间。例如规划 4 / 8 / 8 / 12 / 32 GiB 的虚拟上限仅是初始讨论值，合计 64 GiB，**不是** SSD 所需实际容量保证；Android 和 Flutter 的包更新可能很快超出。开始前检查目标盘剩余空间、源目录增长和独立备份容量。内置卷约 42.84 GiB 的可用空间不是同时容纳多份完整副本的保证。

### 有确认之后的单 SDK 操作顺序

1. 记录快照：SDK 版本、路径、环境变量、所有权、模式、ACL、扩展属性、链接、抽样签名与依赖、磁盘空间、项目/IDE 设置和当前挂载状态；记录确切源、目标和排除项。重新扫描并检查是否有进程使用 SDK；不能确认时暂停。
2. 在另一物理设备准备可恢复备份，完成恢复抽样和关键内容校验。保留原始环境；不要把同一 SSD 上的第二份当作独立备份。固定每次操作对应的 SDK、版本、卷身份和配置基线。
3. 创建空 APFS 映像并先试挂，核对身份、容量和权限语义。复制选定内容而非移动源目录，保留符号链接、文件模式、必要的 ACL 和扩展属性；对所有权可能需要明确策略，不应盲目授予管理员权限。检查空间和失败后的清理范围。
4. 比对文件清单、大小、关键文件哈希、链接目标、权限/ACL/扩展属性及签名；验证卷的目录布局。可写磁盘映像通常没有可供 `hdiutil verify` 验证的镜像校验和，因此不能仅凭该命令宣称复制成功。无法验证的部分标记为阻塞。
5. 在隔离的临时会话和可丢弃的测试项目中验证：明确选择镜像内可执行文件及环境变量、确认解析出的实际路径和版本、检查 architecture、运行基本编译与相关交叉目标；让潜在缓存写入落在临时位置。区分离线测试和可能下载依赖的测试。必要时检验 IDE、Android emulator、Flutter、Xcode、.NET apphost 及已有项目；任何失败停止切换。
6. 出示切换影响、确切路径和回滚动作，再由用户确认。优先通过明确可撤销的环境配置切换，不覆盖原路径或让包管理器误管理副本；新终端和 GUI 环境分别验证。
7. 保留原环境和独立备份，观察至少一个用户认可的周期；在用户再次明确同意前，不删除、移动或改写原安装。

### 回滚与卸载

- 切换失败：停止使用镜像会话，撤回本次确认过的 PATH、环境变量和 IDE 设置；恢复已记录的原配置并验证实际解析路径。原安装始终保留，避免依赖重新下载。
- 卸载：先结束或安全关闭使用该卷的构建、IDE、Gradle、模拟器及其他进程；以已验证的设备或挂载点正常 detach，确认卷不再挂载、数据已同步，再安全弹出外置 SSD。卷忙时报告占用并等待，不默认强制卸载或拔盘。
- 断电或 SSD 意外断连：停止使用该环境，检查文件系统和镜像，再从独立备份或原环境恢复；不要自动继续写入或重试有破坏性的修复。拷贝版本镜像前先正常卸载并做一致性校验，避免复制正在写入的 bundle。
- 切换版本：先停止进程并卸载旧映像，验证挂载点为空，挂载并确认新映像身份与版本；失败时挂回旧映像并重新验证。不要把未挂载状态误报为可用。

## 未来 Swift 应用设计（仅设计，不实现）

### 模块与数据

1. **Domain**：SDK、架构、版本、安装来源、证据、缓存与用户数据、卷身份、权限和风险的纯数据模型。
2. **Discovery**：只读扫描各 SDK 的已知路径、PATH/环境变量、安装收据、二进制架构、链接、配置引用和大小；提供扫描范围、权限错误和未知项，避免无提示执行工具自身的初始化。扫描输出有时间戳与证据来源。
3. **Planner**：选择源与排除项、检查容量及路径，产生不可变迁移计划、详细差异、校验与回滚步骤；计划绑定快照和目标卷身份，状态变化后必须重新检查。
4. **Image & Migration Service（后续阶段）**：封装系统磁盘映像和文件复制能力，执行单项检查、挂载、验证、卸载与事务日志；默认不实现破坏性删除，所有写操作使用受约束的参数和最小权限，拒绝任意 shell 命令。磁盘操作要在本机版本和不同文件系统上单独验收。
5. **CLI / MCP Adapter**：共用 Domain、Discovery 和 Planner，MCP 优先本机 stdio；不把 agent 提供的路径当可信输入，不暴露通用命令执行或任意文件读写。
6. **SwiftUI GUI**：概览 SDK、大小和状态；详情显示来源、缓存、依赖、风险和证据；计划页列出源/目标、空间、影响与回滚；操作前明确显示所需确认，操作中显示进度与中止方式，完成后展示验证结果和审计记录。最初只读展示，安全操作成熟后再接入写入能力。

建议数据模型至少包括：`ScanSnapshot`（时间、主机、扫描范围和失败项）、`Installation`（SDK、来源、路径、版本、架构、权限、链接和证据）、`DataLocation`（SDK/缓存/用户数据分类和重叠关系）、`ImageRecord`（镜像路径、卷 UUID、SDK/版本、容量、状态）、`MigrationPlan`（源、目标、包含/排除、备份、验证、风险、快照标识）、`OperationRecord`（操作、阶段、结果与可回滚状态）。不保存密钥、令牌或配置文件原文。

状态应区分：未发现、发现但未验证、可规划、待确认、准备中、已复制待验证、验证通过、已切换、回滚中、失败、已卸载。不能把“目录存在”或“复制完成”直接当作“可用”。

### 接口草案

只读 CLI 可设计为：`scan`、`inventory`、`inspect <sdk>`、`plan <sdk>`、`status`、`verify-plan`；支持人类可读和带版本的 JSON 输出。写入型命令如 `create-image`、`copy`、`mount`、`switch`、`unmount`、`rollback` 属于后续设计，本轮不实现；所有参数、dry-run、错误码和确认机制须先定稿。

MCP 可先提供 `scan_environments`、`list_installations`、`inspect_installation`、`create_migration_plan`、`inspect_plan`、`get_mount_status` 只读工具，输入使用严格结构和枚举，输出包括风险、证据、扫描时间及缺项。未来的 `prepare_image`、`copy_sdk`、`mount_image`、`switch_environment`、`unmount_image`、`rollback` 必须经过本机用户逐项授权，并重新核验计划与实际状态；模型自己传入的“已确认”布尔值不能作为授权。MCP 的工具说明和参数视为不可信输入，日志与返回值避免泄露凭据和用户数据。[MCP 生命周期](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)、[MCP 工具规范](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)。

确认应绑定具体操作、SDK、源及目标的规范化路径、磁盘/卷身份、计划摘要、预期覆盖范围和有效时间；执行前重新解析路径、核对所有权、挂载点、快照、磁盘空间与进程状态。任何变化或失败需重新审阅；权限提升、覆盖、删除与回滚分别提示，不将一次批准扩展为永久授权。默认拒绝路径穿越、符号链接替换、意外挂载、覆盖现有内容和无法验证的卷身份。管理员授权仅在确实需要时申请，避免把整个 GUI 或 MCP 以 root 运行。

### 实施阶段

1. 扩充只读扫描并对照本次报告，补齐自定义路径、IDE/项目引用、权限和磁盘状态；为失败项和重复统计设计测试。
2. 完成纯计划与差异预览，验证数据模型、容量估算、目标身份、未挂载状态和失败路径。
3. 实现只读 CLI 和本地 MCP，再实现 SwiftUI 只读界面；审查隐私、参数约束和协议兼容性。
4. 使用独立测试目录、测试映像和模拟数据验证挂载/复制/回滚机制，覆盖权限、断连、满盘、链接替换和并发；不得用现有 SDK 作破坏性测试。
5. 单 SDK 试点：用户审阅并批准具体迁移计划后，复制、校验、试用，再单独确认切换；按结果完善流程后扩展到其他 SDK。
6. 用户确认且验证备份、回滚后，再另行讨论原环境的清理和版本更新策略。

## 需要在实际迁移前补齐的信息

- 选择外置 SSD 及其格式、空闲空间、加密与备份介质；目前没有可验证的外置目标。
- 选择首个试点 SDK，明确是否复制 Flutter 的缓存与 Git 元数据、Android 的系统映像等；当前统计中的内容只是现状，不代表用户已授权迁移。
- 从真实终端和 IDE 分别确认项目配置、PATH 优先级、SDK/JDK 指向、正在运行的进程，以及是否依赖特定版本、离线缓存和原路径。
- 确认多台 Mac 的架构、系统版本及 Xcode/JDK 兼容性；在目标机器做独立验证。
