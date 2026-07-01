import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/utils/item_splitter.dart';

void main() {
  group('ItemSplitter.detect - 误判防护', () {
    test('现在他这个滚动页面会动 - 不应拆分', () {
      expect(ItemSplitter.detect('现在他这个滚动页面会动'), isNull);
    });
    test('现在觉得还行 - 不应拆分', () {
      expect(ItemSplitter.detect('现在觉得还行'), isNull);
    });
    test('这个正在聆听的文案 - 不应拆分', () {
      expect(ItemSplitter.detect('这个正在聆听的文案'), isNull);
    });
    test('他现在应该在家里 - 不应拆分', () {
      expect(ItemSplitter.detect('他现在应该在家里'), isNull);
    });
    test('他应该在成都 - 不应拆分', () {
      expect(ItemSplitter.detect('他应该在成都'), isNull);
    });
    test('我在吃饭 - 不应拆分', () {
      expect(ItemSplitter.detect('我在吃饭'), isNull);
    });
    test('他正在路上 - 不应拆分', () {
      expect(ItemSplitter.detect('他正在路上'), isNull);
    });
  });

  group('ItemSplitter.detect - 正常拆分', () {
    test('强分隔符 放在', () {
      final r = ItemSplitter.detect('钥匙放在桌子上');
      expect(r, isNotNull);
      expect(r!.item, '钥匙');
      expect(r.location, '桌子上');
    });
    test('强分隔符 放进', () {
      final r = ItemSplitter.detect('护照放进包里');
      expect(r, isNotNull);
      expect(r!.item, '护照');
    });
    test('强分隔符 搁在', () {
      final r = ItemSplitter.detect('日记本搁在书架上');
      expect(r, isNotNull);
      expect(r!.item, '日记本');
    });
    test('弱分隔符 在 + 方位词', () {
      final r = ItemSplitter.detect('钥匙在抽屉里');
      expect(r, isNotNull);
      expect(r!.item, '钥匙');
      expect(r.location, '抽屉里');
    });
    test('弱分隔符 在 + 短位置', () {
      final r = ItemSplitter.detect('钥匙在门口');
      expect(r, isNotNull);
      expect(r!.item, '钥匙');
      expect(r.location, '门口');
    });
    test('弱分隔符 在 + 方位词上', () {
      final r = ItemSplitter.detect('钥匙在桌子上');
      expect(r, isNotNull);
      expect(r!.item, '钥匙');
      expect(r.location, '桌子上');
    });
    test('身份证在钱包里', () {
      final r = ItemSplitter.detect('身份证在钱包里');
      expect(r, isNotNull);
      expect(r!.item, '身份证');
      expect(r.location, '钱包里');
    });
  });

  group('ItemSplitter.detect - 边界', () {
    test('空字符串', () {
      expect(ItemSplitter.detect(''), isNull);
    });
    test('无分隔符', () {
      expect(ItemSplitter.detect('今天天气不错'), isNull);
    });
    test('长位置无方位词被挡', () {
      // 已知 trade-off：长位置不带方位词会被新规则挡住
      expect(ItemSplitter.detect('游戏机在客厅电视柜'), isNull);
    });
  });

  group('ItemSplitter.cleanPunctuation', () {
    test('保留方法可用', () {
      // 验证 cleanPunctuation 静态方法仍然存在可调用
      expect(ItemSplitter.cleanPunctuation('你好。'), isA<String>());
    });
  });
}
