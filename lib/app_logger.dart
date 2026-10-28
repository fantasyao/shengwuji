import 'dart:async';
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
  final parts = [
    message,
    arg,
    arg2,
    arg3,
  ].where((e) => e != null).map((e) => e.toString());
  final msg = parts.join(' ');
  // ignore: avoid_print
  print(msg); // 控制台（flutter run 时可见）
  AppLogger.appLog(msg); // 显式写入缓冲区（不依赖 zone 拦截）
}

/// 应用运行日志收集器
///
/// 每条日志实时追加写入临时目录下的运行日志文件（IOSink 常开）。主 App 写
/// `runtime_log.txt`，悬浮窗 / 语音 Provider 等独立 FlutterEngine 各写
/// `runtime_log_<engine>.txt`——同进程多 isolate 共用一个文件时，一方压缩
/// 重写会让另一方的常开句柄继续写已 unlink 的旧 inode，日志凭空丢失；分文件
/// 后每个 engine 只写自己的文件，压缩互不干扰。
///
/// 导出时把各 engine 文件与原生侧 `runtime_log_native.txt`（含旧版本遗留的
/// `.old`）按分段合并成**一个**快照文件再交给系统分享——多文件分享的接收方
/// app 兼容性差（多数只取第一个或直接拒绝），合并后单文件任意 app 都能打开。
/// 合并在 IO 线程流式拼接，不回到内存缓冲拼大字串的老路。
///
/// **写入纪律（重要）**：dart:io 的 IOSink 不允许 flush 与写入并发（并发会
/// 让 sink 进入坏状态，后续写入抛异常丢行）。因此日常写入只 `writeln` 不
/// flush（数据会在事件循环内异步落盘，实时性足够）；flush 只在「先同步摘掉
/// 通道（_sink = null）」之后的静默窗口里按顺序调用——导出前和压缩前各一处。
/// 通道未就绪/被摘掉期间的行进 [_pending]，就绪后按序补写。
///
/// 日志文件不按大小轮转，而按行数压缩：超过高水位 [compactThreshold] 行时
/// 重写为「压缩标记 + 最新会话头 + 最新设备诊断 + 最近 [keepLines] 行」。
/// 设备诊断（机型/系统/屏幕/导航/权限等，见 utils/device_diagnostics.dart）
/// 只留最新一块并固定置顶——压缩不能把它滚掉，否则用户发回的诊断包看不出
/// 机型环境。临时文件 + rename 保证导出读方看到的要么是旧文件、要么是新
/// 文件。每个会话首次打开写一行会话头，跨启动的历史按会话分段；运行期压缩
/// 后的重开不补头（仍是同一会话）。
///
/// 内存缓冲（[_logs]）仍然保留：用于条数展示，也是文件通道不可用时的导出
/// 兜底。
class AppLogger {
  static final List<String> _logs = [];
  static const int _maxLines = 2000;

  static IOSink? _sink;
  static File? _file;
  static String _engine = 'main';
  static int _lineCount = 0; // 当前文件逻辑行数（含本会话已写入的行）
  static bool _opening = false;
  static bool _compacting = false;
  static bool _exporting = false; // 导出合并的静默窗口，期间不开新通道
  static int _generation = 0; // 会话代数：reset 后旧压缩的收尾不再重开
  static final List<String> _pending = [];

  /// 压缩后保留的最近行数（测试可调小）
  @visibleForTesting
  static int keepLines = 1000;

  /// 行数高水位：超过才压缩一次，避免每写一行都重写整个文件（测试可调小）
  @visibleForTesting
  static int compactThreshold = 2000;

  /// 测试注入日志目录用；null 时走 path_provider 的临时目录
  @visibleForTesting
  static Directory Function()? directoryProvider;

  /// 当前 isolate 的 engine 标识，决定写哪个日志文件（默认 main）。
  /// 必须在首次写日志前设置（overlayMain / voiceProviderMain 入口）。
  static void setEngine(String engine) {
    final safe = engine.replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    _engine = safe.isEmpty ? 'main' : safe;
  }

  static String get _fileName =>
      _engine == 'main' ? 'runtime_log.txt' : 'runtime_log_$_engine.txt';

  /// 记录一条日志（由 runZonedGuarded 的 print 拦截自动调用）
  /// 不需要再调 print，因为拦截器已经会输出到控制台
  static void appLog(String message) {
    final timestamp = DateTime.now().toString().substring(
      11,
      23,
    ); // HH:mm:ss.SSS
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
    // 通道未就绪（首次写入 / 压缩中 / 导出 flush 中）：攒队列，就绪后按序补写
    _pending.add(line);
    if (_pending.length > 500) {
      _pending.removeRange(0, _pending.length - 500);
    }
    unawaited(_ensureSink());
  }

  static void _emit(IOSink sink, String line) {
    try {
      sink.writeln(line);
      _lineCount++;
      _maybeCompact();
    } catch (_) {}
  }

  /// 打开（或重开）写入通道。只允许一个在途，期间的行进 [_pending]。
  /// [writeHeader] 为 false 用于运行期压缩后的重开——仍在同一会话，不能补
  /// 「会话开始」头把历史截成假的新会话。
  static Future<void> _ensureSink({bool writeHeader = true}) async {
    if (_sink != null || _opening || _compacting || _exporting) return;
    _opening = true;
    try {
      final dir = await _resolveDir();
      final file = File('${dir.path}/$_fileName');
      _lineCount = await _compactIfNeeded(file);
      final sink = file.openWrite(mode: FileMode.append);
      if (writeHeader) {
        sink.writeln(
          '=== 会话开始 ${DateTime.now().toIso8601String()} | '
          '${Platform.operatingSystem} ${Platform.operatingSystemVersion} ===',
        );
        _lineCount++;
      }
      _file = file;
      _sink = sink;
      for (final line in _pending) {
        _emit(sink, line);
      }
      _pending.clear();
    } catch (_) {
      // 文件日志只是兜底通道，失败不影响内存缓冲与控制台输出
    } finally {
      _opening = false;
    }
    _maybeCompact();
  }

  /// 启动压缩：行数超过高水位时重写为「设备诊断 + 最近 N 行」。
  /// 返回文件当前行数；读失败按 0 处理，后续追加照常。
  static Future<int> _compactIfNeeded(File file) async {
    List<String> lines;
    try {
      if (!await file.exists()) return 0;
      lines = await file.readAsLines();
    } catch (_) {
      return 0;
    }
    if (lines.length <= compactThreshold) return lines.length;
    final written = await _rewriteCompacted(file, lines);
    return written ?? lines.length;
  }

  /// 运行期压缩：进程长期不重启时也不能让日志无限变长。
  /// 先摘通道并 flush/close，再重写；期间新行进 [_pending]，重开后按序补写。
  static void _maybeCompact() {
    if (_lineCount <= compactThreshold) return;
    if (_sink == null || _opening || _compacting || _exporting) return;
    unawaited(_compact());
  }

  static Future<void> _compact() async {
    if (_compacting || _sink == null || _exporting) return;
    _compacting = true;
    final gen = _generation;
    final oldSink = _sink;
    final oldFile = _file;
    _sink = null;
    try {
      if (oldSink != null) {
        try {
          await oldSink.flush();
          await oldSink.close();
        } catch (_) {}
      }
      if (oldFile != null) {
        try {
          final lines = await oldFile.readAsLines();
          final written = await _rewriteCompacted(oldFile, lines);
          if (written != null) _lineCount = written;
        } catch (_) {}
      }
    } finally {
      _compacting = false;
    }
    if (gen == _generation) await _ensureSink(writeHeader: false);
  }

  /// 重写为「压缩标记 + 最新会话头 + 最新设备诊断 + 最近 [keepLines] 行」。
  /// 临时文件 + rename 对导出读方原子可见；失败返回 null（保留原文件）。
  static Future<int?> _rewriteCompacted(File file, List<String> lines) async {
    final compacted = _buildCompacted(lines);
    final tmp = File('${file.path}.tmp');
    try {
      await tmp.writeAsString('${compacted.join('\n')}\n', flush: true);
      await tmp.rename(file.path);
      return compacted.length;
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      return null;
    }
  }

  static List<String> _buildCompacted(List<String> lines) {
    final out = <String>['=== 日志压缩：设备信息固定置顶，保留最近 $keepLines 行 ==='];
    final pinned = <int>{};
    final header = _lastSessionHeaderIndex(lines);
    if (header >= 0) {
      out.add(lines[header]);
      pinned.add(header);
    }
    final diagnostics = _latestDiagnostics(lines);
    out.addAll(diagnostics.lines);
    pinned.addAll(diagnostics.indices);

    final tail = <String>[];
    for (var i = lines.length - 1; i >= 0 && tail.length < keepLines; i--) {
      if (pinned.contains(i)) continue;
      tail.add(lines[i]);
    }
    out.addAll(tail.reversed);
    return out;
  }

  static int _lastSessionHeaderIndex(List<String> lines) {
    for (var i = lines.length - 1; i >= 0; i--) {
      if (lines[i].startsWith('=== 会话开始')) return i;
    }
    return -1;
  }

  static final RegExp _diagnosticsTag = RegExp(r'\[设备诊断/([^\]]+)\]');

  /// 各 engine 最新一块成功设备诊断（连续 5 行；失败警告不参与，避免把上一块
  /// 真实机型信息挤掉）。返回块内行与其原下标（用于避免与尾部重复）。
  static ({List<String> lines, Set<int> indices}) _latestDiagnostics(
    List<String> lines,
  ) {
    final blocks = <String, ({int start, int end})>{};
    var engine = '';
    var start = -1;

    void flush(int end) {
      if (engine.isNotEmpty && start >= 0) {
        blocks[engine] = (start: start, end: end);
      }
      engine = '';
      start = -1;
    }

    for (var i = 0; i < lines.length; i++) {
      final match = _diagnosticsTag.firstMatch(lines[i]);
      final info = match != null && lines[i].contains('📱')
          ? match.group(1)!
          : null;
      if (info != null && info == engine) continue;
      flush(i);
      if (info != null) {
        engine = info;
        start = i;
      }
    }
    flush(lines.length);

    final out = <String>[];
    final indices = <int>{};
    for (final block in blocks.values) {
      for (var i = block.start; i < block.end; i++) {
        out.add(lines[i]);
        indices.add(i);
      }
    }
    return (lines: out, indices: indices);
  }

  static Future<Directory> _resolveDir() async {
    final provider = directoryProvider;
    if (provider != null) return provider();
    return getTemporaryDirectory();
  }

  /// 导出日志并通过系统分享。
  ///
  /// Dart 段与原生段（含各自上一代 `.old`）合并成**一个**快照文件再分享，
  /// 避免多文件在接收方 app 里只认第一个。分享前先摘通道并 flush，保证
  /// Dart 日志完整；合并期间新日志进 [_pending]，完成后按序补写。
  ///
  /// 原生日志由 NativeRuntimeLog 逐行 append 到文件（不是内存缓冲），进程
  /// 结束不会丢已写内容。文件通道不可用时，Dart 段退回内存快照。
  static Future<void> exportAndShare() async {
    // 等首次打开/压缩落定，否则 _file 还是 null 会误走内存兜底
    while (_opening || _compacting) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    await _ensureSink();
    final sink = _sink;
    _exporting = true;
    _sink = null; // 摘通道：合并读文件期间不并发写
    File? merged;
    try {
      if (sink != null) {
        try {
          await sink.flush();
        } catch (_) {}
      }
      merged = await _writeMergedExport();
    } catch (_) {
      merged = null;
    } finally {
      if (sink != null && _sink == null) {
        // 合并期间未发生压缩（_exporting 挡着 _ensureSink）：原样接回并补写
        _sink = sink;
        for (final line in _pending) {
          _emit(sink, line);
        }
        _pending.clear();
      }
      _exporting = false;
      _maybeCompact();
    }

    if (merged != null) {
      await Share.shareXFiles([XFile(merged.path)], text: '应用运行日志');
      return;
    }

    // 兜底：合并快照写盘失败（如磁盘异常），退回内存快照写临时文件
    final buffer = StringBuffer();
    buffer.writeln('=== 应用运行日志 ===');
    buffer.writeln('导出时间: ${DateTime.now().toIso8601String()}');
    buffer.writeln(
      '设备: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    );
    buffer.writeln('日志条数: ${_logs.length}');
    buffer.writeln('');
    for (final line in _logs) {
      buffer.writeln(line);
    }
    final dir = await getTemporaryDirectory();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final fallback = File('${dir.path}/app_log_$timestamp.txt');
    await fallback.writeAsString(buffer.toString());
    await Share.shareXFiles([
      XFile(fallback.path),
    ], text: '应用运行日志 (${_logs.length}条)');
  }

  /// 把各 engine 的 Dart 日志与原生日志拼接成一个导出快照。
  /// 每类内部旧段在前、当前段在后；Dart 文件全不可用时改用内存缓冲 [_logs]。
  /// 写盘异常向上抛，由 [exportAndShare] 兜底。
  static String _engineLabel(File file) {
    final name = file.uri.pathSegments.last;
    final label = name.substring('runtime_log_'.length, name.length - 4);
    return switch (label) {
      'overlay' => '悬浮窗',
      'voice_provider' => '语音 Provider',
      _ => label,
    };
  }

  static Future<File> _writeMergedExport() async {
    final dir = await _resolveDir();
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}_'
        '${now.millisecond.toString().padLeft(3, '0')}';
    final merged = File('${dir.path}/声物记运行日志_$stamp.txt');
    final sink = merged.openWrite(mode: FileMode.write);
    try {
      sink.writeln('=== 声物记运行日志 ===');
      sink.writeln('导出时间: ${now.toIso8601String()}');
      sink.writeln(
        '设备: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      );

      Future<bool> addSection(String title, File? file) async {
        List<int>? bytes;
        if (file != null) {
          try {
            if (await file.exists()) bytes = await file.readAsBytes();
          } catch (_) {}
        }
        if (bytes == null || bytes.isEmpty) return false;
        sink.writeln();
        sink.writeln('========== $title ==========');
        sink.add(bytes);
        if (bytes.last != 0x0a) sink.writeln();
        return true;
      }

      final mainLog = File('${dir.path}/runtime_log.txt');
      final hasDartOld = await addSection(
        'Dart 运行日志（上一代 .old，旧版本遗留）',
        File('${mainLog.path}.old'),
      );
      final hasDartCurrent = await addSection('Dart 运行日志', mainLog);

      // 其它 engine 各写自己的文件（悬浮窗、语音 Provider），按文件名排序合并
      final engineFiles = <File>[];
      try {
        await for (final entity in dir.list()) {
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.last;
          if (!name.startsWith('runtime_log_') || !name.endsWith('.txt')) {
            continue;
          }
          if (name == 'runtime_log_native.txt') continue;
          engineFiles.add(entity);
        }
      } catch (_) {}
      engineFiles.sort((a, b) => a.path.compareTo(b.path));
      for (final file in engineFiles) {
        await addSection('Dart 运行日志（${_engineLabel(file)}）', file);
      }

      if (!hasDartOld && !hasDartCurrent && engineFiles.isEmpty) {
        sink.writeln();
        sink.writeln('========== Dart 运行日志（内存缓冲，文件通道不可用） ==========');
        for (final line in _logs) {
          sink.writeln(line);
        }
      }

      await addSection(
        '原生运行日志（上一代 .old）',
        File('${dir.path}/runtime_log_native.txt.old'),
      );
      await addSection('原生运行日志', File('${dir.path}/runtime_log_native.txt'));
    } finally {
      try {
        await sink.flush();
      } catch (_) {}
      try {
        await sink.close();
      } catch (_) {}
    }
    return merged;
  }

  /// 测试用：生成合并导出快照（不触发系统分享）
  @visibleForTesting
  static Future<File> debugBuildMergedExport() => _writeMergedExport();

  /// 内存缓冲当前条数
  @visibleForTesting
  static int get memoryCount => _logs.length;

  /// 测试用：等在途的打开/压缩完成并把缓冲刷到磁盘
  @visibleForTesting
  static Future<void> debugSettle() async {
    while (_opening || _compacting) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    final sink = _sink;
    if (sink != null) await sink.flush();
  }

  /// 测试用：关闭通道并重置全部静态状态
  @visibleForTesting
  static Future<void> resetForTest() async {
    _generation++; // 让在途压缩的收尾作废，不再重开通道
    final sink = _sink;
    _sink = null;
    if (sink != null) {
      try {
        await sink.flush();
        await sink.close();
      } catch (_) {}
    }
    _file = null;
    _engine = 'main';
    _lineCount = 0;
    _pending.clear();
    _logs.clear();
    _opening = false;
    _compacting = false;
    _exporting = false;
    keepLines = 1000;
    compactThreshold = 2000;
  }
}
