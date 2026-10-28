// 截图同步纯逻辑单测：索引编解码、按设备归属合并、下载计划、格式识别，
// 以及下载落库后的 image_path 回填（CloudSyncService._syncImages 采用）。
//
// ⚠️ 独立库文件名：sqflite_common_ffi 的库文件是磁盘上共享的真实文件，
// 与其他 db_*_test 并行跑会撞锁（同 db_sort_order_test 头注释）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/db_helper.dart';
import 'package:shengwuji_app/sync/image_sync.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final shaA = 'a' * 64;
  final shaB = 'b' * 64;
  final shaC = 'c' * 64;

  ImageSyncEntry entry({
    required String noteUuid,
    required String deviceId,
    required String sha256,
    String updatedAt = '2026-10-24T09:00:00.000Z',
    int position = 0,
  }) {
    return ImageSyncEntry(
      noteUuid: noteUuid,
      deviceId: deviceId,
      sha256: sha256,
      name: '$sha256.jpg',
      mimeType: 'image/jpeg',
      byteSize: 123,
      updatedAt: updatedAt,
      position: position,
    );
  }

  test('索引解析：坏 JSON 与顶层不是数组都返回 null，坏行跳过', () {
    expect(tryDecodeImageEntries('not json'), isNull);
    expect(tryDecodeImageEntries('{"entries": []}'), isNull);

    final parsed = tryDecodeImageEntries(jsonEncode([
      {
        'note_uuid': 'n1',
        'device_id': 'phone-a',
        'sha256': shaA,
        'name': '$shaA.jpg',
        'mime': 'image/jpeg',
        'size': 10,
        'updated_at': '2026-10-24T09:00:00.000Z',
      },
      // sha 不合法 → 丢弃
      {'note_uuid': 'n2', 'sha256': 'abc', 'name': 'x.jpg'},
      // 路径穿越会被收敛成 basename
      {'note_uuid': 'n3', 'sha256': shaB, 'name': '../../evil.jpg'},
      'garbage',
    ]));

    expect(parsed, hasLength(2));
    expect(parsed!.first.noteUuid, 'n1');
    expect(parsed.first.remotePath, 'v2/assets/aa/$shaA.jpg');
    expect(parsed.last.name, 'evil.jpg');
  });

  test('编码按 (note_uuid, device_id) 排序，避免顺序抖动重传', () {
    final text = encodeImageEntries([
      entry(noteUuid: 'n2', deviceId: 'b', sha256: shaB),
      entry(noteUuid: 'n2', deviceId: 'a', sha256: shaA),
      entry(noteUuid: 'n1', deviceId: 'c', sha256: shaC),
    ]);

    final decoded = (jsonDecode(text) as List).cast<Map<String, dynamic>>();
    expect(decoded.map((item) => item['note_uuid']), ['n1', 'n2', 'n2']);
    expect(decoded.map((item) => item['device_id']), ['c', 'a', 'b']);
  });

  test('合并：其他设备的多张图原样保留，本机换图只影响本机条目', () {
    final merged = mergeImageIndex(
      remote: [
        entry(noteUuid: 'n1', deviceId: 'pc', sha256: shaA, position: 0),
        entry(noteUuid: 'n1', deviceId: 'pc', sha256: shaB, position: 1),
        entry(noteUuid: 'n1', deviceId: 'phone-a', sha256: shaC),
      ],
      local: [entry(noteUuid: 'n1', deviceId: 'phone-a', sha256: shaA)],
      deviceId: 'phone-a',
      localNoteUuids: {'n1'},
    );

    final pcShas = merged
        .where((item) => item.deviceId == 'pc')
        .map((item) => item.sha256)
        .toList()
      ..sort();
    expect(pcShas, [shaA, shaB]);
    final own = merged.where((item) => item.deviceId == 'phone-a').toList();
    expect(own.single.sha256, shaA); // 本机条目被本地截图替换
  });

  test('合并：本机条目随本地截图替换，其他设备与已删笔记的条目保留', () {
    final merged = mergeImageIndex(
      remote: [
        entry(noteUuid: 'n1', deviceId: 'phone-a', sha256: shaA),
        entry(noteUuid: 'n1', deviceId: 'phone-b', sha256: shaB),
        // 本机为已删除笔记写过的条目：本地没有这行，必须保留
        entry(noteUuid: 'n2', deviceId: 'phone-a', sha256: shaC),
      ],
      local: [entry(noteUuid: 'n1', deviceId: 'phone-a', sha256: shaC)],
      deviceId: 'phone-a',
      localNoteUuids: {'n1'},
    );

    String shaOf(String note, String device) => merged
        .firstWhere(
          (item) => item.noteUuid == note && item.deviceId == device,
        )
        .sha256;

    expect(shaOf('n1', 'phone-a'), shaC); // 本机换成新图
    expect(shaOf('n1', 'phone-b'), shaB); // 其他设备不动
    expect(shaOf('n2', 'phone-a'), shaC); // 已删笔记的旧条目保留
  });

  test('合并：本轮上传失败/超限的笔记保留云端旧条目', () {
    final merged = mergeImageIndex(
      remote: [entry(noteUuid: 'n1', deviceId: 'phone-a', sha256: shaA)],
      local: const [],
      deviceId: 'phone-a',
      localNoteUuids: {'n1'},
      keepOwnFor: {'n1'},
    );

    expect(merged.single.sha256, shaA);
  });

  test('合并：笔记仍在本地但没有截图 → 本机条目被移除', () {
    final merged = mergeImageIndex(
      remote: [entry(noteUuid: 'n1', deviceId: 'phone-a', sha256: shaA)],
      local: const [],
      deviceId: 'phone-a',
      localNoteUuids: {'n1'},
    );

    expect(merged, isEmpty);
  });

  test('下载计划：其他设备多图全部下载，已有 sha 与墓碑跳过', () {
    final (batch, overflow) = planImageDownloads(
      remote: [
        entry(noteUuid: 'n1', deviceId: 'pc', sha256: shaA, position: 1),
        entry(noteUuid: 'n1', deviceId: 'pc', sha256: shaB, position: 0),
        entry(noteUuid: 'n2', deviceId: 'pc', sha256: shaC),
        // 本机条目：该笔记本机已有截图 → 不重下
        entry(noteUuid: 'n3', deviceId: 'phone-a', sha256: shaC),
      ],
      deviceId: 'phone-a',
      localNoteUuids: {'n1', 'n2', 'n3'},
      tombstones: {'n2'},
      existingKeys: {'n1\u0000pc\u0000$shaA'},
      notesWithOwnImage: {'n3'},
    );

    expect(overflow, 0);
    expect(batch, hasLength(1));
    expect(batch.single.noteUuid, 'n1');
    expect(batch.single.sha256, shaB);
    expect(batch.single.deviceId, 'pc');
    expect(batch.single.position, 0);
  });

  test('下载计划：本机截图丢失时恢复本机最新条目一张', () {
    final (batch, _) = planImageDownloads(
      remote: [
        entry(
          noteUuid: 'n1',
          deviceId: 'phone-a',
          sha256: shaA,
          updatedAt: '2026-10-24T08:00:00.000Z',
        ),
        entry(
          noteUuid: 'n1',
          deviceId: 'phone-a',
          sha256: shaB,
          updatedAt: '2026-10-24T10:00:00.000Z',
        ),
      ],
      deviceId: 'phone-a',
      localNoteUuids: {'n1'},
      tombstones: const {},
      existingKeys: const {},
      notesWithOwnImage: const {},
    );

    expect(batch, hasLength(1));
    expect(batch.single.sha256, shaB);
  });

  test('下载计划按上限截断并报告剩余量', () {
    final remote = [
      for (var i = 0; i < 3; i++)
        entry(
          noteUuid: 'n$i',
          deviceId: 'pc',
          sha256: shaA,
        ),
    ];
    final (batch, overflow) = planImageDownloads(
      remote: remote,
      deviceId: 'phone-a',
      localNoteUuids: {'n0', 'n1', 'n2'},
      tombstones: const {},
      existingKeys: const {},
      notesWithOwnImage: const {},
      limit: 2,
    );

    expect(batch, hasLength(2));
    expect(overflow, 1);
  });

  test('按文件头识别图片格式', () {
    expect(
      detectImageExtension(
        Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
      ),
      'png',
    );
    expect(detectImageExtension(Uint8List.fromList([0xFF, 0xD8, 0xFF])), 'jpg');
    expect(
      detectImageExtension(
        Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]),
      ),
      'gif',
    );
    expect(detectImageExtension(Uint8List.fromList([0x42, 0x4D])), 'bmp');
    expect(
      detectImageExtension(
        Uint8List.fromList([
          0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50,
        ]),
      ),
      'webp',
    );
    expect(detectImageExtension(Uint8List.fromList([1, 2, 3])), isNull);
    expect(imageMimeType('jpg'), 'image/jpeg');
  });

  test('下载落库：image_path 回填 + 多图计数与首选图', () async {
    DbHelper.dbFileName = 'items_sync_image_test.db';
    final dbPath = p.join(
      await databaseFactory.getDatabasesPath(),
      DbHelper.dbFileName,
    );
    await databaseFactory.deleteDatabase(dbPath);
    SharedPreferences.setMockInitialValues({});

    final helper = DbHelper();
    await helper.insertDiary('带截图的日记');
    Future<Map<String, dynamic>> rowOf(String uuid) async =>
        (await helper.queryAllDiaries()).firstWhere(
          (row) => row['sync_uuid'] == uuid,
        );
    final inserted = (await helper.queryAllDiaries()).firstWhere(
      (row) => row['content'] == '带截图的日记',
    );
    final uuid = inserted['sync_uuid'] as String;

    expect(await helper.updateDiaryImagePathByUuid(uuid, '/tmp/a.jpg'), 1);
    expect((await rowOf(uuid))['image_path'], '/tmp/a.jpg');
    expect(await helper.updateDiaryImagePathByUuid('missing', '/tmp/b.jpg'), 0);

    // 电脑端两张图：按 position 排序，计数 = 自拍 1 + 下载 2
    await helper.upsertDiaryImage(
      noteUuid: uuid,
      deviceId: 'pc',
      sha256: shaB,
      imagePath: '/tmp/pc2.jpg',
      position: 1,
    );
    await helper.upsertDiaryImage(
      noteUuid: uuid,
      deviceId: 'pc',
      sha256: shaA,
      imagePath: '/tmp/pc1.jpg',
      position: 0,
    );
    final images = await helper.getDiaryImages(uuid);
    expect(images.map((row) => row['sha256']), [shaA, shaB]);

    final card = (await helper.getDiaries()).firstWhere(
      (row) => row['sync_uuid'] == uuid,
    );
    expect(card['image_count'], 3);
    expect(card['primary_image_path'], '/tmp/a.jpg');

    // 同名图重复 upsert 不新增行
    await helper.upsertDiaryImage(
      noteUuid: uuid,
      deviceId: 'pc',
      sha256: shaA,
      imagePath: '/tmp/pc1-again.jpg',
      position: 0,
    );
    expect(await helper.getDiaryImages(uuid), hasLength(2));

    expect(await helper.deleteDiaryImagesForNote(uuid), 2);
    expect(await helper.getDiaryImages(uuid), isEmpty);
    final afterDelete = (await helper.getDiaries()).firstWhere(
      (row) => row['sync_uuid'] == uuid,
    );
    expect(afterDelete['image_count'], 1);
    expect(afterDelete['primary_image_path'], '/tmp/a.jpg');
  });
}
