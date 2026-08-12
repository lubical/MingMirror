import 'dart:convert';
import 'dart:io';

/// 一条语料（corpus/*.json 的条目）。
class CorpusEntry {
  final String id;
  final String text; // 原文
  final String source; // 出处
  final String gloss; // 白话解析
  final List<String> applies; // 适用场景
  final List<String> forbids; // 禁用场景
  final String voice; // 关联声部

  CorpusEntry({
    required this.id,
    required this.text,
    required this.source,
    required this.gloss,
    required this.applies,
    required this.forbids,
    required this.voice,
  });

  factory CorpusEntry.fromJson(Map<String, dynamic> j) => CorpusEntry(
        id: j['id'] as String? ?? '',
        text: j['原文'] as String? ?? '',
        source: j['出处'] as String? ?? '',
        gloss: j['白话解析'] as String? ?? '',
        applies: (j['适用场景'] as List?)?.cast<String>() ?? const [],
        forbids: (j['禁用场景'] as List?)?.cast<String>() ?? const [],
        voice: j['关联声部'] as String? ?? '',
      );
}

/// 语料库：合并 corpus/*.json 的全部条目。
class Corpus {
  final List<CorpusEntry> entries;

  Corpus(this.entries);

  static Corpus load(String dir) {
    final list = <CorpusEntry>[];
    final d = Directory(dir);
    if (!d.existsSync()) return Corpus(list);
    for (final f in d
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))) {
      try {
        final arr = jsonDecode(f.readAsStringSync()) as List;
        for (final e in arr) {
          list.add(CorpusEntry.fromJson(e as Map<String, dynamic>));
        }
      } catch (e) {
        // A3 修复：FormatException 只覆盖 JSON 语法错；类型错（非数组、字段类型不符）
        // 抛 TypeError/_TypeError，原代码不捕获会致启动崩溃。改为全捕获，跳过该文件。
        stderr.writeln('警告: 忽略无法解析的语料文件 ${f.path}（$e）');
      }
    }
    return Corpus(list);
  }

  CorpusEntry? byId(String id) {
    for (final e in entries) {
      if (e.id == id) return e;
    }
    return null;
  }
}

/// 概念条目（concepts/*.json）。
class ConceptEntry {
  final String id;
  final String name;
  final String voice;
  final String definition;
  final List<String> relatedConcepts;
  final List<String> relatedCorpus;

  ConceptEntry({
    required this.id,
    required this.name,
    required this.voice,
    required this.definition,
    required this.relatedConcepts,
    required this.relatedCorpus,
  });

  factory ConceptEntry.fromJson(Map<String, dynamic> j) => ConceptEntry(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        voice: j['声部'] as String? ?? '',
        definition: j['定义'] as String? ?? '',
        relatedConcepts: (j['关联概念'] as List?)?.cast<String>() ?? const [],
        relatedCorpus: (j['关联语料'] as List?)?.cast<String>() ?? const [],
      );
}

/// 概念库：合并 concepts/*.json。
class Concepts {
  final List<ConceptEntry> entries;

  Concepts(this.entries);

  static Concepts load(String dir) {
    final list = <ConceptEntry>[];
    final d = Directory(dir);
    if (!d.existsSync()) return Concepts(list);
    for (final f in d
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))) {
      try {
        final arr = jsonDecode(f.readAsStringSync()) as List;
        for (final e in arr) {
          list.add(ConceptEntry.fromJson(e as Map<String, dynamic>));
        }
      } catch (e) {
        stderr.writeln('警告: 忽略无法解析的概念文件 ${f.path}（$e）');
      }
    }
    return Concepts(list);
  }

  /// 按名称模糊匹配（包含关系）。
  List<ConceptEntry> search(String keyword) => entries
      .where((e) => e.name.contains(keyword) || keyword.contains(e.name))
      .toList();
}
