import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/utils/dart_chrono_parser.dart';
import 'package:shengwuji_app/models/time_entity.dart';

void main() {
  group('DartChronoParser Tests', () {
    final parser = DartChronoParser();

    test('解析"今天"', () async {
      final results = await parser.parseDateTimeEntities('今天天气不错');
      expect(results.length, 1);
      expect(results[0].text, '今天');
      expect(results[0].typeName, 'datetime');
    });

    test('解析"明天"', () async {
      final results = await parser.parseDateTimeEntities('明天开会');
      expect(results.length, 1);
      expect(results[0].text, '明天');
    });

    test('解析"周一"', () async {
      final results = await parser.parseDateTimeEntities('周一提交报告');
      expect(results.length, 1);
      expect(results[0].text, contains('周一'));
    });

    test('解析"下周三"', () async {
      final results = await parser.parseDateTimeEntities('下周三截止');
      expect(results.length, 1);
      expect(results[0].text, contains('下周三'));
    });

    test('解析"下午3点"', () async {
      final results = await parser.parseDateTimeEntities('下午3点吃饭');
      expect(results.length, 1);
      expect(results[0].text, '下午3点');
    });

    test('解析"15:30"', () async {
      final results = await parser.parseDateTimeEntities('15:30开始');
      expect(results.length, 1);
      expect(results[0].text, '15:30');
    });

    test('解析"3天后"', () async {
      final results = await parser.parseDateTimeEntities('3天后交付');
      expect(results.length, 1);
      expect(results[0].text, '3天后');
    });

    test('解析"1月5日"', () async {
      final results = await parser.parseDateTimeEntities('1月5日是生日');
      expect(results.length, 1);
      expect(results[0].text, '1月5日');
    });

    test('解析多个时间"', () async {
      final results =
          await parser.parseDateTimeEntities('今天下午3点和明天开会');
      expect(results.length, 3);
      expect(results[0].text, '今天');
      expect(results[1].text, '下午3点');
      expect(results[2].text, '明天');
    });

    test('空文本返回空列表"', () async {
      final results = await parser.parseDateTimeEntities('');
      expect(results.length, 0);
    });

    test('无时间实体返回空列表"', () async {
      final results = await parser.parseDateTimeEntities('这是一段普通文本');
      expect(results.length, 0);
    });
  });
}
