// 「版本号污染」坏库自愈回归测试（真机 2026-09-21 22:12 复现：覆盖安装
// 崩溃那次升级被瞬态错误打断，sqflite 原生侧的 user_version 写入发生在
// 升级事务之外——DDL 回滚了但版本号已写成 14，产出「版本=14 但
// sync_uuid 列缺失」的坏库；此后 onUpgrade 永不再触发，带 sync_uuid 的
// 写入全部失败（录音落库全丢），回填报 no such column）。
//
// 本测试精确复刻该设备状态：v13 旧 schema + 手动 PRAGMA user_version = 14，
// 用生产 DbHelper 真实打开 → 断言 _ensureSyncSchema 补列 + 回填 + 写入恢复。
//
// ⚠️ 独立库文件名：DbHelper 是进程级静态单例，flutter_test 每文件独立
// isolate——但 sqflite_common_ffi 的库文件是磁盘上共享的真实文件，多文件
// 并行跑时共用 items.db 会互相撞锁（database is locked 偶发失败）；各文件
// 走 DbHelper.dbFileName 静态覆盖口领独立库名。文件内只跑一个 test。
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shengwuji_app/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('版本号=14 但列缺失的坏库：首开自愈补列 + 回填 + 写入恢复', () async {
    DbHelper.dbFileName = 'items_poisoned_v14_test.db';
    final dbPath = p.join(await databaseFactory.getDatabasesPath(), DbHelper.dbFileName);
    await databaseFactory.deleteDatabase(dbPath);

    // ---- 复刻坏库：v13 旧 schema（无 sync_uuid）+ 数据 + 版本号伪写 14 ----
    final poisoned = await databaseFactory.openDatabase(dbPath);
    await poisoned.execute(
      "CREATE TABLE items(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, location TEXT)",
    );
    await poisoned.execute(
      "CREATE TABLE diary(id INTEGER PRIMARY KEY AUTOINCREMENT, content TEXT, created_at TEXT, audio_path TEXT, duration INTEGER, is_archived INTEGER DEFAULT 0, exported_at TEXT, tag TEXT)",
    );
    await poisoned.insert('items', {'name': '牙刷', 'location': '卫生间'});
    await poisoned.insert('diary', {
      'content': '坏库里的老日记',
      'created_at': '2026-09-21T10:00:00.000',
      'is_archived': 0,
    });
    // 模拟 sqflite「DDL 回滚但 setVersion 在事务外已执行」留下的污染
    await poisoned.execute('PRAGMA user_version = 14');
    await poisoned.close();

    // ---- 生产 DbHelper 真实打开：user_version=14 → onUpgrade 不触发，----
    // ---- 唯一的补救机会是首开后的 _ensureSyncSchema                         ----
    final dbHelper = DbHelper();
    final db = await dbHelper.db;

    // 列已就地补齐（自愈）
    final diaryCols = await db.rawQuery('PRAGMA table_info(diary)');
    expect(diaryCols.map((c) => c['name']), contains('sync_uuid'));
    final itemCols = await db.rawQuery('PRAGMA table_info(items)');
    expect(itemCols.map((c) => c['name']), contains('sync_uuid'));
    await db.query('sync_deleted'); // 墓碑表已建

    // 数据完好 + 存量行已回填 uuid
    final diaries = await db.query('diary');
    expect(diaries.length, 1);
    expect(diaries.single['content'], '坏库里的老日记');
    expect(diaries.single['sync_uuid'] as String?, isNotNull);

    // 之前最致命的写入路径恢复：插入不再报 no such column
    final newId = await dbHelper.insertDiary('自愈后的新日记', duration: 3);
    final saved =
        (await db.query('diary', where: 'id = ?', whereArgs: [newId])).single;
    expect(saved['content'], '自愈后的新日记');
    expect(saved['sync_uuid'] as String?, isNotNull);

    // 删除记墓碑路径恢复（旧代码在该状态下 deleteDiary 会同样崩）
    await dbHelper.deleteDiary(diaries.single['id'] as int);
    final tombstones = await dbHelper.loadSyncTombstones();
    expect(tombstones, contains(diaries.single['sync_uuid']));

    await db.close();
  });
}
