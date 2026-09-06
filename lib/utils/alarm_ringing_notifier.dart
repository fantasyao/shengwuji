import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 闹钟响铃状态持有者（性能审查 Top5：替代全局 2 秒 prefs 轮询）
///
/// 响铃标志的原生写入方是 AlarmReceiver（广播接收器，无 Activity 上下文），
/// 现改为双通道通知 Dart：
/// - **事件推送**（常态）：原生响铃开始/停止时经 `com.shengwuji.app/app` 通道推
///   `onAlarmRinging` / `onAlarmStopped`，见 MainActivity.flutterChannel；
/// - **冷启动恢复**（兜底）：进程被杀后闹钟触发过、用户未点通知直接打开 APP 时
///   无引擎可推事件，靠 [restoreOnce] 从 SharedPreferences 一次性读回标志。
///   原生侧仍照旧写 SharedPreferences 标志，就是为这条兜底路径服务。
class AlarmRingingNotifier extends ChangeNotifier {
  bool _ringing = false;

  /// 当前是否响铃中（MainScaffold 据此显隐顶部红色停止横幅）
  bool get ringing => _ringing;

  /// 冷启动一次性恢复。只需在 initState 调一次：进程启动后原生再写的标志
  /// 一律走事件推送，读缓存值不会漏。
  Future<void> restoreOnce() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('is_alarm_ringing') ?? false) {
      if (!_ringing) {
        _ringing = true;
        notifyListeners();
      }
    }
  }

  /// 处理原生推送事件：`onAlarmRinging` → 响铃，`onAlarmStopped` → 停止，
  /// 其余方法名忽略（通道上还有快捷方式/分享/悬浮窗等无关事件）。
  /// 重复同值通知幂等，不重复发通知。
  void handleNativeEvent(String method) {
    final bool? value = switch (method) {
      'onAlarmRinging' => true,
      'onAlarmStopped' => false,
      _ => null,
    };
    if (value != null && value != _ringing) {
      _ringing = value;
      notifyListeners();
    }
  }

  /// 本地乐观收起（横幅「停止」按钮点击后立即隐藏横幅，不等原生回执；
  /// 随后 stopAlarmCompletely 推送的 onAlarmStopped 为同值幂等）
  void markStopped() {
    if (_ringing) {
      _ringing = false;
      notifyListeners();
    }
  }
}
