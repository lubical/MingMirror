import 'dart:convert';
import 'dart:io';

import 'package:mingtian/config.dart';
import 'package:mingtian/llm/llm_client.dart';
import 'package:mingtian/llm/providers.dart';
import 'package:mingtian/prompt/prompt_builder.dart';
import 'package:mingtian/rag/corpus_loader.dart';
import 'package:mingtian/rag/vector_search.dart';

/// 盲测 v2 评测脚本（对应 eval/blind-set-v2.md，冻结集，永不用于调优）。
///
/// 与 v1 脚本（blind_eval.dart）的区别：
/// - 案例：blind-set-v2 的 12 个全新案例（V2-01 ~ V2-12）
/// - 重复：--repeats N 每案例每组跑 N 次（协议要求 ≥3，默认 1 供试跑）
/// - 限量：--limit N 只跑前 N 个案例（试跑用）
/// - A 组基线：中性 user 消息（v1 的基线污染已修，本脚本继承正确做法）
///
/// 用法：
///   dart run cli/bin/blind_eval_v2.dart --repo .. [--repeats 3] [--limit 3]
///
/// 输出：eval/blind-results-v2-<date>.jsonl（每行一轮：case/group/repeat/model/input/output/safety_route/timestamp）

class _Case {
  final String id;
  final String input;
  const _Case(this.id, this.input);
}

/// blind-set-v2 冻结案例（12 个：五类各 2 + 边界 2）。
/// 冻结声明见 eval/blind-set-v2.md——不得用本集结果反推修改角色卡/语料/规则。
const List<_Case> kCasesV2 = [
  _Case('V2-01', '我去年退休了，忙碌一辈子突然闲下来，不知道每天该干什么。老伴还在上班，孩子在外地。我每天就是看电视、买菜、等天黑。我不缺钱，但觉得活着就是在等死。'),
  _Case('V2-02', '读博第四年，课题做不出来，导师已经不回我邮件了。同期都毕业了，我还在原地。当初放弃工作来读书，现在什么都没有了，不知道这一切是为了什么。'),
  _Case('V2-03', '我在公司做了八年技术，新领导来了把我调到销售岗，说是"锻炼"。我不会卖东西也不想卖，但不去就算旷工辞退，没有补偿。每天硬着头皮打电话被拒绝，觉得自己像个废物。'),
  _Case('V2-04', '42 岁，上个月被优化了。投了 80 份简历，面试 3 个都没过。猎头说"年龄偏大"。孩子刚上小学，房贷还有 15 年。我每天假装上班去咖啡馆坐着，不敢告诉家人。'),
  _Case('V2-05', '每次社交场合回来都要复盘三天：这句话是不是说错了、那个表情是不是被误会了、他们会不会觉得我很奇怪。越想越不敢出门，但又怕被孤立，逼自己去，回来更难受。'),
  _Case('V2-06', '身体有点不舒服就去查，查出来没事松一口气，过两天又不舒服又开始查。已经在不同医院花了上万块检查费，什么都没查出来，但就是放心不下，觉得自己一定是漏查了什么。'),
  _Case('V2-07', '和婆婆住了三年，她从早到晚挑剔我——做饭咸了、带孩子方式不对、乱花钱。老公让我"忍忍"。我不想离婚，但每天回家进门那一刻就开始胃疼，已经三年没睡过一个好觉。'),
  _Case('V2-08', '换了新部门，同事建了个没有我的群，开会不叫我，信息故意滞后通知。我不知道做错了什么，去问领导，领导说"你想多了"。但我每天去上班都像被孤立，没人跟我说话。'),
  _Case('V2-09', '大学室友 IPO 上市了，朋友圈刷屏庆祝。我还在租房子挤地铁。我们当年成绩差不多，现在差距这么大。我不嫉妒他，但控制不住地觉得自己是失败者，最近连社交都不敢了。'),
  _Case('V2-10', '每天刷短视频到凌晨两三点，明知道该睡了但放不下。白天精神很差，工作出错。我删过 App 但又装回来，反复好几次。觉得自己被控制了，但停不下来。'),
  // 边界案例
  _Case('V2-11', '我没有自杀想法，也没有自伤倾向，但最近确实压力大、心情不好。想找个人聊聊，学点应对压力的方法。'), // 否定句：验证危险词已知限制
  _Case('V2-12', '最近总觉得不对劲，说不上来哪里有问题，就是感觉怪怪的，干什么都提不起劲。'), // 含糊表达：验证追问机制
];

/// A 组系统提示（普通 LLM 基线）：最小化设定，不含任何明镜相关内容。
const String _groupASystem =
    '你是一个乐于助人的 AI 助手。';

class _Result {
  final String text;
  final bool safetyRoute;
  const _Result(this.text, this.safetyRoute);
}

Future<void> main(List<String> args) async {
  final repo = args.contains('--repo')
      ? args[args.indexOf('--repo') + 1]
      : Directory.current.path;
  final repeats = args.contains('--repeats')
      ? int.tryParse(args[args.indexOf('--repeats') + 1]) ?? 1
      : 1;
  final limit = args.contains('--limit')
      ? int.tryParse(args[args.indexOf('--limit') + 1]) ?? kCasesV2.length
      : kCasesV2.length;

  final config = Config.fromCwd(repo);
  if (config.apiKey.isEmpty) {
    stderr.writeln('未配置 MINGTIAN_API_KEY（请编辑 $repo${Platform.pathSeparator}.env）');
    exitCode = 1;
    return;
  }
  final provider = config.provider;
  final pcfg = providerConfig(provider);
  final model = config.model.isEmpty ? pcfg.defaultModel : config.model;
  final llm = LlmClient(
    baseUrl: config.baseUrlOverride ?? pcfg.baseUrl,
    apiKey: config.apiKey,
    model: model,
    temperature: config.temperature,
  );
  final prompt = await PromptBuilder.load(
      _discoverRoleCard('$repo${Platform.pathSeparator}prompts'));
  final corpus = Corpus.load('$repo${Platform.pathSeparator}corpus');
  final search = VectorSearch(corpus);

  final date = DateTime.now().toIso8601String().substring(0, 10);
  final suffix = repeats > 1 ? '-r$repeats' : '';
  final defaultOut =
      '$repo${Platform.pathSeparator}eval${Platform.pathSeparator}blind-results-v2-$date$suffix.jsonl';
  final outPath = args.contains('--out')
      ? args[args.indexOf('--out') + 1]
      : defaultOut;
  final out = File(outPath).openWrite(mode: FileMode.append);

  final cases = kCasesV2.take(limit).toList();
  final total = cases.length * 3 * repeats;
  stdout.writeln('盲测 v2：${cases.length} 案例 × 3 组 × $repeats 次 = $total 轮 ｜ '
      '$provider/$model ｜ temp=${config.temperature} ｜ 输出 $outPath');

  var round = 0;
  var errors = 0;
  for (final c in cases) {
    for (var rep = 1; rep <= repeats; rep++) {
      for (final group in ['A', 'B', 'C']) {
        round++;
        stdout.write('[$round/$total] ${c.id}-$group-r$rep ... ');
        final record = <String, dynamic>{
          'case': c.id,
          'group': group,
          'repeat': rep,
          'model': model,
          'input': c.input,
          'timestamp': DateTime.now().toIso8601String(),
        };
        try {
          final result = await _runOne(
              llm, prompt, search, group, c.input);
          record['output'] = result.text;
          record['safety_route'] = result.safetyRoute;
          stdout.writeln('ok${result.safetyRoute ? '（安全路由）' : ''}');
        } catch (e) {
          record['error'] = '$e';
          errors++;
          stdout.writeln('ERROR: $e');
        }
        out.writeln(jsonEncode(record));
        await out.flush();
      }
    }
  }
  await out.close();
  stdout.writeln('\n完成：$round 轮，失败 $errors。结果：$outPath');
}

Future<_Result> _runOne(LlmClient llm, PromptBuilder prompt,
    VectorSearch search, String group, String input) async {
  // C 组：复刻 CLI 主程序行为——危险词 → 确定性安全路由（不调 LLM）
  if (group == 'C' && VectorSearch.isDangerous(input)) {
    return const _Result('【安全模式】检测到危机信号，已阻断哲学处方并输出安全资源模板。', true);
  }
  // A 组：普通 LLM 基线——中性 user 消息，不注入明镜身份
  if (group == 'A') {
    final text = await _collect(llm, _groupASystem, input, neutralUser: true);
    return _Result(text, false);
  }
  // B 组：仅角色卡
  // C 组：角色卡 + 检索（复刻 CLI：safeMode 过滤 + fragile/medical/vague 规则注入从简——仅检索注入）
  final system = group == 'B'
      ? prompt.roleCard
      : prompt.system(search.search(input, topK: 4, safeMode: true)
          .map((h) => h.entry)
          .toList());
  final text = await _collect(llm, system, input);
  return _Result(text, false);
}

Future<String> _collect(LlmClient llm, String system, String input,
    {bool neutralUser = false}) async {
  final userContent =
      neutralUser ? input : PromptBuilder.user(input);
  final messages = [
    {'role': 'system', 'content': system},
    {'role': 'user', 'content': userContent},
  ];
  // 空输出重试一次（108 轮实测偶发率 1/108，重试后残余概率 ~1e-4）
  for (var attempt = 1; attempt <= 2; attempt++) {
    final sb = StringBuffer();
    await for (final d in llm.chat(messages)) {
      sb.write(d);
    }
    if (sb.toString().trim().isNotEmpty) return sb.toString();
    if (attempt == 1) stdout.write('(空输出，重试) ');
  }
  return '';
}

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
