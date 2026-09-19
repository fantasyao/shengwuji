import 'dart:developer' as dev;

import 'package:flutter/services.dart';

/// 无障碍服务状态检测（主页「音量键快捷操作」入口行与音量键设置页共用）
///
/// zcode: 从 settings_tab 搬出（2026-09 设置二级页下沉，主页入口行状态点
/// 与二级页状态卡都要用）。检测失败返回 null——与「未开启」区分：
/// ENABLED_ACCESSIBILITY_SERVICES 存储格式无跨写入方保证（全名/短格式），
/// 硬匹配误报历史见 15826e9；回本页 resume 会自动重查恢复。
const MethodChannel _platform = MethodChannel('com.shengwuji.app/app');

/// 返回 null=检测失败（调用方 UI 显式提示，而非静默当未开启）
Future<bool?> checkAccessibilityServiceEnabled() async {
  try {
    final enabled =
        await _platform.invokeMethod<bool>('isAccessibilityServiceEnabled') ??
        false;
    return enabled;
  } catch (e) {
    dev.log('检查无障碍服务状态失败: $e');
    return null;
  }
}

/// 跳转系统无障碍设置
Future<void> openAccessibilitySettings() async {
  try {
    await _platform.invokeMethod<bool>('openAccessibilitySettings');
  } catch (e) {
    dev.log('打开无障碍设置失败: $e');
  }
}
