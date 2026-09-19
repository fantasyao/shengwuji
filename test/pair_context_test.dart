import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/correction/pair_context.dart';
import 'package:shengwuji_app/utils/correction_learner.dart';

void main() {
  group('PairContextGate.keyOf / groupByPair', () {
    test('分隔符防撞 key：ab→c 与 a→bc 不是同一个 key', () {
      expect(PairContextGate.keyOf('ab', 'c'), isNot(PairContextGate.keyOf('a', 'bc')));
    });

    test('groupByPair 按对分组', () {
      final records = [
        const PairContextRecord(error: '影视', correct: '隐私', leftContext: '互联网', rightContext: '可控'),
        const PairContextRecord(error: '影视', correct: '隐私', leftContext: '数据', rightContext: '安全'),
        const PairContextRecord(error: '饰品', correct: '视频', leftContext: '打开', rightContext: '日志'),
      ];
      final grouped = PairContextGate.groupByPair(records);
      expect(grouped[PairContextGate.keyOf('影视', '隐私')]!.length, 2);
      expect(grouped[PairContextGate.keyOf('饰品', '视频')]!.length, 1);
    });
  });

  group('PairContextGate.extract 语境档案抽取', () {
    test('中段出现 → 记录左右各 ≤4 个词字符', () {
      final records = PairContextGate.extract('互联网影视可控', [
        const CorrectionPair(error: '影视', correct: '隐私'),
      ]);
      expect(records, hasLength(1));
      expect(records.first.leftContext, '互联网');
      expect(records.first.rightContext, '可控');
    });

    test('贴近开头：左侧为空，靠右侧判定可用', () {
      final records = PairContextGate.extract('影视可控的', [
        const CorrectionPair(error: '影视', correct: '隐私'),
      ]);
      expect(records, hasLength(1));
      expect(records.first.leftContext, isEmpty);
      expect(records.first.rightContext, '可控的');
    });

    test('标点/空格被剥离，不占字符额度', () {
      final records = PairContextGate.extract('互联网，影视。可控', [
        const CorrectionPair(error: '影视', correct: '隐私'),
      ]);
      expect(records, hasLength(1));
      expect(records.first.leftContext, '互联网');
      expect(records.first.rightContext, '可控');
    });

    test('裸片段（两侧都没有邻接词字符）→ 不产出档案', () {
      final records = PairContextGate.extract('影视', [
        const CorrectionPair(error: '影视', correct: '隐私'),
      ]);
      expect(records, isEmpty);
    });

    test('同一片段多次出现 → 多条档案', () {
      final records = PairContextGate.extract('影视一，影视二', [
        const CorrectionPair(error: '影视', correct: '隐私'),
      ]);
      expect(records, hasLength(2));
    });

    test('删除对（correct 为空）同样记录语境', () {
      final records = PairContextGate.extract('今天嗯嗯去买菜', [
        const CorrectionPair(error: '嗯嗯', correct: ''),
      ]);
      expect(records, hasLength(1));
      expect(records.first.correct, isEmpty);
      expect(records.first.leftContext, '今天');
      expect(records.first.rightContext, '去买菜');
    });

    test('错误片段不在原文（防御）→ 无档案', () {
      final records = PairContextGate.extract('没有这个片段', [
        const CorrectionPair(error: '影视', correct: '隐私'),
      ]);
      expect(records, isEmpty);
    });

    test('ASCII 折叠小写', () {
      final records = PairContextGate.extract('用GLM影视可控', [
        const CorrectionPair(error: '影视', correct: '隐私'),
      ]);
      expect(records.first.leftContext, '用glm');
    });
  });

  group('PairContextGate.shouldPrompt 语境门控', () {
    final pair = const CorrectionPair(error: '影视', correct: '隐私');
    // 模拟从「互联网影视可控」学到的档案
    final learned = PairContextGate.extract('互联网影视可控', [pair]);

    test('无语境档案（老数据/导入/裸片段学到）→ 照旧提示', () {
      expect(PairContextGate.shouldPrompt('今晚看的影视不错', pair, const []), isTrue);
    });

    test('同句重现 → 提示', () {
      expect(
        PairContextGate.shouldPrompt('互联网影视可控', pair, learned),
        isTrue,
      );
    });

    test('左侧公共后缀吻合（存储短、当前长）→ 提示', () {
      // 当前左侧「在互联网」与档案「互联网」公共后缀 3
      expect(
        PairContextGate.shouldPrompt('我在互联网影视安全', pair, learned),
        isTrue,
      );
    });

    test('仅右侧吻合 → 提示', () {
      expect(
        PairContextGate.shouldPrompt('数据影视可控', pair, learned),
        isTrue,
      );
    });

    test('语境完全不同 → 不提示（本功能要消灭的误提示）', () {
      expect(
        PairContextGate.shouldPrompt('今晚看的影视不错', pair, learned),
        isFalse,
      );
      expect(
        PairContextGate.shouldPrompt('影视公司投的新片', pair, learned),
        isFalse,
      );
    });

    test('裸片段撞上有档案的对 → 不提示（无上下文时提示纯属猜测）', () {
      expect(PairContextGate.shouldPrompt('影视', pair, learned), isFalse);
    });

    test('多条档案任一吻合 → 提示', () {
      final many = PairContextGate.extract('互联网影视可控', [pair]) +
          PairContextGate.extract('数据影视安全', [pair]);
      expect(
        PairContextGate.shouldPrompt('数据影视安全', pair, many),
        isTrue,
      );
      expect(
        PairContextGate.shouldPrompt('互联网影视可控', pair, many),
        isTrue,
      );
      expect(
        PairContextGate.shouldPrompt('随便看看影视而已', pair, many),
        isFalse,
      );
    });

    test('同一文本多个出现位置，任一位置语境吻合 → 提示', () {
      expect(
        PairContextGate.shouldPrompt('影视不错，互联网影视可控', pair, learned),
        isTrue,
      );
    });

    test('错误片段不在文本中（防御）→ 不提示', () {
      expect(
        PairContextGate.shouldPrompt('没有命中片段', pair, learned),
        isFalse,
      );
    });

    test('英文混排场景：co林兰→coding plan 的左侧锚定', () {
      final enPair = const CorrectionPair(error: 'co林兰', correct: 'coding plan');
      final enLearned = PairContextGate.extract('我在用co林兰写代码', [enPair]);
      expect(enLearned, hasLength(1));
      expect(enLearned.first.leftContext, '我在用');
      expect(enLearned.first.rightContext, '写代码');
      // 同款句式重现 → 提示
      expect(
        PairContextGate.shouldPrompt('还在用co林兰做原型', enPair, enLearned),
        isTrue,
      );
      // 完全不同语境 → 不提示
      expect(
        PairContextGate.shouldPrompt('这个co林兰是什么意思', enPair, enLearned),
        isFalse,
      );
    });

    test('词字符单字撞车被 2 字符门槛挡掉', () {
      // 档案左侧「今天的」右侧「真不错」；当前左侧「他说的」只有「的」1 字符
      // 沾边、右侧「啊呀」完全不沾 → 不提示
      final todayPair = const CorrectionPair(error: '嗯嗯', correct: '');
      final todayLearned = PairContextGate.extract('今天的嗯嗯真不错', [todayPair]);
      expect(
        PairContextGate.shouldPrompt('他说的嗯嗯啊呀', todayPair, todayLearned),
        isFalse,
      );
      // 右侧「真不错」吻合（≥2）→ 仍提示（单侧足够）
      expect(
        PairContextGate.shouldPrompt('昨天的嗯嗯真不错', todayPair, todayLearned),
        isTrue,
      );
    });
  });
}
