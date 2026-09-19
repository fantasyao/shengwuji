import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme_extension.dart';
import 'neu_widgets.dart';

/// 日历事件确认结果（确认按钮返回；取消/点遮罩返回 null）
class CalendarConfirmResult {
  final DateTime time;

  /// 响铃闹钟（enableAlarm 语义：true = 写日历 + AlarmManager 精确响铃；
  /// false = 仅日历事件）
  final bool enableAlarm;

  const CalendarConfirmResult({required this.time, required this.enableAlarm});
}

/// 日历事件确认底部弹层（日记页时间实体点击与悬浮窗闹钟按钮共用；
/// 月视图日历选日期、时分双拨轮选时间，点选/拨刻度带线性马达段落震感）
///
/// 交互流（悬浮窗 OverlayHome._onCardAlarm）：
/// 点闹钟 → DartChronoParser 识别时间 → 本弹层日历/拨轮预填识别结果
/// （识别不到预填 [CalendarHelper.defaultPrefillTime]）→ 用户点日历或拨轮微调
/// → 确认写系统日历。识别结果只决定初始位置，绝不直接定死。
///
/// 布局（2026-09-14 由「左右日期+时间双转轮」改造）：
/// 宽屏（逻辑宽 > [_CalendarConfirmSheetState.wideLayoutMinWidth]）为左右
/// 结构——左 CalendarDatePicker 月视图（点一下选中 x月x号；头部「yyyy年M月」
/// 点按切年份网格，‹ › 翻月箭头与滑动翻月均为组件自带），右
/// CupertinoDatePicker time 模式时分双拨轮（分钟级，高度与日历同排等高）；
/// 窄屏回落上下结构（日历全宽在上、时间轮固定高在下）——日期格宽 = 面板宽/7，
/// 窄于阈值时每格不足 28dp 且头部标题被翻月按钮预留宽截断，挤压不可用。
///
/// 震感：[onHaptic] 由调用方注入本 engine 的触觉通道——主 App 传
/// DiaryTabState._haptic（MethodChannel com.shengwuji.app/app → MainActivity
/// performHaptic），悬浮窗传 AccessibilityOverlay.performHaptic（overlay
/// engine 无 Activity 够不着主 App 通道，由无障碍服务侧同参映射实现）。
/// 点选日期/拨轮跨刻度统一 'tick'（EFFECT_TICK，系统时钟拨轮同款轻段落感；
/// EFFECT_HEAVY_CLICK 偏强，拨轮快速连拨每秒可触发十余次会很「炸」）。
/// null = 静默（测试与未注入场景安全跳过）。
///
/// [eventTitle] 事件标题（CalendarHelper.buildEventTitle 剥离时间短语后的
/// 动作内容，所见即所得：弹窗显示 = 写入日历的 title = 响铃通知内容）；
/// [recognizedPhrase] 识别到的时间原文（如「周六晚上8点」），展示为提示行，
/// 让用户知道日历/拨轮为什么停在这个位置；null = 未识别到，不展示提示行；
/// [alarmAvailable] false = 未授予通知权限（悬浮窗无 Activity 无法请求），
/// 响铃开关禁用置关 + 提示行说明——与日记页"拒绝通知权限则中止"不同，
/// 悬浮窗降级为"仅日历事件不响铃"，不把用户踢去主 App。
Future<CalendarConfirmResult?> showCalendarConfirmSheet(
  BuildContext context, {
  required String eventTitle,
  required DateTime initialTime,
  String? recognizedPhrase,
  bool alarmAvailable = true,
  void Function(String type)? onHaptic,
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
    // isScrollControlled 允许弹层吃到内容实际高度（左右结构约 560~600，
    // 超过小屏半屏），配合内部 SingleChildScrollView 兜底：640dp 级老
    // 16:9 屏上下结构放不下时内容可滚，按钮永远可达
    isScrollControlled: true,
    builder: (context) => CalendarConfirmSheet(
      eventTitle: eventTitle,
      initialTime: initialTime,
      recognizedPhrase: recognizedPhrase,
      alarmAvailable: alarmAvailable,
      onHaptic: onHaptic,
    ),
  );
}

class CalendarConfirmSheet extends StatefulWidget {
  final String eventTitle;
  final DateTime initialTime;
  final String? recognizedPhrase;
  final bool alarmAvailable;

  /// 触觉反馈回调（type 如 'tick'）；见 [showCalendarConfirmSheet] 说明。
  /// 由调用方注入本 engine 的通道，弹层组件不感知 engine 差异
  final void Function(String type)? onHaptic;

  const CalendarConfirmSheet({
    super.key,
    required this.eventTitle,
    required this.initialTime,
    this.recognizedPhrase,
    this.alarmAvailable = true,
    this.onHaptic,
  });

  @override
  State<CalendarConfirmSheet> createState() => _CalendarConfirmSheetState();
}

class _CalendarConfirmSheetState extends State<CalendarConfirmSheet> {
  /// 左右结构的最小逻辑宽（dp）：低于此宽日期格每格 <28dp、头部标题被
  /// 翻月按钮预留宽（CalendarDatePicker 固定预留 108dp）截断，回落上下结构
  static const double wideLayoutMinWidth = 380;

  /// 上下结构（窄屏回落）时时间轮的固定高度：显示约 3 行刻度
  static const double _stackedTimeWheelHeight = 106;

  /// 左右结构时时间拨轮的固定宽度：24h 两列（时|分）舒适宽；
  /// 12h 为三列（上午/下午|时|分）仍可容纳
  static const double _timeWheelWidth = 132;

  late DateTime _selectedTime;
  late bool _enableAlarm;

  /// 日历 initialDate 必须落在 [firstDate, lastDate] 区间内（CalendarDatePicker
  /// 对越界 initialDate 直接断言崩溃；识别出的时间可能早于去年/晚于五年后，
  /// 与旧转轮 minimumDate/maximumDate 同范围，越界时 clamp）
  late final DateTime _clampedInitialDate;

  @override
  void initState() {
    super.initState();
    _selectedTime = widget.initialTime;
    _enableAlarm = widget.alarmAvailable;
    final now = DateTime.now();
    final firstDate = DateTime(now.year - 1);
    final lastDate = DateTime(now.year + 5);
    _clampedInitialDate = widget.initialTime.isBefore(firstDate)
        ? firstDate
        : (widget.initialTime.isAfter(lastDate) ? lastDate : widget.initialTime);
  }

  /// 日历点选 → 只替换日期部分。日历返回的总是合法日期（用户点选的网格日），
  /// 不逐字段赋值（如手动 month 赋值会把 1月31 日溢出成 3月初），时分保留
  void _applyDate(DateTime date) {
    setState(() {
      _selectedTime = DateTime(
        date.year,
        date.month,
        date.day,
        _selectedTime.hour,
        _selectedTime.minute,
      );
    });
    widget.onHaptic?.call('tick');
  }

  /// 时间拨轮跨刻度 → 只替换时分部分。onDateTimeChanged 返回的日期部分无
  /// 意义（time 模式下是 initialDateTime 的日期），不能整体采用
  void _applyTimeOfDay(DateTime dt) {
    setState(() {
      _selectedTime = DateTime(
        _selectedTime.year,
        _selectedTime.month,
        _selectedTime.day,
        dt.hour,
        dt.minute,
      );
    });
    widget.onHaptic?.call('tick');
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // ⚠️ 安全取值（不能用 AppThemeExtension.of 的非空断言）：本弹层历史实现
    // 只依赖 colorScheme，calendar_confirm_sheet_test 等测试环境不挂语义色槽
    final isNeu =
        Theme.of(context).extension<AppThemeExtension>()?.isNeumorphic ??
        false;
    final now = DateTime.now();
    final wide = MediaQuery.of(context).size.width > wideLayoutMinWidth;
    return SafeArea(
      top: false,
      // 小屏兜底可滚（见 showCalendarConfirmSheet 注释）
      child: SingleChildScrollView(
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
                  // 新拟物主题：凹槽轨道+凸滑块开关（主 App 侧；悬浮窗已降级
                  // 默认青，不会走到拟物分支）；其余主题保持 M3 Switch
                  if (isNeu)
                    NeuSwitch(
                      value: _enableAlarm,
                      onChanged: widget.alarmAvailable
                          ? (v) => setState(() => _enableAlarm = v)
                          : null,
                    )
                  else
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
                  '识别到：${widget.recognizedPhrase}（可在日历上调整）',
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
              // 日期=月视图日历 + 时间=时分双拨轮（宽屏左右排、窄屏上下排；
              // 纯 Flutter 组件，悬浮窗 engine 可直接渲染；中文文案来自两侧
              // MaterialApp 的 GlobalMaterialLocalizations/CupertinoLocalizations）
              if (wide)
                _buildSideBySidePickers(colorScheme, now)
              else
                _buildStackedPickers(colorScheme, now),
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
      ),
    );
  }

  /// 宽屏：左日历 + 右时分双拨轮同排。IntrinsicHeight 取日历自然高
  ///（CalendarDatePicker 自身精确高 = 周表头 + 6 行网格）撑行高，
  /// 拨轮列 stretch 等高——拨动行程与转轮时代相当且不随内容跳动
  Widget _buildSideBySidePickers(ColorScheme colorScheme, DateTime now) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _buildCalendarPicker(colorScheme, now)),
          const SizedBox(width: 10),
          SizedBox(
            width: _timeWheelWidth,
            child: _buildTimeWheelPicker(colorScheme, now),
          ),
        ],
      ),
    );
  }

  /// 窄屏回落：日历全宽在上、时间轮固定高在下
  Widget _buildStackedPickers(ColorScheme colorScheme, DateTime now) {
    return Column(
      children: [
        _buildCalendarPicker(colorScheme, now),
        const SizedBox(height: 10),
        SizedBox(
          height: _stackedTimeWheelHeight,
          child: _buildTimeWheelPicker(colorScheme, now),
        ),
      ],
    );
  }

  /// 月视图日历容器（M3 CalendarDatePicker：选中日实心圆、今天描边圆、
  /// 非本月置灰；头部点按切年份网格，‹ › 与横滑翻月组件自带）
  Widget _buildCalendarPicker(ColorScheme colorScheme, DateTime now) {
    return Container(
      decoration: _pickerBoxDecoration(colorScheme),
      clipBehavior: Clip.antiAlias,
      child: CalendarDatePicker(
        key: const ValueKey('calendar_confirm_calendar'),
        initialDate: _clampedInitialDate,
        firstDate: DateTime(now.year - 1),
        lastDate: DateTime(now.year + 5),
        onDateChanged: _applyDate,
      ),
    );
  }

  /// 时分双拨轮容器（CupertinoDatePicker time 模式：时/分独立轮、分钟级；
  /// use24hFormat 跟随系统，12h 时为「上午/下午|时|分」三列）
  Widget _buildTimeWheelPicker(ColorScheme colorScheme, DateTime now) {
    return Container(
      decoration: _pickerBoxDecoration(colorScheme),
      clipBehavior: Clip.antiAlias,
      child: CupertinoDatePicker(
        // key 沿用旧 dateAndTime 转轮的名字：语义同为「时间拨轮」，
        // 测试与悬浮窗无外部依赖，仅作为弹层内定位锚点
        key: const ValueKey('calendar_confirm_picker'),
        mode: CupertinoDatePickerMode.time,
        use24hFormat: MediaQuery.of(context).alwaysUse24HourFormat,
        minuteInterval: 1,
        initialDateTime: widget.initialTime,
        onDateTimeChanged: _applyTimeOfDay,
      ),
    );
  }

  /// 选择区统一底色容器（旧转轮同款：surfaceContainerHighest 40% + 圆角 12）
  BoxDecoration _pickerBoxDecoration(ColorScheme colorScheme) {
    return BoxDecoration(
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(12),
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
