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
