import 'package:flutter/material.dart';
import 'overlay_app.dart';

/// 悬浮窗的 Dart 入口点
///
/// [flutter_overlay_window] 插件在 Android Service 中启动新的 FlutterEngine，
/// 并执行名为 `overlayMain` 的顶层函数（见 OverlayService.java 中的 DartEntrypoint）。
@pragma('vm:entry-point')
void overlayMain() {
  WidgetsFlutterBinding.ensureInitialized();
  print('🚀 [overlayMain] 悬浮窗引擎已启动');
  runApp(const OverlayApp());
}
