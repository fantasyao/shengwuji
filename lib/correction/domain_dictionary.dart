import 'dart:convert';

/// 领域词条：一个专有名词（或普通词）的正/负上下文词表。
/// related = 出现在窗口里时给该词条加分；conflict = 减分（保护词，方案§15）
class DomainEntry {
  final String word;
  final String type;
  final List<String> related;
  final List<String> conflict;

  /// 折叠（小写）后的词表，评分时上下文词一律以折叠形查表
  final Set<String> _relatedFolded;
  final Set<String> _conflictFolded;

  DomainEntry({
    required this.word,
    required this.type,
    required this.related,
    required this.conflict,
  }) : _relatedFolded = {
         for (final w in related) w.toLowerCase(),
       },
       _conflictFolded = {
         for (final w in conflict) w.toLowerCase(),
       };

  bool isRelated(String foldedContextWord) =>
      _relatedFolded.contains(foldedContextWord);

  bool isConflict(String foldedContextWord) =>
      _conflictFolded.contains(foldedContextWord);
}

/// 领域词典：word → related/conflict 上下文词表（方案§5）。
/// 同时充当"上下文词的封闭词表"——共现统计里的上下文词也出自这里
/// （外加学习累积的 extraVocabulary），所以提取上下文不需要中文分词，
/// 在窗口内做已知词子串扫描即可，信息无损且零依赖。
class DomainDictionary {
  final Map<String, DomainEntry> _entries; // key 折叠

  /// 全部 related ∪ conflict 词的折叠形（上下文词提取的扫描词表）
  late final Set<String> vocabulary = {
    for (final e in _entries.values) ...e._relatedFolded,
    for (final e in _entries.values) ...e._conflictFolded,
  };

  DomainDictionary._(this._entries);

  factory DomainDictionary.fromJsonString(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('domain_words.json 顶层必须是对象');
    }
    final entries = <String, DomainEntry>{};
    decoded.forEach((word, raw) {
      if (word.trim().isEmpty || raw is! Map<String, dynamic>) return;
      List<String> readList(String key) => [
        for (final w in (raw[key] as List? ?? const []))
          if (w is String && w.trim().isNotEmpty) w.trim(),
      ];
      final entry = DomainEntry(
        word: word.trim(),
        type: (raw['type'] as String?) ?? '',
        related: readList('related'),
        conflict: readList('conflict'),
      );
      entries[word.trim().toLowerCase()] = entry;
    });
    return DomainDictionary._(entries);
  }

  static String _fold(String w) => w.toLowerCase();

  /// 按词条词查（大小写不敏感）
  DomainEntry? lookup(String word) => _entries[_fold(word)];
}
