import 'dart:math';

import 'correction_config.dart';
import 'domain_dictionary.dart';
import 'homophone_dictionary.dart';

/// 窗口内提取到的一个上下文词
class ContextWordHit {
  /// 折叠（小写）后的规范形：评分与共现统计统一用它做 key
  final String word;

  /// 距离衰减权重：紧邻候选词 = 1.0，窗口边缘 = 0.5（线性衰减）
  final double weight;

  const ContextWordHit(this.word, this.weight);

  @override
  String toString() => '$word(${weight.toStringAsFixed(2)})';
}

/// 一个候选词在当前上下文中的得分与可解释明细
class CandidateScore {
  /// 候选词原形
  final String word;
  final double score;

  /// 计分明细（日志/调试用，方案§7 的可解释性要求）
  final List<String> reasons;

  const CandidateScore(this.word, this.score, this.reasons);

  @override
  String toString() => '$word=${score.toStringAsFixed(1)}';
}

/// 上下文评分器（纯静态、无 IO）：方案§7 加权评分的实现。
///
///     Score(candidate) = Σ上下文词 距离权重 × (related 命中加分
///                        − conflict 命中减分 + 动态共现分)
///                        + 用户词频弱先验
///
/// ASR 原始置信度一项：sherpa_onnx 离线结果不提供置信度，恒为 0，省略。
class ContextScorer {
  ContextScorer._();

  /// 从 text 的候选区间 [excludeStart, excludeEnd) 前后各 window 个字符里
  /// 提取已知上下文词。词表 = 领域词表 related∪conflict ∪ extraVocabulary
  /// （动态统计见过的词）；同音组成员一律排除——它们正是要被裁决的对象，
  /// 不能反过来当上下文。贪心最长匹配（"大模型"优先于"模型"），
  /// 同一词多次出现取最大权重。
  static List<ContextWordHit> extractContextWords(
    String text,
    int excludeStart,
    int excludeEnd, {
    required DomainDictionary domain,
    Set<String> extraVocabulary = const {},
    HomophoneDictionary? homophones,
    int window = CorrectionConfig.contextWindowChars,
  }) {
    final lo = (excludeStart - window).clamp(0, text.length);
    final hi = (excludeEnd + window).clamp(0, text.length);
    if (lo >= hi) return const [];
    final lower = text.toLowerCase();

    var vocab = {...domain.vocabulary, ...extraVocabulary};
    if (homophones != null) {
      // 同音词不做上下文（折叠形比对）
      vocab = vocab
          .where((w) => !homophones.containsWord(w))
          .toSet();
    }
    final needles = vocab.where((w) => w.isNotEmpty).toList()
      ..sort((a, b) => b.length.compareTo(a.length)); // 长词优先 = 贪心最长匹配

    // occupied 相对 lo 的占用标记；候选词自身区间标记占用，绝不当上下文
    final occupied = List<bool>.filled(hi - lo, false);
    for (
      int i = (excludeStart - lo).clamp(0, occupied.length);
      i < (excludeEnd - lo).clamp(0, occupied.length);
      i++
    ) {
      occupied[i] = true;
    }

    final collected = <ContextWordHit>[];
    for (final needle in needles) {
      int idx = lower.indexOf(needle, lo);
      while (idx >= 0 && idx + needle.length <= hi) {
        var free = true;
        for (int k = idx - lo; k < idx - lo + needle.length; k++) {
          if (occupied[k]) {
            free = false;
            break;
          }
        }
        if (free) {
          for (int k = idx - lo; k < idx - lo + needle.length; k++) {
            occupied[k] = true;
          }
          // 命中区间到候选区间的最近字符距离（0 = 紧邻）
          final dist =
              idx + needle.length <= excludeStart
                  ? excludeStart - (idx + needle.length)
                  : (idx >= excludeEnd ? idx - excludeEnd : 0);
          final weight = (1.0 - 0.5 * dist / window).clamp(0.5, 1.0);
          collected.add(ContextWordHit(needle, weight));
        }
        idx = lower.indexOf(needle, idx + 1);
      }
    }

    // 同一词取最大权重去重
    final deduped = <String, ContextWordHit>{};
    for (final h in collected) {
      final old = deduped[h.word];
      if (old == null || h.weight > old.weight) deduped[h.word] = h;
    }
    return deduped.values.toList();
  }

  /// 给一组候选拿同一份上下文打分，返回与 [candidates] 一一对应。
  /// [coStats] 为共现统计（候选折叠词 → 上下文折叠词 → 计数），
  /// [userFreq] 为用户词频（候选折叠词 → 次数），都来自 DB 预载
  static List<CandidateScore> score({
    required String text,
    required int matchStart,
    required int matchEnd,
    required List<String> candidates,
    required DomainDictionary domain,
    Map<String, Map<String, int>> coStats = const {},
    Map<String, int> userFreq = const {},
    HomophoneDictionary? homophones,
    int window = CorrectionConfig.contextWindowChars,
  }) {
    final hits = extractContextWords(
      text,
      matchStart,
      matchEnd,
      domain: domain,
      extraVocabulary: {
        for (final ctx in coStats.values) ...ctx.keys,
      },
      homophones: homophones,
      window: window,
    );

    final results = <CandidateScore>[];
    for (final cand in candidates) {
      final key = cand.toLowerCase();
      final entry = domain.lookup(cand);
      double s = 0;
      final reasons = <String>[];
      for (final hit in hits) {
        if (entry != null && entry.isRelated(hit.word)) {
          final v = CorrectionConfig.relatedHitScore * hit.weight;
          s += v;
          reasons.add('+${v.toStringAsFixed(1)} ${hit.word}∈related');
        }
        if (entry != null && entry.isConflict(hit.word)) {
          final v = CorrectionConfig.conflictPenaltyScore * hit.weight;
          s -= v;
          reasons.add('-${v.toStringAsFixed(1)} ${hit.word}∈conflict');
        }
        final count = coStats[key]?[hit.word] ?? 0;
        if (count > 0) {
          final v =
              min(count, CorrectionConfig.cooccurrenceCountCap) *
              CorrectionConfig.cooccurrenceScorePerCount *
              hit.weight;
          s += v;
          reasons.add('+${v.toStringAsFixed(1)} 共现${hit.word}×$count');
        }
      }
      final freq = userFreq[key] ?? 0;
      if (freq > 0) {
        final v = CorrectionConfig.userFrequencyWeight * log(1 + freq);
        s += v;
        reasons.add('+${v.toStringAsFixed(1)} 词频×$freq');
      }
      results.add(CandidateScore(cand, s, reasons));
    }
    return results;
  }
}
