import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/correction/context_scorer.dart';
import 'package:shengwuji_app/correction/correction_config.dart';
import 'package:shengwuji_app/correction/domain_dictionary.dart';
import 'package:shengwuji_app/correction/homophone_dictionary.dart';

/// 评分器专用的内嵌小词表：只保留验证计分逻辑所需的最小结构
const String _kDomainJson = '''
{
  "智谱": {
    "type": "company",
    "related": ["公司", "GLM", "大模型", "模型"],
    "conflict": ["性格", "这个人"]
  },
  "质朴": {
    "type": "style",
    "related": ["性格", "这个人"],
    "conflict": ["公司", "GLM", "大模型", "模型"]
  }
}
''';

DomainDictionary _domain() => DomainDictionary.fromJsonString(_kDomainJson);

/// 按词取分（score 返回顺序与候选一致，这里转 Map 方便断言）
Map<String, double> _scores(List<CandidateScore> scores) => {
  for (final s in scores) s.word: s.score,
};

void main() {
  group('ContextScorer.extractContextWords 窗口词提取', () {
    test('提取候选词前后的词表命中词，紧邻词权重 1.0', () {
      final hits = ContextScorer.extractContextWords(
        '质朴公司的模型',
        0,
        2,
        domain: _domain(),
      );
      final byWord = {for (final h in hits) h.word: h.weight};
      expect(byWord.keys, containsAll(['公司', '模型']));
      expect(byWord['公司'], closeTo(1.0, 0.001));
      // 模型距候选 3 字：1 - 0.5*3/12
      expect(byWord['模型'], closeTo(1 - 0.5 * 3 / 12, 0.001));
    });

    test('贪心最长匹配：「大模型」整词命中，不再拆出「模型」', () {
      final hits = ContextScorer.extractContextWords(
        '质朴大模型',
        0,
        2,
        domain: _domain(),
      );
      expect(hits.map((h) => h.word), ['大模型']);
    });

    test('英文上下文词大小写折叠：glm 命中词表里的 GLM', () {
      final hits = ContextScorer.extractContextWords(
        '质朴glm很好',
        0,
        2,
        domain: _domain(),
      );
      expect(hits.map((h) => h.word), contains('glm'));
    });

    test('距离衰减：近邻上下文词权重高于远端，且不低过 0.5', () {
      // 这个人(0-3) 质朴(3-5，候选) 填充8字 公司(14-16)
      final hits = ContextScorer.extractContextWords(
        '这个人质朴AAAAAAAA公司',
        3,
        5,
        domain: _domain(),
      );
      final byWord = {for (final h in hits) h.word: h.weight};
      expect(byWord['这个人']!, greaterThan(byWord['公司']!));
      expect(byWord['公司']!, greaterThanOrEqualTo(0.5));
      expect(byWord['这个人']!, lessThanOrEqualTo(1.0));
    });

    test('同音组成员不做上下文（含 extraVocabulary 混入的情形）', () {
      final homophones = HomophoneDictionary.fromJsonString(
        '{"groups": [["质朴", "智谱"]]}',
      );
      // 候选区间 [0,2) =「智谱」，右侧「公司」是正常上下文词
      final hits = ContextScorer.extractContextWords(
        '智谱公司',
        0,
        2,
        domain: _domain(),
        extraVocabulary: {'智谱'},
        homophones: homophones,
      );
      // 只提「公司」；「智谱」是要被裁决的候选词，即使混进词表也被排除
      expect(hits.map((h) => h.word), ['公司']);
    });
  });

  group('ContextScorer.score 评分', () {
    test('related 命中加分、conflict 命中减分（方案§7 示例量级）', () {
      final scores = _scores(
        ContextScorer.score(
          text: '质朴公司',
          matchStart: 0,
          matchEnd: 2,
          candidates: const ['质朴', '智谱'],
          domain: _domain(),
        ),
      );
      expect(scores['智谱'], closeTo(10, 0.001)); // 公司∈related
      expect(scores['质朴'], closeTo(-12, 0.001)); // 公司∈conflict
    });

    test('动态共现按 min(count,5)×2 计入，与静态分叠加', () {
      final scores = _scores(
        ContextScorer.score(
          text: '质朴公司',
          matchStart: 0,
          matchEnd: 2,
          candidates: const ['质朴', '智谱'],
          domain: _domain(),
          coStats: const {
            '智谱': {'公司': 3},
          },
        ),
      );
      expect(scores['智谱'], closeTo(10 + 3 * 2, 0.001));
    });

    test('动态共现计数封顶：count=99 只记 5×2=10 分', () {
      final scores = _scores(
        ContextScorer.score(
          text: '质朴公司',
          matchStart: 0,
          matchEnd: 2,
          candidates: const ['质朴', '智谱'],
          domain: _domain(),
          coStats: const {
            '智谱': {'公司': 99},
          },
        ),
      );
      expect(scores['智谱'], closeTo(10 + 10, 0.001));
    });

    test('用户词频弱先验：0.2×ln(1+f)，只做 tiebreaker（方案§12）', () {
      final scores = _scores(
        ContextScorer.score(
          text: '质朴公司',
          matchStart: 0,
          matchEnd: 2,
          candidates: const ['质朴', '智谱'],
          domain: _domain(),
          userFreq: const {'智谱': 99},
        ),
      );
      expect(scores['智谱'], closeTo(10 + 0.2 * 4.60517, 0.01));
    });

    test('reasons 输出可解释的计分明细（方案§7）', () {
      final scores = ContextScorer.score(
        text: '质朴公司',
        matchStart: 0,
        matchEnd: 2,
        candidates: const ['质朴', '智谱'],
        domain: _domain(),
      );
      final zhipu = scores.firstWhere((s) => s.word == '智谱');
      expect(zhipu.reasons, isNotEmpty);
      expect(zhipu.reasons.join(), contains('related'));
      final zhipo = scores.firstWhere((s) => s.word == '质朴');
      expect(zhipo.reasons.join(), contains('conflict'));
    });

    test('计分常数与 CorrectionConfig 一致（防调参后测试静默失真）', () {
      expect(CorrectionConfig.relatedHitScore, 10);
      expect(CorrectionConfig.conflictPenaltyScore, 12);
      expect(CorrectionConfig.cooccurrenceCountCap, 5);
      expect(CorrectionConfig.cooccurrenceScorePerCount, 2);
      expect(CorrectionConfig.userFrequencyWeight, 0.2);
      expect(CorrectionConfig.minScore, 7);
      expect(CorrectionConfig.minMargin, 15);
    });
  });
}
