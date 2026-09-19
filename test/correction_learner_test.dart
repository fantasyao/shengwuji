import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/utils/correction_learner.dart';

void main() {
  _codecTests();

  group('CorrectionLearner.extract 片段级差异抽取', () {
    test('识别「饰品日志-」改成「视频日志」→ 学到「饰品→视频」，标点删除不学', () {
      final pairs = CorrectionLearner.extract('饰品日志-', '视频日志');
      expect(pairs, contains(const CorrectionPair(error: '饰品', correct: '视频')));
      // 「-」是纯标点删除，不值得学（下次出现不该提示删所有「-」）
      expect(pairs.where((p) => p.correct.isEmpty), isEmpty);
    });

    test('「明→后」单字错吸收相邻相同上下文 →「明天→后天」', () {
      final pairs = CorrectionLearner.extract('明天去超市', '后天去超市');
      expect(pairs, contains(const CorrectionPair(error: '明天', correct: '后天')));
    });

    test('句中单字替换两侧各吸一个上下文：体直给→体脂给（2026-09-14 真机案例：'
        '识别「体脂率」成「体直给」，用户只点光标改一个字 直→脂）', () {
      final pairs = CorrectionLearner.extract(
        '这种情况下能把我的体直给降下去么？',
        '这种情况下能把我的体脂给降下去么？',
      );
      // 旧逻辑只吸右侧学到「直给→脂给」——钥匙撞上真实词「直给」；
      // 两侧吸收后钥匙是完整错误串「体直给」，不会误伤
      expect(
        pairs,
        contains(const CorrectionPair(error: '体直给', correct: '体脂给')),
      );
      expect(pairs, hasLength(1));
    });

    test('句中单字替换左邻有字时两侧都吸：「看明天→看后天」', () {
      final pairs = CorrectionLearner.extract('看明天去公园', '看后天去公园');
      expect(pairs, contains(const CorrectionPair(error: '看明天', correct: '看后天')));
    });

    test('完全没改 → 不学习', () {
      expect(CorrectionLearner.extract('今天心情很好', '今天心情很好'), isEmpty);
    });

    test('原文为空（手动新建笔记）→ 不学习', () {
      expect(CorrectionLearner.extract('', '随手记的内容'), isEmpty);
    });

    test('纯新增内容（没有错误片段可匹配）→ 不学习', () {
      expect(CorrectionLearner.extract('今天心情很好', '今天心情很好哈哈'), isEmpty);
    });

    test('删除口水词「嗯嗯」→ 学到删除对', () {
      final pairs = CorrectionLearner.extract('嗯嗯今天买了苹果', '今天买了苹果');
      expect(pairs, contains(const CorrectionPair(error: '嗯嗯', correct: '')));
    });

    test('整句重写（相同字符占比过低）→ 不学习', () {
      final pairs = CorrectionLearner.extract('记得明天下午三点去开会', '买牛奶鸡蛋面包');
      expect(pairs, isEmpty);
    });

    test('多字替换拆成片段：钥匙扣在抽屉 → 钥匙在抽屉里', () {
      final pairs = CorrectionLearner.extract('钥匙扣在抽屉', '钥匙在抽屉里');
      // 单字删除「扣」吸收相邻 keep「在」做上下文 → 学到「扣在→在」（净效果=删扣）；
      // 结尾「里」是纯插入，没有错误片段可匹配，不学习
      expect(pairs, [const CorrectionPair(error: '扣在', correct: '在')]);
    });

    test('串首单字替换吸收公共后缀做上下文 →「展里→战里」', () {
      final pairs = CorrectionLearner.extract('展里有人', '战里有人');
      // 差异在串首，「里有人」是公共后缀被trim；虚拟 keep 接回「里」做上下文，
      // 避免学出到处误伤的单字对
      expect(pairs, [const CorrectionPair(error: '展里', correct: '战里')]);
    });

    test('替换段紧邻删除段并成一个片段：nike→NB 学到整词替换', () {
      final pairs = CorrectionLearner.extract('nike鞋在门口', 'NB鞋在门口');
      // 若拆开处理会学出「ni→NB」+「删 ke」两条错对，并段后才是用户真实意图
      expect(pairs, [const CorrectionPair(error: 'nike', correct: 'NB')]);
    });

    test('纯插入被守卫拦住（吸收上下文也不伪装成替换对）', () {
      expect(CorrectionLearner.extract('好的', '好的呀'), isEmpty);
    });

    test('超长差异区（整段重写）→ 不学习', () {
      final original = '甲' * 600;
      final edited = '乙' * 600;
      expect(CorrectionLearner.extract(original, edited), isEmpty);
    });
  });

  group('CorrectionLearner.applyCorrections 一键修正替换', () {
    test('替换所有命中片段', () {
      final pairs = [
        const CorrectionPair(error: '饰品', correct: '视频'),
        const CorrectionPair(error: '日志', correct: '日记'),
      ];
      expect(
        CorrectionLearner.applyCorrections('饰品日志和饰品清单', pairs),
        '视频日记和视频清单',
      );
    });

    test('长错误片段优先替换，避免短片段抢先破坏长匹配', () {
      final pairs = [
        const CorrectionPair(error: '饰品', correct: '首饰'),
        const CorrectionPair(error: '饰品盒', correct: '首饰盒X'),
      ];
      // 「饰品盒」应整体替换，而不是先被「饰品→首饰」拆掉
      expect(CorrectionLearner.applyCorrections('饰品盒里', pairs), '首饰盒X里');
    });

    test('删除对：命中片段被移除', () {
      final pairs = [const CorrectionPair(error: '嗯嗯', correct: '')];
      expect(CorrectionLearner.applyCorrections('嗯嗯好的', pairs), '好的');
    });

    test('空文本安全', () {
      expect(CorrectionLearner.applyCorrections('', const []), '');
    });
  });

  group('CorrectionLearner.extract 分词补全取词（wordSegmenter 注入）', () {
    setUp(() => CorrectionLearner.wordSegmenter = null);
    tearDown(() => CorrectionLearner.wordSegmenter = null);

    /// 造一个假分词器：token 序列拼接必须等于原文（与 jieba 行为一致）
    void injectSegmenter(List<String> Function(String) tokens) {
      CorrectionLearner.wordSegmenter = tokens;
    }

    test('错误字在多字 token 内 → 补全到完整词：「体直给」改「直」学到「体直→体脂」', () {
      injectSegmenter(
        (t) => t == '能把我的体直给降下去么'
            ? ['能把', '我的', '体直', '给', '降', '下去', '么']
            : [t],
      );
      final pairs = CorrectionLearner.extract(
        '能把我的体直给降下去么',
        '能把我的体脂给降下去么',
      );
      expect(pairs, contains(const CorrectionPair(error: '体直', correct: '体脂')));
      // 不再学「体直给→体脂给」这种把下个待改字带进钥匙的半截对
      expect(
        pairs,
        isNot(contains(const CorrectionPair(error: '体直给', correct: '体脂给'))),
      );
    });

    test('整串是一个 token 时同样补全到该 token', () {
      injectSegmenter(
        (t) => t == '能把我的体直给降下去么'
            ? ['能把', '我的', '体直给', '降', '下去', '么']
            : [t],
      );
      final pairs = CorrectionLearner.extract(
        '能把我的体直给降下去么',
        '能把我的体脂给降下去么',
      );
      expect(pairs, contains(const CorrectionPair(error: '体直给', correct: '体脂给')));
    });

    test('AA 叠词钥匙并入紧邻内容词：「管管雎鸠」改「管」学到四字整词', () {
      injectSegmenter(
        (t) => t == '管管雎鸠' ? ['管管', '雎鸠'] : [t],
      );
      final pairs = CorrectionLearner.extract('管管雎鸠', '关关雎鸠');
      expect(
        pairs,
        contains(const CorrectionPair(error: '管管雎鸠', correct: '关关雎鸠')),
      );
    });

    test('非叠词补全后不并邻词：「明天去超市」改「明」仍是「明天→后天」', () {
      injectSegmenter(
        (t) => t == '明天去超市' ? ['明天', '去', '超市'] : [t],
      );
      final pairs = CorrectionLearner.extract('明天去超市', '后天去超市');
      expect(pairs, contains(const CorrectionPair(error: '明天', correct: '后天')));
      expect(
        pairs,
        isNot(contains(const CorrectionPair(error: '明天去', correct: '后天去'))),
      );
    });

    test('单字词补全后仍不足 2 字 → 回退固定吸收：「他」错学成带上下文对', () {
      injectSegmenter(
        (t) => t == '见到他很高兴' ? ['见到', '他', '很高兴'] : [t],
      );
      final pairs = CorrectionLearner.extract('见到他很高兴', '见到她很高兴');
      // 分词补全到单字词「他」后仍 1 字 → 两侧各吸一个 keep 凑区分度
      expect(pairs, contains(const CorrectionPair(error: '到他很', correct: '到她很')));
    });

    test('叠词无紧邻内容词（紧邻标点被过滤）→ 只学叠词', () {
      injectSegmenter(
        (t) => t == '管管，慢点' ? ['管管', '，', '慢点'] : [t],
      );
      final pairs = CorrectionLearner.extract('管管，慢点', '关关，慢点');
      expect(pairs, contains(const CorrectionPair(error: '管管', correct: '关关')));
    });

    test('叠词紧邻超长词（并后超钥匙上限）→ 只学叠词', () {
      const longWord = '一二三四五六七八九十';
      injectSegmenter(
        (t) => t == '管管$longWord' ? ['管管', longWord] : [t],
      );
      final pairs = CorrectionLearner.extract('管管$longWord', '关关$longWord');
      expect(pairs, contains(const CorrectionPair(error: '管管', correct: '关关')));
    });

    test('token 拼接不等于原文（非法分词结果）→ 回退固定吸收', () {
      injectSegmenter((t) => t == '体直给' ? ['体直'] : [t]); // 丢了「给」
      final pairs = CorrectionLearner.extract('体直给', '体脂给');
      expect(pairs, contains(const CorrectionPair(error: '体直给', correct: '体脂给')));
    });

    test('删除对不走分词补全（维持删除类吸收逻辑）', () {
      injectSegmenter(
        (t) => t == '嗯嗯今天买了苹果' ? ['嗯嗯', '今天', '买', '了', '苹果'] : [t],
      );
      final pairs = CorrectionLearner.extract('嗯嗯今天买了苹果', '今天买了苹果');
      expect(pairs, contains(const CorrectionPair(error: '嗯嗯', correct: '')));
    });
  });

  group('CorrectionLearner.extractAll 双钥匙 / dedupeSubsumed 折叠', () {
    setUp(() => CorrectionLearner.wordSegmenter = null);
    tearDown(() => CorrectionLearner.wordSegmenter = null);

    test('整词钥匙 + 短核兜底钥匙同时产出', () {
      CorrectionLearner.wordSegmenter = (t) => t == '管管雎鸠' ? ['管管', '雎鸠'] : [t];
      final all = CorrectionLearner.extractAll('管管雎鸠', '关关雎鸠');
      expect(
        all.primary,
        contains(const CorrectionPair(error: '管管雎鸠', correct: '关关雎鸠')),
      );
      // 短核 = 固定吸收产物（叠词钥匙），下次错误串变形（管管雎究）时兜底
      expect(all.shortCore, [const CorrectionPair(error: '管管', correct: '关关')]);
    });

    test('整词与固定吸收产物相同时 shortCore 去重为空', () {
      CorrectionLearner.wordSegmenter = (t) =>
          t == '能把我的体直给降下去么'
          ? ['能把', '我的', '体直给', '降', '下去', '么']
          : [t];
      final all = CorrectionLearner.extractAll(
        '能把我的体直给降下去么',
        '能把我的体脂给降下去么',
      );
      expect(all.primary, hasLength(1));
      // token 就是完整错误串，补全结果与固定吸收一致 → 无第二条
      expect(all.shortCore, isEmpty);
    });

    test('未注入分词器时 shortCore 为空', () {
      final all = CorrectionLearner.extractAll('明天去超市', '后天去超市');
      expect(all.primary, isNotEmpty);
      expect(all.shortCore, isEmpty);
    });

    test('dedupeSubsumed 折叠双钥匙短核（两侧互为子串），保留独立对', () {
      final deduped = CorrectionLearner.dedupeSubsumed([
        const CorrectionPair(error: '管管雎鸠', correct: '关关雎鸠'),
        const CorrectionPair(error: '管管', correct: '关关'),
        const CorrectionPair(error: '饰品', correct: '视频'),
      ]);
      expect(deduped, [
        const CorrectionPair(error: '管管雎鸠', correct: '关关雎鸠'),
        const CorrectionPair(error: '饰品', correct: '视频'),
      ]);
    });

    test('dedupeSubsumed 不折叠修正侧不同的包含对（可能是独立规则）', () {
      final deduped = CorrectionLearner.dedupeSubsumed([
        const CorrectionPair(error: '体直给', correct: '体脂率'),
        const CorrectionPair(error: '直给', correct: '脂给'),
      ]);
      // 「直给→脂给」的修正「脂给」不是「体脂率」的子串 → 非双钥匙，保留
      expect(deduped, hasLength(2));
    });
  });
}

void _codecTests() {
  group('CorrectionLearner 文本编解码（导入/导出）', () {
    test('编码格式：每行「错误 = 修正」，带注释头', () {
      final text = CorrectionLearner.encodeCorrections([
        const CorrectionPair(error: '饰品', correct: '视频'),
        const CorrectionPair(error: '嗯嗯', correct: ''),
      ]);
      expect(text, contains('# 声物记'));
      expect(text, contains('饰品 = 视频'));
      expect(text, contains('嗯嗯 = '));
    });

    test('编码→解析 roundtrip 还原全部修正对（含删除对）', () {
      final original = [
        const CorrectionPair(error: '饰品', correct: '视频'),
        const CorrectionPair(error: '明天', correct: '后天'),
        const CorrectionPair(error: '嗯嗯', correct: ''),
      ];
      final parsed = CorrectionLearner.parseCorrections(
        CorrectionLearner.encodeCorrections(original),
      );
      expect(parsed, original);
    });

    test('解析跳过注释行、空行、格式不完整的行', () {
      final text = '# 注释行\n\n饰品 = 视频\n没有分隔符的行\n\n= 只有修正\n';
      expect(CorrectionLearner.parseCorrections(text), [
        const CorrectionPair(error: '饰品', correct: '视频'),
      ]);
    });

    test('解析去重同一对', () {
      final text = '饰品 = 视频\n饰品 = 视频\n';
      expect(CorrectionLearner.parseCorrections(text).length, 1);
    });

    test('解析空文本安全', () {
      expect(CorrectionLearner.parseCorrections(''), isEmpty);
    });
  });
}
