import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:mingtian/config.dart';
import 'package:mingtian/llm/llm_client.dart';
import 'package:mingtian/llm/providers.dart';
import 'package:mingtian/prompt/prompt_builder.dart';
import 'package:mingtian/rag/corpus_loader.dart';
import 'package:mingtian/rag/vector_search.dart';

const kUsage = '''
明镜 CLI v0.1 —— 精神导师（角色卡 v0.6 + RAG 检索 + LLM 生成）

用法:
  dart run cli/bin/mingtian.dart [--repo <仓库根>] [--provider glm|deepseek|qwen] [--top-k N]

配置（环境变量或仓库根 .env）:
  MINGTIAN_API_KEY    必填。GLM/DeepSeek 的 API key
  MINGTIAN_PROVIDER   服务商: glm(默认)|deepseek|qwen
  MINGTIAN_MODEL      模型名（留空用服务商默认）
  MINGTIAN_TOP_K      RAG 检索条数（默认 4）
  MINGTIAN_HISTORY    对话历史保留轮数（默认 6）

命令:
  /help               帮助
  /exit 或 /quit      退出
  /概念 <词>          概念查询（本地，不调 LLM）
  /对比 <声部A> <声部B>  两家思想对比（调 LLM）
  /学习               进入学习模式（调 LLM）
  /诊 <困境>          显式求助模式（默认）
  直接输入困境描述     求助模式

安全提示: 本工具不替代专业心理帮助。涉及自伤/自杀/家暴等危机，请优先联系
专业资源（心理援助热线 400-161-9995；家暴 12338/110）。
''';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', help: '显示帮助')
    ..addOption('repo', help: '仓库根目录（含 prompts/corpus/concepts，默认当前目录）')
    ..addOption('provider', help: '服务商 glm|deepseek|qwen（覆盖配置）')
    ..addOption('top-k', help: 'RAG 检索条数');
  final parsed = parser.parse(args);

  if (parsed['help'] as bool) {
    stdout.write(kUsage);
    return;
  }

  final repo = (parsed['repo'] as String?) ?? Directory.current.path;
  final config = Config.fromCwd(repo);
  final provider = (parsed['provider'] as String?) ?? config.provider;
  final pcfg = providerConfig(provider);
  final model = config.model.isEmpty ? pcfg.defaultModel : config.model;
  final topK = parsed['top-k'] != null
      ? int.tryParse(parsed['top-k'] as String) ?? config.topK
      : config.topK;

  // 加载资产
  final roleCardPath = '$repo${Platform.pathSeparator}prompts${Platform.pathSeparator}mingtian-v0.6.md';
  if (!File(roleCardPath).existsSync()) {
    stderr.writeln('未找到角色卡: $roleCardPath');
    stderr.writeln('请用 --repo 指定仓库根目录（含 prompts/mingtian-v0.6.md）');
    exitCode = 1;
    return;
  }
  final prompt = await PromptBuilder.load(roleCardPath);
  final corpus = Corpus.load('$repo${Platform.pathSeparator}corpus');
  final concepts = Concepts.load('$repo${Platform.pathSeparator}concepts');
  final search = VectorSearch(corpus);
  stdout.writeln('明镜 v0.6 ｜ provider=$provider model=$model ｜ 语料 ${corpus.entries.length} 条 ｜ 概念 ${concepts.entries.length} 条');
  stdout.writeln('输入 /help 查看用法；/exit 退出。');

  if (config.apiKey.isEmpty) {
    stdout.writeln('\n⚠ 未配置 MINGTIAN_API_KEY（环境变量或仓库根 .env）。诊断/对比/学习功能不可用；/概念 仍可用。');
  }
  final llm = config.apiKey.isEmpty
      ? null
      : LlmClient(
          baseUrl: config.baseUrlOverride ?? pcfg.baseUrl,
          apiKey: config.apiKey,
          model: model,
        );

  // 会话状态
  final history = <Map<String, String>>[];
  var awaiting = false;

  while (true) {
    stdout.write('\n你 > ');
    final line = stdin.readLineSync(encoding: utf8);
    if (line == null) break;
    final input = line.trim();
    if (input.isEmpty) continue;

    if (input == '/exit' || input == '/quit') {
      stdout.writeln('明镜：愿你带着这面镜子继续前行。');
      break;
    }
    if (input == '/help') {
      stdout.write(kUsage);
      continue;
    }
    if (input.startsWith('/概念')) {
      _handleConcept(input, concepts, corpus);
      continue;
    }
    if (input.startsWith('/对比')) {
      if (llm == null) {
        stdout.writeln('⚠ 未配置 API key，/对比 不可用。');
        continue;
      }
      final parts = input.substring(3).trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
      if (parts.length < 2) {
        stdout.writeln('用法: /对比 <声部A> <声部B>，例如 /对比 庄子 斯多葛');
        continue;
      }
      await _chat(llm, prompt, search,
          messages: [
            {'role': 'system', 'content': prompt.system(const [], extraRule: PromptBuilder.compareRule(parts[0], parts[1]))},
            {'role': 'user', 'content': PromptBuilder.user('请对比「${parts[0]}」与「${parts[1]}」。')},
          ],
          title: '【对比 ${parts[0]} vs ${parts[1]}】');
      continue;
    }
    if (input == '/学习') {
      if (llm == null) {
        stdout.writeln('⚠ 未配置 API key，/学习 不可用。');
        continue;
      }
      await _chat(llm, prompt, search,
          messages: [
            {'role': 'system', 'content': prompt.system(const [], extraRule: PromptBuilder.learnRule)},
            {'role': 'user', 'content': PromptBuilder.user('我想学习这套智慧。')},
          ],
          title: '【学习模式】');
      continue;
    }

    // 求助模式（默认）：诊断对话
    final userText = input.startsWith('/诊') ? input.substring(3).trim() : input;

    // CLI 层安全兜底：危险词命中 → 打印安全提示（不阻断 LLM，LLM 端由角色卡安全条款处理）
    final dangerous = VectorSearch.kDangerWords.any(userText.contains);
    if (dangerous) {
      stdout.writeln('⚠ 检测到可能的危机信号：本工具不替代专业帮助。涉及自伤/自杀请拨打心理援助热线 400-161-9995；家暴可拨打 12338 或 110。');
    }

    final hits = search.search(userText, topK: topK, safeMode: true);
    if (llm == null) {
      stdout.writeln('（未配置 API key，仅展示检索到的参考语料）');
      for (final h in hits) {
        stdout.writeln('  - 【${h.entry.id}】"${h.entry.text}"（${h.entry.source}）');
      }
      continue;
    }

    final messages = <Map<String, String>>[
      {'role': 'system', 'content': prompt.system(hits.map((h) => h.entry).toList(), extraRule: awaiting ? PromptBuilder.awaitingRule : null)},
      ...history,
      {'role': 'user', 'content': PromptBuilder.user(userText)},
    ];
    final reply = await _chat(llm, prompt, search, messages: messages, title: '明镜');
    if (reply == null) continue;

    // 更新历史（保留最近 config.history 轮）
    history.addAll([
      {'role': 'user', 'content': userText},
      {'role': 'assistant', 'content': reply},
    ]);
    while (history.length > config.history * 2) {
      history.removeRange(0, 2);
    }

    // 追问状态判定（启发式：以问号结尾或末尾含问号且无行动编号）
    final tail = reply.length > 120 ? reply.substring(reply.length - 120) : reply;
    final hasQuestion = tail.contains('？') || tail.contains('?');
    final hasAction = RegExp(r'[①②③]|\b[1-3][\.、．]').hasMatch(tail) || tail.contains('行动');
    awaiting = hasQuestion && !hasAction;
  }
}

/// 执行一次流式对话，返回完整回复；失败返回 null 并打印错误。
Future<String?> _chat(
  LlmClient llm,
  PromptBuilder prompt,
  VectorSearch search, {
  required List<Map<String, String>> messages,
  required String title,
}) async {
  stdout.writeln('\n$title：');
  final sb = StringBuffer();
  try {
    await for (final delta in llm.chat(messages)) {
      sb.write(delta);
      stdout.write(delta);
    }
    stdout.writeln();
    return sb.toString();
  } catch (e) {
    stderr.writeln('\n⚠ LLM 调用失败: $e');
    return null;
  }
}

/// /概念：本地概念查询（不调 LLM）。
void _handleConcept(String input, Concepts concepts, Corpus corpus) {
  final keyword = input.substring(3).trim();
  if (keyword.isEmpty) {
    stdout.writeln('用法: /概念 <概念名>，例如 /概念 异化');
    return;
  }
  final hits = concepts.search(keyword);
  if (hits.isEmpty) {
    stdout.writeln('未找到概念「$keyword」。');
    return;
  }
  for (final c in hits.take(5)) {
    stdout.writeln('■ ${c.name}（${c.voice}｜${c.id}）');
    stdout.writeln('  定义: ${c.definition}');
    if (c.relatedConcepts.isNotEmpty) {
      stdout.writeln('  关联概念: ${c.relatedConcepts.join('、')}');
    }
    for (final cid in c.relatedCorpus.take(3)) {
      final e = corpus.byId(cid);
      if (e != null) {
        stdout.writeln('  关联语料【$cid】"${e.text}"（${e.source}）');
      }
    }
    stdout.writeln();
  }
}
