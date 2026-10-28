// 数据库 v18→v19 升级回归测试（diary.updated_at 编辑时间 + sync_note_meta
// 透传表，云同步 v2 的身份与字段保真基础）。
//
// 用 sqflite_common_ffi 复刻用户升级路径：v18 旧 schema（有 image_path、
// 无 updated_at、无 sync_note_meta）建库写数据 → 生产 DbHelper 真实打开 →
// 断言列/表就位、存量行按 created_at 回填、用户编辑会 bump 时间、
// applySyncV2Notes 的插入/覆盖/删除与透传元数据可用。
//
// ⚠️ 独立库文件名：sqflite_common_ffi 的库文件是磁盘上共享的真实文件，
// 与其他 db_*_test 并行跑会撞锁（同 db_upgrade_v17_test 头注释）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('v18 旧库升级 v19：updated_at 回填 + meta 表 + v2 落库 API 可用', () async {
    DbHelper.dbFileName = 'items_upgrade_v19_test.db';
    final dbPath = p.join(
      await databaseFactory.getDatabasesPath(),
      DbHelper.dbFileName,
    );
    await databaseFactory.deleteDatabase(dbPath);
    SharedPreferences.setMockInitialValues({});

    // ---- 1. 复刻 v18 旧库：diary 有 image_path/sort_order，无 updated_at ----
    final oldDb = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 18,
        onCreate: (db, version) async {
          await db.execute(
            "CREATE TABLE items(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, location TEXT, sync_uuid TEXT)",
          );
          await db.execute(
            "CREATE TABLE diary(id INTEGER PRIMARY KEY AUTOINCREMENT, content TEXT, created_at TEXT, audio_path TEXT, duration INTEGER, is_archived INTEGER DEFAULT 0, exported_at TEXT, tag TEXT, sync_uuid TEXT, is_locked INTEGER DEFAULT 0, sort_order INTEGER, image_path TEXT)",
          );
          await db.execute(
            "CREATE TABLE sync_deleted(uuid TEXT PRIMARY KEY, kind TEXT NOT NULL, deleted_at TEXT NOT NULL)",
          );
          await db.execute(
            "CREATE TABLE diary_images(id INTEGER PRIMARY KEY AUTOINCREMENT, note_uuid TEXT NOT NULL, device_id TEXT NOT NULL, sha256 TEXT NOT NULL, image_path TEXT, remote_name TEXT, position INTEGER NOT NULL DEFAULT 0, byte_size INTEGER, created_at TEXT)",
          );
        },
      ),
    );
    await oldDb.insert('diary', {
      'content': '旧日记-活跃',
      'created_at': '2026-10-20T11:00:00.000',
      'is_archived': 0,
      'sort_order': -2,
      'sync_uuid': 'uuid-v18-1',
    });
    await oldDb.insert('diary', {
      'content': '旧日记-归档',
      'created_at': '2026-10-20T10:00:00.000',
      'is_archived': 1,
      'sync_uuid': 'uuid-v18-2',
    });
    await oldDb.close();

    // ---- 2. 生产 DbHelper 真实打开：触发 v18→v19 升级 + 首开回填 ----
    final dbHelper = DbHelper();
    final db = await dbHelper.db;

    // ---- 3. schema 就位 ----
    final cols = await db.rawQuery('PRAGMA table_info(diary)');
    expect(cols.any((c) => c['name'] == 'updated_at'), isTrue);
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='sync_note_meta'",
    );
    expect(tables, hasLength(1));

    // ---- 4. 存量行按 created_at 回填（不是 now：否则会压过电脑端编辑） ----
    final rows = await db.query('diary', orderBy: 'id ASC');
    final expected = DateTime.parse('2026-10-20T11:00:00.000')
        .millisecondsSinceEpoch;
    expect(rows.first['updated_at'], expected);
    expect(
      rows.last['updated_at'],
      DateTime.parse('2026-10-20T10:00:00.000').millisecondsSinceEpoch,
    );

    // ---- 5. 用户编辑正文会 bump updated_at（v2 LWW 依据） ----
    final activeId = rows.first['id'] as int;
    expect(await dbHelper.updateDiary(activeId, '旧日记-改过'), 1);
    final edited =
        (await db.query('diary', where: 'id = ?', whereArgs: [activeId]))
            .single;
    expect(edited['content'], '旧日记-改过');
    expect(edited['updated_at'] as int, greaterThan(expected));

    // ---- 6. v2 合并结果落库：新行插入（活跃区置顶）、已有行覆盖、
    //         墓碑删除、透传元数据写入 ----
    final inserted = await dbHelper.applySyncV2Notes(
      upserts: [
        {
          'sync_uuid': 'uuid-pc-new',
          'content': '电脑端新笔记',
          'created_at': '2026-10-21T09:00:00.000',
          'duration': null,
          'is_archived': 0,
          'is_locked': 0,
          'tag': 'idea',
          'sort_order': 5,
          'updated_at': 1760000000000,
        },
        {
          'sync_uuid': 'uuid-v18-2',
          'content': '电脑端改了归档笔记',
          'created_at': '2026-10-20T10:00:00.000',
          'duration': 2,
          'is_archived': 1,
          'is_locked': 1,
          'tag': null,
          'sort_order': null,
          'updated_at': 1760000001000,
        },
      ],
      deletes: const [],
      metaRows: [
        {
          'note_uuid': 'uuid-pc-new',
          'base_hash': 'hash-new',
          'rev': 3,
          'tags_json': jsonEncode(['tag-a']),
          'attachments_json': jsonEncode([
            {'uuid': 'img-1', 'kind': 'image', 'sha256': 'abc'},
          ]),
          'extras_json': jsonEncode({'pc_only': true}),
        },
      ],
    );
    expect(inserted, 2);

    final newRow = (await db.query(
      'diary',
      where: 'sync_uuid = ?',
      whereArgs: ['uuid-pc-new'],
    )).single;
    expect(newRow['audio_path'], isNull);
    expect(newRow['tag'], 'idea');
    // 本地活跃区非空 → 新行比现有都新，贴顶部行 sort_order 落位（同值由
    // created_at DESC 兜底），不直接采用远端 sort_order，既有行不动
    expect(newRow['sort_order'], -2);
    final activeOrder = await dbHelper.getDiaries();
    expect(
      activeOrder.map((r) => r['content']).take(2),
      ['电脑端新笔记', '旧日记-改过'],
    );

    final patched = (await db.query(
      'diary',
      where: 'sync_uuid = ?',
      whereArgs: ['uuid-v18-2'],
    )).single;
    expect(patched['content'], '电脑端改了归档笔记');
    expect(patched['duration'], 2);
    expect(patched['is_locked'], 1);
    expect(patched['sort_order'], isNull);

    final meta = await dbHelper.loadSyncNoteMeta();
    expect(meta['uuid-pc-new']!['base_hash'], 'hash-new');
    expect(jsonDecode(meta['uuid-pc-new']!['tags_json'] as String), ['tag-a']);

    // ---- 7. 墓碑落库/清除 ----
    await dbHelper.applyRemoteTombstones({'uuid-v18-2': 1760000002000});
    final tombstones = await dbHelper.loadSyncTombstoneRows();
    expect(tombstones.containsKey('uuid-v18-2'), isTrue);
    expect(tombstones['uuid-v18-2']!['kind'], 'diary');
    await dbHelper.removeSyncTombstones(['uuid-v18-2']);
    expect((await dbHelper.loadSyncTombstoneRows()).containsKey('uuid-v18-2'),
        isFalse);

    // ---- 8. 删除：行与透传元数据一并清掉 ----
    await dbHelper.applySyncV2Notes(
      upserts: const [],
      deletes: const ['uuid-pc-new'],
      metaRows: const [],
    );
    expect(
      await db.query('diary', where: 'sync_uuid = ?', whereArgs: ['uuid-pc-new']),
      isEmpty,
    );
    expect((await dbHelper.loadSyncNoteMeta()).containsKey('uuid-pc-new'),
        isFalse);

    await db.close();
  });
}
