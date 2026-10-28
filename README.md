# DevStore

Swift 原生 macOS 开发环境管理器的规划与实验项目。目标：每个受管理环境用一个可写 APFS 卷保存 SDK/runtime、工具管理器、状态、依赖和缓存；支持固定路径挂载、跨盘转移、检查点、回滚和停用压缩归档。

当前为**文档与实验阶段**，没有 Swift CLI、MCP Server 或 SwiftUI 应用实现。Miniconda 在本机固定挂载点的单卷副本通过三轮各 23 项验证；原安装未切换，实验卷已卸载。

## 开始阅读

1. [Claude 入口](CLAUDE.md)
2. [完整移交说明](docs/CLAUDE_HANDOFF.md)
3. [当前单卷方案 v3](docs/reports/单卷独立环境挂载方案-v3.md)
   - [v3 数据模型草案](docs/design/v3数据模型.md)
4. [Miniconda 实验报告](docs/reports/Miniconda单卷实验结果-20261029.md)
5. [文档索引](docs/README.md)

## 目录

| 目录 | 内容 |
|---|---|
| `docs/reports` | 原始扫描、各版方案、实验报告；保留设计历史 |
| `docs/experiments/miniconda-20261029` | 实验摘要、成功与失败测试记录、完整性清单 |
| `artifacts/miniconda-20261029` | 两个可写实验映像和一个压缩检查点；不同时挂载 |
| `artifacts/experiment-support/miniconda-20261029` | 临时验证脚本、打包日志、conda-pack wheel 及工具来源记录，仅供复核 |
| `TRANSFER_MANIFEST.json` | 本次交接的文件大小与 SHA-256 校验清单 |

大型映像不应提交到普通 Git 历史。当前没有初始化 Git 仓库或发布项目；原始 Codex 工作目录保留，项目拷贝不是独立物理备份。
