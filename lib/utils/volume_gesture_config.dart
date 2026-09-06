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

  /// 全部合法动作值（合法性校验 + 设置页选项列表共用）
  static const List<String> all = [
    none,
    showOverlay,
    overlayRecord,
    quickRecord,
    quickTextNote,
    overlayNewNote,
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
