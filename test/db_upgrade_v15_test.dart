// 数据库 v14→v15 升级回归测试（笔记锁定功能：diary 表新增 is_locked 列）。
//
// 用 sqflite_common_ffi 在桌面侧复刻用户升级路径：v14 旧 schema（含 sync_uuid，
// 无 is_locked）建库写数据 → 生产 DbHelper 真实打开 → 断言 is_locked 列就位、
// 存量行默认 0、数据完好。
//
// ⚠️ 独立库文件名：sqflite_common_ffi 的库文件是磁盘上共享的真实文件，
// 多测试文件并行跑时共用 items.db 会互相撞锁（db_upgrade_v14_test 头注释）；
// 各文件走 DbHelper.dbFileName 静态覆盖口领独立库名。文件内只跑一个 test。
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shengwuji_app/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('v14 旧库升级 v15：is_locked 列就位 + 存量行默认未锁定 + 数据完好', () async {
    DbHelper.dbFileName = 'items_upgrade_v15_test.db';
    final dbPath = p.join(
      await databaseFactory.getDatabasesPath(),
      DbHelper.dbFileName,
    );
    await databaseFactory.deleteDatabase(dbPath);

    // ---- 1. 复刻 v14 旧库：diary 有 sync_uuid（v14 产物）、无 is_locked ----
    final oldDb = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 14,
        onCreate: (db, version) async {
          await db.execute(
            "CREATE TABLE items(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, location TEXT, sync_uuid TEXT)",
          );
          await db.execute(
            "CREATE TABLE diary(id INTEGER PRIMARY KEY AUTOINCREMENT, content TEXT, created_at TEXT, audio_path TEXT, duration INTEGER, is_archived INTEGER DEFAULT 0, exported_at TEXT, tag TEXT, sync_uuid TEXT)",
          );
          await db.execute(
            "CREATE TABLE sync_deleted(uuid TEXT PRIMARY KEY, kind TEXT NOT NULL, deleted_at TEXT NOT NULL)",
          );
        },
      ),
    );
    await oldDb.insert('diary', {
      'content': 'v14 旧日记',
      'created_at': '2026-09-21T10:00:00.000',
      'is_archived': 0,
      'sync_uuid': 'uuid-legacy-1',
    });
    await oldDb.close();

    // ---- 2. 生产 DbHelper 真实打开：触发 v14→v15 升级 ----
    final dbHelper = DbHelper();
    final db = await dbHelper.db;

    // ---- 3. 存量数据完好 + is_locked 列存在且默认 0 ----
    final diaries = await db.query('diary', orderBy: 'id');
    expect(diaries.length, 1);
    expect(diaries.first['content'], 'v14 旧日记');
    expect(diaries.first['sync_uuid'], 'uuid-legacy-1');
    expect(diaries.first['is_locked'], 0);

    // ---- 4. setDiaryLocked 写入/解除往返 ----
    final id = diaries.first['id'] as int;
    expect(await dbHelper.setDiaryLocked(id, true), 1);
    expect(
      (await db.query('diary', where: 'id = ?', whereArgs: [id])).first['is_locked'],
      1,
    );
    expect(await dbHelper.setDiaryLocked(id, false), 1);
    expect(
      (await db.query('diary', where: 'id = ?', whereArgs: [id])).first['is_locked'],
      0,
    );

    // ---- 5. 新装库（onCreate 路径）同样带 is_locked 列：插入默认 0 ----
    final newId = await dbHelper.insertDiary('新日记', duration: 3);
    final newRow = (await db.query('diary', where: 'id = ?', whereArgs: [newId])).single;
    expect(newRow['is_locked'], 0);

    await db.close();
  });
}
