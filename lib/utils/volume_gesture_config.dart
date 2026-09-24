/// 音量键手势槽位配置：常量 + 旧配置迁移推导（纯函数）。
///
/// 架构说明：设置页（Dart）与无障碍服务（Kotlin VolumeKeyAccessibilityService）共享同一组
/// SharedPreferences key（原生侧加 "flutter." 前缀）。Kotlin 侧内置同一套迁移 fallback 规则
/// （无障碍服务常驻，App 未打开时也要正确）；本文件的推导仅供设置页显示层使用，
/// 用户改动时才写入新 key。

library;

import 'package:shared_preferences/shared_preferences.dart';

/// 槽位可绑定的动作值（存 SharedPreferences 的字符串常量）。
///
/// 读取方：
/// - 设置页（本文件 loadVolumeGestureActions + 后续的槽位选择 UI）
/// - Kotlin VolumeKeyAccessibilityService（"flutter." 前缀读同一批 key）
///
/// 写入方：设置页（用户改动槽位时写入新 key）
class VolumeGestureAction {
  VolumeGestureAction._(); // 纯常量类，禁止实例化

  /// 无动作（槽位关闭）
  static const String none = 'none';

  /// 显示悬浮窗（显示并自动展开面板；悬浮窗已显示时再触发=立即彻底隐藏，toggle 语义）
  static const String showOverlay = 'show_overlay';

  /// 悬浮窗语音速记（长按直接录音）
  static const String overlayRecord = 'overlay_record';

  /// 快速录音（拉起主 App 录音）
  static const String quickRecord = 'quick_record';

  /// 新建文本笔记
  static const String quickTextNote = 'quick_text_note';

  /// 悬浮窗新增笔记（展开面板 + 插入占位行进入编辑态）
  static const String overlayNewNote = 'overlay_new_note';

  /// 按住说话（实验分支）：长按槽位专属动作——按住达阈值即开录，松开同一键
  /// 立即停录转写。Kotlin 侧复用悬浮窗语音速记链路（ACTION_PTT_RECORD，跨端
  /// 硬编码副本须双侧同步），仅触发与收尾时机不同。双击槽位无「按住中态」
  ///（触发即抬手），没有松手停录语义，设置页只在长按两行提供此选项
  static const String pttRecord = 'ptt_record';

  /// 全部合法动作值（合法性校验 + 设置页选项列表共用）
  static const List<String> all = [
    none,
    showOverlay,
    overlayRecord,
    quickRecord,
    quickTextNote,
    overlayNewNote,
    pttRecord,
  ];

  /// 值是否为合法动作（防 prefs 里存了历史遗留/损坏值）
  static bool isValid(String v) => all.contains(v);
}

/// 手势槽位 key（4 槽位 SharedPreferences key 常量）。
///
/// 读取方/写入方同 [VolumeGestureAction] 类注释。
class VolumeGestureSlot {
  VolumeGestureSlot._(); // 纯常量类，禁止实例化

  /// 长按音量上键
  static const String longPressUp = 'volume_gesture_long_press_up';

  /// 长按音量下键
  static const String longPressDown = 'volume_gesture_long_press_down';

  /// 双击音量上键
  static const String doubleClickUp = 'volume_gesture_double_click_up';

  /// 双击音量下键
  static const String doubleClickDown = 'volume_gesture_double_click_down';

  /// 全部槽位 key（遍历顺序即设置页展示顺序）
  static const List<String> all = [
    longPressUp,
    longPressDown,
    doubleClickUp,
    doubleClickDown,
  ];
}

/// 长按触发阈值（毫秒）：配置 key + 预设档位 + 自定义范围 + 校验。
///
/// 与 4 槽位同模式：设置页 ChoiceChip 写入，Kotlin 无障碍服务每次按键 DOWN
/// 时读落盘 prefs 启动长按计时（无需 MethodChannel，App 未打开也生效）。
/// 2026-09-23 新增「自定义」档（点 chip 弹输入框，50–2000ms 任意值）后，
/// 合法域从预设集合放开为闭区间——预设集合只管设置页 chip 展示，Kotlin 侧
/// 校验同步从集合白名单改为范围校验：⚠️ minMs/maxMs 是新的跨端硬编码副本对
///（Kotlin LONG_PRESS_MS_MIN/MAX），改边界必须双侧同步。
class VolumeLongPressMs {
  VolumeLongPressMs._(); // 纯常量类，禁止实例化

  /// prefs key（Kotlin 侧读取时加 "flutter." 前缀）
  static const String prefKey = 'volume_long_press_ms';

  /// 预设档位（毫秒），设置页 ChoiceChip 展示用。2026-09-21 按用户实测反馈
  /// 从 400/500/800/1200 下调为 200/300/400/700（旧最短档 400 体感仍偏钝，
  /// 重度使用者宁愿改用双击）；2026-09-23 起最短不再受预设限制，用户可经
  /// 「自定义」档输入 50–2000 任意值
  static const List<int> choices = [200, 300, 400, 700];

  /// 自定义档允许的范围边界（毫秒，闭区间）。⚠️ 与 Kotlin 侧
  /// LONG_PRESS_MS_MIN / LONG_PRESS_MS_MAX 严格一致（跨端硬编码副本，改值
  /// 必须双侧同步）。下限 50：刻意单击的按压时长约 100~300ms，低于 100 的
  /// 档位不再只是「误判偏重单击」，而是把该键上的单击调音量/双击手势整体
  /// 挤掉（每次按下都先到长按阈值，UP 被 wasLongPress 短路）——设置页在
  /// 值 <100 时显示警示文案；上限 2000 再长已无「按住」手感
  static const int minMs = 50;
  static const int maxMs = 2000;

  /// 默认档位（未设置/脏值时回落）
  static const int defaultMs = 400;

  /// 合法性校验：[minMs, maxMs] 内的值（含预设档与自定义档）原样生效，
  /// 缺失/脏值/越界回落默认。2026-09-21 版曾把「不在预设集合内」一律回落
  /// 400（旧默认 500 就近迁移）；自定义档放开后范围取代集合成为合法域，
  /// 旧档位 500/800/1200 都在范围内，老用户升级后按原值继续生效（设置页
  /// 显示为「自定义」档，属刻意选择：尊重其当年显式选的档位，不再二次改写）
  static int normalize(int? value) =>
      (value != null && value >= minMs && value <= maxMs) ? value : defaultMs;

  /// 值是否为自定义档（不在预设集合内；入参应是 normalize 后的合法值）。
  /// 设置页据此决定选中「自定义」chip 还是某个预设 chip
  static bool isCustom(int value) => !choices.contains(value);
}

/// 「录音中单击结束录音」开关 prefs key。
///
/// 开启后录音中（主 App 录音或悬浮窗语音速记）单击音量键立即停录，无需再
/// 长按 toggle；耳机线控键/相机键同样生效（平时完全不拦截，仅录音中消费）。
///
/// ⚠️ 与 `keep_muted_on_volume_down`（按音量减保持静音）互斥二选一：单击停录
/// 开启后录音中单击音量减不再走 adjustVolume，keep_muted 标记失去触发入口，
/// 两个开关同开语义自相矛盾——互斥由设置页保证（开一个自动关另一个，
/// volume_key_settings_page），Kotlin 侧不重复校验。
///
/// 读取方：Kotlin 无障碍服务每次按键实时读落盘（"flutter." 前缀，同 4 槽位
/// key 模式：无 MethodChannel、App 未打开也生效）；overlay 语音速记 start()
/// 读同一 key 选停止提示文案。写入方：设置页（唯一）。
const kSingleClickStopRecordingKey = 'single_click_stop_recording';

/// 旧版 SharedPreferences key（迁移推导的输入，仅本文件读取，落盘值不再写入）。
const _legacyKeyVolumeKeyMode = 'volume_key_mode';
const _legacyKeyOverlayVolumeUpLongPress = 'overlay_volume_up_long_press';
const _legacyKeyOverlayVolumeUpAction = 'overlay_volume_up_action';
const _legacyKeyDoubleClickTextNote = 'double_click_text_note';

/// 从 4 个旧 key 推导 4 个槽位的动作（纯函数，不碰 prefs）。
///
/// 参数 null = 旧 key 不存在（全新安装或旧版本从未写过），按旧版默认值处理：
/// volumeKeyMode → 'down'、overlayVolumeUpLongPress → false、doubleClickTextNote → true。
///
/// 推导规则（须与 Kotlin 侧内置的 fallback 保持一致）：
/// - longPressUp：悬浮窗开关优先（开了就把上键完全让渡给悬浮窗——action='record'
///   → 语音速记，否则 → 显示悬浮窗）；未开时 mode 含 up（up/both）→ 快速录音；否则 none
/// - longPressDown：mode 含 down（down/both）→ 快速录音；否则 none
/// - doubleClickUp：mode 含 up 且双击开关开 → 文本笔记；否则 none
/// - doubleClickDown：mode 含 down 且双击开关开 → 文本笔记；否则 none
///
/// 全 null（全新安装）推出出厂默认：longPressDown=quickRecord、
/// doubleClickDown=quickTextNote、两个 up 槽位=none。
Map<String, String> migrateVolumeGestures({
  String? volumeKeyMode,
  bool? overlayVolumeUpLongPress,
  String? overlayVolumeUpAction,
  bool? doubleClickTextNote,
}) {
  // null → 旧版默认值（见方法注释）
  final mode = volumeKeyMode ?? 'down';
  final overlayUpEnabled = overlayVolumeUpLongPress ?? false;
  final overlayAction = overlayVolumeUpAction ?? 'show';
  final doubleClickEnabled = doubleClickTextNote ?? true;

  final modeHasUp = mode == 'up' || mode == 'both';
  final modeHasDown = mode == 'down' || mode == 'both';

  // 长按上键：悬浮窗开关优先级最高，覆盖 volume_key_mode 的 up/both 分支
  final String longPressUp;
  if (overlayUpEnabled) {
    longPressUp = overlayAction == 'record'
        ? VolumeGestureAction.overlayRecord
        : VolumeGestureAction.showOverlay;
  } else if (modeHasUp) {
    longPressUp = VolumeGestureAction.quickRecord;
  } else {
    longPressUp = VolumeGestureAction.none;
  }

  final String longPressDown = modeHasDown
      ? VolumeGestureAction.quickRecord
      : VolumeGestureAction.none;

  final String doubleClickUp = modeHasUp && doubleClickEnabled
      ? VolumeGestureAction.quickTextNote
      : VolumeGestureAction.none;

  final String doubleClickDown = modeHasDown && doubleClickEnabled
      ? VolumeGestureAction.quickTextNote
      : VolumeGestureAction.none;

  return {
    VolumeGestureSlot.longPressUp: longPressUp,
    VolumeGestureSlot.longPressDown: longPressDown,
    VolumeGestureSlot.doubleClickUp: doubleClickUp,
    VolumeGestureSlot.doubleClickDown: doubleClickDown,
  };
}

/// 读取 4 个槽位的动作：新 key 已写入且合法 → 直接用；
/// 缺失或非法的槽位 → 从旧 key 推导补齐。
///
/// **不写回 prefs**（用户改动时设置页才写入新 key）——与 Kotlin 侧
/// "各自内置迁移 fallback"的策略对齐，读取保持无副作用。
Future<Map<String, String>> loadVolumeGestureActions(
  SharedPreferences prefs,
) async {
  final result = <String, String>{};
  var hasGap = false;

  for (final slot in VolumeGestureSlot.all) {
    final value = prefs.getString(slot);
    if (value != null && VolumeGestureAction.isValid(value)) {
      result[slot] = value;
    } else {
      hasGap = true; // 该槽位缺失或存了非法值，需要迁移推导补齐
    }
  }

  if (hasGap) {
    final migrated = migrateVolumeGestures(
      volumeKeyMode: prefs.getString(_legacyKeyVolumeKeyMode),
      overlayVolumeUpLongPress: prefs.getBool(
        _legacyKeyOverlayVolumeUpLongPress,
      ),
      overlayVolumeUpAction: prefs.getString(_legacyKeyOverlayVolumeUpAction),
      doubleClickTextNote: prefs.getBool(_legacyKeyDoubleClickTextNote),
    );
    for (final slot in VolumeGestureSlot.all) {
      result[slot] ??= migrated[slot]!;
    }
  }

  return result;
}
