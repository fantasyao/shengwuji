import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shengwuji_app/sync/webdav_request_counter.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('shengwuji_webdav_counter_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  WebDavRequestCounter make({
    String engine = 'main',
    int limit = WebDavRequestCounter.freeLimit,
    DateTime Function()? clock,
    bool persist = false,
  }) {
    final counter = WebDavRequestCounter(
      engine: engine,
      limit: limit,
      // 只有落盘相关用例挂目录；纯窗口用例不排队写，避免 teardown 删目录后
      // 追加写报 PathNotFoundException
      directory: persist ? dir : null,
      clock: clock,
    );
    addTearDown(counter.dispose);
    return counter;
  }

  test('按滚动 30 分钟窗口计数', () {
    var now = DateTime(2026, 10, 25, 10);
    final counter = make(clock: () => now);

    counter.record();
    counter.record();
    expect(counter.recentCount, 2);

    now = now.add(const Duration(minutes: 29, seconds: 59));
    expect(counter.recentCount, 2);

    now = now.add(const Duration(seconds: 2));
    expect(counter.recentCount, 0);
  });

  test('剩余额度按上限估算且不会为负', () {
    var now = DateTime(2026, 10, 25, 10);
    final counter = make(limit: 3, clock: () => now);

    counter.record();
    counter.record();
    expect(counter.remaining, 1);

    counter.record();
    counter.record();
    expect(counter.remaining, 0);
  });

  test('最早一批请求滑出窗口的时长', () {
    var now = DateTime(2026, 10, 25, 10, 0, 30);
    final counter = make(clock: () => now);

    counter.record();
    expect(counter.untilNextExpiry, const Duration(minutes: 29, seconds: 30));

    now = now.add(const Duration(minutes: 5));
    expect(counter.untilNextExpiry, const Duration(minutes: 24, seconds: 30));
  });

  test('每次请求追加一行日志，重启后按窗口恢复', () async {
    final now = DateTime(2026, 10, 25, 10);
    final first = make(clock: () => now, persist: true);
    first.record();
    first.record();
    first.record();
    await first.flush();

    final file = File(p.join(dir.path, 'webdav_requests_main.log'));
    expect((await file.readAsLines()).length, 3);

    final second = make(clock: () => now, persist: true);
    await second.load();
    expect(second.recentCount, 3);

    final later = make(
      clock: () => now.add(const Duration(minutes: 31)),
      persist: true,
    );
    await later.load();
    expect(later.recentCount, 0);
  });

  test('坏行与坏文件按空窗口处理', () async {
    final now = DateTime(2026, 10, 25, 10);
    final file = File(p.join(dir.path, 'webdav_requests_main.log'));
    await file.writeAsString(
      '${now.millisecondsSinceEpoch}\n'
      'not-a-number\n'
      '\n'
      '123\n',
    );

    final counter = make(clock: () => now, persist: true);
    await counter.load();
    expect(counter.recentCount, 1);

    await file.writeAsString('整份文件都坏了');
    final broken = make(clock: () => now, persist: true);
    await broken.load();
    expect(broken.recentCount, 0);
  });

  test('日志超过阈值时在启动读入后压缩，窗口内计数不变', () async {
    final now = DateTime(2026, 10, 25, 10);
    final file = File(p.join(dir.path, 'webdav_requests_main.log'));
    final old = now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch;
    final lines = <String>[
      for (var i = 0; i < 3; i++) '${now.millisecondsSinceEpoch}',
      for (var i = 0; i < 2100; i++) '$old',
    ];
    await file.writeAsString('${lines.join('\n')}\n');

    final counter = make(clock: () => now, persist: true);
    await counter.load();
    expect(counter.recentCount, 3);
    expect((await file.readAsLines()).length, 3);

    counter.record();
    await counter.flush();
    expect((await file.readAsLines()).length, 4);
    expect(counter.recentCount, 4);
  });

  test('长时间不重启也压缩：运行期累计超过阈值后只留窗口内行', () async {
    var now = DateTime(2026, 10, 25, 10);
    final counter = make(clock: () => now, persist: true);
    for (var i = 0; i < 2000; i++) {
      counter.record();
    }
    await counter.flush();

    final file = File(p.join(dir.path, 'webdav_requests_main.log'));
    expect((await file.readAsLines()).length, 2000);

    // 跨过窗口后再记一条：逻辑行数 2001 触发压缩，旧 2000 行全部过窗
    now = now.add(const Duration(minutes: 31));
    counter.record();
    await counter.flush();

    expect((await file.readAsLines()).length, 1);
    expect(counter.recentCount, 1);
  });

  test('合并另一 engine 的日志，过期条目不参与', () async {
    var mainNow = DateTime(2026, 10, 25, 10);
    final main = make(clock: () => mainNow, persist: true);

    final overlay = make(
      engine: 'overlay',
      clock: () => mainNow,
      persist: true,
    );
    main.record();
    main.record();
    overlay.record();
    overlay.record();
    overlay.record();
    await main.flush();
    await overlay.flush();

    await main.refreshOtherEngine();
    expect(main.ownRecentCount, 2);
    expect(main.otherRecentCount, 3);
    expect(main.recentCount, 5);
    expect(main.remaining, 595);

    // 35 分钟后两边都滑出窗口
    mainNow = mainNow.add(const Duration(minutes: 35));
    expect(main.recentCount, 0);
  });

  test('另一 engine 的新增请求要等下次刷新才可见', () async {
    final now = DateTime(2026, 10, 25, 10);
    final main = make(clock: () => now, persist: true);
    final overlay = make(engine: 'overlay', clock: () => now, persist: true);

    overlay.record();
    await overlay.flush();
    expect(main.otherRecentCount, 0);

    await main.refreshOtherEngine();
    expect(main.recentCount, 1);
  });

  test('dispose 后不再计数，也不留下到期定时器', () {
    final counter = make();
    counter.record();
    counter.dispose();
    counter.record();
    expect(counter.recentCount, 1);
  });
}
