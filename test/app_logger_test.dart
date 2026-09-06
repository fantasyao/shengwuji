import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/app_logger.dart';

/// AppLogger 实时落盘回归：每条日志逐行追加写入 runtime_log.txt（IOSink
/// 常开、逐行 flush），通道未就绪期间的行经 _pending 按序补写不丢；单文件
/// 超 maxFileBytes 轮转为 .old 只留一代、重开后补会话头；导出分享的是文件
/// 本体（share_plus 平台通道不在单测范围，文件侧断言覆盖其前置条件）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;

  setUp(() async {
    await AppLogger.resetForTest();
    tmpDir = await Directory.systemTemp.createTemp('app_logger_test');
    AppLogger.directoryProvider = () => tmpDir;
    AppLogger.maxFileBytes = 1 << 20;
  });

  tearDown(() async {
    await AppLogger.resetForTest();
    AppLogger.directoryProvider = null;
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  File logFile() => File('${tmpDir.path}/runtime_log.txt');

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

  test('超过大小上限轮转：当前文件挪为 .old（只留一代），重开补会话头', () async {
    AppLogger.maxFileBytes = 200;
    for (var i = 0; i < 300; i++) {
      AppLogger.appLog('行$i ${'x' * 20}');
    }
    await AppLogger.debugSettle();

    final old = File('${logFile().path}.old');
    expect(old.existsSync(), isTrue, reason: '旧文件轮转为 .old');
    expect(old.readAsStringSync(), contains('行0'));

    final current = logFile();
    expect(current.existsSync(), isTrue);
    final content = current.readAsStringSync();
    expect(content, contains('=== 会话开始'), reason: '轮转后的新文件补会话头');
    expect(content.length, lessThan(500), reason: '当前文件只剩轮转后的少量行');
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
}
