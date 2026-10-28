# 实验方案：compact 与多槽

日期：2026-10-29。状态：**已执行（A10 除外）**，结果见 [compact 实验结果](../reports/compact实验结果-20261029.md)、[多槽实验结果](../reports/多槽实验结果-20261029.md)。A10 中断测试仍需另行授权。目的：关闭 [v3 数据模型](v3数据模型.md) 第 8 节的两项开放问题——compact 是否值得做、怎么做才安全；同 kind 多槽同时挂载时各实例是否互不借用。

两个实验相互独立，可分别授权；共用第 1 节的前提与第 4 节的边界。

## 1. 共同前提

### 1.1 方案编写时的本机状态（执行前须重新核对）

- `~/.local/dev` 下无挂载；`miniconda/current` 为空占位目录。`hdiutil info` 中没有 DevStore 映像挂载。
- 系统数据卷剩余约 37 GiB（已用 83%）。
- 实验映像：`miniconda.sparsebundle` 约 2.4 GiB、304 个 band；`miniconda-restored.sparsebundle` 约 2.4 GiB、312 个 band；band 大小均为 8 MiB。
- `/usr/bin/sandbox-exec` 可用（Apple 已标记为弃用，但上次实验正常使用）。

### 1.2 不可动的对象

- 原安装 `~/miniconda3`、`~/.conda`、`~/.condarc`、`~/.zshrc`：只读；实验前后比对摘要。
- `artifacts/miniconda-20261029` 下三个现有映像和检查点：**不挂载、不修改**，只作为克隆来源。
- 全局 shell 配置、Homebrew、系统设置：不动。

### 1.3 实验目录与副本规则

- 工作映像：`artifacts/experiments/<实验名>-<日期>/`，用 `cp -c`（APFS 克隆）从现有映像建立，克隆后先比对 `Info.plist` 与 band 列表一致。
- 证据：`docs/experiments/<实验名>-<日期>/`，结构仿照 Miniconda 实验（摘要 JSON + 分阶段记录）。
- **克隆副本与来源卷 UUID 相同**。任何时刻只挂载同一来源的一个副本；每次挂载前用 `hdiutil info` 和 `diskutil info` 确认没有同 UUID 的卷。
- 克隆共享底层存储，`du` 显示的是逻辑分配；宿主可用空间变化另用 `df` 记录。两种口径分别报告，不混用。

### 1.4 需要先写的验证脚本

旧脚本 `artifacts/experiment-support/miniconda-20261029/verify_volume.py` 写死了挂载点、Codex 输出目录和禁止路径，**不直接复用**。新脚本放在 `artifacts/experiment-support/<实验名>-<日期>/`，执行前给用户审阅：

- 参数：`--mount`、`--out`、`--stage`、`--deny`（可多次）、`--write-allow`。
- 保留原 23 项检查与负向对照；负向对照失败则整轮无效。
- 输出符合数据模型第 5 节的 `VerificationRun` 结构，含 `coverage.notCovered`。
- 另写只读的内容清单工具：逐项记录路径、类型、模式、大小、SHA-256、链接目标，可对两个清单做差异比较，可按数据分类排除路径（如 `tmp/`）。

## 2. 实验 A：compact

### 2.1 要回答的问题

1. 卷内删除数据并正常卸载后，sparse bundle 是否已自动释放 band（APFS 在映像上的 TRIM/unmap）？若会，compact 的价值很小。
2. `hdiutil compact` 能回收多少、耗时多久？
3. compact 后内容和运行是否完全不变？
4. compact 被中断后映像是否还能用？这决定是否必须"对临时副本 compact，验证后替换"。

### 2.2 步骤

| 步骤 | 操作 | 记录 |
|---|---|---|
| A0 | 前置核对（1.1、1.3）；记录原安装与 host 配置摘要 | `preflight.json` |
| A1 | 克隆 `miniconda.sparsebundle` → `work.sparsebundle` | band 数、`du`、`df` |
| A2 | 不做任何改动，直接 `hdiutil compact work.sparsebundle` | 前后 band 数、分配字节、耗时（基线：已有空闲能回收多少） |
| A3 | 固定路径 `~/.local/dev/miniconda/current` 挂载；建立内容清单 M1（排除 `tmp/`）；卸载 | `manifest-before.json` |
| A4 | 挂载；在 `tmp/` 写 2 GiB 随机数据（`/dev/urandom`，避免零块被稀疏化）；`sync`；卸载 | 分配字节增量，应约 +2 GiB |
| A5 | 挂载；删除该文件；`sync`；卸载 | **不 compact**，记录分配字节：回答问题 1 |
| A6 | `hdiutil compact` | 前后分配字节、band 数、耗时：回答问题 2 |
| A7 | 挂载；建立清单 M2，与 M1 比对；运行验证套件（stage `compacted`）；卸载 | 回答问题 3 |
| A8 | 重挂并再跑一次验证（stage `compacted-remounted`） | 确认重挂稳定 |
| A9 | 现实场景：挂载，清理 `cacheRebuildable` 分类（`cache/pip`、`cache/xdg`）；卸载；compact | 小数据量时的实际收益 |
| A10（可选，单独授权） | 再克隆一个 `crash.sparsebundle`，重复 A4–A5 制造空闲，compact 启动数秒后终止进程；然后尝试挂载、`diskutil verifyVolume`、建清单比对 | 回答问题 4。只在克隆上做，结束后保留不删，等用户决定 |
| A11 | 比对原安装与 host 配置摘要；确认全部卸载 | `source-verification-after.json` |

### 2.3 判定规则

| 结果 | 对设计的影响 |
|---|---|
| A5 已释放 ≥90% 的删除量 | compact 价值低；数据模型中保留操作位，适配器默认不提供，UI 只在可回收量明显时提示 |
| A5 未释放，A6 回收显著，A7/A8 全通过 | 将 compact 作为 `mutate` 操作开放：卸载 → 克隆为临时副本 → compact → 清单比对 + 验证 → 原子替换 → 原映像标 `retired` |
| A7/A8 任一失败 | 不开放 compact；记录失败证据 |
| A10 中断后映像损坏 | "临时副本 compact 后替换"为硬性要求，禁止原地 compact |
| A10 中断后映像正常 | 仍保留副本流程（成本低），但记录原地 compact 的风险较低 |

### 2.4 资源估计

克隆不立即占用空间；A4 写入使宿主占用增加约 2 GiB，compact 后回落。A10 另需约 2–4 GiB。峰值预计 < 8 GiB，低于当前剩余 37 GiB；执行前低于 15 GiB 则暂停。

## 3. 实验 B：多槽

### 3.1 要回答的问题

1. 把已有实例重定位到第二个槽位 `~/.local/dev/miniconda/lab` 后，能否在不读取 `current` 槽位和原安装的情况下运行？前缀残留有多少、是否影响运行？
2. 两个槽位同时挂载时，各自会话的 `sys.prefix`、conda 根目录、包缓存、配置、HOME 是否只指向自己的卷？
3. 两个槽位同时执行写操作（离线建环境、安装本地包）是否会相互干扰？
4. 卸载一个槽位时另一个是否不受影响？

### 3.2 第二实例的来源

在新建的空白映像中重建，而不是克隆现有映像改路径（克隆会带同一 UUID，且前缀仍指向 `current`）：

- 新建 8 GiB APFS sparse bundle `lab.sparsebundle`，卷 UUID 天然不同。
- 来源：`miniconda.sparsebundle` 的一个克隆，**只读**挂载在 `current` 槽位。不使用原 `~/miniconda3`，以免触及原安装。
- 用上次实验同一 wheel（已有 SHA-256 记录）的 conda-pack 0.9.2，以 `current` 卷为源、`lab` 为目标前缀重定位 base 与三个子环境，处理方式与上次一致（含 `python.app` 定向处理、`python3.10` 用 tar 重建并核对成员）。conda-pack 在临时目录运行，不安装到任何环境。
- 独立的 `state/`、`cache/`、`tmp/` 新建，不从 `current` 复制 HOME 内容。

这一步同时验证数据模型中"换槽位 = 按导入流程重新重定位"的规定。

### 3.3 步骤

| 步骤 | 操作 | 记录 |
|---|---|---|
| B0 | 前置核对；记录原安装与 host 配置摘要 | `preflight.json` |
| B1 | 克隆 `miniconda.sparsebundle` → `current-src.sparsebundle`；只读挂载到 `current` | 挂载信息、UUID |
| B2 | 新建 `lab.sparsebundle` 并挂载到 `lab`；按 3.2 重定位 | 打包记录、警告清单、两个卷 UUID 不同 |
| B3 | 前缀残留扫描：在 `lab` 卷内查找字符串 `/.local/dev/miniconda/current`，按文件类型分类（脚本、文本元数据、二进制、`.pyc`、conda-meta 历史） | `prefix-residue.json`；任何可执行脚本或 shebang 中的残留需单独列出 |
| B4 | 卸载 `current`；单独运行 `lab` 验证套件，禁止读取：原安装、`current` 槽位路径、Homebrew、`/usr/local`；禁网 | stage `lab-alone`，回答问题 1 |
| B5 | 将 `current` 改为**可写**挂载（克隆副本）；两槽同时挂载 | 挂载状态 |
| B6 | 各自运行验证套件：`current` 会话禁止读 `lab`，`lab` 会话禁止读 `current`，二者都禁止原安装 | stage `both-current`、`both-lab`，回答问题 2 |
| B7 | 并发：同时在两槽执行离线建环境 + 安装本地数据包 + NumPy/PyTorch 计算 | 两边结果、耗时、包缓存落点，回答问题 3 |
| B8 | 卸载 `current`，期间 `lab` 正在跑计算任务；随后在 `lab` 再跑一轮快速检查；再重挂 `current` 跑快速检查 | 回答问题 4 |
| B9（对照，可选） | 卸载两槽后，把 `lab` 映像挂到 `current` 路径，运行几项检查 | 预期失败；证明槽位不可随意交换，支持"挂载时比对 fixedMountPath"的规则 |
| B10 | 卸载全部；比对原安装与 host 配置摘要；比对 `current-src` 卷 B1 时与结束时的清单（排除 B6–B8 预期写入的分类） | `source-verification-after.json` |

### 3.4 判定规则

| 结果 | 对设计的影响 |
|---|---|
| B4、B6 全通过，B3 残留不在可执行路径 | 多槽可行；"换槽位按导入重定位"流程成立 |
| B3 有可执行路径残留但 B4 通过 | 记录为适配器已知警告；适配器在导入后增加残留扫描步骤，报告而非静默 |
| B4 或 B6 失败且原因是读到另一槽 | 多槽暂缓；分析具体路径，判断是否能靠会话变量修正 |
| B7 有冲突 | 明确冲突来源（锁文件、共享 TMPDIR、全局状态），在适配器声明中补隔离路径 |
| B9 意外通过 | 不放宽规则；仍要求 fixedMountPath 一致，并记录 |

### 3.5 资源估计

`lab` 映像约 2.5 GiB；`current-src` 克隆在可写挂载后产生少量写入。峰值预计 < 6 GiB。执行前剩余空间低于 15 GiB 则暂停。

## 4. 边界与停止条件

- **执行授权**：实验 A、A10、实验 B 分三次授权；方案中的步骤不构成执行授权。
- **网络**：所有验证轮次禁网。conda-pack wheel 使用已有文件，不重新下载。
- **停止条件**（任一出现即停，卸载并报告）：发现原安装或 host 配置摘要变化；挂载点底层目录非空；出现同 UUID 卷；剩余空间低于 15 GiB；`hdiutil` 报告映像错误。
- **结束状态**：全部卸载；实验映像保留不删，由用户决定；日常 conda 不切换。
- **证据**：失败轮次保留；报告写明已覆盖与未覆盖，例如外置 SSD、跨 Mac 仍不在本方案范围内。

## 5. 执行后产出

- 两份实验报告：`docs/reports/compact实验结果-<日期>.md`、`docs/reports/多槽实验结果-<日期>.md`。
- 更新 v3 数据模型：compact 的决定（第 7 节第 6 项），多槽验收状态（第 8 节）；Miniconda 适配器声明中补充前缀残留扫描与并发隔离路径（如有）。
- 更新移交文档、`TRANSFER_MANIFEST.json`（新增映像和证据的大小与 SHA-256）。
