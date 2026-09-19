import '../utils/correction_learner.dart';

/// 一条修正对的语境档案：错误片段某次被学到时，它在识别原文中出现位置的
/// 左右邻接字符（归一化后的"词字符"，见 [PairContextGate]）。
///
/// 同一个修正对在不同语境下被反复学到时积累多条档案；提示一键修正前用
/// [PairContextGate.shouldPrompt] 比对当前文本的邻接字符，语境吻合才弹
/// 提示——「互联网影视可控」学到的「影视→隐私」不会再去打扰
/// 「今晚看的影视不错」。
class PairContextRecord {
  /// 错误片段（与 correction_pairs.error_text 对应）
  final String error;

  /// 修正片段（与 correction_pairs.corrected_text 对应；空串=删除对）
  final String correct;

  /// 紧邻错误片段左侧的词字符（读序、已归一化），最多 [PairContextGate.contextChars] 个
  final String leftContext;

  /// 紧邻错误片段右侧的词字符（已归一化），最多 [PairContextGate.contextChars] 个
  final String rightContext;

  /// 学习次数（DB 层维护，容量淘汰时低计数先走；内存构造默认 1）
  final int hitCount;

  const PairContextRecord({
    required this.error,
    required this.correct,
    this.leftContext = '',
    this.rightContext = '',
    this.hitCount = 1,
  });

  @override
  bool operator ==(Object other) =>
      other is PairContextRecord &&
      other.error == error &&
      other.correct == correct &&
      other.leftContext == leftContext &&
      other.rightContext == rightContext;

  @override
  int get hashCode => Object.hash(error, correct, leftContext, rightContext);

  @override
  String toString() =>
      '「$error」@($leftContext|$rightContext)';
}

/// 修正对提示的语境门控（纯逻辑，无 IO）。
///
/// 语境用「错误片段边界两侧的邻接字符」表达而不是领域词表的词：学到的
/// 对多来自个人口音/专名（如 影视→隐私、co林兰→coding plan），其语境词
/// （互联网/可控）不在任何封闭词表里，锚定边界的字符指纹不依赖分词和
/// 词库，中英混排通用。
///
/// 匹配规则：左侧比公共后缀（两边都以错误片段为锚点收尾）、右侧比公共
/// 前缀，任一侧连续共享 ≥ [minSharedChars] 即视为同一语境。函数词单字
/// （"的/了"）撞车被 2 字符门槛挡掉。
///
/// 无语境档案的对（老数据/导入/学自无邻接的裸片段）不门控、照旧字面
/// 提示——门控只为砍误提示，不为吞掉本该出现的提示。
class PairContextGate {
  PairContextGate._();

  /// 每侧记录的邻接词字符数
  static const int contextChars = 4;

  /// 任一侧连续共享多少字符才算语境吻合
  static const int minSharedChars = 2;

  /// 语境档案表容量上限（db_helper 侧的 _kPairContextsCap 与之同步）
  static const int tableCap = 2000;

  /// 修正对 → 其语境档案列表 的分组 key。
  /// U+0001 分隔符保证不撞 key（否则 ab→c 与 a→bc 会拼成同一个串）；
  /// 用 fromCharCode 而非转义序列，避免源码里出现不可见字符
  static String keyOf(String error, String correct) =>
      error + String.fromCharCode(1) + correct;

  static String keyOfPair(CorrectionPair p) => keyOf(p.error, p.correct);

  /// 按修正对分组（提示点一次查全表后建索引用）
  static Map<String, List<PairContextRecord>> groupByPair(
    Iterable<PairContextRecord> records,
  ) {
    final map = <String, List<PairContextRecord>>{};
    for (final r in records) {
      map.putIfAbsent(keyOf(r.error, r.correct), () => []).add(r);
    }
    return map;
  }

  /// 学习时抽取语境档案：找 [original] 中每个错误片段的出现位置，
  /// 记录边界两侧的归一化邻接字符。两侧都不足 [minSharedChars] 的出现
  /// 位置（裸片段、贴着只有标点的边界）不产出档案——这种档案永远匹配
  /// 不上，只会白白把对变成"永不提示"。
  static List<PairContextRecord> extract(
    String original,
    List<CorrectionPair> pairs,
  ) {
    if (original.isEmpty || pairs.isEmpty) return const [];
    final records = <PairContextRecord>[];
    final seen = <PairContextRecord>{};
    for (final p in pairs) {
      if (p.error.isEmpty) continue;
      int idx = original.indexOf(p.error);
      while (idx >= 0) {
        final left = _window(original, idx, left: true);
        final right = _window(original, idx + p.error.length, left: false);
        if (left.length >= minSharedChars || right.length >= minSharedChars) {
          final rec = PairContextRecord(
            error: p.error,
            correct: p.correct,
            leftContext: left,
            rightContext: right,
          );
          if (seen.add(rec)) records.add(rec);
        }
        idx = original.indexOf(p.error, idx + p.error.length);
      }
    }
    return records;
  }

  /// 提示前门控：该对在 [text] 中的出现位置是否与任一已存档案同语境。
  /// - 档案为空（或全不可用）→ true：没有语境信息，退回字面提示旧行为
  /// - 有档案但当前出现位置的邻接字符与所有档案都不沾边 → false（不弹）
  /// - 错误片段不在 text 中 → false（防御；调用方都先做过 contains 过滤）
  ///
  /// 注意精度优先：当前出现位置两侧一个词字符都没有（裸片段撞上有档案
  /// 的对）也返回 false——上下文全无时提示纯属猜测，宁漏勿扰。
  static bool shouldPrompt(
    String text,
    CorrectionPair pair,
    List<PairContextRecord> contexts,
  ) {
    if (pair.error.isEmpty) return false;
    final usable =
        contexts
            .where(
              (r) =>
                  r.leftContext.length >= minSharedChars ||
                  r.rightContext.length >= minSharedChars,
            )
            .toList();
    if (usable.isEmpty) return true;
    int idx = text.indexOf(pair.error);
    while (idx >= 0) {
      final left = _window(text, idx, left: true);
      final right = _window(text, idx + pair.error.length, left: false);
      for (final r in usable) {
        if (_commonSuffixLen(r.leftContext, left) >= minSharedChars ||
            _commonPrefixLen(r.rightContext, right) >= minSharedChars) {
          return true;
        }
      }
      idx = text.indexOf(pair.error, idx + pair.error.length);
    }
    return false;
  }

  /// 取 boundary 两侧的归一化邻接字符：先取 2×contextChars 个原始字符的
  /// 窗口（给标点/空格留出被剥离的余量），归一化后左取尾、右取头
  /// （贴近边界的一端才是有效语境）。
  static String _window(String text, int boundary, {required bool left}) {
    final clamped = boundary.clamp(0, text.length);
    final String raw;
    if (left) {
      final start = (clamped - contextChars * 2).clamp(0, text.length);
      raw = text.substring(start, clamped);
    } else {
      final end = (clamped + contextChars * 2).clamp(0, text.length);
      raw = text.substring(clamped, end);
    }
    final normalized = _normalize(raw);
    if (normalized.length <= contextChars) return normalized;
    return left
        ? normalized.substring(normalized.length - contextChars)
        : normalized.substring(0, contextChars);
  }

  /// 只留词字符（中文/字母/数字），ASCII 折叠小写——标点/空格在 ASR
  /// 文本里位置不稳定，参与比对只会制造错位
  static String _normalize(String s) {
    final buf = StringBuffer();
    for (final cu in s.codeUnits) {
      final isCJK =
          (cu >= 0x4E00 && cu <= 0x9FFF) || (cu >= 0x3400 && cu <= 0x4DBF);
      final isDigit = cu >= 0x30 && cu <= 0x39;
      final isUpper = cu >= 0x41 && cu <= 0x5A;
      final isLower = cu >= 0x61 && cu <= 0x7A;
      if (isCJK || isDigit || isLower) {
        buf.writeCharCode(cu);
      } else if (isUpper) {
        buf.writeCharCode(cu + 0x20);
      }
    }
    return buf.toString();
  }

  /// 公共后缀长度（左侧语境两边都以错误片段为锚收尾，从尾部对齐比）
  static int _commonSuffixLen(String a, String b) {
    var n = 0;
    while (
        n < a.length &&
        n < b.length &&
        a.codeUnitAt(a.length - 1 - n) == b.codeUnitAt(b.length - 1 - n)
    ) {
      n++;
    }
    return n;
  }

  /// 公共前缀长度（右侧语境从头部=紧邻错误片段处对齐比）
  static int _commonPrefixLen(String a, String b) {
    var n = 0;
    while (
        n < a.length && n < b.length && a.codeUnitAt(n) == b.codeUnitAt(n)
    ) {
      n++;
    }
    return n;
  }
}
