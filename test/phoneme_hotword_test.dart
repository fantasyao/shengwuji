// 音素热词单测：转换层（对拍 pypinyin 字典权威值）+ 匹配引擎（CapsWriter
// 同参行为）+ 双格式解析 + 短热词保险丝。
// 匹配用例的期望分数均为手算值（代价规则：同值 0 / 模糊音 0.5 / 声调差
// 0.5 / 非模糊音素 1，score = 1 - dist/热词语素数），注释里给出推导。
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/hotword/phoneme.dart';
import 'package:shengwuji_app/hotword/phoneme_corrector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await PinyinDict.ensureLoaded();
  });

  group('音素转换 getPhonemeInfo', () {
    test('中文字：声母+韵母+声调，词首词尾标记', () {
      final seq = getPhonemeInfo('中');
      expect(seq.map((p) => p.value).toList(), ['zh', 'ong', '1']);
      expect(seq[0].isWordStart, isTrue);
      expect(seq[0].isWordEnd, isFalse);
      expect(seq[1].isWordStart, isFalse);
      expect(seq[2].isWordEnd, isTrue);
      expect(seq[2].isTone, isTrue);
    });

    test('零声母字「安」：韵母顶词首（an1，字典权威值）', () {
      final seq = getPhonemeInfo('安');
      expect(seq.map((p) => p.value).toList(), ['an', '1']);
      expect(seq[0].isWordStart, isTrue);
    });

    test('多音字/轻声取 pypinyin 默认读音（与 CapsWriter 同参一致）', () {
      // 长默认 zhang3（「长江 chang2」场景需热词别名兜底）
      expect(getPhonemeInfo('长').map((p) => p.value), ['zh', 'ang', '3']);
      // 的 → de5 轻声记 5
      expect(getPhonemeInfo('的').map((p) => p.value), ['d', 'e', '5']);
    });

    test('英文逐字母拆分（ascii_split_char=True，CapsWriter 同款）', () {
      final seq = getPhonemeInfo('cloud');
      expect(seq.map((p) => p.value).toList(), ['c', 'l', 'o', 'u', 'd']);
      expect(seq.every((p) => p.lang == 'en'), isTrue);
      expect(seq.first.isWordStart, isTrue);
      expect(seq.last.isWordEnd, isTrue);
    });

    test('英数混合按 token 断开：字母/数字边界各自词首词尾', () {
      final seq = getPhonemeInfo('abc123');
      expect(seq.map((p) => p.value).toList(),
          ['a', 'b', 'c', '1', '2', '3']);
      expect(seq[2].lang, 'en');
      expect(seq[2].isWordEnd, isTrue); // abc token 结束
      expect(seq[3].lang, 'num');
      expect(seq[3].isWordStart, isTrue); // 123 token 开始
    });

    test('标点跳过但保留原文字符区间映射', () {
      final seq = getPhonemeInfo('你好,世界');
      final shi = seq.firstWhere((p) => p.value == 'sh');
      expect(shi.charStart, 3); // 你[0,1) 好[1,2) 逗号[2,3) 世[3,4)
      expect(shi.charEnd, 4);
    });

    test('字典无读音的生僻字整字兜底（CapsWriter 降级同款）', () {
      final seq = getPhonemeInfo('兙'); // 生成脚本 68 个无读音字之一
      expect(seq.length, 1);
      expect(seq[0].value, '兙');
      expect(seq[0].isWordStart, isTrue);
      expect(seq[0].isWordEnd, isTrue);
    });
  });

  group('模糊子串搜索 searchConstrained', () {
    test('完全匹配命中且区间正确', () {
      final hw = getPhonemeInfo('撒贝宁');
      final input = getPhonemeInfo('我非常喜欢撒贝宁说的新闻');
      final found = PhonemeCorrector.searchConstrained(hw, input, 0.9);
      expect(found, isNotEmpty);
      expect(found.first.$1, 1.0); // 同音同调 dist=0
      final (score, start, end) = found.first;
      expect(end - start, hw.length);
    });

    test('「西安」不会误伤「先」（跨音节边界不得匹配）', () {
      // 手算：x=x; i↔ian 非模糊 1; 声调 1↔1 同值 0; a/n/1 插入删位 3
      // dist=3, n=6 → score=0.5
      final hw = getPhonemeInfo('西安');
      final input = getPhonemeInfo('先');
      final found = PhonemeCorrector.searchConstrained(hw, input, 0.4);
      expect(found.where((f) => f.$1 >= 0.6), isEmpty);
    });
  });

  group('PhonemeCorrector.correct', () {
    PhonemeCorrector build(List<String> lines, {double threshold = 0.85}) {
      final c = PhonemeCorrector(threshold: threshold);
      c.updateHotwords(parseHotwordEntries(lines.join('\n')));
      return c;
    }

    test('发音近似替换：买当劳→麦当劳（dist=0.5/9 → 0.944 ≥0.85）', () {
      final c = build(['麦当劳']);
      final r = c.correct('我想吃买当劳');
      expect(r.text, '我想吃麦当劳');
      expect(r.matches, hasLength(1));
      expect(r.matches.first.score, closeTo(0.944, 0.01));
    });

    test('多处替换：买当劳和啃得鸡→麦当劳和肯德基', () {
      final c = build(['麦当劳', '肯德基']);
      final r = c.correct('我想吃买当劳和啃得鸡');
      expect(r.text, '我想吃麦当劳和肯德基');
      expect(r.matches, hasLength(2));
    });

    test('阈值分流：撒贝你→撒贝宁 0.833，@0.7 替换、@0.85 仅提示', () {
      // 手算：韵母 ing↔i 非模糊 1 + 声调 2↔3 0.5 → dist=1.5, n=9 → 0.833
      final lenient = build(['撒贝宁'], threshold: 0.7);
      final lenientR = lenient.correct('我喜欢撒贝你');
      expect(lenientR.text, '我喜欢撒贝宁');

      final strict = build(['撒贝宁']); // 默认 0.85
      final strictR = strict.correct('我喜欢撒贝你');
      expect(strictR.text, '我喜欢撒贝你'); // 不动原文
      expect(strictR.matches, isEmpty);
      expect(strictR.similars, hasLength(1));
      expect(strictR.similars.first.hotword, '撒贝宁');
    });

    test('老热词自动音素化：次我→次卧（热词「次握 = 次卧」0.917）', () {
      final c = build(['次握 = 次卧']);
      final r = c.correct('主卧旁边的次我');
      expect(r.text, '主卧旁边的次卧');
    });

    test('别名机制：识别 cloud 替换为 Claude（别名组 1.0 分优先）', () {
      final c = build(['Claude | cloud | 克劳德']);
      final r = c.correct('我很喜欢 cloud');
      expect(r.text, '我很喜欢 Claude');
      expect(r.matches, hasLength(1));
      expect(r.matches.first.hotword, 'Claude');
    });

    test('短热词保险丝：单字热词（3 音素 <4）过阈值也只提示不替换', () {
      // 手算：猫 mao1 vs 毛 mao2 仅声调差 0.5 → dist=0.5, n=3 → 0.833
      final c = build(['猫'], threshold: 0.7);
      final r = c.correct('我家毛毛');
      expect(r.text, '我家毛毛');
      expect(r.matches, isEmpty);
      expect(r.similars.map((m) => m.hotword), contains('猫'));
    });

    test('两字热词（6 音素 ≥4）不受保险丝影响', () {
      final c = build(['次卧'], threshold: 0.7);
      final r = c.correct('在次我睡觉');
      expect(r.text, '在次卧睡觉');
    });

    test('原地匹配只占位不替换', () {
      final c = build(['麦当劳']);
      final r = c.correct('麦当劳真好吃');
      expect(r.text, '麦当劳真好吃');
      expect(r.matches, isEmpty);
    });

    test('冲突解决：分数高的热词赢，重叠区间丢弃低分', () {
      // 「牢和」1.0 > 「麦当劳」0.944，且区间 [2,4) 与 [0,3) 重叠
      final c = build(['麦当劳', '牢和']);
      final r = c.correct('买当劳和啃得鸡');
      expect(r.matches.map((m) => m.hotword), ['牢和']);
      expect(r.text.contains('牢和'), isTrue);
      // 低分被挤掉的进 similars 供用户知晓
      expect(r.similars.map((m) => m.hotword), contains('麦当劳'));
    });

    test('相似中间带收窄：月清→乐清 0.667，@0.85 低于新提示线 0.75 不提示不替换', () {
      // 手算：y↔l 非模糊 1 + ue↔e 非模糊 1 + 声调同 0 → dist=2, n=6 → 0.667
      // similarGap 0.25→0.10（用户要求提示线 0.75）后，0.667 连提示都不再进
      final c = build(['乐清']);
      final r = c.correct('我在月清上班');
      expect(r.text, '我在月清上班');
      expect(r.similars, isEmpty);
    });

    test('提示带下沿：撒贝你→撒贝宁 0.833 ≥ 新提示线 0.75，@0.85 仍提示', () {
      final c = build(['撒贝宁']); // 默认 0.85，similar = 0.85 - 0.10 = 0.75
      final r = c.correct('我喜欢撒贝你');
      expect(r.similars, hasLength(1));
      expect(r.similars.first.score, closeTo(0.833, 0.01));
    });

    test('无热词/空文本原样返回', () {
      final c = build(['麦当劳']);
      expect(c.correct('').text, '');
      final empty = PhonemeCorrector();
      empty.updateHotwords([]);
      expect(empty.correct('随便什么').text, '随便什么');
    });
  });

  group('parseHotwordEntries 双格式解析', () {
    test('老格式登记字面对 + 音素条目', () {
      final literals = <String, String>{};
      final entries = parseHotwordEntries(
        '次握 = 次卧\n',
        onLiteralPair: (w, r) => literals[w] = r,
      );
      expect(literals, {'次握': '次卧'});
      expect(entries.single.target, '次卧');
      expect(entries.single.aliases, ['次握']);
    });

    test('新格式：首个为目标其余为别名，不做字面替换', () {
      final literals = <String, String>{};
      final entries = parseHotwordEntries(
        'Claude | cloud | 克劳德\n',
        onLiteralPair: (w, r) => literals[w] = r,
      );
      expect(literals, isEmpty);
      expect(entries.single.target, 'Claude');
      expect(entries.single.aliases, ['cloud', '克劳德']);
    });

    test('注释行/空行/非法行跳过', () {
      final entries = parseHotwordEntries(
        '# 注释 = 注释\n\nhello = world = oops\n| 只有别名\n目标 | ',
      );
      expect(entries, isEmpty);
    });

    test('基础格式：整行一个热词（CapsWriter hot.txt 默认，无别名）', () {
      final entries = parseHotwordEntries('麦当劳\n撒贝宁');
      expect(entries, hasLength(2));
      expect(entries[0].target, '麦当劳');
      expect(entries[0].aliases, isEmpty);
    });
  });

  test('阈值配置脏值回落默认', () {
    expect(PhonemeHotwordConfig.normalizeThreshold(0.85), 0.85);
    expect(PhonemeHotwordConfig.normalizeThreshold(0.5),
        PhonemeHotwordConfig.defaultThreshold);
    expect(PhonemeHotwordConfig.normalizeThreshold(1.5),
        PhonemeHotwordConfig.defaultThreshold);
  });
}
