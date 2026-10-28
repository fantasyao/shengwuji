import 'package:flutter/services.dart';

import '../app_logger.dart';

/// 从主 App 内启动悬浮窗（设置页「立即启动悬浮窗」按钮）。
///
/// 链路：MainActivity 通道 → VolumeKeyAccessibilityService 同进程静态实例
/// → showOverlayFromSettings（非 toggle，已显示则重建展开；含 Pro 第二层
/// 兜底门禁）。前置条件：无障碍服务已启用（调用方负责检查与引导）。
class OverlayLauncher {
  static const _channel = MethodChannel('com.shengwuji.app/app');

  /// 启动悬浮窗并自动展开面板。返回 false = 无障碍服务未运行或 Pro 未解锁。
  static Future<bool> showOverlay() async {
    try {
      final r = await _channel.invokeMethod<bool>('showOverlay');
      return r ?? false;
    } on PlatformException catch (e) {
      log('❌ [OverlayLauncher] 启动悬浮窗失败: ${e.message}');
      return false;
    }
  }
}
