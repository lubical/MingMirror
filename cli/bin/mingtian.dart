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
明镜 CLI v0.1 —— 精神导师（角色卡自动发现 + 检索 + LLM 流式生成）

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

隐私: 本工具为本地客户端，推理由服务商云端完成——对话内容会上传至所选 provider。
安全提示: 本工具不替代专业心理帮助。心理援助热线 12356（全国统一）；家暴 12338；
即时危险请拨打 110/120。
''';

/// 确定性安全模板：危险信号命中时输出（不调用 LLM、不处方思想）。
const String _kSafetyTemplate = '''
明镜（安全模式）：
听到这些，我很担心你此刻的安全。现在最重要的不是讲道理，是先确保你（或你担心的人）安全。

请立即联系：
· 心理援助热线 12356（全国统一，服务时段以当地接通为准）
· 若正在发生即时危险或已自伤：拨打 110 / 120
· 家暴/侵害场景：可拨打 12338（妇女维权热线）或 110

如果你愿意，可以继续告诉我发生了什么，我会在这里陪着你——但请先确保自己在一个安全的地方。
你不需要独自面对。

（输入 /exit 退出，或继续输入任何内容我都会回应。）''';

/// 自动发现 prompts/ 下版本号最高的角色卡。
String _discoverRoleCard(String promptsDir) {
  final dir = Directory(promptsDir);
  if (!dir.existsSync()) return '';
  final re = RegExp(r'mingtian-v(\d+)\.(\d+)\.md');
  String best = '';
  var bestMajor = -1;
  var bestMinor = -1;
  for (final f in dir.listSync().whereType<File>()) {
    final m = re.firstMatch(f.uri.pathSegments.last);
    if (m != null) {
      final ma = int.parse(m.group(1)!);
      final mi = int.parse(m.group(2)!);
      if (ma > bestMajor || (ma == bestMajor && mi > bestMinor)) {
        bestMajor = ma;
        bestMinor = mi;
        best = f.path;
      }
    }
  }
  return best;
}

/// 从角色卡路径提取版本字符串（如 v0.8）。
String _roleCardVersion(String path) {
  final m = RegExp(r'mingtian-(v\d+\.\d+)\.md').firstMatch(path);
  return m?.group(1) ?? '?';
}

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

  // 加载资产（角色卡自动发现最高版本，消除硬编码漂移）
  final roleCardPath = _discoverRoleCard('$repo${Platform.pathSeparator}prompts');
  if (roleCardPath.isEmpty) {
    stderr.writeln('未找到角色卡: 请确认 $repo${Platform.pathSeparator}prompts 下存在 mingtian-vX.Y.md');
    stderr.writeln('可用 --repo 指定仓库根目录');
    exitCode = 1;
    return;
  }
  final prompt = await PromptBuilder.load(roleCardPath);
  final roleCardVersion = _roleCardVersion(roleCardPath);
  final corpus = Corpus.load('$repo${Platform.pathSeparator}corpus');
  final concepts = Concepts.load('$repo${Platform.pathSeparator}concepts');
  final search = VectorSearch(corpus);
  stdout.writeln('明镜 $roleCardVersion ｜ provider=$provider model=$model ｜ 语料 ${corpus.entries.length} 条 ｜ 概念 ${concepts.entries.length} 条');
  stdout.writeln('输入 /help 查看用法；/exit 退出。');

  // 实际 baseUrl 与 model（隐私告知必须用真实值，A4 修复）
  final actualBaseUrl = config.baseUrlOverride ?? pcfg.baseUrl;
  if (config.apiKey.isEmpty) {
    stdout.writeln('\n⚠ 未配置 MINGTIAN_API_KEY（环境变量或仓库根 .env）。诊断/对比/学习功能不可用；/概念 仍可用。');
  } else {
    // 数据出境告知（本地客户端、云端推理）——用真实 baseUrl，避免 override 时告知失真
    stdout.writeln('\n⚠ 隐私提示：本工具为本地客户端，但推理由「$provider」云端完成——'
        '你的对话内容会发送至 $actualBaseUrl（模型 $model）。涉及健康、关系、创伤等敏感信息请知悉。'
        '首次使用建议：不输入真实姓名/工作单位/住址等可识别身份的信息。');
  }
  // E3：未知 provider 警告
  if (!kProviders.containsKey(provider.toLowerCase())) {
    stderr.writeln('⚠ 未知 provider「$provider」，已回退到 glm。请检查 MINGTIAN_PROVIDER（可选：glm/deepseek/qwen）。');
  }
  final llm = config.apiKey.isEmpty
      ? null
      : LlmClient(
          baseUrl: actualBaseUrl,
          apiKey: config.apiKey,
          model: model,
          temperature: config.temperature,
        );

  // 会话状态
  final history = <Map<String, String>>[];
  var awaiting = false;
  var privacyAcknowledged = false;
  var crisisMode = false; // v0.1.2：危机状态持久化——进入后持续安全模式，明确安全才恢复

  // 危机退出信号：用户明确表示已安全/已求助时，退出危机模式
  const crisisExitSignals = ['我没事了', '我安全了', '我已安全', '我打过电话了', '我联系了', '我好了', '已报警', '已联系'];
  bool isCrisisExit(String text) =>
      crisisExitSignals.any(text.contains) || text.contains(RegExp(r'12338|12356|110|120'));

  // 隐私同意（云端推理告知）：任何 LLM 调用前必须通过。
  // A6：管道/重定向输入（EOF）时 readLineSync 返回 null——此时视为非交互环境，放行（不再永久取消）。
  Future<bool> ensureConsent() async {
    if (privacyAcknowledged) return true;
    stdout.writeln('本条消息将发送至云端（$provider）处理。输入 y 同意并继续，或其他键取消本次发送。');
    final ack = stdin.readLineSync(encoding: utf8)?.trim().toLowerCase();
    if (ack == null) {
      // 非交互输入（管道/重定向/EOF）——放行，避免自动化场景永久失效
      privacyAcknowledged = true;
      return true;
    }
    if (ack != 'y') {
      stdout.writeln('已取消发送。可修改措辞后重发，或输入 /exit 退出。');
      return false;
    }
    privacyAcknowledged = true;
    return true;
  }

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
      if (!await ensureConsent()) continue;
      final parts = input.substring(3).trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
      if (parts.length < 2) {
        stdout.writeln('用法: /对比 <声部A> <声部B>，例如 /对比 庄子 斯多葛');
        continue;
      }
      await _chat(llm, prompt, search,
          messages: [
            {'role': 'system', 'content': prompt.system(const [], extraRule: PromptBuilder.compareRule)},
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
      if (!await ensureConsent()) continue;
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

    // CLI 层确定性安全路由（v0.1.2 持久危机模式）：
    // - 本轮命中危险词 → 进入危机模式
    // - 已在危机模式 → 持续安全模板，直到用户明确表示已安全/已求助
    //   （防止"我不想活→模板；他现在在门外→哲学处方"的致命跳回）
    final dangerous = VectorSearch.isDangerous(userText);
    if (dangerous) {
      crisisMode = true;
      stdout.writeln(_kSafetyTemplate);
      continue;
    }
    if (crisisMode) {
      // 用户明确安全/已求助 → 退出危机模式，回普通流程
      if (isCrisisExit(userText)) {
        crisisMode = false;
        stdout.writeln('（已退出危机模式。如果你之后又感到不安全，随时告诉我。）\n');
        // 不 continue——继续本轮作为普通对话处理
      } else {
        // 仍在危机模式：持续安全响应，不恢复哲学处方
        stdout.writeln(_kSafetyTemplate);
        continue;
      }
    }

    final hits = search.search(userText, topK: topK, safeMode: true);
    if (llm == null) {
      stdout.writeln('（未配置 API key，仅展示检索到的参考语料）');
      for (final h in hits) {
        stdout.writeln('  - 【${h.entry.id}】"${h.entry.text}"（${h.entry.source}）');
      }
      continue;
    }

    // 首次发送前的隐私同意（云端推理告知，评审 P0-4）
    if (!await ensureConsent()) continue;

    final fragile = VectorSearch.kFragileKeywords.any(userText.contains);
    final medical = VectorSearch.isMedical(userText);
    final vague = VectorSearch.isVague(userText);
    final rules = <String>[
      if (awaiting) PromptBuilder.awaitingRule,
      if (fragile) PromptBuilder.fragileRule,
      if (medical) PromptBuilder.medicalRule,
      if (vague) PromptBuilder.vagueRule,
    ];
    final extraRule = rules.isEmpty ? null : rules.join('\n');
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': prompt.system(hits.map((h) => h.entry).toList(), extraRule: extraRule)},
      ...history,
      {'role': 'user', 'content': PromptBuilder.user(userText)},
    ];
    final reply = await _chat(llm, prompt, search, messages: messages, title: '明镜');
    if (reply == null) continue;
    if (medical) {
      stdout.writeln('\n【就医提醒】你提到正在服药/就医。精神科/心理药物的调整请务必与你的主治医生沟通，'
          '不要自行停药或改量；如果持续难受，请尽快复诊。以上内容只作陪伴，不替代治疗。');
    }

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
