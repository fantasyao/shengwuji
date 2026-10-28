// DbHelper.restoreDeletedDiary 回归测试（悬浮窗「滑动直接删除」撤销窗口的
// 数据层语义：真删后重插）。
//
// 用 sqflite_common_ffi 在桌面侧跑生产 DbHelper：全字段日记 → deleteDiary
// 真删（内置记同步墓碑）→ restoreDeletedDiary 原样插回 → 断言全字段保留
//（content/created_at/audio_path/duration/tag/is_locked/is_archived 与
// sync_uuid 跨端身份）、墓碑已清除（行复活后墓碑残留会让云端同 uuid 条目
// 永远无法再拉回本地）、本地自增 id 重新分配。
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

  test('滑动删除撤销：真删记墓碑 → 恢复全字段还原（sync_uuid 保留）+ 墓碑清除', () async {
    DbHelper.dbFileName = 'items_restore_deleted_test.db';
    final dbPath = p.join(
      await databaseFactory.getDatabasesPath(),
      DbHelper.dbFileName,
    );
    await databaseFactory.deleteDatabase(dbPath);
    // bump/snapshot 走 SharedPreferences（内部已 try/catch 静默容错），
    // mock 掉避免 MissingPluginException 噪声
    SharedPreferences.setMockInitialValues({});

    final dbHelper = DbHelper();
    final db = await dbHelper.db;

    // ---- 1. 造一条全字段日记（录音 + tag + 锁定） ----
    final id = await dbHelper.insertDiary(
      '撤销测试日记',
      audioPath: '/tmp/undo_test.wav',
      duration: 5,
    );
    await dbHelper.updateDiaryTag(id, 'star');
    await dbHelper.setDiaryLocked(id, true);
    await dbHelper.updateDiaryImage(id, '/tmp/undo_shot.jpg');
    final before =
        (await db.query('diary', where: 'id = ?', whereArgs: [id])).single;
    final uuid = before['sync_uuid'] as String;
    expect(uuid, isNotEmpty);

    // ---- 2. 真删：deleteDiary 内置记墓碑 ----
    await dbHelper.deleteDiary(id);
    expect(await db.query('diary', where: 'id = ?', whereArgs: [id]), isEmpty);
    expect(
      await db.query('sync_deleted', where: 'uuid = ?', whereArgs: [uuid]),
      hasLength(1),
    );

    // ---- 3. 撤销：原样插回 ----
    final newId = await dbHelper.restoreDeletedDiary(
      Map<String, dynamic>.of(before),
    );

    // 本地自增 id 重新分配（不沿用旧 id）
    expect(newId, isNot(id));

    final restored =
        (await db.query('diary', where: 'id = ?', whereArgs: [newId])).single;
    // 全字段还原
    expect(restored['content'], before['content']);
    expect(restored['created_at'], before['created_at']);
    expect(restored['audio_path'], before['audio_path']);
    expect(restored['duration'], before['duration']);
    expect(restored['is_archived'], before['is_archived']);
    expect(restored['exported_at'], before['exported_at']);
    expect(restored['tag'], before['tag']);
    expect(restored['is_locked'], before['is_locked']);
    // 截图附件随行还原（撤销窗口内图片文件未删，路径原样指回）
    expect(restored['image_path'], '/tmp/undo_shot.jpg');
    // 跨端身份保留（sync_uuid 是云同步合并键）
    expect(restored['sync_uuid'], uuid);

    // 墓碑清除（行已复活）
    expect(
      await db.query('sync_deleted', where: 'uuid = ?', whereArgs: [uuid]),
      isEmpty,
    );

    await db.close();
  });
}
