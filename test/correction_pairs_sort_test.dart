// 修正对管理页排序回归测试：compareCorrectionPairs 三种模式（默认长度 /
// 命中次数 / 最近命中时间）+ formatPairTime 展示格式 + getAllCorrectionPairs
// 把 created_at/last_used_at 映射进模型（管理页排序的数据源）。
//
// ⚠️ DB 用例独立成文件：DbHelper 是进程级单例，flutter_test 每文件独立
// isolate，避免与其他 db_*_test 的已开连接互相污染。
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shengwuji_app/db_helper.dart';
import 'package:shengwuji_app/utils/correction_learner.dart';
import 'package:shengwuji_app/widgets/correction_pairs_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('compareCorrectionPairs', () {
    test('默认模式：错误片段长的在前（与替换链路先长后短一致）', () {
      final short = CorrectionPair(error: '短错', correct: 'a', hitCount: 9);
      final long = CorrectionPair(error: '很长很长的错误', correct: 'b', hitCount: 1);
      final list =
          [short, long]..sort(
            (a, b) => compareCorrectionPairs(a, b, PairSortMode.defaultOrder),
          );
      expect(list.map((e) => e.error).toList(), ['很长很长的错误', '短错']);
    });

    test('默认模式：同长错误片段按命中次数降序', () {
      final a = CorrectionPair(error: '一样长', correct: 'x', hitCount: 2);
      final b = CorrectionPair(error: '一样长', correct: 'y', hitCount: 7);
      final list =
          [a, b]..sort(
            (x, y) => compareCorrectionPairs(x, y, PairSortMode.defaultOrder),
          );
      expect(list.map((e) => e.hitCount).toList(), [7, 2]);
    });

    test('按命中次数：多在前；同次数最近活跃在前；无时间排最后', () {
      final older = CorrectionPair(
        error: 'aa',
        correct: 'x',
        hitCount: 5,
        lastUsedAt: '2026-09-01T00:00:00',
      );
      final newer = CorrectionPair(
        error: 'bb',
        correct: 'x',
        hitCount: 5,
        lastUsedAt: '2026-09-10T00:00:00',
      );
      final noTime = CorrectionPair(error: 'cc', correct: 'x', hitCount: 5);
      final list = [older, noTime, newer]..sort(
        (x, y) => compareCorrectionPairs(x, y, PairSortMode.hitCount),
      );
      expect(list.map((e) => e.error).toList(), ['bb', 'aa', 'cc']);
    });

    test('按命中次数：命中数悬殊时纯比次数（排查高频错误的主诉求）', () {
      final low = CorrectionPair(error: 'aa', correct: 'x', hitCount: 1);
      final high = CorrectionPair(error: 'bbbbbbbb', correct: 'x', hitCount: 30);
      final list =
          [low, high]..sort(
            (x, y) => compareCorrectionPairs(x, y, PairSortMode.hitCount),
          );
      expect(list.map((e) => e.hitCount).toList(), [30, 1]);
    });

    test('按最近命中时间：last_used_at 优先，缺则回落 created_at，全无最后', () {
      final hasLastUsed = CorrectionPair(
        error: 'aa',
        correct: 'x',
        hitCount: 1,
        lastUsedAt: '2026-09-21T00:00:00',
        createdAt: '2026-09-01T00:00:00',
      );
      final onlyCreated = CorrectionPair(
        error: 'bb',
        correct: 'x',
        hitCount: 9,
        createdAt: '2026-09-05T00:00:00',
      );
      final noTime = CorrectionPair(error: 'cc', correct: 'x', hitCount: 99);
      final list = [noTime, onlyCreated, hasLastUsed]..sort(
        (x, y) => compareCorrectionPairs(x, y, PairSortMode.lastUsed),
      );
      expect(list.map((e) => e.error).toList(), ['aa', 'bb', 'cc']);
    });

    test('按最近命中时间：同时间按命中次数降序', () {
      final a = CorrectionPair(
        error: 'aa',
        correct: 'x',
        hitCount: 1,
        lastUsedAt: '2026-09-10T00:00:00',
      );
      final b = CorrectionPair(
        error: 'bb',
        correct: 'x',
        hitCount: 3,
        lastUsedAt: '2026-09-10T00:00:00',
      );
      final list =
          [a, b]..sort(
            (x, y) => compareCorrectionPairs(x, y, PairSortMode.lastUsed),
          );
      expect(list.first.error, 'bb');
    });
  });

  group('formatPairTime', () {
    test('本年只显示 MM-dd HH:mm', () {
      expect(formatPairTime('2026-09-21T10:30:00'), '09-21 10:30');
    });

    test('跨年补年份', () {
      expect(formatPairTime('2025-01-02T08:05:00'), '2025-01-02 08:05');
    });

    test('坏时间串原样返回不抛，空/null 返回空串', () {
      expect(formatPairTime('不是时间'), '不是时间');
      expect(formatPairTime(''), '');
      expect(formatPairTime(null), '');
    });
  });

  test('getAllCorrectionPairs 带出时间戳：管理页排序的数据源', () async {
    // 独立库名：flutter test 多文件并行 isolate，共用 items.db 会与
    // db_upgrade_v14 / db_poisoned_v14 的 deleteDatabase 互相打架
    DbHelper.dbFileName = 'items_correction_sort_test.db';
    final dbPath = p.join(
      await databaseFactory.getDatabasesPath(),
      DbHelper.dbFileName,
    );
    await databaseFactory.deleteDatabase(dbPath);
    final dbHelper = DbHelper();
    final db = await dbHelper.db;

    // 三行：长度 / 命中 / 时间三个维度各占头名，外加一行老数据的无时间行
    await db.insert('correction_pairs', {
      'error_text': '长错误片段abcd',
      'corrected_text': 'x',
      'hit_count': 1,
      'created_at': '2026-09-01T08:00:00',
      'last_used_at': '2026-09-01T08:00:00',
    });
    await db.insert('correction_pairs', {
      'error_text': '短错',
      'corrected_text': 'y',
      'hit_count': 5,
      'created_at': '2026-09-20T08:00:00',
      'last_used_at': '2026-09-21T09:30:00',
    });
    await db.insert('correction_pairs', {
      'error_text': '无时间对',
      'corrected_text': 'z',
      'hit_count': 2,
    });

    final pairs = await dbHelper.getAllCorrectionPairs();
    expect(pairs.length, 3);

    // DB 默认序不变：错误片段长度降序
    expect(pairs.map((e) => e.error).toList(), [
      '长错误片段abcd',
      '无时间对',
      '短错',
    ]);

    // 时间戳字段映射到位（query 本就取全列，只是此前没读）
    final withTime = pairs.firstWhere((e) => e.error == '短错');
    expect(withTime.lastUsedAt, '2026-09-21T09:30:00');
    expect(withTime.createdAt, '2026-09-20T08:00:00');
    expect(pairs.firstWhere((e) => e.error == '无时间对').lastUsedAt, isNull);

    // 管理页两种排序作用于真实查询结果
    final hitSorted =
        [...pairs]..sort(
          (a, b) => compareCorrectionPairs(a, b, PairSortMode.hitCount),
        );
    expect(hitSorted.map((e) => e.error).toList(), ['短错', '无时间对', '长错误片段abcd']);
    final timeSorted =
        [...pairs]..sort(
          (a, b) => compareCorrectionPairs(a, b, PairSortMode.lastUsed),
        );
    expect(timeSorted.map((e) => e.error).toList(), [
      '短错',
      '长错误片段abcd',
      '无时间对',
    ]);

    await db.close();
  });
}
