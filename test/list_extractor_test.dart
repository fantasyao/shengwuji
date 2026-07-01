import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/list_extractor.dart';

void main() {
  late ListExtractor extractor;

  setUp(() {
    extractor = ListExtractor();
  });

  // ============================================================
  // 端到端场景测试
  // ============================================================

  group('端到端场景', () {
    test('场景1: 购物清单（有连接词）', () {
      final result = extractor.extract('代办去买牛奶、然后买鸡蛋、再买点饮料');
      expect(result.isList, true);
      expect(result.items.length, 3);
      expect(result.items[0].content, '牛奶');
      expect(result.items[1].content, '鸡蛋');
      expect(result.items[2].content, '饮料');
      // 所有条目应归类为"购物"
      expect(result.items.every((i) => i.category == '购物'), true);
    });

    test('场景2: 购物清单（无连接词，纯罗列）', () {
      final result = extractor.extract('代办我要买10个苹果，20个梨子，5斤大米');
      expect(result.isList, true);
      expect(result.items.length, 3);
      expect(result.items[0].content, '苹果');
      expect(result.items[0].quantity, 10);
      expect(result.items[0].unit, '个');
      expect(result.items[1].content, '梨子');
      expect(result.items[1].quantity, 20);
      expect(result.items[1].unit, '个');
      expect(result.items[2].content, '大米');
      expect(result.items[2].quantity, 5);
      expect(result.items[2].unit, '斤');
    });

    test('场景3: 代办任务', () {
      final result = extractor.extract('代办明天要先打扫卫生、清理厕所、叫保洁');
      expect(result.isList, true);
      expect(result.items.length, 3);
      expect(result.items[0].content, '打扫卫生');
      expect(result.items[0].category, '家务');
      expect(result.items[1].content, '清理厕所');
      expect(result.items[1].category, '家务');
      expect(result.items[2].content, contains('保洁'));
    });

    test('场景4: 混合类型', () {
      final result = extractor.extract('代办先去超市买牛奶和鸡蛋，回来打扫卫生，下午三点开会');
      expect(result.isList, true);
      // 至少拆出 3 条
      expect(result.items.length, greaterThanOrEqualTo(3));
      // 检查分类多样性
      final categories = result.items.map((i) => i.category).toSet();
      expect(categories.length, greaterThanOrEqualTo(2));
    });

    test('场景5: 不是清单（只有一条物品）', () {
      final result = extractor.extract('钥匙放在客厅');
      expect(result.isList, false);
      expect(result.items.length, 0);
    });

    test('场景6: 简单购物罗列（顿号分隔）', () {
      final result = extractor.extract('代办买牛奶、鸡蛋、面包、饮料');
      expect(result.isList, true);
      expect(result.items.length, 4);
      expect(result.items[0].content, '牛奶');
      expect(result.items[1].content, '鸡蛋');
      expect(result.items[2].content, '面包');
      expect(result.items[3].content, '饮料');
    });
  });

  // ============================================================
  // 触发词门禁测试（2026-06-29 新增）
  // ============================================================

  group('触发词门禁', () {
    test('"代办"开头应触发清单提取', () {
      final result = extractor.extract('代办买苹果、香蕉');
      expect(result.isList, true);
      expect(result.items.length, 2);
    });

    test('"待办"开头同样应触发（同音字变体）', () {
      final result = extractor.extract('待办买苹果、香蕉');
      expect(result.isList, true);
      expect(result.items.length, 2);
    });

    test('回归: "刚刚地震了，还有点吓人"不应识别为清单', () {
      // 这条曾经因"还"/"还有"子串双重匹配被误判
      final result = extractor.extract('刚刚地震了，还有点吓人');
      expect(result.isList, false);
    });

    test('触发词不在开头不触发', () {
      final result = extractor.extract('我说代办买苹果、香蕉');
      expect(result.isList, false);
    });

    test('触发词在中间不触发', () {
      final result = extractor.extract('买代办');
      expect(result.isList, false);
    });

    test('只有触发词无内容不触发', () {
      final result = extractor.extract('代办');
      expect(result.isList, false);
    });

    test('触发词+逗号+无内容不触发', () {
      final result = extractor.extract('代办，');
      expect(result.isList, false);
    });

    test('触发词命中但拆分后只有1条不触发（代办语义是批量）', () {
      final result = extractor.extract('代办买苹果');
      expect(result.isList, false);
    });

    test('触发词后直接接内容（无分隔符）应正常工作', () {
      final result = extractor.extract('代办苹果、香蕉、橘子');
      expect(result.isList, true);
      expect(result.items[0].content, '苹果');
    });

    test('触发词后跟逗号应正常工作', () {
      final result = extractor.extract('代办，买苹果、香蕉');
      expect(result.isList, true);
      expect(result.items[0].content, '苹果');
    });

    test('触发词前有填充词（"嗯"）预处理后被去除，仍可触发', () {
      // 预处理先去"嗯"，剩"代办..."，触发词命中
      final result = extractor.extract('嗯代办买苹果、香蕉');
      expect(result.isList, true);
    });
  });

  // ============================================================
  // 意图检测测试（仅用于分类标签，isList 已由触发词门禁决定）
  // ============================================================

  group('意图检测', () {
    test('空文本应返回 isList=false', () {
      final result = extractor.extract('');
      expect(result.isList, false);
    });

    test('纯空格应返回 isList=false', () {
      final result = extractor.extract('   ');
      expect(result.isList, false);
    });

    test('日记前缀"记录一下"不应识别为清单', () {
      // 注意：即使没有触发词门禁，这条也不会进清单流程
      final result = extractor.extract('记录一下今天天气不错');
      expect(result.isList, false);
    });

    test('日记前缀"记一下"不应识别为清单', () {
      final result = extractor.extract('记一下明天要开会');
      expect(result.isList, false);
    });

    test('单条物品不应识别为清单', () {
      final result = extractor.extract('遥控器在茶几上');
      expect(result.isList, false);
    });

    test('多条物品有顿号应识别为清单', () {
      final result = extractor.extract('代办牛奶、鸡蛋、面包');
      expect(result.isList, true);
    });

    test('包含"买"且有多个条目应识别为清单', () {
      final result = extractor.extract('代办买苹果，买香蕉，买橘子');
      expect(result.isList, true);
      expect(result.detectedIntent, '购物');
    });

    test('包含任务动词的多条目应识别为任务', () {
      final result = extractor.extract('代办整理房间，收拾厨房，打扫客厅');
      expect(result.isList, true);
    });
  });

  // ============================================================
  // 条目拆分测试
  // ============================================================

  group('条目拆分', () {
    test('按顿号拆分', () {
      final result = extractor.extract('代办牛奶、鸡蛋、面包');
      expect(result.items.length, 3);
    });

    test('按逗号拆分', () {
      final result = extractor.extract('代办买牛奶，买鸡蛋，买面包');
      expect(result.items.length, 3);
    });

    test('按枚举连接词拆分', () {
      final result = extractor.extract('代办然后买牛奶然后买鸡蛋然后买面包');
      expect(result.items.length, greaterThanOrEqualTo(2));
    });

    test('顿号优先于逗号', () {
      final result = extractor.extract('代办牛奶、鸡蛋，面包、饮料');
      // 顿号优先，按顿号拆
      expect(result.items.length, greaterThanOrEqualTo(3));
    });
  });

  // ============================================================
  // 数量提取测试
  // ============================================================

  group('数量提取', () {
    test('"10个苹果"应提取 quantity=10, unit="个"', () {
      final result = extractor.extract('代办买10个苹果、20个香蕉');
      expect(result.items[0].quantity, 10);
      expect(result.items[0].unit, '个');
      expect(result.items[0].content, '苹果');
    });

    test('"5斤大米"应提取 quantity=5, unit="斤"', () {
      final result = extractor.extract('代办买5斤大米、3斤面粉');
      expect(result.items[0].quantity, 5);
      expect(result.items[0].unit, '斤');
      expect(result.items[0].content, '大米');
    });

    test('"牛奶"无数量应提取 quantity=null', () {
      final result = extractor.extract('代办买牛奶、鸡蛋');
      expect(result.items[0].quantity, isNull);
      expect(result.items[0].unit, isNull);
      expect(result.items[0].content, '牛奶');
    });

    test('"两瓶水"中文数字"两"应转为2', () {
      final result = extractor.extract('代办买两瓶水、3瓶可乐');
      expect(result.items[0].quantity, 2);
      expect(result.items[0].unit, '瓶');
      expect(result.items[0].content, '水');
    });
  });

  // ============================================================
  // 分类测试
  // ============================================================

  group('分类', () {
    test('含"买"应分类为"购物"', () {
      final result = extractor.extract('代办买牛奶、鸡蛋、面包');
      expect(result.items.every((i) => i.category == '购物'), true);
    });

    test('"打扫卫生"应分类为"家务"', () {
      final result = extractor.extract('代办打扫卫生、清理厕所、擦桌子');
      expect(result.items[0].category, '家务');
    });

    test('"开会"应分类为"工作"', () {
      final result = extractor.extract('代办开会、写报告、发邮件');
      expect(result.items.any((i) => i.category == '工作'), true);
    });

    test('"预约"应分类为"生活"', () {
      final result = extractor.extract('代办预约体检、缴费、取快递');
      expect(result.items[0].category, '生活');
    });
  });

  // ============================================================
  // 口语填充词测试
  // ============================================================

  group('口语填充词处理', () {
    test('含"那个"应被去除', () {
      final result = extractor.extract('代办去买那个牛奶、鸡蛋、面包');
      expect(result.normalizedText, isNot(contains('那个')));
    });

    test('含"嗯"应被去除', () {
      final result = extractor.extract('代办嗯去买牛奶、鸡蛋、面包');
      expect(result.normalizedText, isNot(contains('嗯')));
    });
  });

  // ============================================================
  // 边界情况测试
  // ============================================================

  group('边界情况', () {
    test('半角逗号应正常处理', () {
      final result = extractor.extract('代办买牛奶,买鸡蛋,买面包');
      expect(result.isList, true);
      expect(result.items.length, 3);
    });

    test('时间前缀应被提取', () {
      final result = extractor.extract('代办明天打扫卫生、清理厕所、擦桌子');
      expect(result.isList, true);
      expect(result.items.any((i) => i.time != null), true);
    });

    test('去除"买点"前缀', () {
      final result = extractor.extract('代办买点牛奶、鸡蛋、饮料');
      expect(result.isList, true);
      // "买点"应被去除
      expect(result.items[0].content, '牛奶');
    });

    test('去除"点"量级修饰词', () {
      final result = extractor.extract('代办买牛奶、带点饮料、拿些水果');
      expect(result.isList, true);
    });
  });

  // ============================================================
  // toMarkdown 输出格式测试（2026-06-29 方案 A：保留原句语序）
  // ============================================================

  group('toMarkdown 输出', () {
    test('数量不再前置，保留原句语序', () {
      // 回归 case：原逻辑会输出"2包最后再买烟"（语序错乱）
      // 方案 A：保留原句"最后再买两包烟"
      final result = extractor.extract('代办最后再买两包烟、然后还要买点鸡蛋');
      expect(result.isList, true);
      final md = result.toMarkdown();
      expect(md, contains('最后再买两包烟'));
      expect(md, isNot(contains('2包最后再买')));
    });

    test('句号应被清理', () {
      final result = extractor.extract('代办买苹果、买香蕉。');
      expect(result.isList, true);
      final md = result.toMarkdown();
      // 末尾句号不应出现在 markdown 中
      expect(md, isNot(contains('。')));
    });

    test('空结果返回空字符串', () {
      const result = ExtractionResult(isList: false);
      expect(result.toMarkdown(), '');
    });

    test('markdown 应为任务列表格式（- [ ] 前缀）', () {
      final result = extractor.extract('代办买苹果、香蕉');
      final md = result.toMarkdown();
      expect(md, startsWith('- [ ] '));
      expect(md.split('\n').length, 2);
    });

    test('quantity/unit 仍作为元数据保留', () {
      // 即使 markdown 显示原句，结构化数据仍要保留供将来 UI 使用
      final result = extractor.extract('代办买10个苹果、20个香蕉');
      expect(result.items[0].quantity, 10);
      expect(result.items[0].unit, '个');
      expect(result.items[1].quantity, 20);
      // markdown 用 rawSegment，含原始数字
      final md = result.toMarkdown();
      expect(md, contains('10个苹果'));
    });
  });
}
