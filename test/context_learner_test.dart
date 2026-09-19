import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/correction/context_learner.dart';
import 'package:shengwuji_app/correction/domain_dictionary.dart';
import 'package:shengwuji_app/correction/homophone_dictionary.dart';
import 'package:shengwuji_app/utils/correction_learner.dart';

/// 编辑学习分流测试：加载真实 asset 词库，验证方案§11/§18 的关键约束——
/// 同音组内的纠错对改道共现统计（绝不进盲替换表），普通对照旧进修正对表。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HomophoneDictionary homophones;
  late DomainDictionary domain;

  setUpAll(() async {
    homophones = HomophoneDictionary.fromJsonString(
      await rootBundle.loadString('assets/homophones.json'),
    );
    domain = DomainDictionary.fromJsonString(
      await rootBundle.loadString('assets/domain_words.json'),
    );
  });

  ContextLearnOutcome split(String original, String edited) {
    return ContextLearner.split(
      original,
      edited,
      homophones: homophones,
      domain: domain,
    );
  }

  group('ContextLearner.split 同音组纠错对分流', () {
    test('「质朴→智谱」进统计与词频，不进 regularPairs（防盲替换打架）', () {
      final outcome = split(
        '我最近在研究质朴公司的模型',
        '我最近在研究智谱公司的模型',
      );
      expect(outcome.regularPairs, isEmpty);
      expect(outcome.userWordBumps, ['智谱']);
      final bumps = outcome.statBumps.map((b) => '${b.source}×${b.context}');
      expect(bumps, containsAll(['智谱×研究', '智谱×公司', '智谱×模型']));
    });

    test('同音组反向编辑（用户撤销自动纠错）同样学给用户所选的词', () {
      final outcome = split('这个人很智谱', '这个人很质朴');
      expect(outcome.regularPairs, isEmpty);
      expect(outcome.userWordBumps, ['质朴']);
      expect(
        outcome.statBumps.map((b) => '${b.source}×${b.context}'),
        contains('质朴×这个人'),
      );
    });
  });

  group('ContextLearner.split 普通纠错对照旧走 correction_pairs', () {
    test('「饰品→视频」进 regularPairs，不产生统计', () {
      final outcome = split('饰品日志', '视频日志');
      expect(
        outcome.regularPairs,
        contains(const CorrectionPair(error: '饰品', correct: '视频')),
      );
      expect(outcome.statBumps, isEmpty);
      expect(outcome.userWordBumps, isEmpty);
    });

    test('删除对（删口水词）进 regularPairs', () {
      final outcome = split('今天心情很好嗯嗯', '今天心情很好');
      expect(outcome.regularPairs, hasLength(1));
      expect(outcome.regularPairs.first.correct, isEmpty);
      expect(outcome.statBumps, isEmpty);
    });

    test('纯新增不学（extract 返回空 → 三路全空）', () {
      final outcome = split('今天心情很好', '今天心情很好呀');
      expect(outcome.regularPairs, isEmpty);
      expect(outcome.statBumps, isEmpty);
      expect(outcome.userWordBumps, isEmpty);
    });

    test('没改 → 三路全空', () {
      final outcome = split('同一段话', '同一段话');
      expect(outcome.regularPairs, isEmpty);
      expect(outcome.statBumps, isEmpty);
      expect(outcome.userWordBumps, isEmpty);
    });

    test('双钥匙：注入分词器时整词钥匙与短核兜底钥匙都进 regularPairs', () {
      CorrectionLearner.wordSegmenter = (t) => t == '管管雎鸠' ? ['管管', '雎鸠'] : [t];
      try {
        final outcome = split('管管雎鸠', '关关雎鸠');
        expect(
          outcome.regularPairs,
          containsAll([
            const CorrectionPair(error: '管管雎鸠', correct: '关关雎鸠'),
            const CorrectionPair(error: '管管', correct: '关关'),
          ]),
        );
        expect(outcome.statBumps, isEmpty);
      } finally {
        CorrectionLearner.wordSegmenter = null;
      }
    });
  });

  group('ContextStatBump 模型', () {
    test('delta 默认 1，可表达负增量（预留）', () {
      expect(const ContextStatBump('智谱', '公司').delta, 1);
      expect(
        const ContextStatBump('智谱', '公司', delta: -1).delta,
        -1,
      );
    });
  });
}
