import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// 日历事件确认结果（确认按钮返回；取消/点遮罩返回 null）
class CalendarConfirmResult {
  final DateTime time;

  /// 响铃闹钟（enableAlarm 语义：true = 写日历 + AlarmManager 精确响铃；
  /// false = 仅日历事件）
  final bool enableAlarm;

  const CalendarConfirmResult({required this.time, required this.enableAlarm});
}

/// 日历事件确认底部弹层（日记页时间实体点击与悬浮窗闹钟按钮共用；
/// 转轮预填、可改、永不打字）
///
/// 交互流（悬浮窗 OverlayHome._onCardAlarm）：
/// 点闹钟 → DartChronoParser 识别时间 → 本弹层转轮预填识别结果
/// （识别不到预填 [CalendarHelper.defaultPrefillTime]）→ 用户转轮微调
/// → 确认写系统日历。识别结果只决定转轮初始位置，绝不直接定死。
///
/// [eventTitle] 事件标题（CalendarHelper.buildEventTitle 剥离时间短语后的
/// 动作内容，所见即所得：弹窗显示 = 写入日历的 title = 响铃通知内容）；
/// [recognizedPhrase] 识别到的时间原文（如「周六晚上8点」），展示为提示行，
/// 让用户知道转轮为什么停在这个位置；null = 未识别到，不展示提示行；
/// [alarmAvailable] false = 未授予通知权限（悬浮窗无 Activity 无法请求），
/// 响铃开关禁用置关 + 提示行说明——与日记页"拒绝通知权限则中止"不同，
/// 悬浮窗降级为"仅日历事件不响铃"，不把用户踢去主 App。
Future<CalendarConfirmResult?> showCalendarConfirmSheet(
  BuildContext context, {
  required String eventTitle,
  required DateTime initialTime,
  String? recognizedPhrase,
  bool alarmAvailable = true,
}) {
  return showModalBottomSheet<CalendarConfirmResult>(
    context: context,
    // 不传 backgroundColor：吃主题 colorScheme.surface 不透明底（四套主题
    // surface 均为不透明白）。传 transparent 又不自己画背景容器会让内容
    // 直接叠在遮罩上——悬浮窗 engine 的 FlutterView 本身透明，下层卡片
    // 文字全部透出（2026-09-06 真机首验踩坑）。圆角用项目同款 shape
    //（对齐 pro_unlock_dialog 付款方式弹层：顶部圆角 16）
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    isScrollControlled: true,
    builder: (context) => CalendarConfirmSheet(
      eventTitle: eventTitle,
      initialTime: initialTime,
      recognizedPhrase: recognizedPhrase,
      alarmAvailable: alarmAvailable,
    ),
  );
}

class CalendarConfirmSheet extends StatefulWidget {
  final String eventTitle;
  final DateTime initialTime;
  final String? recognizedPhrase;
  final bool alarmAvailable;

  const CalendarConfirmSheet({
    super.key,
    required this.eventTitle,
    required this.initialTime,
    this.recognizedPhrase,
    this.alarmAvailable = true,
  });

  @override
  State<CalendarConfirmSheet> createState() => _CalendarConfirmSheetState();
}

class _CalendarConfirmSheetState extends State<CalendarConfirmSheet> {
  late DateTime _selectedTime;
  late bool _enableAlarm;

  @override
  void initState() {
    super.initState();
    _selectedTime = widget.initialTime;
    _enableAlarm = widget.alarmAvailable;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题行 + 响铃开关（日记页原 AlarmDialog 的「响铃闹钟」开关语义，
            // 该对话框已删除、两入口共用本弹层）
            Row(
              children: [
                Expanded(
                  child: Text(
                    '添加日历提醒',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Text(
                  '响铃闹钟',
                  style: TextStyle(
                    fontSize: 13,
                    color: _enableAlarm
                        ? colorScheme.onSurfaceVariant
                        : colorScheme.outline,
                  ),
                ),
                const SizedBox(width: 4),
                Switch(
                  value: _enableAlarm,
                  // 通知权限缺失时禁用（悬浮窗无法请求权限，降级仅日历事件）
                  onChanged: widget.alarmAvailable
                      ? (v) => setState(() => _enableAlarm = v)
                      : null,
                ),
              ],
            ),
            // 提示行：识别到的时间原文 / 响铃不可用说明（可同时出现）
            if (widget.recognizedPhrase != null)
              _buildHintRow(
                Icons.alarm_on,
                '识别到：${widget.recognizedPhrase}（可转轮调整）',
                colorScheme.primary,
              ),
            if (!widget.alarmAvailable)
              _buildHintRow(
                Icons.notifications_off_outlined,
                '未授予通知权限，响铃不可用（仅日历事件）',
                colorScheme.outline,
              ),
            const SizedBox(height: 8),
            Text(
              widget.eventTitle,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            // 日期+时间转轮（iOS 同款上下滚动；纯 Flutter 组件，悬浮窗
            // engine 可直接渲染；中文文案来自 OverlayApp 的本地化配置）
            Container(
              height: 216,
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.4,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              clipBehavior: Clip.antiAlias,
              child: CupertinoDatePicker(
                key: const ValueKey('calendar_confirm_picker'),
                mode: CupertinoDatePickerMode.dateAndTime,
                use24hFormat: MediaQuery.of(context).alwaysUse24HourFormat,
                minuteInterval: 1,
                initialDateTime: widget.initialTime,
                minimumDate: DateTime(now.year - 1),
                maximumDate: DateTime(now.year + 5),
                onDateTimeChanged: (dt) =>
                    setState(() => _selectedTime = dt),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('calendar_confirm_ok'),
                    onPressed: () => Navigator.of(context).pop(
                      CalendarConfirmResult(
                        time: _selectedTime,
                        enableAlarm: _enableAlarm,
                      ),
                    ),
                    child: const Text('添加到日历'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHintRow(IconData icon, String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: color),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
