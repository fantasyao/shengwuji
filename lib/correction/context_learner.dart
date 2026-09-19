import '../utils/correction_learner.dart';
import 'context_scorer.dart';
import 'domain_dictionary.dart';
import 'homophone_dictionary.dart';

/// 一条共现统计增量：source 词 × context 词 计数 +delta
class ContextStatBump {
  /// 用户选定的词（如「智谱」）
  final String source;

  /// 上下文词（折叠形，与评分查表 key 一致）
  final String context;
  final int delta;

  const ContextStatBump(this.source, this.context, {this.delta = 1});

  @override
  String toString() => '$source×$context';
}

/// ContextLearner.split 的产出：纠错对两条去路的分流结果
class ContextLearnOutcome {
  /// 普通纠错对 → correction_pairs（提示制盲替换表，照旧）
  final List<CorrectionPair> regularPairs;

  /// 同音组纠错 → 共现统计（ContextScorer 动态评分用）
  final List<ContextStatBump> statBumps;

  /// 用户选定的同音词 → 词频 +1（弱先验，方案§12）
  final List<String> userWordBumps;

  const ContextLearnOutcome({
    this.regularPairs = const [],
    this.statBumps = const [],
    this.userWordBumps = const [],
  });
}

/// 编辑学习分流器（纯逻辑，方案§11/§18）。
///
/// 关键原则：同音组内的纠错对（如 质朴→智谱）绝不能进 correction_pairs
/// 盲替换表——replaceAll 会把「这个人很质朴」也改掉。这类对改道为
/// 「用户选的词 × 上下文词」共现统计，只影响上下文评分，不影响替换决策。
/// 普通纠错对（饰品→视频）与旧行为一致进提示表。
class ContextLearner {
  ContextLearner._();

  /// 对比「识别原文 → 用户改后文本」并分流。
  /// 只应被用户的明确修改行为触发（编辑保存 / 一键修正采纳），
  /// 自动纠错的结果绝不回流成训练数据（防错误反馈循环，方案§18）
  static ContextLearnOutcome split(
    String original,
    String edited, {
    required HomophoneDictionary homophones,
    required DomainDictionary domain,
    Set<String> extraVocabulary = const {},
  }) {
    // 双钥匙：整词钥匙 + 短核兜底钥匙同走分流（同音组对都改道统计，
    // 普通对都进提示表）；提示场景由 CorrectionLearner.dedupeSubsumed
    // 折叠短核，替换场景 applyCorrections 长钥匙先应用自然去重
    final extracted = CorrectionLearner.extractAll(original, edited);
    final pairs = [...extracted.primary, ...extracted.shortCore];
    final regular = <CorrectionPair>[];
    final bumps = <ContextStatBump>[];
    final userWords = <String>[];
    for (final p in pairs) {
      final isHomophoneFix =
          p.correct.isNotEmpty && homophones.isSameGroup(p.error, p.correct);
      if (!isHomophoneFix) {
        regular.add(p);
        continue;
      }
      final target = p.correct;
      userWords.add(target);
      // 定位用户改后的词，取其窗口内的上下文词累计共现
      final idx = edited.indexOf(target);
      if (idx < 0) continue; // 理论上必在（刚被用户写进去）；防御
      final hits = ContextScorer.extractContextWords(
        edited,
        idx,
        idx + target.length,
        domain: domain,
        extraVocabulary: extraVocabulary,
        homophones: homophones,
      );
      for (final h in hits) {
        bumps.add(ContextStatBump(target, h.word));
      }
    }
    return ContextLearnOutcome(
      regularPairs: regular,
      statBumps: bumps,
      userWordBumps: userWords,
    );
  }
}
