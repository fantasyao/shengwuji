import 'package:flutter/material.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'overlay_app.dart';
import '../app_logger.dart';
import '../sync/webdav_request_counter.dart';

/// 悬浮窗的 Dart 入口点
///
/// [flutter_overlay_window] 插件在 Android Service 中启动新的 FlutterEngine，
/// 并执行名为 `overlayMain` 的顶层函数（见 OverlayService.java 中的 DartEntrypoint）。
@pragma('vm:entry-point')
void overlayMain() async {
  // 悬浮窗是独立 isolate：运行日志写自己的文件，避免与主 App 共写一个文件时
  // 一方压缩重写让另一方的常开句柄写进已 unlink 的旧 inode（见 AppLogger 头注释）
  AppLogger.setEngine('overlay');
  WidgetsFlutterBinding.ensureInitialized();
  // ⚠️ FFI 绑定须在本 isolate 初始化（铁律，见 recognition_service.dart 同款
  // 注释：绑定指针表缓存在各 isolate 自己的 heap，互不共享——主 engine
  // main() 里调过的对本 engine 无效）。缺失的后果：悬浮窗语音速记的静音
  // 检测 VAD 创建直接抛 "Please initialize sherpa-onnx first"（2026-09-16
  // 真机日志确诊），说完自动停止在悬浮窗静默失灵
  sherpa_onnx.initBindings();
  // 悬浮窗也能发起云同步：本 engine 单独记一份请求日志（与主 App 的
  // WebDAV 计数互不共享静态变量，展示时由主 App 合并两份文件）
  await WebDavRequestCounter.initialize(engine: 'overlay');
  print('🚀 [overlayMain] 悬浮窗引擎已启动');
  runApp(const OverlayApp());
}
