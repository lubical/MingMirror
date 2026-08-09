import 'corpus_loader.dart';

/// 检索结果。
class SearchResult {
  final CorpusEntry entry;
  final double score;
  SearchResult(this.entry, this.score);
}

/// 检索器（MVP 零依赖实现）。
///
/// 设计说明：预计算 embedding 只覆盖 corpus 侧，query 的 embedding 在
/// Dart 端零依赖下无来源（方案缺陷修正）。因此默认采用：
///   1) 困境类型关键词分类 → 在命中分类的"适用场景"条目内检索
///      （保证"加班/辞职"类 query 能召回"工作倦怠与异化"类语料）
///   2) 字符 bigram Jaccard 相似度排序（gloss 权重 0.7 / 原文 0.3）
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
  /// 注意：关键词匹配是兜底层，必然有漏网——未命中时仍由角色卡安全条款
  /// （v0.8 人际安全评估前置 + 危机转介）兜底，双层防御。
  static const List<String> kDangerWords = [
    // 自伤/自杀（含隐含表达）
    '自杀', '自伤', '轻生', '不想活', '活不下去', '想消失', '不如结束', '了结',
    '伤害自己', '割腕', '跳楼', '吃安眠药', '一了百了', '撑不住', '撑不下去了', '受不了了',
    // 家暴/人身侵害（含隐含表达）
    '家暴', '殴打', '扇我', '打我', '他掐我', '掐脖子', '砸东西威胁', '威胁',
    '控制生活费', '不让我出门', '关着我', '锁起来', '跟踪', '骚扰', '霸凌',
    '勒索', '侵害', '强奸', '猥亵',
    // 其他高危信号
    '幻觉', '幻听', '被害妄想',
  ];

  /// 判定文本是否命中危险信号（CLI 安全路由入口）。
  static bool isDangerous(String text) => kDangerWords.any(text.contains);

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
    final dangerous = kDangerWords.any(query.contains);

    final candidates = <CorpusEntry>[];
    for (final e in corpus.entries) {
      if (safeMode &&
          dangerous &&
          e.forbids.any((f) => kDangerWords.any(f.contains))) {
        continue; // 安全过滤：该条目的禁用场景命中危险词，不返回
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
