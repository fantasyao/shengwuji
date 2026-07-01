/// 时间实体模型
/// 用于封装从 Microsoft Recognizers-Text 解析出的时间信息
class TimeEntity {
  /// 原始文本，如"明天下午8点"
  final String text;

  /// 在源文本中的起始索引
  final int start;

  /// 在源文本中的结束索引
  final int end;

  /// 类型名称：datetime/timer/duration
  final String typeName;

  /// ISO 8601 时间字符串
  final String value;

  /// 时区信息（可选）
  final String? timezone;

  TimeEntity({
    required this.text,
    required this.start,
    required this.end,
    required this.typeName,
    required this.value,
    this.timezone,
  });

  /// 从 Map 创建（用于 Method Channel 返回值解析）
  factory TimeEntity.fromMap(Map<String, dynamic> map) {
    return TimeEntity(
      text: map['text'] as String,
      start: map['start'] as int,
      end: map['end'] as int,
      typeName: map['typeName'] as String? ?? 'datetime',
      value: map['value'] as String,
      timezone: map['timezone'] as String?,
    );
  }

  /// 解析为 DateTime 对象
  DateTime? get dateTime {
    try {
      return DateTime.parse(value);
    } catch (e) {
      return null;
    }
  }

  /// 判断是否为未来时间
  bool get isFuture {
    final dt = dateTime;
    return dt != null && dt.isAfter(DateTime.now());
  }

  /// 获取友好的时间显示文本
  String get displayText {
    final dt = dateTime;
    if (dt == null) return text;

    final now = DateTime.now();
    final difference = dt.difference(now);

    // 判断是否为今天、明天或昨天
    if (difference.inDays == 0 || (difference.inDays == -1 && dt.day == now.day)) {
      // 今天
      final hour = dt.hour.toString().padLeft(2, '0');
      final minute = dt.minute.toString().padLeft(2, '0');
      return '今天 $hour:$minute';
    } else if (difference.inDays == 1) {
      // 明天
      final hour = dt.hour.toString().padLeft(2, '0');
      final minute = dt.minute.toString().padLeft(2, '0');
      return '明天 $hour:$minute';
    } else if (difference.inDays == -1) {
      // 昨天
      final hour = dt.hour.toString().padLeft(2, '0');
      final minute = dt.minute.toString().padLeft(2, '0');
      return '昨天 $hour:$minute';
    } else {
      // 其他日期
      return '${dt.month}月${dt.day}日 ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
    }
  }

  @override
  String toString() {
    return 'TimeEntity(text: $text, start: $start, end: $end, value: $value)';
  }
}
