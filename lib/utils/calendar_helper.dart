import '../models/time_entity.dart';
import 'dart_chrono_parser.dart';

/// 日历事件构建共享工具（主 App 日记页蓝色时间文字与悬浮窗闹钟按钮共用）
///
/// 职责：
/// - [buildEventTitle]：从日记内容剥离时间子串得到日历事件标题
///   （时间信息经 timestamp 传递，标题无需重复）
/// - [extractBestTime]：解析文本时间并选出适合预填日历转轮的最佳实体
///   （悬浮窗闹钟一键预填用；日记页仍展示全部实体由用户点选）
/// - [defaultPrefillTime]：无时间可识别时的默认预填（现在 + 1 小时取整）
class CalendarHelper {
  CalendarHelper._();

  /// 从日记内容中剥离时间子串，得到动作内容作为日历事件标题
  /// 例：「今天晚上十二点提醒我去睡觉」→「提醒我去睡觉」
  /// 例：「下午3点」→ 剥离后为空 → 回退用原文「下午3点」
  /// 防御：start/end 越界或非法区间时原样返回
  static String stripTimePhrase(String content, TimeEntity entity) {
    if (content.isEmpty) return content;
    if (entity.start < 0 ||
        entity.end > content.length ||
        entity.start >= entity.end) {
      return content;
    }
    final before = content.substring(0, entity.start);
    final after = content.substring(entity.end);
    String remaining = before + after;
    // 去掉首尾中英文标点和空白（剥离后可能留下孤立逗号/顿号）
    remaining = remaining.replaceAll(RegExp(r'^[\s，,。.、；;：:！!？?]+'), '');
    remaining = remaining.replaceAll(RegExp(r'[\s，,。.、；;：:！!？?]+$'), '');
    // 合并中间连续空格（如「提醒我 明天8点 起床」→「提醒我 起床」中间留有空格）
    remaining = remaining.replaceAll(RegExp(r'\s+'), ' ').trim();
    // 剥离后为空（原文只有时间表达式）→ 回退用原文，避免空标题
    return remaining.isEmpty ? content : remaining;
  }

  /// 生成日历事件标题：识别到时间则剥离时间短语（所见即所得：
  /// 弹窗显示的标题 = 写入日历的 title = 通知栏响铃显示的内容）；
  /// 未识别到或剥离后为空回退原文；原文也为空兜底「日历提醒」
  static String buildEventTitle(String content, TimeEntity? entity) {
    if (entity == null) {
      return content.isEmpty ? '日历提醒' : content;
    }
    final stripped = stripTimePhrase(content, entity);
    return stripped.isEmpty ? '日历提醒' : stripped;
  }

  /// 解析文本中的时间并选出最佳预填实体
  ///
  /// 选择规则：取文本顺序第一个实体（解析器已合并"周六+晚上8点"这类相邻
  /// 日期+时间表达）；过去时间滚动到未来——含「月日」的明确日期 +1 年
  /// （"6月8日"九月说指向明年 6 月 8 日），其余逐日滚到未来：纯时刻
  /// "晚上8点"晚九点说 → 明天 20:00，「昨天/前天」这类罕见输入也能保证
  /// 落点在未来；星期表达式解析器本身已算下一次出现，恒为未来走不到滚动。
  ///
  /// 返回 (entity, time)：time 为滚动后的最终预填时刻；解析不到返回 null。
  static Future<({TimeEntity entity, DateTime time})?> extractBestTime(
    String content, {
    DateTime? now,
  }) async {
    final ref = now ?? DateTime.now();
    if (content.trim().isEmpty) return null;

    // 文本预处理与日记页 _parseTimeEntities 同款：中文冒号换英文点
    //（"8点30：开会"等场景 chrono 能正确解析）。refDate 必须传：解析器
    // 内部"下一个周X"等相对推算以它为基准，测试与跨天场景才可预测
    final processedText = content.replaceAll('：', '.');
    final entities = await DartChronoParser().parseDateTimeEntities(
      processedText,
      refDate: ref.toIso8601String(),
    );
    if (entities.isEmpty) return null;

    final entity = entities.first;
    final base = entity.dateTime;
    if (base == null) return null;

    var dt = base; // 已是非空 DateTime，do-while 回边不再丢提升
    if (!dt.isAfter(ref)) {
      if (entity.text.contains('月')) {
        dt = DateTime(dt.year + 1, dt.month, dt.day, dt.hour, dt.minute);
      } else {
        do {
          dt = dt.add(const Duration(days: 1));
        } while (!dt.isAfter(ref));
      }
    }
    return (entity: entity, time: dt);
  }

  /// 无时间可识别时的默认预填：现在 + 1 小时并向后取整到整点
  ///（对齐 iOS 提醒事项"今天 +1 小时"惯例；14:20 → 16:00，14:00 → 15:00）
  static DateTime defaultPrefillTime([DateTime? now]) {
    final plus = (now ?? DateTime.now()).add(const Duration(hours: 1));
    final onTheHour = plus.minute == 0 && plus.second == 0 && plus.millisecond == 0;
    return DateTime(plus.year, plus.month, plus.day, plus.hour + (onTheHour ? 0 : 1));
  }
}
