// 云同步 v2 落库路径（无网络）端到端测试：首次从 v2 导入（保留电脑端
// 标签/图片/未知字段）、手机编辑不回退、电脑端编辑覆盖、首次接 v2 的
// seed 保真、双方冲突留副本、远端墓碑删除。
//
// mergeLocalDiariesV2 是同步主流程里不依赖 WebDAV 的本地段，直接驱动它，
// 网络发布段另行在真机验证。
//
// ⚠️ 独立库文件名 + 单个 test：DbHelper 是静态连接，多 test 会互相干扰
// （同 db_upgrade_v19_test 头注释）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/db_helper.dart';
import 'package:shengwuji_app/sync/cloud_sync_service.dart';
import 'package:shengwuji_app/sync/sync_models.dart';
import 'package:shengwuji_app/sync/sync_v2.dart';
import 'package:shengwuji_app/text_processor.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

V2NotesParseResult notesPayload(List<Map<String, dynamic>> notes) =>
    parseNotesV2(
      jsonEncode({
        'format': 'shengwuji.notes',
        'version': 2,
        'notes': notes,
      }),
    );

V2TombstonesParseResult tombstonesPayload(List<Map<String, dynamic>> rows) =>
    parseTombstonesV2(
      jsonEncode({'format': 'shengwuji.tombstones', 'version': 2, 'tombstones': rows}),
    );

Map<String, dynamic> richNoteJson({
  required String uuid,
  required String content,
  required String updatedAt,
  required int sortOrder,
}) => {
  'uuid': uuid,
  'content': content,
  'created_at': '2026-10-20T09:00:00.000Z',
  'updated_at': updatedAt,
  'rev': 4,
  'mark': 'idea',
  'archived': false,
  'locked': false,
  'sort_order': sortOrder,
  'tags': [
    {'uuid': 'tag-work', 'name': '工作'},
  ],
  'attachments': [
    {
      'uuid': 'img-1',
      'kind': 'image',
      'origin': 'mobile',
      'sha256': 'abc123',
      'name': 'shot.jpg',
    },
    {
      'uuid': 'aud-1',
      'kind': 'audio',
      'origin': 'record',
      'name': 'rec.m4a',
      'duration_ms': 3000,
    },
  ],
  'extras': {'pc_only': 1},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('v2 合并：首次导入/双向编辑/seed 保真/冲突副本/墓碑删除', () async {
    DbHelper.dbFileName = 'items_cloud_sync_v2_merge_test.db';
    final dbPath = p.join(
      await databaseFactory.getDatabasesPath(),
      DbHelper.dbFileName,
    );
    await databaseFactory.deleteDatabase(dbPath);
    SharedPreferences.setMockInitialValues({});

    final dbHelper = DbHelper();
    final service = CloudSyncService(
      dbHelper: dbHelper,
      processor: TextProcessor(),
    );

    // ---- A. 首次同步：v1 投影 + v2 富记录 → 插入并保留透传字段 ----
    final v1Entries = [
      DiarySyncEntry(
        uuid: 'n1',
        content: '电脑端笔记',
        createdAt: '2026-10-20T09:00:00.000',
        audioName: 'rec.m4a',
        duration: 3,
        tag: 'idea',
        sortOrder: 0,
      ),
    ];
    final n1 = richNoteJson(
      uuid: 'n1',
      content: '电脑端笔记',
      updatedAt: '2026-10-20T09:00:00.000Z',
      sortOrder: 0,
    );
    final statsA = <String>[];
    final mergedA = await service.mergeLocalDiariesV2(
      remoteDiary: v1Entries,
      remoteNotes: notesPayload([n1]),
      remoteTombstones: tombstonesPayload(const []),
      stats: statsA,
    );
    expect(statsA, contains('下载日记 1 条'));
    expect(mergedA.notes['n1']!.attachments, hasLength(2));

    var row = (await dbHelper.queryAllDiaries())
        .firstWhere((r) => r['sync_uuid'] == 'n1');
    expect(row['content'], '电脑端笔记');
    expect(row['tag'], 'idea');
    final noteId = row['id'] as int;
    var meta = await dbHelper.loadSyncNoteMeta();
    expect(jsonDecode(meta['n1']!['tags_json'] as String), hasLength(1));
    expect(
      jsonDecode(meta['n1']!['attachments_json'] as String),
      hasLength(2),
    );
    expect(jsonDecode(meta['n1']!['extras_json'] as String), {'pc_only': 1});
    expect(meta['n1']!['base_hash'], mergedA.notes['n1']!.payloadHash);

    // ---- B. 手机改正文：远端没改 → 本地保留，不被旧内容回滚 ----
    expect(await dbHelper.updateDiary(noteId, '手机改过'), 1);
    final statsB = <String>[];
    final mergedB = await service.mergeLocalDiariesV2(
      remoteDiary: const [],
      remoteNotes: notesPayload([n1]),
      remoteTombstones: tombstonesPayload(const []),
      stats: statsB,
    );
    expect(statsB, isEmpty);
    expect(mergedB.notes['n1']!.content, '手机改过');
    row = (await dbHelper.queryAllDiaries())
        .firstWhere((r) => r['sync_uuid'] == 'n1');
    expect(row['content'], '手机改过');
    meta = await dbHelper.loadSyncNoteMeta();
    expect(meta['n1']!['base_hash'], mergedB.notes['n1']!.payloadHash);

    // ---- C. 电脑端随后改正文且更新 → 覆盖手机（基线判定远端单边改过） ----
    final desktopEdit = richNoteJson(
      uuid: 'n1',
      content: '电脑端改过',
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch + 60000,
        isUtc: true,
      ).toIso8601String(),
      sortOrder: 0,
    );
    final statsC = <String>[];
    final mergedC = await service.mergeLocalDiariesV2(
      remoteDiary: const [],
      remoteNotes: notesPayload([desktopEdit]),
      remoteTombstones: tombstonesPayload(const []),
      stats: statsC,
    );
    expect(statsC, contains('更新日记 1 条'));
    expect(mergedC.notes['n1']!.content, '电脑端改过');
    row = (await dbHelper.queryAllDiaries())
        .firstWhere((r) => r['sync_uuid'] == 'n1');
    expect(row['content'], '电脑端改过');

    // ---- D. 首次接 v2 的本地老笔记：用远端同 uuid 记录做 seed，
    //         标签/图片不因本地载荷“缺字段”而被 LWW 覆盖掉 ----
    final localOnlyId = await dbHelper.insertDiary('手机原有笔记');
    final localOnlyRow =
        (await dbHelper.queryAllDiaries()).firstWhere((r) => r['id'] == localOnlyId);
    final localOnlyUuid = localOnlyRow['sync_uuid'] as String;
    final seededRemote = parseNotesV2(
      jsonEncode({
        'version': 2,
        'notes': [
          {
            'uuid': localOnlyUuid,
            'content': '手机原有笔记',
            'created_at':
                DateTime.parse(localOnlyRow['created_at'] as String)
                    .toUtc()
                    .toIso8601String(),
            'updated_at':
                DateTime.parse(localOnlyRow['created_at'] as String)
                    .toUtc()
                    .toIso8601String(),
            'sort_order': localOnlyRow['sort_order'],
            'tags': [
              {'uuid': 'tag-keep'},
            ],
            'attachments': [
              {'uuid': 'img-keep', 'kind': 'image', 'sha256': 'keep'},
            ],
            'extras': {'pc_keep': true},
          },
        ],
      }),
    );
    final statsD = <String>[];
    final mergedD = await service.mergeLocalDiariesV2(
      remoteDiary: const [],
      remoteNotes: seededRemote,
      remoteTombstones: tombstonesPayload(const []),
      stats: statsD,
    );
    final seeded = mergedD.notes[localOnlyUuid]!;
    expect(seeded.content, '手机原有笔记');
    expect(seeded.tags, hasLength(1));
    expect(seeded.attachments.single.uuid, 'img-keep');
    expect(seeded.extras, {'pc_keep': true});
    meta = await dbHelper.loadSyncNoteMeta();
    expect(
      jsonDecode(meta[localOnlyUuid]!['attachments_json'] as String),
      hasLength(1),
    );

    // ---- E. 双方同时改且时间接近 → 远端赢 + 本地保留冲突副本 ----
    final conflictId = await dbHelper.insertDiary('冲突前');
    final conflictRow =
        (await dbHelper.queryAllDiaries()).firstWhere((r) => r['id'] == conflictId);
    final conflictUuid = conflictRow['sync_uuid'] as String;
    final beforeEdit = noteFromDiaryRow(conflictRow);
    await dbHelper.applySyncV2Notes(
      upserts: const [],
      deletes: const [],
      metaRows: [metaRowFromV2Note(beforeEdit)],
    );
    await dbHelper.updateDiary(conflictId, '手机版本');
    final remoteConflict = parseNotesV2(
      jsonEncode({
        'version': 2,
        'notes': [
          {
            'uuid': conflictUuid,
            'content': '电脑版本',
            'created_at':
                DateTime.parse(conflictRow['created_at'] as String)
                    .toUtc()
                    .toIso8601String(),
            'updated_at': DateTime.fromMillisecondsSinceEpoch(
              DateTime.now().millisecondsSinceEpoch + 60000,
              isUtc: true,
            ).toIso8601String(),
            'sort_order': conflictRow['sort_order'],
          },
        ],
      }),
    );
    final statsE = <String>[];
    final mergedE = await service.mergeLocalDiariesV2(
      remoteDiary: const [],
      remoteNotes: remoteConflict,
      remoteTombstones: tombstonesPayload(const []),
      stats: statsE,
    );
    expect(statsE, contains('更新日记 1 条'));
    expect(statsE, contains('保留冲突副本 1 条'));
    expect(mergedE.conflictCopies, 1);
    final allRows = await dbHelper.queryAllDiaries();
    expect(allRows.any((r) => r['content'] == '电脑版本'), isTrue);
    expect(allRows.any((r) => r['content'] == '手机版本'), isTrue);
    final copy = allRows.firstWhere((r) => r['content'] == '手机版本');
    final copyMeta = (await dbHelper.loadSyncNoteMeta())[copy['sync_uuid']]!;
    expect(jsonDecode(copyMeta['extras_json'] as String), {
      'conflict_of': conflictUuid,
    });

    // ---- F. 远端墓碑：删除本地行、落墓碑、清透传元数据 ----
    final statsF = <String>[];
    final mergedF = await service.mergeLocalDiariesV2(
      remoteDiary: const [],
      remoteNotes: const V2NotesParseResult(notes: [], skipped: 0),
      remoteTombstones: tombstonesPayload([
        {
          'entity': 'note',
          'uuid': conflictUuid,
          'deleted_at': DateTime.fromMillisecondsSinceEpoch(
            DateTime.now().millisecondsSinceEpoch + 120000,
            isUtc: true,
          ).toIso8601String(),
        },
      ]),
      stats: statsF,
    );
    expect(statsF, contains('删除日记 1 条'));
    expect(mergedF.notes.containsKey(conflictUuid), isFalse);
    expect(
      (await dbHelper.queryAllDiaries())
          .any((r) => r['sync_uuid'] == conflictUuid),
      isFalse,
    );
    expect(
      (await dbHelper.loadSyncTombstoneRows()).containsKey(conflictUuid),
      isTrue,
    );
  });
}
