/// 上下文纠错模块的可调参数集中地（方案§13：阈值必须可配置）。
///
/// 调参以 test/context_corrector_test.dart 的验收用例集为规格：
/// 「应改」用例需要 赢家分 ≥ [minScore] 且 领先差距 ≥ [minMargin]，
/// 「防误改」用例必须全部不触发。
class CorrectionConfig {
  CorrectionConfig._();

  /// 候选词前后各取多少字符作为上下文窗口（方案§6：前 5~10 个词 ≈ 10~20 字）
  static const int contextWindowChars = 12;

  /// 上下文词命中候选词 related 词表时的加分
  /// （方案§7 示例「公司+10、GLM+15」的量级；一词一加，不做逐词权重）
  static const double relatedHitScore = 10;

  /// 上下文词命中 conflict 词表时的减分（保护词，方案§15）
  static const double conflictPenaltyScore = 12;

  /// 动态共现统计单个上下文词的计数封顶（防某条高频统计爆炸主导评分）
  static const int cooccurrenceCountCap = 5;

  /// 动态共现每单位计数的分值：贡献 = min(count, cap) × weight × 距离权重
  static const double cooccurrenceScorePerCount = 2;

  /// 用户词频先验权重（方案§12：log(1+freq) 乘小系数，只做同分微调，
  /// 绝不允许「用户常说智谱」单独决定替换）
  static const double userFrequencyWeight = 0.2;

  /// 自动替换的赢家绝对分下限：低于此分不动原文——
  /// 只有纯负面证据（赢家 0 分）时同样不替换，宁漏勿错。
  /// 7 = 单条远端 related 命中（距离权重 0.75 × 10 分）仍可通过，
  /// 而 0 分赢家（纯靠对手 conflict 减分抬差距）永远不替换
  static const double minScore = 7;

  /// 自动替换的最小领先差距：赢家分 − 次高分（方案§13：差距太小宁可不改）。
  /// 15 的含义：单个静态 related 命中（+10）不足以翻案，必须搭配
  /// 对侧 conflict 减分或第二条证据才行——误改成本高于漏改
  static const double minMargin = 15;

  /// 共现统计表容量上限（行），超出按 count 从低到高淘汰
  static const int contextStatsCap = 3000;

  /// prefs 开关 key：同音词上下文纠错总开关（默认开）
  static const String enabledPrefKey = 'context_correction_enabled';
}
