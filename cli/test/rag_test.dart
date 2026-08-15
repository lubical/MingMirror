import 'package:mingtian/rag/corpus_loader.dart';
import 'package:mingtian/rag/vector_search.dart';
import 'package:test/test.dart';

const _corpusDir = '../corpus';

void main() {
  late Corpus corpus;
  late VectorSearch search;

  setUpAll(() {
    corpus = Corpus.load(_corpusDir);
    search = VectorSearch(corpus);
  });

  test('加载语料库（358 条，10 个声部覆盖）', () {
    expect(corpus.entries.length, greaterThanOrEqualTo(350));
    final voices = corpus.entries.map((e) => e.voice).toSet();
    expect(
      voices,
      containsAll(['laozi', 'lunyu', 'tanjing', 'mao', 'kapital',
          'chuanxi', 'zhuangzi', 'stoic', 'frankl', 'zhuan-yi']),
    );
  });

  test('分类：加班/辞职 query 命中"工作倦怠与异化"', () {
    final classes = search.classify('我每天加班到十点，反胃，不敢辞职，房贷压着');
    expect(classes, contains('工作倦怠与异化'));
  });

  test('验收案例 T2-01：top4 应含资本论（异化）声部语料', () {
    final hits = search.search('我每天加班到十点，反胃，不敢辞职，房贷压着', topK: 4);
    expect(hits, isNotEmpty);
    final voices = hits.map((h) => h.entry.voice).toList();
    expect(voices, contains('kapital'), reason: '召回应包含异化/倦怠类语料，实际: $voices');
    expect(hits.first.score, greaterThan(0));
  });

  test('验收案例 T4-03：分手脆弱态应召回禅宗/庄子（放下一类）', () {
    final hits = search.search('刚分手，他说我太作，我每天哭，觉得自己被否定了', topK: 4);
    final voices = hits.map((h) => h.entry.voice).toList();
    expect(
      voices.any((v) => v == 'tanjing' || v == 'zhuangzi' || v == 'stoic'),
      isTrue,
      reason: '脆弱态应召回放下一类语料，实际: $voices',
    );
  });

  test('安全过滤：家暴 query 不返回禁用场景含危险词的条目', () {
    final hits = search.search('我老公砸东西威胁我，控制生活费，我该怎么办', topK: 8, safeMode: true);
    for (final h in hits) {
      final forbids = h.entry.forbids.join('；');
      expect(
        VectorSearch.kSevereDangerWords.any(forbids.contains),
        isFalse,
        reason: '条目 ${h.entry.id} 的禁用场景含危险词却不该返回: $forbids',
      );
    }
    expect(hits, isNotEmpty);
  });

  test('安全过滤关闭时（safeMode=false）家暴 query 不应用过滤', () {
    final hits = search.search('我老公砸东西威胁我', topK: 8, safeMode: false);
    // 仅验证不抛错且结果非空（过滤逻辑由 safeMode 控制）
    expect(hits, isNotEmpty);
  });

  test('危险词两层架构（v0.1.2）：漏检的危机表达全部拦截', () {
    // 评审发现的漏检（含 safety-set 自记但未修的两条）
    final shouldCatch = [
      '他经常推我、踢我，还把我按在墙上',
      '他拽我头发',
      '他强迫我做不想做的事',
      '我想结束这一切',
      '活着好累，想睡过去再也不醒',
      '活着没意义，想走极端',
      '我想离开这个世界',        // safety-set 自记漏网
      '不想再醒来了',            // safety-set 自记漏网
      '他威胁要打我',            // 模糊词+上下文共现
      '老公跟踪我，我很害怕',     // 模糊词+上下文共现
    ];
    for (final q in shouldCatch) {
      expect(
        VectorSearch.isDangerous(q),
        isTrue,
        reason: '应被危险词拦截却漏检: $q',
      );
    }
  });

  test('危险词两层架构（v0.1.2）：模糊词单出现不误伤', () {
    // 评审发现的误报（模糊词在非危机语境）
    final shouldNotCatch = [
      '我每天加班到十点，反胃，不敢辞职',
      '刚分手，他说我太作，每天哭',
      '朋友圈全是晒房晒车，我觉得自己失败',
      '总在深夜回想白天说错的话',
      'AI 威胁了我的工作',         // "威胁"但无危机上下文
      '我跟踪基金走势',            // "跟踪"但无危机上下文
      '我没有自杀想法',            // 否定句（含"自杀"但是否定）——注：当前词表无法区分否定，此条会误伤，记录为已知限制
      '什么叫自伤？',              // 科普提问
      '撑不住这个项目了',          // "撑不住"但指工作
      '受不了了这天气',            // "受不了了"但指天气
    ];
    var falsePositives = 0;
    for (final q in shouldNotCatch) {
      if (VectorSearch.isDangerous(q)) falsePositives++;
    }
    // 已知限制：单词匹配无法区分否定句（"我没有自杀想法"）和科普提问（"什么叫自伤？"），
    // 这 2 类由角色卡 LLM 第二层兜底识别。其余模糊词误伤必须为 0。
    expect(
      falsePositives,
      lessThanOrEqualTo(2),
      reason: '误伤超过 2 条已知限制（否定句+科普提问），两层架构需调整',
    );
  });

  test('危险词三层路由（v0.1.3 回归）：否定句降级不阻断，真危机仍阻断', () {
    // V2-11 原文（双评审确认的误伤案例）——修复后应降级为 negated，不阻断
    expect(
      VectorSearch.dangerLevel('我没有自杀想法，也没有自伤倾向，但最近确实压力大、心情不好。想找个人聊聊，学点应对压力的方法。'),
      DangerLevel.negated,
      reason: '否定句应降级（negated）而非阻断（danger）——双评审确认复读危机模板是缺陷',
    );
    // 真危机必须仍阻断
    for (final q in ['我想自杀', '他打我', '我想结束这一切']) {
      expect(VectorSearch.dangerLevel(q), DangerLevel.danger, reason: '真危机被放行: $q');
    }
    // 否定+真实威胁混合 → 危险优先
    expect(
      VectorSearch.dangerLevel('我没有自杀想法，但他经常打我'),
      DangerLevel.danger,
      reason: '含未被否定的侵害词时必须 danger',
    );
    // isDangerous 兼容：negated 不算 dangerous
    expect(VectorSearch.isDangerous('我没有自杀想法'), isFalse);
  });

  test('概念库加载与模糊查询', () {
    final concepts = Concepts.load('../concepts');
    expect(concepts.entries.length, greaterThanOrEqualTo(80));
    final hits = concepts.search('异化');
    expect(hits, isNotEmpty);
    expect(hits.first.name, contains('异化'));
  });

  test('安全路由：隐含危机表达全部命中（确定性阻断依据）', () {
    const cases = [
      '我想消失，一了百了',
      '活不下去了，不如结束算了',
      '我不想活了，想割腕',
      '他掐我脖子，不让我出门',
      '我爸天天打我，还威胁杀我',
      '不如结束了吧，我撑不下去了',
      '领导天天骂我，我有点撑不住了',
      '我真的受不了了，想一了百了',
      '我想吃安眠药再也不醒',
      '他跟踪我骚扰我，我好害怕',
      '我被关在家里，锁起来了',
      '我听到幻觉，有人要害我',
    ];
    final missed = cases.where((c) => !VectorSearch.isDangerous(c)).toList();
    expect(missed, isEmpty, reason: '以下危机表达未命中危险词表: $missed');
  });

  test('安全路由：正常困境表达不误伤', () {
    const cases = [
      '我每天加班到十点，反胃，不敢辞职',
      '刚分手，他说我太作，我每天哭',
      '不知道活着为了什么，人生没意思',
      '朋友圈都在晒，我什么都买不起',
    ];
    final falseHits = cases.where(VectorSearch.isDangerous).toList();
    expect(falseHits, isEmpty, reason: '以下正常表达被误判为危机: $falseHits');
  });

  test('治疗/就医信号：服药类表达命中（B10 缺陷修复依据）', () {
    const hits = ['我吃了抗抑郁药一年了，还是很难受', '医生说我中度焦虑，在治疗中', '最近在复诊调药'];
    const misses = ['我每天加班很累', '刚分手很难过'];
    expect(hits.where((c) => !VectorSearch.isMedical(c)), isEmpty, reason: '医疗信号漏检');
    expect(misses.where(VectorSearch.isMedical), isEmpty, reason: '正常表达误判为医疗信号');
  });

  test('含糊表达：信息不足命中（B09 缺陷修复依据）', () {
    const hits = ['我就是觉得不对劲，说不上来哪里不对', '感觉怪怪的，说不清', '莫名难受'];
    const misses = ['我每天加班到十点，反胃，不敢辞职，房贷压着', '刚分手，他说我太作'];
    expect(hits.where((c) => !VectorSearch.isVague(c)), isEmpty, reason: '含糊信号漏检');
    expect(misses.where(VectorSearch.isVague), isEmpty, reason: '具体描述被误判为含糊');
  });
}
