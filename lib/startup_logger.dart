import 'app_logger.dart' as applog;
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 启动耗时诊断日志收集器
/// 收集启动各阶段的耗时数据，支持通过设置页导出分享
class StartupLogger {
  static final List<String> _logs = [];
  static DateTime? _appStartTime;

  /// 标记应用启动开始，清空旧日志
  static void markAppStart() {
    _appStartTime = DateTime.now();
    _logs.clear();
    _logs.add("=== 启动耗时诊断 ===");
    _logs.add("应用启动时间: ${_appStartTime!.toIso8601String()}");
    _logs.add("设备: ${Platform.operatingSystem}");
    _logs.add("");
  }

  /// 记录一个启动阶段的耗时
  static void log(String phase, int elapsedMs, {String? extra}) {
    final line = "$phase: ${elapsedMs}ms${extra != null ? ' ($extra)' : ''}";
    _logs.add(line);
    applog.log("⏱️ $line");
  }

  /// 记录一条原始文本日志
  static void logRaw(String message) {
    _logs.add(message);
  }

  /// 导出日志文件并通过系统分享
  static Future<void> exportAndShare() async {
    // 添加汇总信息
    final totalLog = [..._logs];
    totalLog.add("");
    totalLog.add("=== 总计 ===");
    if (_appStartTime != null) {
      totalLog.add(
        "从 app start 到导出: ${DateTime.now().difference(_appStartTime!).inMilliseconds}ms",
      );
    }

    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/startup_log_${DateTime.now().millisecondsSinceEpoch}.txt',
    );
    await file.writeAsString(totalLog.join('\n'));

    await Share.shareXFiles([XFile(file.path)], text: '启动耗时诊断日志');
  }
}
