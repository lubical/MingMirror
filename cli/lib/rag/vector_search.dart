import 'corpus_loader.dart';

/// 检索结果。
class SearchResult {
  final CorpusEntry entry;
  final double score;
  SearchResult(this.entry, this.score);
}

/// 危险等级三态（v0.1.3）。
/// none：无信号；negated：危险词全被否定（"我没有自杀想法"）——降级不阻断；
/// danger：真危机——阻断哲学处方。
enum DangerLevel { none, negated, danger }

/// 检索器（MVP 零依赖实现）。
///
/// 设计说明：预计算 embedding 只覆盖 corpus 侧，query 的 embedding 在
/// Dart 端零依赖下无来源（方案缺陷修正）。因此默认采用：
///   1) 困境类型关键词分类 → 在命中分类的"适用场景"条目内检索
///      （保证"加班/辞职"类 query 能召回"工作倦怠与异化"类语料）
///   2) 字符 bigram Jaccard 相似度排序（gloss 权重 0.5 / 原文 0.2，剩余 0.3 预算给分类命中加成 + 声部矩阵加成）
///   3) 安全过滤：query 含侵害/自伤类关键词时，剔除"禁用场景"含危险词的条目
/// 若未来接入 embedding API（与预计算向量同模型同维度），替换 search 实现即可。
class VectorSearch {
  final Corpus corpus;

  /// 困境类型 → 关键词（用于分类 query）。
  static const Map<String, List<String>> kDilemmaKeywords = {
    '工作倦怠与异化': ['加班', '工作', '上班', '辞职', '报表', '老板', '绩效', '卷', '裁员', '工具人', '职业', '反胃', '异化'],
    '焦虑与精神内耗': ['焦虑', '睡不着', '失眠', '反刍', '担心', '想太多', '紧张', '内耗', '心慌', '控制不住', '怕'],
    '意义与方向危机': ['意义', '活着', '方向', '迷茫', '没意思', '价值', '人生', '不知道干什么', '空虚', '无意义'],
    '人际与情感困扰': ['朋友', '分手', '男友', '女友', '关系', '背叛', '讨好', '孤立', '吵架', '老公', '家人', '拒绝', '被否定'],
    '欲望与物质匮乏感': ['买', '钱', '朋友圈', '攀比', '欲望', '月光', '穷', '想要', '消费', '限量'],
  };

  /// 困境类型 → 声部加成（编码自解药矩阵：首选 +0.3 / 辅选 +0.2 / 回避 -0.3）。
  static const Map<String, Map<String, double>> kDilemmaVoiceBonus = {
    '工作倦怠与异化': {'kapital': 0.3, 'mao': 0.2, 'chuanxi': 0.2},
    '焦虑与精神内耗': {'laozi': 0.3, 'stoic': 0.3, 'tanjing': 0.2, 'zhuangzi': 0.2, 'mao': -0.3},
    '意义与方向危机': {'tanjing': 0.3, 'frankl': 0.3, 'lunyu': 0.2, 'mao': 0.2, 'kapital': -0.3},
    '人际与情感困扰': {'lunyu': 0.3, 'chuanxi': 0.3, 'tanjing': 0.2, 'zhuangzi': 0.2, 'stoic': 0.2, 'mao': -0.3},
    '欲望与物质匮乏感': {'laozi': 0.3, 'stoic': 0.2, 'kapital': 0.2, 'zhuangzi': 0.2},
  };

  /// 脆弱态关键词：命中时优先放下一类声部（禅宗/庄子/斯多葛/弗兰克尔），降权 mao。
  static const List<String> kFragileKeywords = [
    '哭', '难过', '崩溃', '走不出来', '伤心', '刚分手', '被否定', '撑不住', '心灰',
  ];

  /// 侵害/自伤类危险词：命中后走确定性安全路由（CLI 层阻断哲学处方）。
  /// 危险词两层架构（v0.1.2 评审修复）：
  /// 原单词表同时造成漏报（"我想离开这个世界"）和误报（"AI 威胁了我的工作""我跟踪基金"）。
  /// 拆为两层：确定词单命中即拦截；模糊词需与危机上下文词共现才拦截。
  ///
  /// 仍是兜底层——未命中时由角色卡安全条款（v0.8 人际安全评估前置 + 危机转介）兜底，双层防御。

  /// 第一层：确定危险词——单命中即拦截。
  /// 这些词几乎不会在非危机语境出现（自伤动词、强侵害动词、明确意图短语）。
  static const List<String> kSevereDangerWords = [
    // 自伤/自杀：动词与明确意图
    '自杀', '自伤', '轻生', '不想活', '活不下去', '想消失', '不如结束', '结束这一切',
    '了结', '一了百了', '伤害自己', '割腕', '跳楼', '吃安眠药',
    '活着好累', '活着没意义', '活着没意思', '想走极端', '不想醒来', '不想再醒来',
    '离开这个世界', '从桥上', '跳下去', '了此一生', '了却此生',
    // 家暴/人身侵害：暴力动词（带"我"或"他打"等主体，几乎不会误伤）
    '家暴', '殴打', '扇我', '打我', '推我', '踢我', '踹我', '拽我', '扯我',
    '按在墙上', '掐我', '掐脖子', '他掐我', '揍我', '动手打',
    '强迫我', '控制生活费', '经济控制', '不让我出门', '关着我', '锁起来', '限制自由',
    '强奸', '猥亵', '性侵',
    // 其他高危信号
    '幻觉', '幻听', '被害妄想',
  ];

  /// 第二层：模糊危险词——需与"危机上下文词"共现才拦截。
  /// 这些词本身在非危机语境常见（"AI 威胁工作""跟踪基金""撑不住项目"），单独命中易误伤。
  static const List<String> kAmbiguousDangerWords = [
    '威胁', '恐吓', '跟踪', '骚扰', '霸凌', '勒索', '侵害',
    '撑不住', '撑不下去了', '受不了了', '解脱',
  ];

  /// 危机上下文词：与模糊词共现时，才认定危机。
  /// 含自伤指向、侵害主体、绝望情绪等。
  static const List<String> kCrisisContextWords = [
    // 自伤/死亡指向
    '不想活', '活着', '生命', '人生', '死', '了结', '消失', '崩溃', '绝望',
    // 侵害主体（暗示真实人身威胁）
    '他', '她', '老公', '老婆', '伴侣', '家人', '父亲', '母亲', '男友', '女友', '同事', '老板',
    // 暴力/侵害场景
    '打', '骂', '钱', '出门', '回家', '夜里', '害怕', '怕',
  ];

  /// 否定词：出现在确定危险词**前方近距离**时，该危险词被否定（如"没有自杀想法"）。
  /// 注意：不含单独的"不"——"不想活"本身是危机表达，不能用"不"放行。
  static const List<String> kNegationWords = [
    '没有', '从未', '并无', '并不是', '并非', '不曾', '无',
  ];

  /// 危险等级三态（v0.1.3 否定句降级）。
  /// [DangerLevel.none] 无信号；[DangerLevel.negated] 危险词全部被否定
  /// （如"我没有自杀想法"）——不阻断，正常对话但注入安全备注规则；
  /// [DangerLevel.danger] 真危机——阻断哲学处方，走安全模板。
  static DangerLevel dangerLevel(String text) {
    // 第一层：确定词。区分"被否定的"与"真实的"
    final severeHits = kSevereDangerWords.where(text.contains).toList();
    if (severeHits.isNotEmpty) {
      final anyReal = severeHits.any((w) => !_isNegated(text, w));
      if (anyReal) return DangerLevel.danger;
      // 所有确定词都被否定 → 继续查模糊层；若模糊层也无 → negated
      final hasAmbiguous = kAmbiguousDangerWords.any(text.contains);
      if (hasAmbiguous && kCrisisContextWords.any(text.contains)) {
        return DangerLevel.danger;
      }
      return DangerLevel.negated;
    }
    // 第二层：模糊词 + 上下文共现
    final hasAmbiguous = kAmbiguousDangerWords.any(text.contains);
    if (hasAmbiguous && kCrisisContextWords.any(text.contains)) {
      return DangerLevel.danger;
    }
    return DangerLevel.none;
  }

  /// 判断危险词 word 在 text 中的出现是否紧跟否定词（前方 ≤3 字符内）。
  static bool _isNegated(String text, String word) {
    var idx = text.indexOf(word);
    while (idx >= 0) {
      // 检查该出现位置前方 1-3 字符窗口是否含否定词
      final start = idx - 3 >= 0 ? idx - 3 : 0;
      final prefix = text.substring(start, idx);
      if (kNegationWords.any(prefix.contains)) return true;
      idx = text.indexOf(word, idx + 1);
    }
    return false;
  }

  /// 兼容旧接口：danger 级别才返回 true（negated 不算 dangerous）。
  static bool isDangerous(String text) => dangerLevel(text) == DangerLevel.danger;


  /// 治疗/就医信号词：命中后注入转介规则（medicalRule，强制先确认就医情况）。
  static const List<String> kMedicalKeywords = [
    '吃药', '服药', '药物', '用药', '药量', '医院', '医生', '诊断',
    '治疗', '住院', '复诊', '抗抑郁', '抗焦虑', '心理科', '精神科',
  ];

  /// 含糊表达信号词：命中后注入追问规则（vagueRule，信息不足不瞎开方）。
  static const List<String> kVagueKeywords = [
    '不对劲', '说不上来', '说不清', '不清楚', '不知道怎么回事',
    '感觉怪怪的', '有点怪', '就是难受', '有点不舒服', '莫名',
  ];

  /// 判定文本是否命中治疗/就医信号。
  static bool isMedical(String text) => kMedicalKeywords.any(text.contains);

  /// 判定文本是否为含糊表达（信息不足）。
  static bool isVague(String text) => kVagueKeywords.any(text.contains);

  // isDangerous 定义见上方两层架构（kSevereDangerWords + kAmbiguousDangerWords 共现）。

  VectorSearch(this.corpus);

  /// 判定 query 命中的困境类型集合。
  List<String> classify(String query) {
    final hits = <String>[];
    for (final entry in kDilemmaKeywords.entries) {
      if (entry.value.any(query.contains)) hits.add(entry.key);
    }
    return hits;
  }

  static Map<String, int> _bigrams(String s) {
    final t = s.replaceAll(RegExp(r'\s+'), '');
    final m = <String, int>{};
    if (t.length < 2) {
      m[t] = 1;
      return m;
    }
    for (var i = 0; i < t.length - 1; i++) {
      final g = t.substring(i, i + 2);
      m[g] = (m[g] ?? 0) + 1;
    }
    return m;
  }

  static double _jaccard(Map<String, int> a, Map<String, int> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    var inter = 0;
    for (final k in a.keys) {
      if (b.containsKey(k)) inter += (a[k]! < b[k]! ? a[k]! : b[k]!);
    }
    final union = a.values.fold<int>(0, (s, v) => s + v) +
        b.values.fold<int>(0, (s, v) => s + v) -
        inter;
    if (union <= 0) return 0;
    return inter / union;
  }

  bool get queryIsDangerous => false; // 由外部按 query 判定，见 search 参数

  /// 检索 top-K。safeMode=true 时对危险 query 应用禁用场景过滤。
  List<SearchResult> search(String query, {int topK = 4, bool safeMode = true}) {
    final qBigrams = _bigrams(query);
    final classes = classify(query);
    final dangerous = isDangerous(query);

    final candidates = <CorpusEntry>[];
    for (final e in corpus.entries) {
      // 安全过滤：query 危险时，剔除"禁用场景含确定危险词"的条目（用确定词表，避免误过滤）
      if (safeMode &&
          dangerous &&
          e.forbids.any((f) => kSevereDangerWords.any(f.contains))) {
        continue;
      }
      if (classes.isNotEmpty && !classes.any(e.applies.contains)) {
        continue; // 分类命中时，只保留适用该困境类型的条目
      }
      candidates.add(e);
    }

    final scored = <(CorpusEntry, double)>[];
    final fragile = kFragileKeywords.any(query.contains);
    for (final e in candidates) {
      final glossScore = _jaccard(qBigrams, _bigrams(e.gloss));
      final textScore = _jaccard(qBigrams, _bigrams(e.text));
      // 分类命中加成：适用场景含命中困境类型的条目获得基础分
      final classBonus =
          classes.isNotEmpty && e.applies.any(classes.contains) ? 0.4 : 0.0;
      // 声部加成（解药矩阵首选/辅选/回避）+ 脆弱态修正
      var voiceBonus = 0.0;
      for (final c in classes) {
        final b = kDilemmaVoiceBonus[c]?[e.voice];
        if (b != null && b > voiceBonus) voiceBonus = b;
      }
      if (fragile) {
        if (e.voice == 'mao' || e.voice == 'lunyu') voiceBonus -= 0.3;
        if (const {'tanjing', 'zhuangzi', 'stoic', 'frankl'}.contains(e.voice)) {
          voiceBonus += 0.3;
        }
      }
      final score = glossScore * 0.5 + textScore * 0.2 + classBonus + voiceBonus;
      if (score > 0) scored.add((e, score));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return scored
        .take(topK)
        .map((s) => SearchResult(s.$1, s.$2))
        .toList();
  }
}
