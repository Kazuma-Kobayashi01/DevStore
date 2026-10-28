# DevStore 文档索引

当前有效方案：[单卷独立环境挂载方案 v3](reports/单卷独立环境挂载方案-v3.md)。

## 移交入口

- [Claude 移交说明](CLAUDE_HANDOFF.md)：当前状态、证据、限制及建议的后续阶段。
- [需求与决策记录](需求与决策记录.md)：用户目标、范围和设计变更。
- [路径与材料位置](路径与材料位置.md)：新项目与原始 Codex 工作目录的对应关系。

## 下一步

- [下一阶段：Miniconda 实际使用测试](design/下一阶段-Miniconda实际使用.md)：新建→写入 SDK→使用→回收→压缩/加密→冷备份，以及与现有实现的差距。

## 实现

- [CLI 与 MCP](CLI与MCP.md)：命令、授权模型、实机测试与未实现项。

## 报告与方案

| 文档 | 状态 |
|---|---|
| [macOS 开发环境迁移评估](reports/macOS开发环境迁移评估.md) | 本机扫描基线；其中旧迁移设计已由 v3 替代 |
| [SDK 双镜像挂载与压缩方案 v1](reports/SDK双镜像挂载与压缩方案-v1.md) | 历史：只读 SDK + 可写缓存，已弃用 |
| [可写独立环境挂载与压缩方案 v2](reports/可写独立环境挂载与压缩方案-v2.md) | 历史：可写环境 + 可选缓存卷，已被 v3 替代 |
| [Miniconda 单卷实验结果](reports/Miniconda单卷实验结果-20261029.md) | 本机首次运行、重挂与归档恢复通过 |
| [单卷独立环境挂载方案 v3](reports/单卷独立环境挂载方案-v3.md) | 当前默认设计；其他语言待验收 |
| [v3 数据模型与能力边界](design/v3数据模型.md) | 设计草案；待决问题已决定；无实现 |
| [compact 与多槽实验方案](design/实验方案-compact与多槽.md) | 已执行（A10 中断测试除外） |
| [compact 实验结果](reports/compact实验结果-20261029.md) | 卸载不自动释放；compact 回收 2 GB、内容一致、23/23×2 |
| [多槽实验结果](reports/多槽实验结果-20261029.md) | 两槽同时挂载与并发通过，166/166；发现原安装路径的二进制残留 |

## 实验证据

- [摘要](experiments/miniconda-20261029/experiment-summary.json)
- [首次成功运行](experiments/miniconda-20261029/verification-initial.json)
- [重挂验证](experiments/miniconda-20261029/verification-remounted.json)
- [归档恢复运行](experiments/miniconda-20261029/verification-restored.json)
- [恢复内容完整性](experiments/miniconda-20261029/restore-content-verification.json)
- [原安装未变](experiments/miniconda-20261029/source-verification-after.json)
- [最初失败尝试](experiments/miniconda-20261029/verification-initial-attempt.json)

该目录还包含原始包清单、打包记录、复制缺项检查、全量文件摘要与链接清单。两份全量清单较大，先读摘要，按需检索，避免一次加载全部。
