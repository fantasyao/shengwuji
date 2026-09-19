import 'package:flutter/material.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'overlay_app.dart';

/// 悬浮窗的 Dart 入口点
///
/// [flutter_overlay_window] 插件在 Android Service 中启动新的 FlutterEngine，
/// 并执行名为 `overlayMain` 的顶层函数（见 OverlayService.java 中的 DartEntrypoint）。
@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  // ⚠️ FFI 绑定须在本 isolate 初始化（铁律，见 recognition_service.dart 同款
  // 注释：绑定指针表缓存在各 isolate 自己的 heap，互不共享——主 engine
  // main() 里调过的对本 engine 无效）。缺失的后果：悬浮窗语音速记的静音
  // 检测 VAD 创建直接抛 "Please initialize sherpa-onnx first"（2026-09-16
  // 真机日志确诊），说完自动停止在悬浮窗静默失灵
  sherpa_onnx.initBindings();
  print('🚀 [overlayMain] 悬浮窗引擎已启动');
  runApp(const OverlayApp());
}
