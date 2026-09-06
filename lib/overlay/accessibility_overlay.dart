import 'package:flutter/services.dart';
// 说明：VoidCallback 由 services.dart 透出，无需额外 import foundation.dart

/// 无障碍浮窗（TYPE_ACCESSIBILITY_OVERLAY）与原生层的通信通道
///
/// 因为 flutter_overlay_window 在小米/HyperOS 上被系统级拦截，
/// 现在改用已有的无障碍服务来创建和管理浮窗。本类负责把 Dart 层的
/// 尺寸/焦点/关闭请求转发给原生服务。
class AccessibilityOverlay {
  static const MethodChannel _channel = MethodChannel(
    'com.shengwuji.app/accessibility_overlay',
  );

  /// 调整浮窗尺寸
  static Future<void> resizeOverlay(
    int width,
    int height, {
    bool enableDrag = false,
  }) async {
    await _channel.invokeMethod('resizeOverlay', {
      'width': width,
      'height': height,
      'enableDrag': enableDrag,
    });
  }

  /// 更新浮窗标志位
  ///
  /// - `defaultFlag`：不可聚焦（收起态把手）
  /// - `focusPointer`：可聚焦（编辑态需要键盘）
  static Future<void> updateFlag(String flag) async {
    await _channel.invokeMethod('updateFlag', {'flag': flag});
  }

  /// 关闭浮窗
  static Future<void> closeOverlay() async {
    await _channel.invokeMethod('closeOverlay');
  }

  /// 注册原生→Dart 消息（expand / reset / startVoiceMemo / stopVoiceMemo /
  /// newNote）。
  /// 原生 showOverlay(autoExpand: true) 若早于本注册到达会被静默丢弃，
  /// 因此原生侧用 dartReady/pendingAutoExpand 握手兜底（语音速记的
  /// pendingVoiceMemoStart 同机制）。
  /// 调用方：overlay_home.dart initState；参数为收到消息后的回调。
  /// [onStartVoiceMemo] 携带 Kotlin 发来的 hiddenReveal 负载：true = 当前是
  /// 隐藏窗口（alpha=0 等揭示），Dart 据此决定 voiceMemoUiReady 的发送时机
  ///（隐藏窗口由揭示门在"录音态首帧"构建完后发，见 overlay_home 的
  /// _revealGatePending 注释；消除揭示竞态）
  /// [onNewNote]：悬浮窗新增笔记（overlay_new_note 手势动作），payload null
  static void setupNativeChannel({
    required VoidCallback onExpand,
    required VoidCallback onReset,
    required void Function(bool hiddenReveal) onStartVoiceMemo,
    required VoidCallback onStopVoiceMemo,
    VoidCallback? onNewNote,
  }) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'expand':
          onExpand();
        case 'reset':
          onReset();
        case 'startVoiceMemo':
          // Kotlin 携带 hiddenReveal 负载（map）；旧版本发 null 时按 false
          // 兼容（把手在屏上路径语义：立即发 voiceMemoUiReady，Kotlin 非
          // pendingVoiceMemoReveal 时收到是 no-op）
          final args = call.arguments;
          onStartVoiceMemo(args is Map && args['hiddenReveal'] == true);
        case 'stopVoiceMemo':
          onStopVoiceMemo();
        case 'newNote':
          onNewNote?.call();
      }
      return null;
    });
  }

  /// 握手：原生收到后若挂起 pendingAutoExpand 会立即补发 expand。
  /// 调用方：overlay_home.dart initState（setupNativeChannel 之后调用）
  static Future<void> notifyDartReady() async {
    await _channel.invokeMethod('dartReady');
  }

  // ── 语音速记回执（Dart → Kotlin，Kotlin 侧 toggle 状态机的复位依据）──
  // Kotlin 侧 stopVoiceMemo 有 3s 超时兜底，回执晚到也幂等

  /// 回执：语音速记录音已真正开始（取消 Kotlin 侧可能的 stop 超时兜底计时）。
  /// 调用方：overlay_home.dart（controller.start() 成功后）
  static Future<void> voiceMemoStarted() async {
    await _channel.invokeMethod('voiceMemoStarted');
  }

  /// 回执：录音胶囊 UI 首帧已渲染完成（冷启动隐藏窗口的揭示信号）。
  /// Kotlin 收到后把隐藏窗口（alpha=0 + NOT_TOUCHABLE）恢复 alpha=1——
  /// 保证用户看到的第一个画面是录音胶囊而非把手。
  /// 调用方：overlay_home.dart——隐藏窗口模式由揭示门在"录音态首帧"构建完
  /// 发出（build 挂门短路，见 _revealGatePending 注释）；把手在屏上的原地
  /// 切换路径维持 voiceMemoStarted 回执后立即发（Kotlin 非 pending 时收到
  /// 是 no-op）
  static Future<void> voiceMemoUiReady() async {
    await _channel.invokeMethod('voiceMemoUiReady');
  }

  /// 回执：语音速记录音已停止（进入转写，Kotlin 复位 voiceMemoActive）。
  /// 调用方：OverlayVoiceMemoController.stop
  static Future<void> voiceMemoStopped() async {
    await _channel.invokeMethod('voiceMemoStopped');
  }

  /// 回执：语音速记失败（权限未授予/麦克风被占等，Kotlin 复位并隐藏浮窗）。
  /// 调用方：OverlayVoiceMemoController.fail / overlay_home.dart start 失败分支
  static Future<void> voiceMemoFailed(String reason) async {
    await _channel.invokeMethod('voiceMemoFailed', {'reason': reason});
  }

  /// 回执：语音速记转写完成（成功/失败/丢弃的统一收尾）→ 原生清除浮窗常亮。
  /// 调用方：OverlayVoiceMemoController._finishTranscribe（所有收尾路径共用出口）
  static Future<void> voiceMemoFinished() async {
    await _channel.invokeMethod('voiceMemoFinished');
  }

  /// 系统分享面板（悬浮窗无 Activity，由原生 Service 侧起 ACTION_SEND，
  /// 内部已加 FLAG_ACTIVITY_NEW_TASK）。卡片分享入口已于 2026-09-05 替换为
  /// AI 对话按钮（见 launchApp），本方法暂留作通道 API 备用（Kotlin handler
  /// 同步保留，未来 flomo 分享卡片等入口可复用）
  static Future<void> shareText(String text) async {
    await _channel.invokeMethod('shareText', {'text': text});
  }

  /// 拉起外部应用（悬浮窗无 Activity，由原生 Service 侧 startActivity，
  /// 内部统一加 FLAG_ACTIVITY_NEW_TASK）。原生启动顺序：包名 → scheme →
  /// web url 三级兜底，全部失败 Toast 提示并返回 false。微信等偏好 scheme
  /// 的应用由调用方传空 packageName 跳过包名步骤（对齐日记页 _shareToAI）。
  /// 调用方：OverlayHome._onCardShareToAI
  static Future<bool> launchApp({
    required String name,
    required String packageName,
    required String scheme,
    required String url,
  }) async {
    final ok = await _channel.invokeMethod('launchApp', {
      'name': name,
      'packageName': packageName,
      'scheme': scheme,
      'url': url,
    });
    return ok == true;
  }

  /// 复制文本到系统剪贴板（原生侧 ClipboardManager 写入 + EFFECT_TICK 震动
  /// 反馈，对齐主 App 日记页卡片复制；Dart 的 Clipboard 系统通道在 overlay
  /// engine + 后台状态下不可靠）。返回 true = 写入成功。
  /// 调用方：OverlayHome._onCardCopy / _onCardShareToAI
  static Future<bool> copyText(String text) async {
    final ok = await _channel.invokeMethod('copyText', {'text': text});
    return ok == true;
  }

  /// 删除按钮震动反馈：走原生 EFFECT_TICK，对齐复制按钮反馈。
  /// 调用方：OverlayHome._onCardDelete（删除按钮两次点击）
  static Future<void> vibrateTick() async {
    await _channel.invokeMethod('vibrateTick');
  }

  // ── 语音速记临时静音（悬浮窗录音，与主 App 快捷录音同一份交互）──
  // 原生实现在 MediaMuteHelper（与 MainActivity 静音 handler 共用的伴生工具，
  // 本通道由无障碍 Service 侧执行）。保持静音的标记方在 Service 的音量减
  // adjustVolume，受设置页「按音量减保持静音」开关控制——一个开关管两处录音

  /// 录音开始时临时静音媒体：保存当前音量 → 音量置 0。
  /// 调用方：OverlayVoiceMemoController.start（录音流开成功后）
  static Future<void> muteMedia() async {
    await _channel.invokeMethod('muteMedia');
  }

  /// 录音结束后恢复媒体音量（用户录音中按过音量减则保持静音，见 MediaMuteHelper）。
  /// 调用方：OverlayVoiceMemoController.stop / fail
  static Future<void> restoreMedia() async {
    await _channel.invokeMethod('restoreMedia');
  }

  // ── 悬浮窗闹钟（日历提醒，OverlayHome._onCardAlarm）──
  // 语义说明：写日历的 addCalendarEvent 原生实现在主 App 的 MainActivity
  // 通道（com.shengwuji.app/app）——两个 engine messenger 互不相通，悬浮窗
  // 调不到；这里的日历方法走本通道，由 CalendarEventHelper（与 MainActivity
  // 共用的伴生工具）在无障碍 Service 侧执行

  /// 检查闹钟相关权限（原生 checkSelfPermission，不需要 Activity——
  /// permission_handler 的 request() 需要 Activity，悬浮窗 engine 没有）。
  /// calendar = READ+WRITE_CALENDAR（写事件必需）；
  /// notification = POST_NOTIFICATIONS（API 33+ 响铃通知必需，33 以下恒 true）。
  /// 通道异常返回 null（调用方按最严处理）。
  /// 调用方：OverlayHome._onCardAlarm（弹确认 sheet 前预检）
  static Future<({bool calendar, bool notification})?> checkAlarmPermissions() async {
    try {
      final raw = await _channel.invokeMethod('checkAlarmPermissions');
      if (raw is Map) {
        return (
          calendar: raw['calendar'] == true,
          notification: raw['notification'] == true,
        );
      }
      return null;
    } catch (e) {
      print('⏰ [AccessibilityOverlay] checkAlarmPermissions 失败: $e');
      return null;
    }
  }

  /// 缺日历权限时的补救路径：原生 Toast 提示 + 拉起主 App（launcher intent
  /// 带 type=grant_calendar extra，MainActivity 路由到 Dart 后自动弹系统
  /// 授权框——悬浮窗无 Activity 不能自己请求）。
  /// ⚠️ 调用方必须先收起面板：授权框弹在主 App，窗口层级低于悬浮窗，展开的
  /// 面板（全屏窗口期连透明区都吞触摸）会挡住授权框。
  /// 调用方：OverlayHome._onCardAlarm（收起等 _collapseSettled 后调用）
  static Future<void> requestCalendarPermission() async {
    await _channel.invokeMethod('requestCalendarPermission');
  }

  /// 写系统日历 + 按需设置 AlarmManager 精确响铃（与日记页写日历同一份
  /// 原生逻辑 CalendarEventHelper）。成功/失败反馈由原生侧 Toast 完成。
  /// 返回 true = 事件写入成功。调用方：OverlayHome._onCardAlarm
  static Future<bool> addCalendarEvent({
    required DateTime time,
    required String title,
    required bool enableAlarm,
  }) async {
    final ok = await _channel.invokeMethod('addCalendarEvent', {
      'timestamp': time.millisecondsSinceEpoch,
      'title': title,
      'enableAlarm': enableAlarm,
    });
    return ok == true;
  }
}
