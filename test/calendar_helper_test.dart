import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/models/time_entity.dart';
import 'package:shengwuji_app/utils/calendar_helper.dart';

/// CalendarHelper 单元回归：剥离时间短语 / 生成标题 / 解析选最佳实体 /
/// 过去时间滚动 / 默认预填。悬浮窗闹钟（OverlayHome._onCardAlarm）与
/// 日记页（_handleTimeEntityTap）共用的语义都在这里
void main() {
  group('stripTimePhrase 剥离时间短语', () {
    test('剥离合并实体「今天晚上12点」', () {
      // start/end 与解析器输出对齐：entity 覆盖「今天晚上12点」子串
      const content = '今天晚上12点提醒我去睡觉';
      final entity = TimeEntity(
        text: '今天晚上12点',
        start: 0,
        end: 7,
        typeName: 'datetime',
        value: '2026-09-06T12:00:00.000',
      );
      expect(CalendarHelper.stripTimePhrase(content, entity), '提醒我去睡觉');
    });

    test('时间在中间：前后拼接 + 合并空格', () {
      const content = '提醒我 明天8点 起床';
      final entity = TimeEntity(
        text: '明天8点',
        start: 4,
        end: 8,
        typeName: 'datetime',
        value: '2026-09-07T08:00:00.000',
      );
      expect(CalendarHelper.stripTimePhrase(content, entity), '提醒我 起床');
    });

    test('剥离后为空回退原文', () {
      const content = '下午3点';
      final entity = TimeEntity(
        text: '下午3点',
        start: 0,
        end: 4,
        typeName: 'datetime',
        value: '2026-09-06T15:00:00.000',
      );
      expect(CalendarHelper.stripTimePhrase(content, entity), '下午3点');
    });

    test('越界 start/end 防御性原样返回', () {
      const content = '普通文本';
      final entity = TimeEntity(
        text: '越界',
        start: 10,
        end: 20,
        typeName: 'datetime',
        value: '2026-09-06T12:00:00.000',
      );
      expect(CalendarHelper.stripTimePhrase(content, entity), '普通文本');
    });
  });

  group('buildEventTitle 生成标题', () {
    test('有实体：剥离时间短语', () {
      const content = '明天8点开会';
      final entity = TimeEntity(
        text: '明天8点',
        start: 0,
        end: 4,
        typeName: 'datetime',
        value: '2026-09-07T08:00:00.000',
      );
      expect(CalendarHelper.buildEventTitle(content, entity), '开会');
    });

    test('无实体：原文即标题', () {
      expect(CalendarHelper.buildEventTitle('买牛奶', null), '买牛奶');
    });

    test('空内容兜底「日历提醒」', () {
      expect(CalendarHelper.buildEventTitle('', null), '日历提醒');
    });
  });

  group('extractBestTime 解析选最佳实体', () {
    test('用户示例「周六晚上八点提醒我去看电影」：合并实体 + 下周六 20:00', () async {
      final parsed = await CalendarHelper.extractBestTime(
        '周六晚上八点提醒我去看电影',
        now: DateTime(2026, 9, 2, 10), // 周三
      );
      expect(parsed, isNotNull);
      expect(parsed!.entity.text, '周六晚上八点');
      expect(parsed.time, DateTime(2026, 9, 5, 20)); // 下一个周六
    });

    test('无时间返回 null', () async {
      expect(
        await CalendarHelper.extractBestTime('记得买牛奶', now: DateTime(2026, 9, 6)),
        isNull,
      );
      expect(
        await CalendarHelper.extractBestTime('', now: DateTime(2026, 9, 6)),
        isNull,
      );
    });

    test('过去纯时刻逐日滚动（今天 22 点说「晚上8点」→ 明天 20:00）', () async {
      final parsed = await CalendarHelper.extractBestTime(
        '晚上8点散会',
        now: DateTime(2026, 9, 6, 22),
      );
      expect(parsed!.entity.text, '晚上8点');
      expect(parsed.time, DateTime(2026, 9, 7, 20));
    });

    test('「昨天」等已过多日的实体也能滚到未来（14 点说「昨天」→ 明天 12 点）',
        () async {
      final parsed = await CalendarHelper.extractBestTime(
        '昨天提醒的事',
        now: DateTime(2026, 9, 6, 14),
      );
      expect(parsed!.time, DateTime(2026, 9, 7, 12));
    });

    test('过去「月日」+1 年滚动（9 月说「6月8日」→ 明年）', () async {
      final parsed = await CalendarHelper.extractBestTime(
        '6月8日交报告',
        now: DateTime(2026, 9, 6, 12),
      );
      expect(parsed!.entity.text, '6月8日');
      expect(parsed.time, DateTime(2027, 6, 8, 12));
    });

    test('中文冒号预处理与日记页同款（「8点：开会」可解析）', () async {
      final parsed = await CalendarHelper.extractBestTime(
        '上午8点：开会',
        now: DateTime(2026, 9, 6, 6),
      );
      expect(parsed!.time.hour, 8);
    });
  });

  group('defaultPrefillTime 默认预填', () {
    test('非整点：+1 小时后向上取整（14:20 → 16:00）', () {
      expect(
        CalendarHelper.defaultPrefillTime(DateTime(2026, 9, 6, 14, 20)),
        DateTime(2026, 9, 6, 16),
      );
    });

    test('整点：+1 小时即整点（14:00 → 15:00）', () {
      expect(
        CalendarHelper.defaultPrefillTime(DateTime(2026, 9, 6, 14)),
        DateTime(2026, 9, 6, 15),
      );
    });

    test('23 点跨天到次日 0 点（23:30 → 次日 1:00）', () {
      expect(
        CalendarHelper.defaultPrefillTime(DateTime(2026, 9, 6, 23, 30)),
        DateTime(2026, 9, 7, 1),
      );
    });
  });
}
