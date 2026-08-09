# 外部实测原始证据（raw）

> 本目录归档阶段 1 外部 LLM 实测的**原始输出文件**，作为可追溯证据。仓库内 `eval/phase1-*.md` 是在原始文件基础上追加评审段的加工版。

## 文件对应关系

| 原始文件（本目录） | 测试模型 | 加工版（eval/ 根目录） | 加工版增加的内容 |
|---|---|---|---|
| `external-glm-v0.4-eval-results.md` | **GLM** | `eval/phase1-mimo-v2.md` | 末尾追加 Reasonix 评审段 |
| `external-mimo-v2.5pro-self-test-v0.4.md` | **mimoV2.5Pro** | `eval/phase1-independent-run.md` | 末尾追加 Reasonix 评审段 |

> ⚠️ **文件名历史误导说明**：加工版文件名 `phase1-mimo-v2.md` 实际对应的是 **GLM** 输出，`phase1-independent-run.md` 对应的是 **mimoV2.5Pro** 输出（命名源于工作流顺序，非模型归属）。原始文件名以模型为准，避免歧义。已在设计文档 §12 修正登记。

## 测试条件（用户确认 2026-08-09）

- 两份均为**新开会话、仅访问 D:/temp 目录下文件**（角色卡 + trial-set，无 corpus 注入）
- 分别用 GLM 和 mimoV2.5Pro 两个模型独立运行
- 结果由 deepseek 审核后写回设计文档 §12

## 与本仓库其他实测的区别

| 实测 | 模型 | corpus 注入 | 文件 |
|---|---|---|---|
| 本目录两份 | GLM / mimoV2.5Pro（外部） | ❌ 无 | `eval/raw/` |
| MiMo 受控演示 | MiMo（本地 agent） | ✅ 有 | `eval/phase1-run.md` |
| GLM-5.2 交叉实测 | GLM-5.2（本地 agent） | ✅ 有 | `eval/phase1-run-glm52.md` |

> 本目录两份是唯一**无 corpus 注入**的实测，最接近"用户粘贴角色卡到任意 LLM"的真实使用场景，证据价值最高。
