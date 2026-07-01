import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

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
