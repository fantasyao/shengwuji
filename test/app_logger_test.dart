import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/app_logger.dart';

/// AppLogger 落盘与压缩回归：每条日志逐行追加写入运行日志文件；主 App /
/// 悬浮窗 / 语音 Provider 各写自己的文件（避免跨 isolate 压缩重写互踩）；
/// 启动与运行期超过高水位后压缩，最新会话头与设备诊断固定置顶、只留最近
/// [AppLogger.keepLines] 行；导出把各 engine 与原生文件合并成单文件。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;

  setUp(() async {
    await AppLogger.resetForTest();
    tmpDir = await Directory.systemTemp.createTemp('app_logger_test');
    AppLogger.directoryProvider = () => tmpDir;
  });

  tearDown(() async {
    await AppLogger.resetForTest();
    AppLogger.directoryProvider = null;
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  File logFile() => File('${tmpDir.path}/runtime_log.txt');

  String diag(String time, String suffix) => '[$time] 📱 [设备诊断/main] 机型$suffix';

  test('appLog 实时落盘：逐行写入并带会话头', () async {
    AppLogger.appLog('第一行');
    AppLogger.appLog('第二行');
    await AppLogger.debugSettle();

    final file = logFile();
    expect(file.existsSync(), isTrue);
    final content = file.readAsStringSync();
    expect(content, contains('第一行'));
    expect(content, contains('第二行'));
    expect(content, contains('=== 会话开始'));
    expect(content, contains(Platform.operatingSystem));
  });

  test('通道未就绪期间的行不丢：就绪后按序补写', () async {
    // 首条触发异步打开，后续条目在打开完成前进 _pending
    for (var i = 0; i < 10; i++) {
      AppLogger.appLog('seq$i');
    }
    await AppLogger.debugSettle();

    final content = logFile().readAsStringSync();
    final offsets = [for (var i = 0; i < 10; i++) content.indexOf('seq$i')];
    expect(offsets.every((o) => o >= 0), isTrue, reason: '全部落盘');
    final sorted = List<int>.of(offsets)..sort();
    expect(offsets, sorted, reason: '写入顺序与调用顺序一致');
  });

  test('启动压缩：最新设备诊断与会话头固定置顶，旧行滚掉', () async {
    AppLogger.keepLines = 5;
    AppLogger.compactThreshold = 20;
    final lines = <String>[
      '=== 会话开始 旧会话 ===',
      for (var i = 0; i < 5; i++) diag('00:00:00.000', '旧$i'),
      for (var i = 0; i < 20; i++) '[00:00:02.000] 历史行$i',
      '=== 会话开始 新会话 ===',
      for (var i = 0; i < 5; i++) diag('00:00:03.000', '新$i'),
    ];
    await logFile().writeAsString('${lines.join('\n')}\n');

    AppLogger.appLog('本次新行');
    await AppLogger.debugSettle();

    final content = logFile().readAsStringSync();
    expect(content, contains('日志压缩'));
    expect(content, contains('新会话'));
    expect(content, contains('机型新0'));
    expect(content, contains('机型新4'));
    expect(content, isNot(contains('旧会话')));
    expect(content, isNot(contains('机型旧0')));
    expect(content, contains('历史行19'), reason: '最近 5 行保留');
    expect(content, isNot(contains('历史行14')), reason: '更早的行滚掉');
    expect(content, contains('本次新行'));
    expect('机型新0'.allMatches(content).length, 1, reason: '置顶块已从尾部剔除，不重复');
    expect(
      File('${logFile().path}.old').existsSync(),
      isFalse,
      reason: '不再按大小轮转',
    );
  });

  test('运行期压缩：累计超过高水位后只留最近行，设备信息保留', () async {
    AppLogger.keepLines = 5;
    AppLogger.compactThreshold = 20;
    for (var i = 0; i < 5; i++) {
      AppLogger.appLog('📱 [设备诊断/main] 机型$i');
    }
    for (var i = 0; i < 30; i++) {
      AppLogger.appLog('流水$i');
    }
    await AppLogger.debugSettle();

    final content = logFile().readAsStringSync();
    expect(content, contains('机型0'), reason: '设备诊断固定置顶');
    expect(content, contains('流水29'));
    expect(content, isNot(contains('流水0')), reason: '早期流水行被压缩掉');
    final lineCount = content.trimRight().split('\n').length;
    expect(lineCount, lessThanOrEqualTo(20));
    expect(
      content.trimRight().split('\n').first,
      contains('日志压缩'),
      reason: '压缩标记固定在首行',
    );
    expect(
      '=== 会话开始'.allMatches(content).length,
      1,
      reason: '压缩后重开不补会话头，避免伪造新会话',
    );
  });

  test('不同 engine 各写自己的文件，导出时合并', () async {
    AppLogger.appLog('MAIN_LINE');
    await AppLogger.debugSettle();
    await AppLogger.resetForTest();
    AppLogger.setEngine('overlay');
    AppLogger.appLog('OVERLAY_LINE');
    await AppLogger.debugSettle();

    final main = logFile();
    final overlay = File('${tmpDir.path}/runtime_log_overlay.txt');
    expect(main.readAsStringSync(), contains('MAIN_LINE'));
    expect(main.readAsStringSync(), isNot(contains('OVERLAY_LINE')));
    expect(overlay.readAsStringSync(), contains('OVERLAY_LINE'));

    final merged = (await AppLogger.debugBuildMergedExport())
        .readAsStringSync();
    expect(merged, contains('MAIN_LINE'));
    expect(merged, contains('OVERLAY_LINE'));
    expect(merged, contains('Dart 运行日志（悬浮窗）'));
  });

  test('内存缓冲保留且不超过 2000 行上限', () async {
    for (var i = 0; i < 2100; i++) {
      AppLogger.appLog('m$i');
    }
    await AppLogger.debugSettle();
    expect(AppLogger.memoryCount, 2000);
    expect(logFile().readAsStringSync(), contains('m2099'));
  });

  test('导出前置条件成立：flush 后日志文件存在于临时目录', () async {
    AppLogger.appLog('导出内容验证');
    await AppLogger.debugSettle();

    // exportAndShare 的文件分支前提：_ensureSink 后文件存在
    final file = logFile();
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(0));
    expect(file.readAsStringSync(), contains('导出内容验证'));
  });

  test('合并导出：各 engine 与原生文件拼成单文件，旧段在前', () async {
    await File(
      '${tmpDir.path}/runtime_log.txt.old',
    ).writeAsString('[00:00:00.000] DART_OLD\n');
    await File(
      '${tmpDir.path}/runtime_log_native.txt.old',
    ).writeAsString('[00:00:00.000] NATIVE_OLD\n');
    await File(
      '${tmpDir.path}/runtime_log_native.txt',
    ).writeAsString('[00:00:01.000] NATIVE_CURRENT\n');
    await File(
      '${tmpDir.path}/runtime_log_overlay.txt',
    ).writeAsString('[00:00:02.000] OVERLAY_CURRENT\n');

    AppLogger.appLog('DART_CURRENT');
    await AppLogger.debugSettle();

    final merged = await AppLogger.debugBuildMergedExport();
    final content = merged.readAsStringSync();
    expect(content, contains('=== 声物记运行日志 ==='));
    expect(content, contains('========== Dart 运行日志 =========='));
    expect(content, contains('========== Dart 运行日志（悬浮窗） =========='));
    expect(content, contains('========== 原生运行日志 =========='));
    expect(content, contains('DART_OLD'));
    expect(content, contains('DART_CURRENT'));
    expect(content, contains('OVERLAY_CURRENT'));
    expect(content, contains('NATIVE_OLD'));
    expect(content, contains('NATIVE_CURRENT'));
    expect(
      content.indexOf('DART_OLD'),
      lessThan(content.indexOf('DART_CURRENT')),
      reason: '旧段在前，保持同类日志的时间顺序',
    );
    expect(
      content.indexOf('NATIVE_OLD'),
      lessThan(content.indexOf('NATIVE_CURRENT')),
    );
  });

  test('合并导出：原生日志不存在时不生成空段', () async {
    AppLogger.appLog('ONLY_DART');
    await AppLogger.debugSettle();

    final merged = await AppLogger.debugBuildMergedExport();
    final content = merged.readAsStringSync();
    expect(content, contains('ONLY_DART'));
    expect(content, isNot(contains('原生运行日志')));
  });
}
