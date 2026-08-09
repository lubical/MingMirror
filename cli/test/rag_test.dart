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
        VectorSearch.kDangerWords.any(forbids.contains),
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

  test('概念库加载与模糊查询', () {
    final concepts = Concepts.load('../concepts');
    expect(concepts.entries.length, greaterThanOrEqualTo(80));
    final hits = concepts.search('异化');
    expect(hits, isNotEmpty);
    expect(hits.first.name, contains('异化'));
  });
}
