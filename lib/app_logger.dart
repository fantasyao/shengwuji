import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
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
///
/// 每条日志实时追加写入临时目录下的 `runtime_log.txt`（IOSink 常开），导出
/// 时直接把这个文件交给系统分享——不再现场把内存缓冲拼成大字符串整体写盘，
/// 避免点击导出瞬间在 UI 线程上集中做拼接+编码造成的卡顿。
///
/// **写入纪律（重要）**：dart:io 的 IOSink 不允许 flush 与写入并发（并发会
/// 让 sink 进入坏状态，后续写入抛异常丢行）。因此日常写入只 `writeln` 不
/// flush（数据会在事件循环内异步落盘，实时性足够）；flush 只在「先同步摘掉
/// 通道（_sink = null）」之后的静默窗口里按顺序调用——导出前和轮转关闭前
/// 各一处。通道未就绪/被摘掉期间的行进 [_pending]，就绪后按序补写。
///
/// 内存缓冲（[_logs]）仍然保留：用于条数展示，也是文件通道不可用时的导出
/// 兜底。单文件超过 [maxFileBytes] 轮转为 `.old`（只留一代），文件每次打开
/// 都写一行会话头，跨启动的历史在同一个文件里按会话分段。
class AppLogger {
  static final List<String> _logs = [];
  static const int _maxLines = 2000;

  static IOSink? _sink;
  static File? _file;
  static int _bytesWritten = 0; // 当前文件已写字节数（utf8 精确计，跨会话清零）
  static bool _opening = false;
  static bool _rotating = false;
  static bool _exporting = false; // 导出 flush 的静默窗口，期间不开新通道
  static int _generation = 0; // 会话代数：reset 后旧轮转的收尾不再重开
  static final List<String> _pending = [];

  /// 单个日志文件大小上限，超过后轮转为 `.old`（测试可调小）
  @visibleForTesting
  static int maxFileBytes = 1 << 20;

  /// 测试注入日志目录用；null 时走 path_provider 的临时目录
  @visibleForTesting
  static Directory Function()? directoryProvider;

  /// 记录一条日志（由 runZonedGuarded 的 print 拦截自动调用）
  /// 不需要再调 print，因为拦截器已经会输出到控制台
  static void appLog(String message) {
    final timestamp = DateTime.now().toString().substring(11, 23); // HH:mm:ss.SSS
    final line = '[$timestamp] $message';
    _logs.add(line);
    // 超出上限则丢弃旧日志
    if (_logs.length > _maxLines) {
      _logs.removeRange(0, _logs.length - _maxLines);
    }
    _writeToFile(line);
  }

  static void _writeToFile(String line) {
    final sink = _sink;
    if (sink != null) {
      _emit(sink, line);
      return;
    }
    // 通道未就绪（首次写入 / 轮转中 / 导出 flush 中）：攒队列，就绪后按序补写
    _pending.add(line);
    if (_pending.length > 500) {
      _pending.removeRange(0, _pending.length - 500);
    }
    unawaited(_ensureSink());
  }

  static void _emit(IOSink sink, String line) {
    try {
      sink.writeln(line);
      _bytesWritten += utf8.encode(line).length + 1;
      if (_bytesWritten > maxFileBytes) unawaited(_rotate());
    } catch (_) {}
  }

  /// 打开（或重开）写入通道。只允许一个在途，期间的行进 [_pending]。
  static Future<void> _ensureSink() async {
    if (_sink != null || _opening || _rotating || _exporting) return;
    _opening = true;
    try {
      final dir = await _resolveDir();
      final file = File('${dir.path}/runtime_log.txt');
      final isNew = !await file.exists();
      if (!isNew && await file.length() > maxFileBytes) {
        // 上个会话遗留超限：先轮转再开新文件
        final old = File('${file.path}.old');
        if (await old.exists()) await old.delete();
        await file.rename(old.path);
      }
      final sink = file.openWrite(mode: FileMode.append);
      sink.writeln(
        '=== 会话开始 ${DateTime.now().toIso8601String()} | '
        '${Platform.operatingSystem} ${Platform.operatingSystemVersion} ===',
      );
      _file = file;
      _sink = sink;
      _bytesWritten = 0;
      for (final line in _pending) {
        _emit(sink, line);
      }
      _pending.clear();
    } catch (_) {
      // 文件日志只是兜底通道，失败不影响内存缓冲与控制台输出
    } finally {
      _opening = false;
    }
  }

  /// 当前文件超限：摘通道 → flush/close → 挪 `.old`（只留一代）→ 重开补写。
  /// 由 [_emit] 在写入线程同步触发：`_rotating` 立即置位防重入、`_sink` 立即
  /// 置空，之后的 IO 都发生在微任务里，flush 与 writeln 天然不并发。轮转中
  /// 补写批次再次超限也没关系——重开后的新文件从 0 计数，剩余量下次轮转。
  static Future<void> _rotate() async {
    if (_rotating) return;
    _rotating = true;
    final gen = _generation;
    final oldSink = _sink;
    final oldFile = _file;
    _sink = null;
    if (oldSink != null) {
      try {
        await oldSink.flush();
        await oldSink.close();
      } catch (_) {}
    }
    try {
      if (oldFile != null && await oldFile.exists()) {
        final old = File('${oldFile.path}.old');
        if (await old.exists()) await old.delete();
        await oldFile.rename(old.path);
      }
    } catch (_) {}
    _rotating = false;
    if (gen == _generation) await _ensureSink();
  }

  static Future<Directory> _resolveDir() async {
    final provider = directoryProvider;
    if (provider != null) return provider();
    return getTemporaryDirectory();
  }

  /// 导出日志并通过系统分享：直接分享正在写的日志文件本体（先在静默窗口里
  /// flush 保证内容完整），不再现场拼内存快照写临时文件。
  /// 文件通道不可用时退回老的内存快照路径。
  static Future<void> exportAndShare() async {
    await _ensureSink();
    final file = _file;
    if (file != null && await file.exists()) {
      final sink = _sink;
      if (sink != null) {
        _exporting = true;
        _sink = null; // 摘通道：期间新日志进 pending，flush 不与写入并发
        try {
          await sink.flush();
        } catch (_) {}
        if (_sink == null) {
          // 期间未发生轮转：原样接回并补写 pending
          _sink = sink;
          for (final line in _pending) {
            _emit(sink, line);
          }
          _pending.clear();
        }
        _exporting = false;
      }
      await Share.shareXFiles([XFile(file.path)], text: '应用运行日志');
      return;
    }

    // 兜底：文件日志不可用（如磁盘异常），退回内存快照写临时文件
    final buffer = StringBuffer();
    buffer.writeln('=== 应用运行日志 ===');
    buffer.writeln('导出时间: ${DateTime.now().toIso8601String()}');
    buffer.writeln('设备: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    buffer.writeln('日志条数: ${_logs.length}');
    buffer.writeln('');
    for (final line in _logs) {
      buffer.writeln(line);
    }
    final dir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final fallback = File('${dir.path}/app_log_$timestamp.txt');
    await fallback.writeAsString(buffer.toString());
    await Share.shareXFiles([XFile(fallback.path)], text: '应用运行日志 (${_logs.length}条)');
  }

  /// 内存缓冲当前条数
  @visibleForTesting
  static int get memoryCount => _logs.length;

  /// 测试用：等在途的打开/轮转完成并把缓冲刷到磁盘
  @visibleForTesting
  static Future<void> debugSettle() async {
    while (_opening || _rotating) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    final sink = _sink;
    if (sink != null) await sink.flush();
  }

  /// 测试用：关闭通道并重置全部静态状态
  @visibleForTesting
  static Future<void> resetForTest() async {
    _generation++; // 让在途轮转的收尾作废，不再重开通道
    final sink = _sink;
    _sink = null;
    if (sink != null) {
      try {
        await sink.flush();
        await sink.close();
      } catch (_) {}
    }
    _file = null;
    _pending.clear();
    _logs.clear();
    _bytesWritten = 0;
    _opening = false;
    _rotating = false;
    _exporting = false;
  }
}
