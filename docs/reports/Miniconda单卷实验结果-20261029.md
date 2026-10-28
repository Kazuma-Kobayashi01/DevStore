# Miniconda 单卷实验结果

日期：2026-10-29。结论：**本机 Miniconda 在单个可写 APFS 卷中的副本通过了首次运行、正常卸载重挂、压缩归档恢复三轮验证，每轮 23 项，最终共 69/69 项通过。** 原安装及日常 shell 配置没有切换。试验结束时两个可写实验映像均已正常卸载。

这证明本机、当前固定挂载路径下的 Miniconda 单卷方案可行；不等于所有 Python 包、GPU、外置盘或其他语言环境均已通过。后续总体设计以单卷为默认，按各 SDK 继续验收。

## 来源与实验布局

- 源：`/Users/jackson-hao/miniconda3`，扫描时占用约 2.11 GiB；conda 25.11.1，arm64。
- 一个 APFS 可写卷，虚拟容量上限 8 GiB，存储为 sparse bundle；没有独立缓存卷。
- 固定挂载点：`/Users/jackson-hao/.local/dev/miniconda/current`。这是新建的实验挂载路径，未替换源目录。
- 卷内 `miniconda3` 保存 base、三个子环境、包缓存与原生安装结构；`state` 保存独立 conda 配置、实验用户 HOME 和状态；`cache` 保存 pip 等缓存；`tmp` 保存实验临时数据。
- 受控会话将 conda 环境/包目录、HOME、配置、pip/XDG 缓存、临时路径与证书/模块路径映射到同一卷；不会自动使用原 shell 的 conda 初始化配置。
- 没有复制源 `~/.conda` 中的登录令牌，没有执行 `conda init`，没有改动原 Miniconda 或安装全局打包工具。

| 环境 | Python | conda 包数 | 验证的代表性能力 |
|---|---|---:|---|
| base | 3.13.11 | 113 | Python、pip、SSL/SQLite/压缩模块、conda CLI、原生插件与环境管理 |
| llama-cpp | 3.10.20 | 19 | Python、pip、HTTPX 0.28.1、conda run |
| neocloud | 3.11.15 | 19 | Python、pip、FastAPI 0.141.1、Pydantic 2.13.4、Requests 2.34.2、shell 激活 |
| python3.10 | 3.10.19 | 82 | Python、pip、NumPy 2.2.5 与 PyTorch 2.5.1 的 CPU 计算 |

包数为 conda 元数据计数，不含所有 pip 包；包名、版本、build 与源环境的 conda 清单一致。环境名 `llama-cpp` 不代表测试过模型推理或其中所有应用。

## 防止“借用原安装”的验证

每轮运行用系统访问规则阻止读取原 `~/miniconda3`、原 `~/.conda`、原 `~/.condarc`、`/opt/homebrew` 与 `/usr/local`，并禁止联网；写入仅允许实验卷和临时目录。每轮先执行负向对照，确认原安装的实际文件确实读取失败，然后才开始功能验证。

检查四个 Python 的 `sys.prefix`、解释器路径、标准库路径与 sysconfig prefix 均在实验卷内；检查 conda 根目录、环境发现和包缓存位置均指向卷内。卷内没有指向卷外的符号链接。这些是针对本次环境的运行证据，不等于完整的文件访问审计或容器隔离。

每轮 23 项包括：负向对照；四个环境各自的 Python/标准库/路径检查和 pip；conda 脚本入口、隔离 info、原生插件 info、环境发现、激活、run；代表性包和数值计算；离线创建临时环境、安装实验生成的数据包、核对内容、移除临时环境；卷内状态与缓存标记的持久化。

离线安装使用实验创建的无依赖数据包，只验证包管理写入、包缓存和新环境都落在同一卷。它不代表现有环境所需的所有包都已缓存，也不代表能够离线升级全部环境。

## 过程中发现并处理的问题

Conda 环境不能简单复制后任意换目录；本次使用隔离下载到项目临时目录的 conda-pack 0.9.2 做前缀处理，下载 wheel 的 SHA-256 已与 PyPI 元数据比对。没有把工具安装到源环境。[conda-pack 官方说明](https://conda.github.io/conda-pack/)。

1. 源包缓存基本已清理，conda-pack 无法使用全部原包的缓存记录完成最稳健的前缀重写。因此保留警告，必须通过禁止原路径访问的代表性运行测试；不据此声称所有包已完全可搬运。
2. base 的 `python.app` 包安装后会将 `pythonapp` 移为实际的 `python.app`，其旧元数据仍列出前者。确认这是现有 post-link 脚本的行为后，只针对这一项包含实际 bundle；没有恢复、修改或删除原安装文件。Python GUI bundle 的图形启动未测。
3. 首次直接复制输出不完整，`python3.10` 的三项运行测试失败，文件清单检查也发现缺项；失败记录保留。改用完整 tar 归档，核对归档成员，再恢复该子环境，所有期望路径均存在后重跑。最终的 69/69 指修复后通过的三轮验证，不能理解为首个尝试零失败。

## 完整性和恢复结果

- 原安装：逐项核对 **103,075 个条目**的文件内容摘要、文件模式和链接目标，未发现变化或新增/缺失。
- 原 `~/.zshrc`、`~/.condarc`、`~/.conda/environments.txt` 的摘要未变；日常 `conda` 仍由原有 shell 配置选择。
- 归档恢复：对 `miniconda3`、`state`、`cache` 内 **103,105 个条目**核对文件摘要、模式和链接，全部与检查点一致，再通过 23 项运行测试。
- 压缩映像的 `hdiutil verify` 校验通过，另记录 SHA-256；可写映像不使用该内置校验和来代替内容验证。

## 压缩与恢复

| 项目 | 测量结果 |
|---|---|
| 原可写实验 sparse bundle 已分配空间 | 2,538,987,520 字节，约 2.36 GiB |
| LZFSE 压缩 DMG 文件大小 | 660,660,631 字节，约 630.05 MiB |
| 压缩 DMG 在宿主上的已分配空间 | 671,092,736 字节，约 640 MiB |
| 归档文件大小相对原 bundle 已分配空间 | 约减少 73.98%，不是按 8 GiB 虚拟容量计算 |
| 本次压缩耗时 | 约 4.94 秒 |
| 转回新可写 sparse bundle 耗时 | 约 3.93 秒，不含后续挂载、内容核对和运行测试 |
| 恢复可写卷的宿主已分配空间 | 2,597,453,824 字节，约 2.42 GiB |

耗时仅代表本次内置盘与文件缓存条件，不是冷盘性能基准。压缩比与文件内容相关；恢复卷体积可能因分配布局和测试写入有所变化。压缩 DMG 用作停用归档，运行时仍是独立可写卷。

压缩检查点 SHA-256：`61d8c5e27c73af6286c156a1ba75cbc41b8a99cfd515eafcdbaea6705bcdb5ba`。

## 保存的结果与使用边界

[实验摘要](../experiments/miniconda-20261029/experiment-summary.json)、[首次成功运行](../experiments/miniconda-20261029/verification-initial.json)、[重挂验证](../experiments/miniconda-20261029/verification-remounted.json)、[归档恢复验证](../experiments/miniconda-20261029/verification-restored.json)、[原安装核对](../experiments/miniconda-20261029/source-verification-after.json)、[恢复内容核对](../experiments/miniconda-20261029/restore-content-verification.json) 均已保存。

存储目录：`outputs/experiments/miniconda-20261029`，保留原可写实验映像 `miniconda.sparsebundle`、压缩检查点 `miniconda-checkpoint.dmg` 和恢复后的可写映像 `miniconda-restored.sparsebundle`。它们是同一实验的副本/归档，不是三个需要同时挂载的卷，也不是跨物理设备备份。

目前均已卸载。使用副本时须挂回上面的固定路径，并使用独立会话配置；直接在其他挂载路径打开映像并不代表 conda 前缀已再次重定位。跨盘后保持固定挂载点是后续方案；跨用户目录、跨 Mac 或跨架构必须另做前缀和依赖验证。没有把原安装重命名、移走或删除以制造“脱离原环境”的测试条件。

未测试的项目包括外置 SSD、跨 Mac/架构、GPU/MPS、任意用户工作负载、全部第三方包、在线升级、GUI Python、凭据迁移和 compact。其他语言改为单卷是架构决策，仍需各自验证。
