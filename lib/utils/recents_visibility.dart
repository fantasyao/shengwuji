import '../app_logger.dart';
import 'package:flutter/services.dart';

/// 后台隐藏（防误杀）：开启后 App 退到后台时不出现在多任务（最近任务）页面。
///
/// 参照 GKD 实现：原生侧 `activityManager.appTasks.forEach { setExcludeFromRecents }`
/// （Android 标准 API，无需权限）。prefs key `exclude_from_recents` 即真值源——
/// MainActivity.onCreate 每次冷启动按落盘值重放，本类只负责运行期实时切换，
/// 无需回查系统状态。
class RecentsVisibility {
  static const _channel = MethodChannel('com.shengwuji.app/app');

  /// 设置本 App 任务是否从多任务页隐藏。返回原生层是否成功执行。
  static Future<bool> setExcludeFromRecents(bool enable) async {
    try {
      final r = await _channel.invokeMethod<bool>('setExcludeFromRecents', {
        'enable': enable,
      });
      return r ?? false;
    } on PlatformException catch (e) {
      log('❌ [RecentsVisibility] 设置失败: ${e.message}');
      return false;
    }
  }
}
