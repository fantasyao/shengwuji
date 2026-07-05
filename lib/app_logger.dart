import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 业务日志函数：同时输出控制台 + 写入 [AppLogger] 缓冲区。
///
/// **为什么不能用 `print`**：
/// `main.dart` 用 `runZonedGuarded(zoneSpecification: print: ...)` 拦截 print，
/// 但 Dart zone 机制对 **async callback / platform channel / Stream.listen**
/// 注册的回调存在已知限制——这些回调注册时的 zone 是 root zone（不是 runApp
/// 所在的拦截 zone），运行时 print 会绕过 zoneSpecification，导致日志丢失。
/// 实测：Switch.onChanged、record.startStream、sherpa_onnx 的回调都属于这类。
///
/// **用法**：把原本的 `print('...')` 改为 `log('...')`，签名兼容。
/// 保留 `print()` 给纯调试场景（不进 AppLogger 的临时输出）。
void log(Object? message, [Object? arg, Object? arg2, Object? arg3]) {
  final parts = [message, arg, arg2, arg3].where((e) => e != null).map((e) => e.toString());
  final msg = parts.join(' ');
  // ignore: avoid_print
  print(msg); // 控制台（flutter run 时可见）
  AppLogger.appLog(msg); // 显式写入缓冲区（不依赖 zone 拦截）
}

/// 应用运行日志收集器
/// 自动拦截所有 print 输出，支持导出分享
class AppLogger {
  static final List<String> _logs = [];
  static const int _maxLines = 2000;

  /// 记录一条日志（由 runZonedGuarded 的 print 拦截自动调用）
  /// 不需要再调 print，因为拦截器已经会输出到控制台
  static void appLog(String message) {
    final timestamp = DateTime.now().toString().substring(11, 23); // HH:mm:ss.SSS
    _logs.add('[$timestamp] $message');
    // 超出上限则丢弃旧日志
    if (_logs.length > _maxLines) {
      _logs.removeRange(0, _logs.length - _maxLines);
    }
  }

  /// 导出日志文件并通过系统分享
  static Future<void> exportAndShare() async {
    final buffer = StringBuffer();

    // 文件头
    buffer.writeln('=== 应用运行日志 ===');
    buffer.writeln('导出时间: ${DateTime.now().toIso8601String()}');
    buffer.writeln('设备: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    buffer.writeln('日志条数: ${_logs.length}');
    buffer.writeln('');

    // 日志内容
    for (final line in _logs) {
      buffer.writeln(line);
    }

    // 写入临时文件
    final dir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final file = File('${dir.path}/app_log_$timestamp.txt');
    await file.writeAsString(buffer.toString());

    // 系统分享
    await Share.shareXFiles([XFile(file.path)], text: '应用运行日志 (${_logs.length}条)');
  }
}
