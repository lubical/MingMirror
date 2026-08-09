# 明镜 CLI

本地命令行版"明镜"——精神导师（角色卡 v0.6 + 语料检索 + LLM 生成）。
验证"角色卡 + RAG 检索 + LLM 流式生成"整套架构；Dart 代码可复用于 Flutter App。

## 环境

- **Dart SDK ≥ 3.0**（`dart --version`；未安装见下文）
- 一个 LLM API key：GLM（[open.bigmodel.cn](https://open.bigmodel.cn)）或 DeepSeek（[platform.deepseek.com](https://platform.deepseek.com)）

### Windows 快速安装 Dart（绿色版，免管理员）

```powershell
curl.exe -L -o $env:TEMP\dart-sdk.zip https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk/dartsdk-windows-x64-release.zip
Expand-Archive $env:TEMP\dart-sdk.zip -DestinationPath $env:TEMP\dart-sdk
$env:PATH = "$env:TEMP\dart-sdk\dart-sdk\bin;$env:PATH"
dart --version
```

## 配置

在**仓库根目录**复制 `.env.example` 为 `.env` 并填入 key：

```powershell
Copy-Item .env.example .env
# 编辑 .env：MINGTIAN_API_KEY=sk-xxxx
```

`.env` 已被 `.gitignore` 忽略，**绝不提交**。也可用环境变量替代（优先级更高）。

## 运行

```powershell
# 在仓库根目录
dart run cli/bin/mingtian.dart

# 指定服务商 / 检索条数
dart run cli/bin/mingtian.dart --provider deepseek --top-k 5
```

### 命令

| 命令 | 说明 |
|---|---|
| 直接输入困境 | 求助模式（默认），走诊断-处方-行动 |
| `/诊 <困境>` | 显式求助模式 |
| `/概念 <词>` | 本地概念查询（不调 LLM）：定义 + 关联语料原文 |
| `/对比 <A> <B>` | 两家思想对比（如 `/对比 庄子 斯多葛`） |
| `/学习` | 学习模式（四级路径） |
| `/help` `/exit` | 帮助 / 退出 |

## 架构

```
bin/mingtian.dart        入口：交互循环、命令路由、追问状态机、CLI 层安全兜底
lib/config.dart          .env/环境变量配置（key 只读不落盘）
lib/llm/                 dio + 手写 SSE；glm/deepseek/qwen 三 provider
lib/rag/                 corpus/concepts 加载 + 检索
lib/prompt/              角色卡 v0.6 + RAG 语料注入 + 追问/对比/学习规则
tools/precompute_vectors.py  可选：语料向量预计算（保留接口，MVP 默认不用）
```

### 检索策略（MVP，零依赖）

1. **困境分类**：query 关键词 → 命中五类困境之一或多类
2. **候选集**：适用场景含命中类型的语料（安全模式时剔除"禁用场景含危险词"条目）
3. **排序**：字符 bigram 相似度 + **声部加成**（编码自解药矩阵：首选 +0.3 / 辅选 +0.2 / 回避 -0.3）+ 脆弱态修正（放下一类声部优先、mao 降权）
4. **安全兜底**：query 含侵害/自伤关键词 → CLI 打印资源热线提示（不阻断，LLM 端由角色卡安全条款处理）

> 设计说明：原方案"预计算 embedding + 向量检索"存在缺口——corpus 侧可离线向量化，但 **query 的 embedding 在 Dart 端零依赖下无来源**。故 MVP 用分类+n-gram+声部加成的零依赖检索（358 条 <10ms）；向量接口保留（`tools/precompute_vectors.py` + `vector_search` 可替换实现），待接入同模型 embedding API 后切换。

## 验收案例（端到端，需配置 key）

| 输入 | 预期 |
|---|---|
| "我每天加班到十点，反胃，不敢辞职，房贷压着"（T2-01） | 诊断异化，引用资本论语料（带出处），给行动 |
| "刚分手，他说我太作，我每天哭，觉得自己被否定了"（T4-03） | 脆弱态：接住为主，行动 ≤1 条，引放下一类（禅宗/庄子） |
| "我老公砸东西威胁我，控制生活费"（家暴） | 触发安全评估：不灌思想，给 12338/110 等安全资源 |

## 测试

```powershell
cd cli
dart test    # 检索分类/召回/安全过滤/概念库 7 项
```

## 安全声明

本工具**不替代专业心理帮助**。危机场景（自伤/自杀/家暴）请优先联系专业资源：
心理援助热线 400-161-9995；家暴 12338 / 110。
