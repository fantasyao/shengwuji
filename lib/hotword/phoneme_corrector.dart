/// 音素热词 · 模糊匹配替换引擎。
///
/// 移植自 CapsWriter-Offline `core/client/hotword/`（algo_calc.py 的模糊子串
/// DP + hot_phoneme.py 的阈值分流/冲突解决），核心约定一致：
/// - 音素代价：同值 0 / 模糊音（前后鼻音、平翘舌、n-l、f-h 等 17 组）0.5 /
///   中文声调不同 0.5 / 英文 token LCS 字符相似 / 跨语言 1
/// - 硬边界约束：匹配起点必须词首（isWordStart）、终点必须词尾（isWordEnd），
///   只匹配整字/整词，不会切进字中间
/// - 分数 = 1 - 编辑距离/热词语素数；≥ 强制阈值才替换，≥ 相似阈值仅提示
/// - 与 CapsWriter 的差异（有意的简化，见 docs/architecture/phoneme-hotword.md）：
///   ① 不移植 FastRAG 倒排粗筛（个人热词几十~几百条，全文 DP 毫秒级够用，
///      行最小值早停剪枝保留）；② 新增短热词保险丝：别名气素数 <4（约单字）
///      即使过强制阈值也只进 similars 提示、不静默替换（CapsWriter 文档自认
///      短词易误换）。
library;

import 'phoneme.dart';

/// 相似音素组（CapsWriter SIMILAR_PHONEMES 原表照搬，改动须双侧同步语义）。
const List<List<String>> kSimilarPhonemes = [
  // 前后鼻音
  ['an', 'ang'],
  ['en', 'eng'],
  ['in', 'ing'],
  ['ian', 'iang'],
  ['uan', 'uang'],
  // 平翘舌
  ['z', 'zh'],
  ['c', 'ch'],
  ['s', 'sh'],
  // 鼻音/边音
  ['l', 'n'],
  // 唇齿音/声门音 (Hu Jian / Fu Jian)
  ['f', 'h'],
  // 常见易混韵母
  ['ai', 'ei'],
  ['o', 'uo'],
  ['e', 'ie'],
  // 送气不送气（音近）
  ['p', 't'],
  ['p', 'b'],
  ['t', 'd'],
  ['k', 'g'],
];

/// 一条热词条目：target 为替换目标，aliases 为可触发的别名写法。
/// 老格式「错词 = 正词」解析为 target=正词、aliases=[错词]；
/// 新格式「目标 | 别名1 | 别名2」按顺序取。
class PhonemeEntry {
  const PhonemeEntry({required this.target, required this.aliases});

  final String target;
  final List<String> aliases;
}

/// 热词文本三格式解析（纯函数，TextProcessor 与单测共用）：
/// - 老格式「错词 = 正词」：回调 [onLiteralPair] 供字面替换表收集，
///   同时生成音素条目（正词为目标、错词为别名）——老条目零迁移获得发音匹配
/// - 新格式「目标 | 别名1 | 别名2」（CapsWriter）：仅音素条目，无字面替换
/// - 基础格式「整行一个热词」（CapsWriter hot.txt 默认）：无别名，仅音素条目
/// - 注释行（# 开头）/空行跳过（此前注释行含「 = 」会被解析成一条无害但
///   无意义的字面规则，音素化后会被当别名参与匹配，必须显式过滤）
List<PhonemeEntry> parseHotwordEntries(
  String content, {
  void Function(String wrong, String right)? onLiteralPair,
}) {
  final entries = <PhonemeEntry>[];
  for (var line in content.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final eqParts = trimmed.split(' = ');
    if (eqParts.length == 2) {
      final wrong = eqParts[0].trim();
      final right = eqParts[1].trim();
      if (wrong.isNotEmpty && right.isNotEmpty) {
        onLiteralPair?.call(wrong, right);
        entries.add(PhonemeEntry(target: right, aliases: [wrong]));
      }
      continue;
    }
    if (trimmed.contains('|')) {
      final parts = trimmed
          .split('|')
          .map((p) => p.trim())
          .where((p) => p.isNotEmpty)
          .toList();
      if (parts.length >= 2) {
        entries.add(PhonemeEntry(target: parts[0], aliases: parts.sublist(1)));
      }
      continue;
    }
    // 畸形行（如「a = b = c」两个等号）：既非合法老格式也无别名语义，防呆跳过
    if (trimmed.contains(' = ')) continue;
    // 基础格式：整行一个热词（无别名，音素参与匹配、目标即自身）
    entries.add(PhonemeEntry(target: trimmed, aliases: const []));
  }
  return entries;
}

/// 一处命中（原文字符区间 → 热词 + 相似度）。
class PhonemeMatch {
  const PhonemeMatch({
    required this.original,
    required this.hotword,
    required this.score,
    required this.start,
    required this.end,
  });

  final String original;
  final String hotword;
  final double score;
  final int start;
  final int end;

  @override
  String toString() => '「$original」→「$hotword」(${(score * 100).toStringAsFixed(0)}%)';
}

class PhonemeCorrectorResult {
  const PhonemeCorrectorResult({
    required this.text,
    required this.matches,
    required this.similars,
  });

  /// 替换后的文本
  final String text;

  /// 已静默替换的匹配
  final List<PhonemeMatch> matches;

  /// 达相似阈值但未替换的（提示用；含被短热词保险丝拦下的候选）
  final List<PhonemeMatch> similars;
}

class PhonemeCorrector {
  PhonemeCorrector({
    this.threshold = PhonemeHotwordConfig.defaultThreshold,
    double? similarThreshold,
  }) : similarThreshold =
            similarThreshold ?? threshold - PhonemeHotwordConfig.similarGap;

  /// 强制替换阈值（越高越严格）
  final double threshold;

  /// 相似提示阈值（低于 threshold，命中只提示不替换）
  final double similarThreshold;

  /// 短热词保险丝：别名气素数 <4（约单字 3 音素）不允许静默替换。
  /// 单字误伤面最大（如热词「猫」会把「抹」也换掉），只提示让用户决定。
  static const int minPhonemesForReplace = 4;

  /// target → 音素组列表（target 自身 + 各别名，全参与匹配，CapsWriter 同款）
  final Map<String, List<List<Phoneme>>> hotwords = {};

  /// 重建热词库（保存热词/加入热词后调用；拼音字典须已加载）
  void updateHotwords(List<PhonemeEntry> entries) {
    hotwords.clear();
    for (final entry in entries) {
      final groups = <List<Phoneme>>[];
      for (final part in [entry.target, ...entry.aliases]) {
        final phons = getPhonemeInfo(part);
        if (phons.isNotEmpty) groups.add(phons);
      }
      if (groups.isNotEmpty) hotwords[entry.target] = groups;
    }
  }

  /// 对文本执行音素匹配：达 [threshold] 的替换，达 [similarThreshold] 的记入
  /// similars 供 UI 提示。
  PhonemeCorrectorResult correct(String text) {
    if (text.isEmpty || hotwords.isEmpty) {
      return PhonemeCorrectorResult(
          text: text, matches: const [], similars: const []);
    }
    final input = getPhonemeInfo(text);
    if (input.isEmpty) {
      return PhonemeCorrectorResult(
          text: text, matches: const [], similars: const []);
    }

    // 搜索阈值放宽到相似阈值下方一点（CapsWriter 同款），一次 DP 同时覆盖
    // 替换带与提示带
    final searchThreshold =
        (threshold < similarThreshold ? threshold : similarThreshold) - 0.1;

    final charMatches = <_CharMatch>[];
    final similarByKey = <String, PhonemeMatch>{};

    hotwords.forEach((target, groups) {
      PhonemeMatch? bestSimilar;
      for (final group in groups) {
        final found = searchConstrained(group, input, searchThreshold);
        if (found.isEmpty) continue;
        // 别名气素数 <4：保险丝拦截，即使过强制阈值也降级为提示
        final allowReplace = group.length >= minPhonemesForReplace;
        for (final (score, phStart, phEnd) in found) {
          final charStart = input[phStart].charStart;
          final charEnd = input[phEnd - 1].charEnd;
          final original = text.substring(charStart, charEnd);
          if (allowReplace && score >= threshold) {
            charMatches.add(_CharMatch(
              start: charStart,
              end: charEnd,
              score: score,
              hotword: target,
            ));
          }
          if (score >= similarThreshold) {
            final m = PhonemeMatch(
              original: original,
              hotword: target,
              score: score,
              start: charStart,
              end: charEnd,
            );
            // 同热词多处命中只留最优（分数降序、别名长度降序，CapsWriter 同款）
            final cur = bestSimilar;
            if (cur == null ||
                score > cur.score ||
                (score == cur.score && original.length > cur.original.length)) {
              bestSimilar = m;
            }
          }
        }
      }
      if (bestSimilar != null) similarByKey[target] = bestSimilar;
    });

    final replaced = _resolveAndReplace(text, charMatches);
    final similars = similarByKey.values.toList()
      ..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        return b.original.length.compareTo(a.original.length);
      });

    return PhonemeCorrectorResult(
      text: replaced.text,
      matches: replaced.matches,
      similars: similars,
    );
  }

  /// 冲突解决与替换（CapsWriter _resolve_and_replace）：分数优先 > 覆盖长度
  /// 优先，区间不重叠，原文已等于目标的原地匹配只占位不替换，最后从后往前改。
  ({String text, List<PhonemeMatch> matches}) _resolveAndReplace(
    String text,
    List<_CharMatch> matches,
  ) {
    matches.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return (b.end - b.start).compareTo(a.end - a.start);
    });

    final finalMatches = <_CharMatch>[];
    final occupied = <_CharMatch>[];
    for (final m in matches) {
      var overlap = false;
      for (final r in occupied) {
        if (!(m.end <= r.start || m.start >= r.end)) {
          overlap = true;
          break;
        }
      }
      if (overlap) continue;
      finalMatches.add(m);
      occupied.add(m);
    }

    // 从后往前替换，避免区间位移
    final buf = text.split('');
    final applied = <PhonemeMatch>[];
    final ordered = finalMatches.toList()
      ..sort((a, b) => b.start.compareTo(a.start));
    for (final m in ordered) {
      if (text.substring(m.start, m.end) == m.hotword) continue; // 原地不替换
      buf.replaceRange(m.start, m.end, m.hotword.split(''));
      applied.add(PhonemeMatch(
        original: text.substring(m.start, m.end),
        hotword: m.hotword,
        score: m.score,
        start: m.start,
        end: m.end,
      ));
    }
    applied.sort((a, b) => a.start.compareTo(b.start));
    return (text: buf.join(), matches: applied);
  }

  /// 词边界约束的模糊子串搜索（CapsWriter fuzzy_substring_search_constrained）。
  ///
  /// 返回 [(score, 起点音素下标, 终点音素下标（exclusive）)]，按分数降序，
  /// 同终点只留最优。start 必须 isWordStart、end 必须 isWordEnd。
  static List<(double, int, int)> searchConstrained(
    List<Phoneme> hw,
    List<Phoneme> input,
    double threshold,
  ) {
    final n = hw.length;
    final m = input.length;
    if (n == 0 || m == 0) return const [];

    // dp[i][j] = hw 前 i 个音素匹配以 input[j-1] 结尾片段的最小编辑距离
    final dp = List.generate(n + 1, (_) => List.filled(m + 1, double.infinity));
    // path[i][j] 记录该状态匹配片段的起点音素下标
    final path = List.generate(n + 1, (_) => List.filled(m + 1, 0));

    // 第一行：允许从任何字边界（词首）开始匹配
    for (var j = 0; j <= m; j++) {
      if (j == 0 || (j < m && input[j].isWordStart)) {
        dp[0][j] = 0;
        path[0][j] = j;
      }
    }

    final hwVals = hw.map((p) => p.value).toList();
    final hwLangs = hw.map((p) => p.lang).toList();
    final hwTones = hw.map((p) => p.isTone).toList();
    final inVals = input.map((p) => p.value).toList();
    final inLangs = input.map((p) => p.lang).toList();
    final inTones = input.map((p) => p.isTone).toList();

    final maxRowMin = n * (1.0 - threshold) + 2; // 早停上界（CapsWriter 同款放宽 +2）

    for (var i = 1; i <= n; i++) {
      var rowMin = double.infinity;
      final hV = hwVals[i - 1];
      final hL = hwLangs[i - 1];
      final hP = hwTones[i - 1];
      for (var j = 1; j <= m; j++) {
        final iV = inVals[j - 1];
        final iL = inLangs[j - 1];
        var cost = 1.0;
        if (hL == iL) {
          if (hV == iV) {
            cost = 0;
          } else if (hL == 'zh') {
            if (hP) {
              cost = 0.5; // 热词侧是声调而输入侧不同音 → 声调差异
            } else if (_isSimilarPhoneme(hV, iV)) {
              cost = 0.5;
            }
          } else if (hL == 'en') {
            final lcs = lcsLength(hV, iV);
            final maxLen = hV.length > iV.length ? hV.length : iV.length;
            if (maxLen > 0) cost = 1.0 - lcs / maxLen;
          }
        }
        final dMatch = dp[i - 1][j - 1] + cost;
        final dDel = dp[i - 1][j] + 1.0;
        final dIns = dp[i][j - 1] + 1.0;
        if (dMatch <= dDel) {
          if (dMatch <= dIns) {
            dp[i][j] = dMatch;
            path[i][j] = path[i - 1][j - 1];
          } else {
            dp[i][j] = dIns;
            path[i][j] = path[i][j - 1];
          }
        } else {
          if (dDel <= dIns) {
            dp[i][j] = dDel;
            path[i][j] = path[i - 1][j];
          } else {
            dp[i][j] = dIns;
            path[i][j] = path[i][j - 1];
          }
        }
        if (dp[i][j] < rowMin) rowMin = dp[i][j];
      }
      if (rowMin > maxRowMin) break; // 整行都超阈值，后续只会更差
    }

    // 收集：终点必须词尾，距离硬上限过滤，同终点留最优
    final byEnd = <int, (double, int, int)>{};
    for (var j = 1; j <= m; j++) {
      if (!input[j - 1].isWordEnd) continue;
      final dist = dp[n][j];
      if (dist.isInfinite || dist >= n * 0.8) continue;
      final score = 1.0 - dist / n;
      if (score < threshold) continue;
      final cur = byEnd[j];
      if (cur == null || score > cur.$1) {
        byEnd[j] = (score, path[n][j], j);
      }
    }
    final results = byEnd.values.toList()
      ..sort((a, b) => b.$1.compareTo(a.$1));
    return results;
  }

  static bool _isSimilarPhoneme(String a, String b) {
    for (final group in kSimilarPhonemes) {
      if (group.contains(a) && group.contains(b)) return true;
    }
    return false;
  }
}

class _CharMatch {
  const _CharMatch({
    required this.start,
    required this.end,
    required this.score,
    required this.hotword,
  });

  final int start;
  final int end;
  final double score;
  final String hotword;
}

/// 音素热词配置（prefs key 集中地，风格对齐 CorrectionConfig）。
class PhonemeHotwordConfig {
  PhonemeHotwordConfig._();

  static const String enabledPrefKey = 'phoneme_hotword_enabled';
  static const String thresholdPrefKey = 'phoneme_hotword_threshold';

  /// 默认强制替换阈值（CapsWriter hot_thresh 同款）
  static const double defaultThreshold = 0.85;

  /// 相似提示阈值 = 强制阈值 - gap（源自 CapsWriter hot_similar 0.6 关系；
  /// 用户要求提示线 0.75，gap 0.25→0.10 收窄提示带，偏离 CapsWriter 属有意为之）
  static const double similarGap = 0.10;

  /// 阈值可调范围（设置页滑条）；越界/脏值回落默认
  static const double minThreshold = 0.70;
  static const double maxThreshold = 0.95;

  /// 修正对「加入热词」升级通道的命中次数门槛（用户拍板：满 3 次才提议）
  static const int promotionHitThreshold = 3;

  static double normalizeThreshold(double v) =>
      v >= minThreshold && v <= maxThreshold ? v : defaultThreshold;
}
