// 数据库 v13→v14 升级回归测试（真机事故回归：2026-09-21 覆盖安装后首启
// database_closed，杀后台重启自愈——根因是旧进程文件锁未完全释放时新进程
// 秒开撞瞬态锁 + 回填拉长升级事务窗口；修复为单飞打开 + 瞬态重试 + 回填
// 挪到首开后，见 DbHelper._openWithRetry/_openDbOnce 注释）。
//
// 用 sqflite_common_ffi 在桌面侧复刻用户升级路径：
// v13 旧 schema 建库写数据 → 生产 DbHelper 真实打开 → 断言升级 + 回填 +
// 数据完好 + 墓碑生效 + 并发首开单飞。
//
// ⚠️ 独立库文件名：DbHelper 是进程级静态单例，flutter_test 每个测试文件
// 独立 isolate——但 sqflite_common_ffi 的库文件是磁盘上共享的真实文件，
// 多文件并行跑时共用 items.db 会互相 BEGIN EXCLUSIVE 撞锁（database is
// locked 偶发失败，2026-09-21 全量跑实测复现）；各文件走 DbHelper.dbFileName
// 静态覆盖口领独立库名。文件内只跑一个 test。
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shengwuji_app/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('v13 旧库覆盖升级 v14：DDL 迁移 + 首开后回填 + 数据完好 + 墓碑 + 单飞', () async {
    DbHelper.dbFileName = 'items_upgrade_v14_test.db';
    final dbPath = p.join(await databaseFactory.getDatabasesPath(), DbHelper.dbFileName);
    await databaseFactory.deleteDatabase(dbPath);

    // ---- 1. 复刻 v13 旧库：老 schema（无 sync_uuid）+ 存量数据 ----
    final oldDb = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 13,
        onCreate: (db, version) async {
          await db.execute(
            "CREATE TABLE items(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, location TEXT)",
          );
          await db.execute(
            "CREATE TABLE diary(id INTEGER PRIMARY KEY AUTOINCREMENT, content TEXT, created_at TEXT, audio_path TEXT, duration INTEGER, is_archived INTEGER DEFAULT 0, exported_at TEXT, tag TEXT)",
          );
          await db.execute(
            "CREATE TABLE dismissed_splits(id INTEGER PRIMARY KEY AUTOINCREMENT, content TEXT NOT NULL UNIQUE, created_at TEXT)",
          );
        },
      ),
    );
    await oldDb.insert('items', {'name': '牙刷', 'location': '卫生间'});
    await oldDb.insert('items', {'name': '伞', 'location': '门口'});
    await oldDb.insert('diary', {
      'content': '旧日记一',
      'created_at': '2026-09-20T10:00:00.000',
      'is_archived': 0,
    });
    await oldDb.insert('diary', {
      'content': '旧日记二',
      'created_at': '2026-09-21T10:00:00.000',
      'is_archived': 1,
    });
    await oldDb.close();

    // ---- 2. 生产 DbHelper 真实打开：触发 v13→v14 升级 + 首开后回填 ----
    final dbHelper = DbHelper();
    final db = await dbHelper.db;

    // ---- 3. 升级后数据完好（迁移事务不丢数据）----
    final items = await db.query('items', orderBy: 'id');
    expect(items.length, 2);
    expect(items.map((r) => r['name']), ['牙刷', '伞']);
    final diaries = await db.query('diary', orderBy: 'id');
    expect(diaries.map((r) => r['content']).toSet(), {'旧日记一', '旧日记二'});
    expect(diaries.singleWhere((r) => r['content'] == '旧日记二')['is_archived'], 1);

    // ---- 4. 存量行 sync_uuid 全部回填且唯一（首开后回填路径）----
    final itemUuids = items.map((r) => r['sync_uuid'] as String?).toSet();
    expect(itemUuids.length, 2);
    expect(itemUuids.every((u) => u != null && u.isNotEmpty), isTrue);
    final diaryUuids = diaries.map((r) => r['sync_uuid'] as String?).toSet();
    expect(diaryUuids.length, 2);
    expect(diaryUuids.every((u) => u != null && u.isNotEmpty), isTrue);

    // ---- 5. 墓碑表存在且删除记墓碑 ----
    final tombstoneProbe = await db.query('sync_deleted');
    expect(tombstoneProbe, isEmpty); // 表存在且为空
    final removedUuid = diaries.first['sync_uuid'] as String;
    await dbHelper.deleteDiary(diaries.first['id'] as int);
    expect(await dbHelper.loadSyncTombstones(), {removedUuid});

    // ---- 6. 升级后新增行走 DbHelper 正常携带 uuid ----
    final newId = await dbHelper.insertDiary('新日记', duration: 5);
    final newRow = (await db.query('diary', where: 'id = ?', whereArgs: [newId])).single;
    expect(newRow['sync_uuid'] as String?, isNotNull);

    // ---- 7. 并发首开单飞：多次 get db 返回同一连接 ----
    final concurrent = await Future.wait([dbHelper.db, dbHelper.db, dbHelper.db]);
    expect(identical(concurrent[0], concurrent[1]), isTrue);
    expect(identical(concurrent[1], concurrent[2]), isTrue);

    await db.close();
  });
}
