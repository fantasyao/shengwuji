import '../app_logger.dart';
import '../models/time_entity.dart';

/// 纯 Dart 实现的中文时间解析器
/// 替代 flutter_js 方案，解决内存溢出问题
class DartChronoParser {
  DartChronoParser._internal();

  static final DartChronoParser _instance = DartChronoParser._internal();

  factory DartChronoParser() => _instance;

  /// 解析文本中的时间实体
  /// [text] 待解析的文本
  /// [refDate] 可选的参考日期（ISO 字符串格式），默认为当前时间
  /// 返回 [TimeEntity] 列表
  Future<List<TimeEntity>> parseDateTimeEntities(
    String text, {
    String? refDate,
  }) async {
    if (text.isEmpty) return [];

    final now = refDate != null ? DateTime.parse(refDate) : DateTime.now();

    final results = <TimeEntity>[];

    results.addAll(_parseRelativeTime(text, now));
    results.addAll(_parseWeekday(text, now));
    results.addAll(_parseSpecificDate(text, now));
    results.addAll(_parseTime(text, now));
    results.addAll(_parseOffset(text, now));

    results.sort((a, b) => a.start.compareTo(b.start));

    // 去重（key = 起始位置 + 文本）
    final uniqueResults = <TimeEntity>[];
    final seen = <String>{};
    for (final entity in results) {
      final key = '${entity.start}_${entity.text}';
      if (!seen.contains(key)) {
        seen.add(key);
        uniqueResults.add(entity);
      }
    }

    // 合并相邻的日期+时间实体（如"周六早上10点50"被拆成"周六"+"早上10点50"）
    final merged = _mergeAdjacentEntities(uniqueResults, text);

    if (merged.isNotEmpty) {
      log('🕐 Dart Chrono 解析到 ${merged.length} 个时间实体: $merged');
    }

    return merged;
  }

  /// 解析相对时间关键字（今天、明天、后天、昨天、前天）
  List<TimeEntity> _parseRelativeTime(String text, DateTime now) {
    final results = <TimeEntity>[];

    final todayMatch = _findFirstMatch(text, '今天');
    if (todayMatch != null) {
      results.add(_createEntity(text: '今天', index: todayMatch, date: now));
    }

    final tomorrowMatch = _findFirstMatch(text, '明天');
    if (tomorrowMatch != null) {
      final date = now.add(const Duration(days: 1));
      results.add(
        _createEntity(text: '明天', index: tomorrowMatch, date: date, hour: 12),
      );
    }

    final afterTomorrowMatch = _findFirstMatch(text, '后天');
    if (afterTomorrowMatch != null) {
      final date = now.add(const Duration(days: 2));
      results.add(
        _createEntity(
          text: '后天',
          index: afterTomorrowMatch,
          date: date,
          hour: 12,
        ),
      );
    }

    final yesterdayMatch = _findFirstMatch(text, '昨天');
    if (yesterdayMatch != null) {
      final date = now.subtract(const Duration(days: 1));
      results.add(
        _createEntity(text: '昨天', index: yesterdayMatch, date: date, hour: 12),
      );
    }

    final beforeYesterdayMatch = _findFirstMatch(text, '前天');
    if (beforeYesterdayMatch != null) {
      final date = now.subtract(const Duration(days: 2));
      results.add(
        _createEntity(
          text: '前天',
          index: beforeYesterdayMatch,
          date: date,
          hour: 12,
        ),
      );
    }

    return results;
  }

  /// 解析星期（周一、下周三等）
  List<TimeEntity> _parseWeekday(String text, DateTime now) {
    final results = <TimeEntity>[];

    final weekdayMap = {
      '一': 1,
      '二': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '日': 0,
      '天': 0,
      '1': 1,
      '2': 2,
      '3': 3,
      '4': 4,
      '5': 5,
      '6': 6,
      '7': 0,
      '0': 0,
    };

    // 匹配"周一/星期一"等（排除"下周X"）
    final weekPattern = RegExp(r'(?<!下)(?:星期|周)([一二三四五六日天12345670])');
    for (final match in weekPattern.allMatches(text)) {
      final weekday = weekdayMap[match.group(1)];
      if (weekday != null) {
        final date = _getNextWeekday(now, weekday);
        results.add(
          _createEntity(
            text: match.group(0)!,
            index: match.start,
            date: date,
            hour: 12,
          ),
        );
      }
    }

    // 下周一/下周三
    final nextWeekPattern = RegExp(
      r'(?:下(?:周|星期))(?:一|二|三|四|五|六|日|天|1|2|3|4|5|6|7|0)',
    );
    for (final match in nextWeekPattern.allMatches(text)) {
      final weekdayStr = match.group(0)!.replaceFirst(RegExp(r'下(?:周|星期)'), '');
      final weekday = weekdayMap[weekdayStr];
      if (weekday != null) {
        final date = _getNextWeekday(now, weekday, offsetDays: 7);
        results.add(
          _createEntity(
            text: match.group(0)!,
            index: match.start,
            date: date,
            hour: 12,
          ),
        );
      }
    }

    return results;
  }

  /// 解析具体日期（如：1月5日、1月5号）
  List<TimeEntity> _parseSpecificDate(String text, DateTime now) {
    final results = <TimeEntity>[];

    // 匹配"1月5日"或"1月5号"
    final pattern1 = RegExp(r'(\d+)月(\d+)[日号]');
    for (final match in pattern1.allMatches(text)) {
      final month = int.parse(match.group(1)!);
      final day = int.parse(match.group(2)!);

      if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
        var date = DateTime(now.year, month, day);

        // 如果这个日期已经过了，则指向明年
        if (date.isBefore(now) &&
            date.month == now.month &&
            date.day < now.day) {
          date = DateTime(now.year + 1, month, day);
        }

        results.add(
          _createEntity(
            text: match.group(0)!,
            index: match.start,
            date: date,
            hour: 12,
          ),
        );
      }
    }

    return results;
  }

  /// 解析时间（如：下午3点、15:30、八点半、两点）
  ///
  /// 时段表达式的钟点/分钟接受中文数字（"晚上八点""晚上八点三十"）——
  /// 语音转写与手输笔记都常出现中文数字写法，纯 \d+ 会漏识；
  /// 分钟支持"半"（"八点半"→:30）与省略"分"字（"3点50"）；
  /// 另支持无时段词的裸钟点（"八点半去提醒我吃饭""两点开会"——口语
  /// 常省时段词，此前这类表达完全解析不到）。
  List<TimeEntity> _parseTime(String text, DateTime now) {
    final results = <TimeEntity>[];

    // 钟点/分钟字符集：阿拉伯数字 + 中文数字（零〇一二两三四五六七八九十）
    const numCls = r'[零〇一二两三四五六七八九十\d]+';

    // (模式, 是否午后[小时<12则+12/上午小时>=12则-12], 纯"一"跳过
    // [防"早一点/晚一点"口语误伤])
    final periodPatterns = <(RegExp, bool, bool)>[
      (
        RegExp('(?:上午|早上|早)($numCls)点(?:钟)?(?:(?:($numCls)(?:分)?)|(半))?'),
        false,
        true,
      ),
      (
        RegExp('(?:下午|中午)($numCls)点(?:钟)?(?:(?:($numCls)(?:分)?)|(半))?'),
        true,
        false,
      ),
      (
        RegExp('(?:晚上|夜间|晚)($numCls)点(?:钟)?(?:(?:($numCls)(?:分)?)|(半))?'),
        true,
        true,
      ),
    ];

    // 时段词命中区间（含被"一"守卫跳过的）：裸钟点与之重叠一律丢弃——
    // 防"下午3点"再拆出重复"3点"、"晚一点"复活成"一点"。
    // 用区间重叠而非前置字断言（(?<!下)会误挡"楼下3点"这种正常话）
    final covered = <({int start, int end})>[];

    for (final (pattern, isPm, skipPureOne) in periodPatterns) {
      for (final match in pattern.allMatches(text)) {
        covered.add((start: match.start, end: match.end));
        if (skipPureOne && match.group(1) == '一') continue;
        final hourRaw = _cnNumToInt(match.group(1)!);
        if (hourRaw == null || hourRaw > 23) continue;
        final minute = _minuteFrom(match.group(2), match.group(3));
        if (minute == null || minute > 59) continue;

        var hour = hourRaw;
        if (isPm && hour < 12) {
          hour += 12;
        } else if (!isPm && hour >= 12) {
          hour -= 12;
        }

        results.add(
          _createEntity(
            text: match.group(0)!,
            index: match.start,
            date: now,
            hour: hour,
            minute: minute,
          ),
        );
      }
    }

    // 裸钟点（无时段词）："点半"吞"钟"字（"八点钟"整段进实体，
    // 标题剥离不留孤字）；前置断言只挡"第3点"序号写法；纯"一"跳过
    final barePattern = RegExp(
      '(?<!第)($numCls)点(?:钟)?(?:(?:($numCls)(?:分)?)|(半))?',
    );
    for (final match in barePattern.allMatches(text)) {
      if (match.group(1) == '一') continue;
      final overlapsCovered = covered.any(
        (r) => match.start < r.end && r.start < match.end,
      );
      if (overlapsCovered) continue;
      final hourRaw = _cnNumToInt(match.group(1)!);
      if (hourRaw == null || hourRaw > 23) continue;
      final minute = _minuteFrom(match.group(2), match.group(3));
      if (minute == null || minute > 59) continue;

      results.add(
        _createEntity(
          text: match.group(0)!,
          index: match.start,
          date: now,
          hour: hourRaw, // 无时段词不偏移，按 24 小时制原样
          minute: minute,
        ),
      );
    }

    // HH:MM 格式
    final clockPattern = RegExp(r'(\d{1,2}):(\d{2})');
    for (final match in clockPattern.allMatches(text)) {
      final hour = int.parse(match.group(1)!);
      final minute = int.parse(match.group(2)!);

      if (hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59) {
        results.add(
          _createEntity(
            text: match.group(0)!,
            index: match.start,
            date: now,
            hour: hour,
            minute: minute,
          ),
        );
      }
    }

    return results;
  }

  /// 解析相对时间（如：3天后、2小时后）
  List<TimeEntity> _parseOffset(String text, DateTime now) {
    final results = <TimeEntity>[];

    // 时间单位映射（秒）
    final unitMs = {
      '秒': 1,
      '分': 60,
      '分钟': 60,
      '小时': 3600,
      '钟': 3600,
      '天': 86400,
      '日': 86400,
      '周': 604800,
      '星期': 604800,
      '月': 2592000, // 30天
      '年': 31536000, // 365天
    };

    // 匹配"3天后"、"2小时后"
    final pattern = RegExp(r'(\d+)(秒|分|分钟|小时|钟|天|日|周|星期|月|年)(?:后|之?后|以?后)');
    for (final match in pattern.allMatches(text)) {
      final amount = int.parse(match.group(1)!);
      final unit = match.group(2)!;
      final seconds = unitMs[unit];

      if (seconds != null) {
        final date = now.add(Duration(seconds: amount * seconds));
        results.add(
          _createEntity(text: match.group(0)!, index: match.start, date: date),
        );
      }
    }

    return results;
  }

  /// 分钟组取值："半"→30；未写分钟（两组皆 null）→0；其余中文/数字串转 int
  static int? _minuteFrom(String? raw, String? half) {
    if (half != null) return 30;
    if (raw == null) return 0;
    return _cnNumToInt(raw);
  }

  /// 中文/阿拉伯数字串转 int（"八"→8、"十二"→12、"二十"→20、"二十一"→21、
  /// "两"→2、"30"→30、"零五"→5）；不合法（空/"一三"式杂混）返回 null
  static int? _cnNumToInt(String raw) {
    if (RegExp(r'^\d+$').hasMatch(raw)) return int.tryParse(raw);
    const digitMap = {
      '零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3,
      '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
    };
    if (raw == '十') return 10;
    if (raw.contains('十')) {
      // 仅支持"X十Y"标准形式（X/Y 可空）
      final parts = raw.split('十');
      if (parts.length != 2) return null;
      final tens = parts[0].isEmpty ? 1 : digitMap[parts[0]];
      final ones = parts[1].isEmpty ? 0 : digitMap[parts[1]];
      if (tens == null || ones == null) return null;
      return tens * 10 + ones;
    }
    if (raw.length == 1) return digitMap[raw];
    // 全是单数字字符的串按位拼接（"零五"→"05"→5）——口语"三点零五"写法
    if (raw.split('').every(digitMap.containsKey)) {
      return int.parse(raw.split('').map((c) => digitMap[c]).join());
    }
    return null;
  }

  /// 获取下一个指定星期几的日期
  /// [weekday] 星期几（0=周日, 1=周一, ..., 6=周六）
  /// [offsetDays] 额外的天数偏移（用于"下周"）
  DateTime _getNextWeekday(DateTime now, int weekday, {int offsetDays = 0}) {
    final currentDay = now.weekday % 7; // 转换为 0=周日, 1=周一
    int diff = weekday - currentDay;

    if (diff < 0) {
      diff += 7;
    }

    // 如果今天就是这个星期X，且没有明确指定"本周"，则指向下周
    if (diff == 0 && offsetDays == 0) {
      diff += 7;
    }

    return now.add(Duration(days: diff + offsetDays));
  }

  /// 创建时间实体
  TimeEntity _createEntity({
    required String text,
    required int index,
    required DateTime date,
    int? hour,
    int? minute,
  }) {
    final finalDate = DateTime(
      date.year,
      date.month,
      date.day,
      hour ?? date.hour,
      minute ?? date.minute,
    );

    return TimeEntity(
      text: text,
      start: index,
      end: index + text.length,
      typeName: 'datetime',
      value: finalDate.toIso8601String(),
      timezone: 'Asia/Shanghai',
    );
  }

  /// 查找文本中第一个匹配的索引
  int? _findFirstMatch(String text, String pattern) {
    final index = text.indexOf(pattern);
    return index >= 0 ? index : null;
  }

  /// 合并相邻的日期+时间实体
  /// 例如："周六"(date) + "早上10点50"(time) → "周六早上10点50"(datetime)
  /// 合并条件：date实体的end == time实体的start（紧挨着，无间隔）
  List<TimeEntity> _mergeAdjacentEntities(
    List<TimeEntity> entities,
    String originalText,
  ) {
    if (entities.length < 2) return entities;

    // 判断一个实体是否是"纯日期"（时分用的是默认填充值）
    bool isDateOnly(TimeEntity e) {
      final dt = e.dateTime;
      if (dt == null) return false;
      // 纯日期实体通常在12:00或当前时间
      // 检查文本是否不包含时间关键词
      final timeKeywords = ['早上', '上午', '下午', '中午', '晚上', '夜间', '点', ':'];
      return !timeKeywords.any((k) => e.text.contains(k));
    }

    // 判断一个实体是否是"纯时间"（日期用的是今天）
    bool isTimeOnly(TimeEntity e) {
      final dateKeywords = [
        '今天', '明天', '后天', '昨天', '前天',
        '周', '星期', '月', '日', '号',
      ];
      return !dateKeywords.any((k) => e.text.contains(k));
    }

    final usedIndices = <int>{};
    final merged = <TimeEntity>[];

    for (int i = 0; i < entities.length; i++) {
      if (usedIndices.contains(i)) continue;

      final current = entities[i];
      bool didMerge = false;

      // 尝试与下一个实体合并
      if (i + 1 < entities.length && !usedIndices.contains(i + 1)) {
        final next = entities[i + 1];

        // 条件1: 紧挨着（中间可能有0-1个字符的间隙，容错）
        final gap = next.start - current.end;
        if (gap >= 0 && gap <= 1) {
          // 条件2: 一个是日期，一个是时间
          if ((isDateOnly(current) && isTimeOnly(next)) ||
              (isTimeOnly(current) && isDateOnly(next))) {
            final dateEntity = isDateOnly(current) ? current : next;
            final timeEntity = isTimeOnly(current) ? current : next;

            final dateDt = dateEntity.dateTime!;
            final timeDt = timeEntity.dateTime!;

            // 从原始文本中截取合并后的完整文本
            final mergedStart = current.start < next.start ? current.start : next.start;
            final mergedEnd = current.end > next.end ? current.end : next.end;
            final mergedText = originalText.substring(mergedStart, mergedEnd);

            // 合并：取日期的年月日 + 时间的时分
            final finalDate = DateTime(
              dateDt.year,
              dateDt.month,
              dateDt.day,
              timeDt.hour,
              timeDt.minute,
            );

            merged.add(TimeEntity(
              text: mergedText,
              start: mergedStart,
              end: mergedEnd,
              typeName: 'datetime',
              value: finalDate.toIso8601String(),
              timezone: 'Asia/Shanghai',
            ));

            usedIndices.add(i);
            usedIndices.add(i + 1);
            didMerge = true;
          }
        }
      }

      if (!didMerge) {
        merged.add(current);
        usedIndices.add(i);
      }
    }

    merged.sort((a, b) => a.start.compareTo(b.start));
    return merged;
  }
}
