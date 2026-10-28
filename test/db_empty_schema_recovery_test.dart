// 「版本号=19 但一张表都没有」空库自愈回归测试。
//
// 真机现场（2026-10-27 02:27 模拟器首启，adb 取库确认）：新建库时 onCreate
// 的 DDL 与说明卡插入全部跑完，但 sqflite 侧 COMMIT 报
// 「Cannot perform this operation because there is no current transaction」
// 失败并关闭连接；user_version 是独立写出去的（同 v14 事故的「版本号在
// 事务之外」），于是留下「版本=19 但零张表」的空库。重试打开时 onCreate
// 被跳过，列级自愈只会在 ALTER 上报 no such table，唯一直写 DDL 的
// diary_images 自愈反而建成了 —— 库里只剩 diary_images、没有 diary，
// 随手记每条查询都失败、页面永远停在「加载中」。
//
// 本测试精确复刻该设备状态：user_version=19 + 只有 diary_images 表 →
// 用生产 DbHelper 真实打开 → 断言缺表自愈补齐全部表和列、补回说明卡、
// 且原来失败的那条 getDiaries 查询、以及插入路径都恢复正常。
//
// ⚠️ 独立库文件名：sqflite_common_ffi 的库文件是磁盘上共享的真实文件，
// 与其他 db_*_test 并行跑会撞锁（同 db_poisoned_v14_test 头注释）。
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('版本号=19 但缺全部表的空库：首开自愈补表 + 补说明卡 + 查询恢复', () async {
    DbHelper.dbFileName = 'items_empty_schema_test.db';
    final dbPath = p.join(
      await databaseFactory.getDatabasesPath(),
      DbHelper.dbFileName,
    );
    await databaseFactory.deleteDatabase(dbPath);
    SharedPreferences.setMockInitialValues({});

    // ---- 1. 复刻坏库：只有 diary_images（唯一自愈能直写建成的表）+ 版本号 19 ----
    final broken = await databaseFactory.openDatabase(dbPath);
    await broken.execute('''
CREATE TABLE diary_images(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  note_uuid TEXT NOT NULL,
  device_id TEXT NOT NULL,
  sha256 TEXT NOT NULL,
  image_path TEXT,
  remote_name TEXT,
  mime_type TEXT,
  byte_size INTEGER,
  position INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT,
  UNIQUE(note_uuid, device_id, sha256)
)''');
    await broken.execute(
      'CREATE INDEX IF NOT EXISTS idx_diary_images_note '
      'ON diary_images(note_uuid)',
    );
    // 模拟 sqflite「DDL 回滚但 setVersion 已在事务外执行」留下的污染
    await broken.execute('PRAGMA user_version = 19');
    await broken.close();

    // ---- 2. 生产 DbHelper 真实打开：user_version=19 → onCreate 不触发，----
    // ---- 唯一的补救机会是首开后的缺表自愈                                 ----
    final dbHelper = DbHelper();
    final db = await dbHelper.db;

    // 全部内置表就位（与 onCreate 同源的 _coreTables）
    final tableNames = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    )).map((r) => r['name'] as String).toSet();
    for (final name in const [
      'items',
      'diary',
      'dismissed_splits',
      'correction_pairs',
      'correction_context_stats',
      'correction_user_words',
      'correction_pair_contexts',
      'sync_deleted',
      'diary_images',
      'sync_note_meta',
    ]) {
      expect(tableNames, contains(name), reason: '缺表自愈应补齐 $name');
    }

    // diary 的 v15~v19 列也都在（自愈补的是完整 schema，不是旧版建表）
    final diaryCols = (await db.rawQuery('PRAGMA table_info(diary)'))
        .map((c) => c['name'] as String)
        .toSet();
    for (final col in const [
      'sync_uuid',
      'is_locked',
      'sort_order',
      'image_path',
      'updated_at',
    ]) {
      expect(diaryCols, contains(col), reason: 'diary 应含 $col 列');
    }

    // ---- 3. 等价新装库：内置说明卡补回，且 sync_uuid 回填 ----
    final diaries = await db.query('diary');
    expect(diaries.length, 9, reason: '缺表自愈后应补回 9 条内置说明卡');
    expect(
      diaries.every((d) => (d['sync_uuid'] as String?) != null),
      isTrue,
      reason: '说明卡的 sync_uuid 应由首开回填补上',
    );

    // ---- 4. 原来失败的那条查询（getDiaries 带 diary_images 子查询）恢复 ----
    final rows = await dbHelper.getDiaries();
    expect(rows, isNotEmpty);
    expect(rows.every((r) => r['image_count'] == 0), isTrue);

    // ---- 5. 写入路径恢复（_nextTopSortOrder 也在原先报错的调用栈里） ----
    final newId = await dbHelper.insertDiary('自愈后的新日记', duration: 2);
    final saved =
        (await db.query('diary', where: 'id = ?', whereArgs: [newId])).single;
    expect(saved['content'], '自愈后的新日记');
    expect(saved['sort_order'], isNotNull);

    await db.close();
  });
}
