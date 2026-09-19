import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/correction/context_corrector.dart';
import 'package:shengwuji_app/correction/domain_dictionary.dart';
import 'package:shengwuji_app/correction/homophone_dictionary.dart';

/// 端到端验收：加载**真实打包的 asset 词库**（assets/homophones.json +
/// assets/domain_words.json），用方案§20 的「智谱/质朴」用例集做规格——
/// 「应改」用例全部自动替换、「防误改」用例全部保持原文。
/// DB 统计以内存 Map 注入（测试环境无 sqflite）。
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

  CorrectionDeps deps({
    Map<String, Map<String, int>> coStats = const {},
    Map<String, int> userFreq = const {},
  }) {
    return CorrectionDeps(
      homophones: homophones,
      domain: domain,
      coStats: coStats,
      userFreq: userFreq,
    );
  }

  group('HomophoneDictionary 解析与匹配', () {
    test('asset 词库能解析出种子同音组', () {
      expect(homophones.containsWord('智谱'), isTrue);
      expect(homophones.containsWord('质朴'), isTrue);
      expect(homophones.containsWord('深度求索'), isTrue);
      expect(homophones.containsWord('深度搜索'), isTrue);
      expect(homophones.containsWord('成都'), isFalse);
    });

    test('isSameGroup：同组 true，跨组/未收录/同词 false', () {
      expect(homophones.isSameGroup('质朴', '智谱'), isTrue);
      expect(homophones.isSameGroup('质朴', '深度求索'), isFalse);
      expect(homophones.isSameGroup('成都', '智谱'), isFalse);
      expect(homophones.isSameGroup('质朴', '质朴'), isFalse);
    });

    test('findMatches 返回命中区间与全组候选', () {
      final matches = homophones.findMatches('我最近在研究质朴');
      expect(matches, hasLength(1));
      expect(matches.first.start, 6);
      expect(matches.first.end, 8);
      expect(matches.first.matchedWord, '质朴');
      expect(matches.first.candidates, containsAll(['质朴', '智谱']));
    });

    test('findMatches 同文多次命中逐一返回', () {
      final matches = homophones.findMatches('智谱和质朴');
      expect(matches.map((m) => m.matchedWord), ['智谱', '质朴']);
    });

    test('findMatches 英文组成员大小写不敏感且保留原形', () {
      final h = HomophoneDictionary.fromJsonString(
        '{"groups": [["AI", "爱"]]}',
      );
      final matches = h.findMatches('ai很强');
      expect(matches, hasLength(1));
      expect(matches.first.matchedWord, 'ai'); // 原文原形
      expect(matches.first.candidates, ['AI', '爱']);
    });
  });

  group('DomainDictionary 解析', () {
    test('asset 词库能解析且查词大小写不敏感', () {
      expect(domain.lookup('智谱'), isNotNull);
      expect(domain.lookup('智谱')!.isRelated('公司'), isTrue);
      expect(domain.lookup('智谱')!.isRelated('glm'), isTrue);
      expect(domain.lookup('质朴')!.isConflict('公司'), isTrue);
      expect(domain.vocabulary, contains('chatglm'));
    });
  });

  group('端到端验收：应识别成「智谱」（喂 SenseVoice 的错误变体「质朴」）', () {
    const cases = <String, String>{
      '质朴公司': '智谱公司',
      '质朴AI': '智谱AI',
      '质朴的GLM模型': '智谱的GLM模型',
      '质朴发布了新的模型': '智谱发布了新的模型',
      '我最近在研究质朴': '我最近在研究智谱',
      '质朴的大模型': '智谱的大模型',
    };
    for (final entry in cases.entries) {
      test('「${entry.key}」→「${entry.value}」', () {
        final result = ContextCorrector.correctWith(entry.key, deps());
        expect(result.text, entry.value);
        expect(result.applied, hasLength(1));
        expect(result.applied.first.from, '质朴');
        expect(result.applied.first.to, '智谱');
      });
    }
  });

  group('端到端验收：应识别成「质朴」（喂错误变体「智谱」）', () {
    const cases = <String, String>{
      '这个人很智谱': '这个人很质朴',
      '他的性格非常智谱': '他的性格非常质朴',
      '这个女孩看起来很智谱': '这个女孩看起来很质朴',
      '他为人智谱真诚': '他为人质朴真诚',
      '我喜欢这种智谱的感觉': '我喜欢这种质朴的感觉',
    };
    for (final entry in cases.entries) {
      test('「${entry.key}」→「${entry.value}」', () {
        final result = ContextCorrector.correctWith(entry.key, deps());
        expect(result.text, entry.value);
        expect(result.applied.first.to, '质朴');
      });
    }
  });

  group('端到端验收：防误改（宁漏勿错，方案§13）', () {
    const keepCases = <String>[
      // 无上下文：没有证据不动
      '质朴',
      '智谱',
      // 「同意/通义」组：日常语义无 AI 上下文，绝不翻成品牌词
      '我同意你的看法',
      '大家都同意用AI',
      // 原文本来就对：赢家=原词，no-op
      '他用深度搜索查资料',
      '这个人性格非常质朴',
      '我在用智谱的模型',
      // 与词库无关的普通文本直通
      '今天我去了成都，然后买了一些水果',
    ];
    for (final text in keepCases) {
      test('「$text」保持原文', () {
        final result = ContextCorrector.correctWith(text, deps());
        expect(result.text, text);
        expect(result.applied, isEmpty);
      });
    }
  });

  group('端到端验收：深度求索/深度搜索 与 通义 组', () {
    test('AI 语境下「深度搜索」应改回「深度求索」', () {
      final result = ContextCorrector.correctWith(
        '深度搜索发布了新的推理模型',
        deps(),
      );
      expect(result.text, '深度求索发布了新的推理模型');
    });

    test('强品牌语境下「同意」应改回「通义」', () {
      final result = ContextCorrector.correctWith('我用同意千问写代码', deps());
      expect(result.text, '我用通义千问写代码');
    });
  });

  group('阈值门控（方案§13：MIN_SCORE 与 MIN_MARGIN 双闸）', () {
    test('赢家 0 分（纯负面证据抬差距）不替换', () {
      final d = CorrectionDeps(
        homophones: homophones,
        domain: DomainDictionary.fromJsonString('''
{
  "智谱": {"related": [], "conflict": []},
  "质朴": {"related": [], "conflict": ["公司"]}
}
'''),
      );
      final result = ContextCorrector.correctWith('质朴公司', d);
      expect(result.text, '质朴公司');
    });

    test('两候选得分打平（margin=0）不替换', () {
      final d = CorrectionDeps(
        homophones: homophones,
        domain: DomainDictionary.fromJsonString('''
{
  "智谱": {"related": ["公司"], "conflict": []},
  "质朴": {"related": ["公司"], "conflict": []}
}
'''),
      );
      final result = ContextCorrector.correctWith('质朴公司', d);
      expect(result.text, '质朴公司');
    });

    test('动态共现达到双证据时可以翻案（静态词表里没有的上下文词）', () {
      final result = ContextCorrector.correctWith(
        '质朴芯片融资进展',
        deps(
          coStats: {
            '智谱': {'芯片': 5, '融资': 5},
          },
        ),
      );
      expect(result.text, '智谱芯片融资进展');
      expect(result.applied.first.to, '智谱');
    });
  });

  group('多次命中逐位置独立处理', () {
    test('同文两处「质朴」分别按各自上下文替换', () {
      final result = ContextCorrector.correctWith(
        '质朴公司的质朴发布会',
        deps(),
      );
      expect(result.text, '智谱公司的智谱发布会');
      expect(result.applied, hasLength(2));
    });
  });
}
