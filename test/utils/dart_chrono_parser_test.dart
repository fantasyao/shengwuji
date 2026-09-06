import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/utils/dart_chrono_parser.dart';

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

    test('解析多个时间：相邻日期+时间合并，间隔的各自独立', () async {
      final results =
          await parser.parseDateTimeEntities('今天下午3点和明天开会');
      // 「今天+下午3点」紧挨着被合并为一个实体（_mergeAdjacentEntities，
      // 悬浮窗闹钟「周六晚上8点」整体识别的前提），「和」隔开的明天独立
      expect(results.length, 2);
      expect(results[0].text, '今天下午3点');
      expect(results[1].text, '明天');
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

  group('DartChronoParser 中文数字支持（2026-09-06 悬浮窗闹钟）', () {
    final parser = DartChronoParser();

    test('解析"晚上八点"（用户示例的核心写法）', () async {
      final results = await parser.parseDateTimeEntities('晚上八点吃药');
      expect(results.length, 1);
      expect(results[0].text, '晚上八点');
      final dt = results[0].dateTime!;
      expect(dt.hour, 20);
      expect(dt.minute, 0);
    });

    test('解析"周六晚上八点"：日期+时间合并，指向下周六 20:00', () async {
      // 固定参考时间：2026-09-02（周三）→ 下一个周六 = 09-05
      final results = await parser.parseDateTimeEntities(
        '周六晚上八点提醒我去看电影',
        refDate: '2026-09-02T10:00:00',
      );
      expect(results.length, 1);
      expect(results[0].text, '周六晚上八点');
      final dt = results[0].dateTime!;
      expect(dt.year, 2026);
      expect(dt.month, 9);
      expect(dt.day, 5);
      expect(dt.hour, 20);
    });

    test('解析"下午三点二十"（中文分钟）', () async {
      final results = await parser.parseDateTimeEntities('下午三点二十碰头');
      expect(results.length, 1);
      final dt = results[0].dateTime!;
      expect(dt.hour, 15);
      expect(dt.minute, 20);
    });

    test('解析"上午十点"与"两"字写法', () async {
      final r1 = await parser.parseDateTimeEntities('上午十点站会');
      expect(r1.single.text, '上午十点');
      expect(r1.single.dateTime!.hour, 10);

      final r2 = await parser.parseDateTimeEntities('晚上两点值班');
      expect(r2.single.dateTime!.hour, 14); // 两=2 → +12
    });

    test('"十二点"与阿拉伯数字行为一致（晚上12点 → 12 时刻，语义不动）',
        () async {
      final results = await parser.parseDateTimeEntities('晚上十二点收工');
      expect(results.single.dateTime!.hour, 12);
    });

    test('口语"晚一点"不误伤（纯"一"不当钟点；"晚上1点"数字写法不受影响）',
        () async {
      expect(await parser.parseDateTimeEntities('时间再晚一点通知我'), isEmpty);
      expect(await parser.parseDateTimeEntities('晚上1点见'), isNotEmpty);
    });

    test('阿拉伯数字写法回归不变（"晚上8点30"）', () async {
      final results = await parser.parseDateTimeEntities('晚上8点30散会');
      expect(results.single.text, '晚上8点30');
      final dt = results.single.dateTime!;
      expect(dt.hour, 20);
      expect(dt.minute, 30);
    });
  });

  group('DartChronoParser 半点与裸钟点（2026-09-06 用户反馈）', () {
    final parser = DartChronoParser();

    test('"八点半去提醒我吃饭"（用户原话：无时段词 + 半）', () async {
      final results = await parser.parseDateTimeEntities('八点半去提醒我吃饭');
      expect(results.length, 1);
      expect(results[0].text, '八点半');
      final dt = results[0].dateTime!;
      expect(dt.hour, 8);
      expect(dt.minute, 30);
    });

    test('"晚上八点半"：半 = 30 分', () async {
      final results = await parser.parseDateTimeEntities('晚上八点半吃药');
      expect(results.single.text, '晚上八点半');
      final dt = results.single.dateTime!;
      expect(dt.hour, 20);
      expect(dt.minute, 30);
    });

    test('"两点提醒我开会"：裸中文钟点（"2点"式同权）', () async {
      final r1 = await parser.parseDateTimeEntities('两点提醒我开会');
      expect(r1.single.text, '两点');
      expect(r1.single.dateTime!.hour, 2);

      final r2 = await parser.parseDateTimeEntities('2点提醒我开会');
      expect(r2.single.text, '2点');
      expect(r2.single.dateTime!.hour, 2);
    });

    test('"下午3点半"与"12点半"：带/不带时段词的半点', () async {
      final r1 = await parser.parseDateTimeEntities('下午3点半碰头');
      expect(r1.single.dateTime!.hour, 15);
      expect(r1.single.dateTime!.minute, 30);

      final r2 = await parser.parseDateTimeEntities('12点半午休');
      expect(r2.single.dateTime!.hour, 12);
      expect(r2.single.dateTime!.minute, 30);
    });

    test('"八点钟"整吞"钟"字（标题剥离不留孤字）', () async {
      final results = await parser.parseDateTimeEntities('八点钟出发');
      expect(results.single.text, '八点钟');
      expect(results.single.dateTime!.hour, 8);
    });

    test('"明天八点"：日期 + 裸钟点合并', () async {
      final now = DateTime.now();
      final results = await parser.parseDateTimeEntities('明天八点出发');
      expect(results.single.text, '明天八点');
      final dt = results.single.dateTime!;
      final tomorrow = now.add(const Duration(days: 1));
      expect(dt.day, tomorrow.day);
      expect(dt.hour, 8);
    });

    test('"第3点"序号与"晚一点"口语不误伤', () async {
      expect(await parser.parseDateTimeEntities('第3点再讨论一下'), isEmpty);
      expect(await parser.parseDateTimeEntities('时间再晚一点通知我'), isEmpty);
    });

    test('"三点零五"：零头分钟（"零五"按位拼接）', () async {
      final results = await parser.parseDateTimeEntities('三点零五碰头');
      expect(results.single.dateTime!.hour, 3);
      expect(results.single.dateTime!.minute, 5);
    });
  });
}
