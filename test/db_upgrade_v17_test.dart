// 数据库 v16→v17 升级回归测试（diary 表新增 image_path 截图附件列）。
//
// 用 sqflite_common_ffi 在桌面侧复刻用户升级路径：v16 旧 schema（含
// sort_order，无 image_path）建库写数据 → 生产 DbHelper 真实打开 → 断言
// image_path 列就位、存量行 NULL（无附件）、updateDiaryImage 可写可清、
// 数据完好。
//
// ⚠️ 独立库文件名：sqflite_common_ffi 的库文件是磁盘上共享的真实文件，
// 多测试文件并行跑时共用 items.db 会互相撞锁（db_upgrade_v14_test 头注释）；
// 各文件走 DbHelper.dbFileName 静态覆盖口领独立库名。文件内只跑一个 test。
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('v16 旧库升级 v17：image_path 列就位 + 存量行 NULL + 写入/清除可用', () async {
    DbHelper.dbFileName = 'items_upgrade_v17_test.db';
    final dbPath = p.join(
      await databaseFactory.getDatabasesPath(),
      DbHelper.dbFileName,
    );
    await databaseFactory.deleteDatabase(dbPath);
    // bump/snapshot 走 SharedPreferences（内部已 try/catch 静默容错），
    // mock 掉避免 MissingPluginException 噪声
    SharedPreferences.setMockInitialValues({});

    // ---- 1. 复刻 v16 旧库：diary 有 sort_order（v16 产物）、无 image_path ----
    final oldDb = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 16,
        onCreate: (db, version) async {
          await db.execute(
            "CREATE TABLE items(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, location TEXT, sync_uuid TEXT)",
          );
          await db.execute(
            "CREATE TABLE diary(id INTEGER PRIMARY KEY AUTOINCREMENT, content TEXT, created_at TEXT, audio_path TEXT, duration INTEGER, is_archived INTEGER DEFAULT 0, exported_at TEXT, tag TEXT, sync_uuid TEXT, is_locked INTEGER DEFAULT 0, sort_order INTEGER)",
          );
          await db.execute(
            "CREATE TABLE sync_deleted(uuid TEXT PRIMARY KEY, kind TEXT NOT NULL, deleted_at TEXT NOT NULL)",
          );
        },
      ),
    );
    await oldDb.insert('diary', {
      'content': '旧日记-有排序',
      'created_at': '2026-10-20T11:00:00.000',
      'is_archived': 0,
      'sort_order': -2,
      'sync_uuid': 'uuid-v16-1',
    });
    await oldDb.insert('diary', {
      'content': '旧日记-归档',
      'created_at': '2026-10-20T10:00:00.000',
      'is_archived': 1,
      'sync_uuid': 'uuid-v16-2',
    });
    await oldDb.close();

    // ---- 2. 生产 DbHelper 真实打开：触发 v16→v17 升级 ----
    final dbHelper = DbHelper();
    final db = await dbHelper.db;

    // ---- 3. image_path 列就位：PRAGMA 核实表结构 ----
    final cols = await db.rawQuery('PRAGMA table_info(diary)');
    expect(cols.any((c) => c['name'] == 'image_path'), isTrue);

    // ---- 4. 存量行默认 NULL（无附件）且数据完好 ----
    final diaries = await dbHelper.getDiaries();
    expect(diaries, hasLength(2));
    expect(diaries.every((d) => d['image_path'] == null), isTrue);
    expect(diaries.first['content'], '旧日记-有排序');
    expect(diaries.first['sort_order'], -2);
    expect(diaries.last['is_locked'], 0);

    // ---- 5. updateDiaryImage：写入与清除（传 null）均生效 ----
    final id = diaries.first['id'] as int;
    expect(
      await dbHelper.updateDiaryImage(id, '/tmp/diary_images/shot.jpg'),
      1,
    );
    var row = (await db.query('diary', where: 'id = ?', whereArgs: [id])).single;
    expect(row['image_path'], '/tmp/diary_images/shot.jpg');

    expect(await dbHelper.updateDiaryImage(id, null), 1);
    row = (await db.query('diary', where: 'id = ?', whereArgs: [id])).single;
    expect(row['image_path'], isNull);

    // ---- 6. 新插入行默认无附件（悬浮窗/主 App 常规新建路径） ----
    final newId = await dbHelper.insertDiary('升级后新卡');
    final newRow =
        (await db.query('diary', where: 'id = ?', whereArgs: [newId])).single;
    expect(newRow['image_path'], isNull);

    await db.close();
  });
}
