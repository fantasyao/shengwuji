import 'dart:convert';

/// 同音词命中：文本中某处出现了同音组内的词，整组候选进入上下文评分
class HomophoneMatch {
  /// 全组候选词（含命中词自身，原形大小写）
  final List<String> candidates;

  /// 命中的原文片段
  final String matchedWord;

  /// 在原文中的区间 [start, end)
  final int start;
  final int end;

  const HomophoneMatch({
    required this.candidates,
    required this.matchedWord,
    required this.start,
    required this.end,
  });

  @override
  String toString() => '$matchedWord@$start';
}

/// 同音词词典：只提供候选，不决定答案（方案§4/§21）。
///
/// JSON 形如 `{"groups": [["质朴","智谱"], ...]}`——同一组内的词互为候选。
/// 文本任一处出现组内任一词，该位置及其全组候选交给 ContextScorer 评分，
/// 词典本身不做任何替换决定。
class HomophoneDictionary {
  final List<List<String>> groups;

  /// 折叠（小写）词 → 所属组（组的实例共享，isSameGroup 用 identical 判定）
  final Map<String, List<String>> _wordToGroup;

  /// 全部折叠后的词（findMatches 扫描用）
  final Set<String> _allWords;

  HomophoneDictionary._(this.groups)
    : _wordToGroup = {
        for (final g in groups)
          for (final w in g) w.toLowerCase(): g,
      },
      _allWords = {
        for (final g in groups)
          for (final w in g) w.toLowerCase(),
      };

  factory HomophoneDictionary.fromJsonString(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('homophones.json 顶层必须是对象');
    }
    final rawGroups = decoded['groups'];
    if (rawGroups is! List) {
      throw const FormatException('homophones.json 缺少 groups 数组');
    }
    final groups = <List<String>>[
      for (final g in rawGroups)
        if (g is List)
          [
            for (final w in g)
              if (w is String && w.trim().isNotEmpty) w.trim(),
          ],
    ]
        .where((g) => g.length >= 2)
        .toList(); // 单词组没有歧义，跳过（省扫描）
    return HomophoneDictionary._(groups);
  }

  static String _fold(String w) => w.toLowerCase();

  /// 词是否收录在任一同音组
  bool containsWord(String word) => _wordToGroup.containsKey(_fold(word));

  /// 两个词是否属于同一同音组（用于把这类纠错对从盲替换表分流出去）。
  /// 任一词未收录、或分属不同组 → false
  bool isSameGroup(String a, String b) {
    if (_fold(a) == _fold(b)) return false;
    final ga = _wordToGroup[_fold(a)];
    final gb = _wordToGroup[_fold(b)];
    return ga != null && identical(ga, gb);
  }

  /// 找出文本中所有同音组命中：按 start 升序排列，重叠命中只保留最先
  /// 出现的一个（同组词互不为子串，正常语料不会重叠，此为防御）。
  /// 匹配对 ASCII 大小写不敏感（组里若收录英文词也能命中）
  List<HomophoneMatch> findMatches(String text) {
    if (text.isEmpty || _allWords.isEmpty) return const [];
    final lower = text.toLowerCase();
    final raw = <HomophoneMatch>[];
    for (final needle in _allWords) {
      int idx = lower.indexOf(needle);
      while (idx >= 0) {
        raw.add(
          HomophoneMatch(
            candidates: _wordToGroup[needle]!,
            matchedWord: text.substring(idx, idx + needle.length),
            start: idx,
            end: idx + needle.length,
          ),
        );
        idx = lower.indexOf(needle, idx + needle.length);
      }
    }
    if (raw.isEmpty) return const [];
    // start 升序；同起点时长者优先（先吃长词，短词因重叠被跳过）
    raw.sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      return byStart != 0 ? byStart : b.end.compareTo(a.end);
    });
    final result = <HomophoneMatch>[];
    var lastEnd = 0;
    for (final m in raw) {
      if (m.start < lastEnd) continue;
      result.add(m);
      lastEnd = m.end;
    }
    return result;
  }
}
