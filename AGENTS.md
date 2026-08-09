# AGENTS.md — MentalTutor（明镜）

**明镜**：熔炼儒道佛 + 毛泽东 + 资本论等九声部的"精神导师"AI。三个载体：角色卡粘贴（`prompts/`）、本地 CLI（`cli/`，Dart）、纸版工具包（`paperkit/`）。设计权威源：`docs/superpowers/specs/2026-08-07-spiritual-mentor-design.md`（当前 v0.7）。

## Commands

```powershell
# 语料+概念全量校验（每次改 corpus/concepts 后必跑）
node tests/validate-corpus.mjs corpus concepts

# CLI 静态检查 + 单元测试（改 cli/ 后必跑）
cd cli; dart analyze; dart test

# 运行 CLI（需 .env 配 MINGTIAN_API_KEY；dart 在 D:\dart-sdk\bin，若不在 PATH 先执行 $env:PATH = "D:\dart-sdk\bin;$env:PATH"）
# 启动会提示云端推理（隐私告知），首次发送消息需输入 y 同意；角色卡版本自动发现 prompts/ 最高版本
dart run cli/bin/mingtian.dart

# git 提交（仓库 git 用户统一用 MentalTutor；Windows PowerShell 下避免 heredoc 链式命令）
git -c user.name="MentalTutor" -c user.email="mentor@localhost" commit -m "..."
```

## Architecture

| 模块 | 角色 |
|---|---|
| `docs/superpowers/specs/2026-08-07-spiritual-mentor-design.md` | **设计权威源**：角色卡 §9、解药矩阵 §4、资产规范 §8、实测修订记录 §12 |
| `prompts/mingtian-v0.7.md` | 角色卡（粘贴进任意 LLM 用）——**必须与设计文档 §9 diff 一致** |
| `corpus/` `concepts/` `methods/` `guides/` `examples/` | 知识资产四层+示例：358 金句 / 87 概念 / 16 方法 / 10 导读 / 6 示例 |
| `paperkit/` | 纸版工具包（无 AI 自助审视，含第 0 步安全筛查） |
| `cli/` | Dart CLI：`bin/mingtian.dart`（入口/追问状态机/命令路由）、`lib/llm`（dio+SSE，glm/deepseek/qwen）、`lib/rag`（分类+n-gram+矩阵声部加成检索+危险词过滤）、`lib/prompt`（角色卡+RAG 注入+fragileRule/追问规则） |
| `eval/` `docs/reviews/` | 试金石困境与实测归档（phase1-*.md）；评审报告（*-review.md） |

## Conventions

- **语料条目七字段**：`id / 原文 / 出处 / 白话解析 / 适用场景 / 禁用场景 / 关联声部`；**禁用场景必填**（防"开错药"的最后一道闸）。
- **白名单**：声部 `laozi/lunyu/tanjing/mao/kapital/chuanxi/zhuangzi/stoic/frankl/zhuan-yi`；困境五类（意义与方向危机/工作倦怠与异化/焦虑与精神内耗/人际与情感困扰/欲望与物质匮乏感）；概念 id 用 `concept-` 前缀。
- **角色卡变更纪律**：升版本号 → `prompts/mingtian-vX.Y.md` 与 §9 双载体同步（diff 校验一致）→ §12 修订记录登记。
- **毛泽东声部**：仅哲学方法论（矛盾论/实践论/调查研究等），严禁政治立场/历史评价；白话解析必须生活化转译。
- **安全条款**：脆弱态（刚受打击/哭泣）首回合禁反求诸己、行动 ≤1 条；真实侵害/危机信号优先保护与转介，不灌思想、不劝和解。
- **矩阵一致性**：解药矩阵在 §4 / 角色卡 / paperkit 速查卡 / `cli/lib/rag/vector_search.dart` 的 `kDilemmaVoiceBonus` 四处同步——改矩阵须联动。
- **密钥**：`.env` 已被 .gitignore 保护，绝不提交；BYOK。
- **安全与隐私（双层防御）**：①CLI 危险信号命中（词表 + `isDangerous`，单测覆盖隐含表达）→ **确定性阻断**哲学处方、输出固定安全模板；②未命中由角色卡安全条款兜底。危机转介热线：**12356**（心理）/110、120（即时）/12338（家暴）/12355（未成年）——见 `eval/safety-set.md`。**隐私**：本地客户端、云端推理——启动横幅告知 + 首次发送 y 同意。
- **版本纪律**：CLI 自动发现 `prompts/` 最高版本角色卡（改 prompts 无需改 CLI）。
- **版本历史**：v0.1→v0.8 演进全程记录在 §12，改动前先读它避免重复或冲突。

## Notes

（留白，随项目演进补充。）
