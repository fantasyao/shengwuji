import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/utils/search_command_detector.dart';

/// 语音搜索指令检测器的单测（判定规则见库注释）。
void main() {
  group('SearchCommandDetector.detect', () {
    test('「搜索」开头命中并提取关键词', () {
      final r = SearchCommandDetector.detect('搜索明天天气');
      expect(r.isSearchCommand, isTrue);
      expect(r.keyword, '明天天气');
    });

    test('「搜一下」开头命中并提取关键词', () {
      final r = SearchCommandDetector.detect('搜一下附近的奶茶店');
      expect(r.isSearchCommand, isTrue);
      expect(r.keyword, '附近的奶茶店');
    });

    test('「搜索一下」先长后短匹配，关键词不留「一下」残留', () {
      final r = SearchCommandDetector.detect('搜索一下明天天气');
      expect(r.isSearchCommand, isTrue);
      expect(r.keyword, '明天天气');
    });

    test('触发词不在开头不命中', () {
      expect(SearchCommandDetector.detect('我去搜索一下明天天气').isSearchCommand, isFalse);
      expect(SearchCommandDetector.detect('帮我搜索苹果').isSearchCommand, isFalse);
    });

    test('只有触发词没有关键词不命中', () {
      expect(SearchCommandDetector.detect('搜索').isSearchCommand, isFalse);
      expect(SearchCommandDetector.detect('搜索一下').isSearchCommand, isFalse);
      expect(SearchCommandDetector.detect('搜一下').isSearchCommand, isFalse);
    });

    test('剥离触发词后只剩标点/空白不命中', () {
      expect(SearchCommandDetector.detect('搜索一下，').isSearchCommand, isFalse);
      expect(SearchCommandDetector.detect('搜索 。').isSearchCommand, isFalse);
    });

    test('关键词首尾中英文标点与空白被清理', () {
      final r = SearchCommandDetector.detect('搜索，明天天气怎么样？');
      expect(r.isSearchCommand, isTrue);
      expect(r.keyword, '明天天气怎么样');

      final r2 = SearchCommandDetector.detect('搜索 苹果!');
      expect(r2.isSearchCommand, isTrue);
      expect(r2.keyword, '苹果');
    });

    test('整体首尾空白先 trim 再判定', () {
      final r = SearchCommandDetector.detect('  搜索一下明天的航班  ');
      expect(r.isSearchCommand, isTrue);
      expect(r.keyword, '明天的航班');
    });

    test('空串与纯空白不命中', () {
      expect(SearchCommandDetector.detect('').isSearchCommand, isFalse);
      expect(SearchCommandDetector.detect('   ').isSearchCommand, isFalse);
    });

    test('普通句子不命中', () {
      expect(SearchCommandDetector.detect('钥匙放在客厅').isSearchCommand, isFalse);
      expect(SearchCommandDetector.detect('今天搜到一家不错的店').isSearchCommand, isFalse);
    });
  });

  group('SearchCommandDetector.detect 自定义触发词', () {
    test('用自定义触发词匹配，默认触发词不再生效', () {
      final r = SearchCommandDetector.detect(
        '查一下明天天气',
        triggers: ['查一下'],
      );
      expect(r.isSearchCommand, isTrue);
      expect(r.keyword, '明天天气');

      expect(
        SearchCommandDetector.detect('搜索明天天气', triggers: ['查一下'])
            .isSearchCommand,
        isFalse,
      );
    });

    test('调用方传入乱序触发词时内部按先长后短裁决', () {
      final r = SearchCommandDetector.detect(
        '搜索一下明天的航班',
        triggers: ['搜索', '搜索一下'],
      );
      expect(r.isSearchCommand, isTrue);
      expect(r.keyword, '明天的航班');
    });

    test('自定义触发词剥离后无关键词不命中', () {
      expect(
        SearchCommandDetector.detect('查一下，', triggers: ['查一下']).isSearchCommand,
        isFalse,
      );
    });

    test('triggers 为空列表时回落默认白名单', () {
      final r = SearchCommandDetector.detect('搜索明天天气', triggers: []);
      expect(r.isSearchCommand, isTrue);
      expect(r.keyword, '明天天气');
    });
  });

  group('SearchCommandDetector.normalize', () {
    test('按换行 / 逗号 / 顿号拆分并 trim、去空（按长度降序）', () {
      expect(
        SearchCommandDetector.normalize('  搜一下 \n\n搜索,，、搜索一下  '),
        ['搜索一下', '搜一下', '搜索'],
      );
    });

    test('去重且按长度降序（先长后短）', () {
      expect(
        SearchCommandDetector.normalize('搜索\n搜索一下\n搜索\n搜一下'),
        ['搜索一下', '搜一下', '搜索'],
      );
    });

    test('空串 / 纯分隔符 / 纯空白返回空列表', () {
      expect(SearchCommandDetector.normalize(''), isEmpty);
      expect(SearchCommandDetector.normalize(' ,，、\n\n '), isEmpty);
    });
  });

  group('SearchCommandDetector.parseTriggers', () {
    test('null / 空串 / 纯空白回落默认白名单', () {
      expect(SearchCommandDetector.parseTriggers(null), kDefaultVoiceSearchTriggers);
      expect(SearchCommandDetector.parseTriggers(''), kDefaultVoiceSearchTriggers);
      expect(SearchCommandDetector.parseTriggers('  \n '), kDefaultVoiceSearchTriggers);
    });

    test('有内容时返回规范化结果（去重 + 先长后短）', () {
      expect(
        SearchCommandDetector.parseTriggers('搜索\n查一下\n搜索'),
        ['查一下', '搜索'],
      );
    });
  });
}
