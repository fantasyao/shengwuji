// 云同步 v2 纯逻辑单测：编解码 round-trip、载荷指纹、三方合并（基线/ LWW /
// 冲突副本 / 墓碑与复活 / 版本守卫）、本地行 ↔ v2 笔记转换。
// 协议与裁决规则见 docs/architecture/cloud-sync.md「v2 编辑同步」。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/sync/sync_v2.dart';
import 'package:shengwuji_app/sync/sync_v2_merge.dart';

V2Note note(
  String uuid, {
  String content = '正文',
  int createdAt = 1000,
  int updatedAt = 1000,
  String? mark,
  bool archived = false,
  bool locked = false,
  int? sortOrder,
  List<dynamic> tags = const [],
  List<V2Attachment> attachments = const [],
  Map<String, dynamic> extras = const {},
}) => V2Note(
  uuid: uuid,
  content: content,
  createdAtMs: createdAt,
  updatedAtMs: updatedAt,
  mark: mark,
  archived: archived,
  locked: locked,
  sortOrder: sortOrder,
  tags: tags,
  attachments: attachments,
  extras: extras,
);

void main() {
  group('v2 笔记编解码', () {
    test('encode → parse 保留标签/附件/未知字段与时间瞬时', () {
      final source = V2Note(
        uuid: 'n1',
        content: '周会纪要',
        createdAtMs: DateTime.utc(2026, 10, 20, 9).millisecondsSinceEpoch,
        updatedAtMs: DateTime.utc(2026, 10, 20, 10).millisecondsSinceEpoch,
        mark: 'urgent',
        archived: true,
        locked: true,
        sortOrder: -3,
        rev: 7,
        tags: [
          {'uuid': 'tag-1', 'name': '工作'},
        ],
        attachments: const [
          V2Attachment(
            uuid: 'a1',
            kind: 'image',
            origin: 'mobile',
            sha256: 'abc',
            name: 'shot.jpg',
            mimeType: 'image/jpeg',
            byteSize: 12,
            sortOrder: 2,
          ),
        ],
        extras: const {'pc_only': 'keep-me', 'nested': {'x': 1}},
      );

      final encoded = encodeNotesV2(
        notes: [source],
        topExtras: const {'extra_top': true},
        deviceId: 'dev-a',
        nowMs: 5000,
      );
      final parsed = parseNotesV2(jsonEncode(encoded));

      expect(parsed.skipped, 0);
      expect(parsed.topExtras, {'extra_top': true});
      final back = parsed.notes.single;
      expect(back.uuid, 'n1');
      expect(back.content, '周会纪要');
      expect(back.createdAtMs, source.createdAtMs);
      expect(back.updatedAtMs, source.updatedAtMs);
      expect(back.mark, 'urgent');
      expect(back.archived, isTrue);
      expect(back.locked, isTrue);
      expect(back.sortOrder, -3);
      expect(back.rev, 7);
      expect(back.tags, source.tags);
      expect(back.extras, source.extras);
      final attachment = back.attachments.single;
      expect(attachment.kind, 'image');
      expect(attachment.origin, 'mobile');
      expect(attachment.sha256, 'abc');
      expect(attachment.name, 'shot.jpg');
      expect(attachment.mimeType, 'image/jpeg');
      expect(attachment.byteSize, 12);
      expect(attachment.sortOrder, 2);
      // 载荷指纹跨编解码稳定（合并基线才能对上）
      expect(back.payloadHash, source.payloadHash);
    });

    test('坏行跳过、顶层结构坏了抛错（不把坏文件当空快照）', () {
      final raw = jsonEncode({
        'format': 'shengwuji.notes',
        'version': 2,
        'notes': [
          {'uuid': 'ok', 'content': '好的', 'created_at': '2026-10-20T09:00:00.000Z'},
          {'uuid': '', 'content': '缺身份', 'created_at': '2026-10-20T09:00:00.000Z'},
          {'uuid': 'no-time', 'content': '缺时间'},
          'not-a-map',
        ],
      });
      final parsed = parseNotesV2(raw);
      expect(parsed.notes.single.uuid, 'ok');
      // updated_at 缺失时回退 created_at
      expect(parsed.notes.single.updatedAtMs, parsed.notes.single.createdAtMs);
      expect(parsed.skipped, 3);

      expect(parseNotesV2(null).notes, isEmpty);
      expect(parseNotesV2('  ').notes, isEmpty);
      expect(() => parseNotesV2('[]'), throwsFormatException);
      expect(() => parseNotesV2('{"version":2}'), throwsFormatException);
    });

    test('v1 audio/duration 兼容：无附件列表时也能解析出音频附件', () {
      final parsed = parseNotesV2(
        jsonEncode({
          'version': 2,
          'notes': [
            {
              'uuid': 'legacy',
              'content': '带录音',
              'created_at': '2026-10-20T09:00:00.000Z',
              'audio': 'rec.m4a',
              'duration': 3,
            },
          ],
        }),
      );
      final back = parsed.notes.single;
      final audio = back.attachments.single;
      expect(audio.isAudio, isTrue);
      expect(audio.name, 'rec.m4a');
      expect(audio.durationMs, 3000);
      expect(back.extras.containsKey('audio'), isFalse);
    });

    test('载荷指纹：tags 字段与 extras.tags 两种形态一致（电脑端兼容）', () {
      final withTagsField = note('n', tags: ['tag-a']);
      final withLegacyExtras = note('n', extras: {'tags': ['tag-a']});
      expect(withTagsField.payloadHash, withLegacyExtras.payloadHash);

      // updated_at / rev 是诊断字段，不参与指纹；内容/标注/排序参与
      expect(
        note('n').payloadHash,
        note('n', updatedAt: 999999).payloadHash,
      );
      expect(note('n').payloadHash, isNot(note('n', content: '改过').payloadHash));
      expect(note('n').payloadHash, isNot(note('n', mark: 'task').payloadHash));
      expect(note('n').payloadHash, isNot(note('n', sortOrder: 1).payloadHash));
    });
  });

  group('v2 墓碑编解码', () {
    test('round-trip 保留非 note 条目与顶层未知字段', () {
      final encoded = encodeTombstonesV2(
        tombstones: const [
          V2Tombstone(uuid: 'n1', deletedAtMs: 2000, rev: 2),
        ],
        preservedRows: const [
          {'entity': 'item', 'uuid': 'i1', 'deleted_at': '2026-10-20T09:00:00Z'},
        ],
        topExtras: const {'future_field': 1},
        nowMs: 3000,
      );
      final parsed = parseTombstonesV2(jsonEncode(encoded));
      expect(parsed.tombstones['n1']!.deletedAtMs, 2000);
      expect(parsed.tombstones['n1']!.rev, 2);
      expect(parsed.preservedRows.single['uuid'], 'i1');
      expect(parsed.topExtras, {'future_field': 1});
    });

    test('缺 deleted_at / uuid 的 note 行跳过', () {
      final parsed = parseTombstonesV2(
        jsonEncode({
          'version': 2,
          'tombstones': [
            {'entity': 'note', 'uuid': 'bad'},
            {'entity': 'note', 'uuid': '', 'deleted_at': '2026-10-20T09:00:00Z'},
          ],
        }),
      );
      expect(parsed.tombstones, isEmpty);
      expect(parsed.preservedRows, isEmpty);
    });
  });

  group('v2 manifest', () {
    test('远端协议版本更高 → 中止同步', () {
      final manifest = V2Manifest.tryParse(
        jsonEncode({'protocol_version': 3, 'min_reader_version': 3}),
      )!;
      expect(manifest.ensureSupported, throwsFormatException);
    });

    test('写回保留旧 writers 与未知字段，只更新本机 last_seen', () {
      final previous = V2Manifest.tryParse(
        jsonEncode({
          'format': 'shengwuji.manifest',
          'protocol_version': 2,
          'min_reader_version': 2,
          'unknown': 'keep',
          'writers': {
            'dev-b': {'protocol': 2, 'last_seen': '2026-10-20T09:00:00Z'},
          },
        }),
      );
      final next = encodeManifestV2(
        previous: previous,
        deviceId: 'dev-a',
        nowMs: DateTime.utc(2026, 10, 21).millisecondsSinceEpoch,
        counts: const {'notes': 3},
      );
      expect(next['unknown'], 'keep');
      expect((next['writers'] as Map)['dev-b'], {
        'protocol': 2,
        'last_seen': '2026-10-20T09:00:00Z',
      });
      expect(((next['writers'] as Map)['dev-a'] as Map)['protocol'], 2);
      expect(next['counts'], {'notes': 3});
    });

    test('sameV2Content 忽略生成时间与本机 last_seen，内容变了才写', () {
      final previous = {
        'format': 'shengwuji.notes',
        'version': 2,
        'generated_at': '2026-10-20T09:00:00.000Z',
        'device_id': 'dev-a',
        'writers': {
          'dev-a': {'protocol': 2, 'last_seen': '2026-10-20T09:00:00.000Z'},
        },
        'notes': [
          {'uuid': 'n1', 'content': '正文'},
        ],
      };
      Map<String, dynamic> next(String content) => {
        'format': 'shengwuji.notes',
        'version': 2,
        'generated_at': '2026-10-21T09:00:00.000Z',
        'device_id': 'dev-a',
        'writers': {
          'dev-a': {'protocol': 2, 'last_seen': '2026-10-21T09:00:00.000Z'},
        },
        'notes': [
          {'uuid': 'n1', 'content': content},
        ],
      };

      expect(
        sameV2Content(
          previous,
          next('正文'),
          ignoreKeys: const {'generated_at', 'device_id'},
          deviceId: 'dev-a',
        ),
        isTrue,
      );
      expect(
        sameV2Content(
          previous,
          next('改过'),
          ignoreKeys: const {'generated_at', 'device_id'},
          deviceId: 'dev-a',
        ),
        isFalse,
      );
      expect(
        sameV2Content(
          null,
          next('正文'),
          ignoreKeys: const {'generated_at'},
          deviceId: 'dev-a',
        ),
        isFalse,
      );
    });
  });

  group('mergeV2Notes 三方合并', () {
    test('远端改、本地没改（基线=本地）→ 采用远端', () {
      final local = note('n1', content: '旧文', updatedAt: 1000);
      final remote = note('n1', content: '电脑改过', updatedAt: 2000);
      final out = mergeV2Notes(
        V2MergeInput(
          localNotes: [local],
          localTombstones: const {},
          remoteNotes: [remote],
          remoteTombstones: const {},
          bases: {'n1': local.payloadHash},
          nowMs: 3000,
        ),
      );
      expect(out.appliedRemote, 1);
      expect(out.conflictCopies, 0);
      expect(out.notes['n1']!.content, '电脑改过');
    });

    test('本地改、远端没改（基线=远端）→ 保留本地', () {
      final base = note('n1', content: '原文', updatedAt: 1000);
      final local = note('n1', content: '手机改过', updatedAt: 3000);
      final remote = base;
      final out = mergeV2Notes(
        V2MergeInput(
          localNotes: [local],
          localTombstones: const {},
          remoteNotes: [remote],
          remoteTombstones: const {},
          bases: {'n1': base.payloadHash},
          nowMs: 4000,
        ),
      );
      expect(out.appliedRemote, 0);
      expect(out.keptLocal, 1);
      expect(out.conflictCopies, 0);
      expect(out.notes['n1']!.content, '手机改过');
    });

    test('双方都改且远端更晚（≤5 分钟）→ 远端赢 + 本地留冲突副本', () {
      final base = note('n1', content: '原文', updatedAt: 1000);
      final local = note('n1', content: '手机改过', updatedAt: 2000);
      final remote = note(
        'n1',
        content: '电脑改过',
        updatedAt: 2000 + const Duration(minutes: 1).inMilliseconds,
      );
      final out = mergeV2Notes(
        V2MergeInput(
          localNotes: [local],
          localTombstones: const {},
          remoteNotes: [remote],
          remoteTombstones: const {},
          bases: {'n1': base.payloadHash},
          nowMs: 9000,
        ),
      );
      expect(out.notes['n1']!.content, '电脑改过');
      expect(out.conflictCopies, 1);
      final copy = out.notes.values.singleWhere(
        (item) => item.uuid != 'n1',
      );
      expect(copy.content, '手机改过');
      expect(copy.extras['conflict_of'], 'n1');
      expect(copy.archived, isFalse);
      expect(copy.updatedAtMs, 9000);
      expect(copy.rev, 1);
    });

    test('双方都改且本地更晚 → 本地赢，不产生冲突副本', () {
      final base = note('n1', content: '原文', updatedAt: 1000);
      final local = note('n1', content: '手机改过', updatedAt: 5000);
      final remote = note('n1', content: '电脑改过', updatedAt: 2000);
      final out = mergeV2Notes(
        V2MergeInput(
          localNotes: [local],
          localTombstones: const {},
          remoteNotes: [remote],
          remoteTombstones: const {},
          bases: {'n1': base.payloadHash},
          nowMs: 9000,
        ),
      );
      expect(out.notes['n1']!.content, '手机改过');
      expect(out.conflictCopies, 0);
      expect(out.keptLocal, 1);
    });

    test('双方都改但时间差 > 5 分钟 → 远端赢且不建冲突副本', () {
      final base = note('n1', content: '原文', updatedAt: 1000);
      final local = note('n1', content: '手机改过', updatedAt: 2000);
      final remote = note(
        'n1',
        content: '电脑改过',
        updatedAt: 2000 + const Duration(minutes: 6).inMilliseconds,
      );
      final out = mergeV2Notes(
        V2MergeInput(
          localNotes: [local],
          localTombstones: const {},
          remoteNotes: [remote],
          remoteTombstones: const {},
          bases: {'n1': base.payloadHash},
          nowMs: 9000,
        ),
      );
      expect(out.notes['n1']!.content, '电脑改过');
      expect(out.conflictCopies, 0);
    });

    test('没有基线（首次同步）只按 LWW，不误判冲突', () {
      final local = note('n1', content: '手机旧', updatedAt: 2000);
      final remote = note('n1', content: '电脑新', updatedAt: 2500);
      final out = mergeV2Notes(
        V2MergeInput(
          localNotes: [local],
          localTombstones: const {},
          remoteNotes: [remote],
          remoteTombstones: const {},
          bases: const {},
          nowMs: 9000,
        ),
      );
      expect(out.notes['n1']!.content, '电脑新');
      expect(out.conflictCopies, 0);
    });

    test('远端墓碑删除本地未再编辑的笔记', () {
      final local = note('n1', content: '要删', updatedAt: 2000);
      final out = mergeV2Notes(
        V2MergeInput(
          localNotes: [local],
          localTombstones: const {},
          remoteNotes: const [],
          remoteTombstones: {
            'n1': const V2Tombstone(uuid: 'n1', deletedAtMs: 3000),
          },
          bases: {'n1': local.payloadHash},
          nowMs: 4000,
        ),
      );
      expect(out.notes.containsKey('n1'), isFalse);
      expect(out.tombstones['n1']!.deletedAtMs, 3000);
      expect(out.remoteDeletions, 1);
    });

    test('墓碑之后的编辑复活笔记并清掉墓碑', () {
      final local = note('n1', content: '删除后又改', updatedAt: 5000);
      final out = mergeV2Notes(
        V2MergeInput(
          localNotes: [local],
          localTombstones: const {},
          remoteNotes: const [],
          remoteTombstones: {
            'n1': const V2Tombstone(uuid: 'n1', deletedAtMs: 3000),
          },
          bases: const {},
          nowMs: 6000,
        ),
      );
      expect(out.notes['n1']!.content, '删除后又改');
      expect(out.tombstones.containsKey('n1'), isFalse);
      expect(out.resurrected, 1);
    });

    test('远端笔记晚于远端墓碑 → 采用笔记并清墓碑', () {
      final remote = note('n1', content: '新建后同名', updatedAt: 5000);
      final out = mergeV2Notes(
        V2MergeInput(
          localNotes: const [],
          localTombstones: {
            'n1': const V2Tombstone(uuid: 'n1', deletedAtMs: 3000),
          },
          remoteNotes: [remote],
          remoteTombstones: const {},
          bases: const {},
          nowMs: 6000,
        ),
      );
      expect(out.notes['n1']!.content, '新建后同名');
      expect(out.tombstones, isEmpty);
      expect(out.resurrected, greaterThan(0));
    });

    test('远端笔记早于本地墓碑 → 不复活', () {
      final remote = note('n1', content: '旧内容', updatedAt: 2000);
      final out = mergeV2Notes(
        V2MergeInput(
          localNotes: const [],
          localTombstones: {
            'n1': const V2Tombstone(uuid: 'n1', deletedAtMs: 3000),
          },
          remoteNotes: [remote],
          remoteTombstones: const {},
          bases: const {},
          nowMs: 6000,
        ),
      );
      expect(out.notes, isEmpty);
      expect(out.tombstones['n1']!.deletedAtMs, 3000);
    });
  });

  group('本地行 ↔ v2 笔记', () {
    test('noteFromDiaryRow 重建本机录音附件并透传电脑端图片/标签/未知字段', () {
      final row = {
        'sync_uuid': 'n1',
        'content': '带录音的笔记',
        'created_at': '2026-10-20T09:00:00.000',
        'audio_path': '/data/record/new.m4a',
        'duration': 3,
        'is_archived': 0,
        'is_locked': 1,
        'tag': 'star',
        'sort_order': -2,
        'updated_at': 1234,
      };
      final meta = {
        'rev': 5,
        'tags_json': jsonEncode(['tag-a']),
        'extras_json': jsonEncode({'pc_only': 1, 'tags': ['stale']}),
        'attachments_json': jsonEncode([
          {
            'uuid': 'old-audio',
            'kind': 'audio',
            'origin': 'download',
            'name': 'old.m4a',
          },
          {
            'uuid': 'image-1',
            'kind': 'image',
            'origin': 'mobile',
            'sha256': 'abc',
            'name': 'shot.jpg',
          },
        ]),
      };

      final back = noteFromDiaryRow(row, meta: meta);
      expect(back.content, '带录音的笔记');
      expect(back.updatedAtMs, 1234);
      expect(back.mark, 'star');
      expect(back.locked, isTrue);
      expect(back.sortOrder, -2);
      expect(back.rev, 5);
      expect(back.tags, ['tag-a']);
      expect(back.extras, {'pc_only': 1});
      // 旧录音（不同文件名）被丢掉，新录音沿用与电脑端一致的稳定 uuid
      final audios = back.attachments.where((a) => a.isAudio).toList();
      expect(audios.single.name, 'new.m4a');
      expect(audios.single.uuid, audioAttachmentUuid('n1', 'new.m4a'));
      expect(audios.single.durationMs, 3000);
      expect(audios.single.mimeType, 'audio/mp4');
      // 电脑端图片附件原样保留
      final image = back.attachments.singleWhere((a) => a.isImage);
      expect(image.uuid, 'image-1');
      expect(image.sha256, 'abc');
    });

    test('手机新建（无 meta）没有透传字段', () {
      final back = noteFromDiaryRow({
        'sync_uuid': 'n2',
        'content': '新笔记',
        'created_at': '2026-10-21T08:00:00.000',
        'is_archived': 0,
        'is_locked': 0,
        'updated_at': 333,
      });
      expect(back.tags, isEmpty);
      expect(back.attachments, isEmpty);
      expect(back.extras, isEmpty);
      expect(back.rev, 1);
      expect(back.updatedAtMs, 333);
    });

    test('meta 为空（首次接 v2）用远端同 uuid 记录做 seed，本机录音仍优先', () {
      final seed = V2Note(
        uuid: 'n2',
        content: '旧正文',
        createdAtMs: 1000,
        updatedAtMs: 1000,
        rev: 6,
        tags: ['tag-a'],
        attachments: const [
          V2Attachment(
            uuid: 'remote-audio',
            kind: 'audio',
            origin: 'download',
            name: 'old.m4a',
          ),
          V2Attachment(
            uuid: 'remote-image',
            kind: 'image',
            origin: 'mobile',
            sha256: 'abc',
            name: 'shot.jpg',
          ),
        ],
        extras: const {'pc_only': 1},
      );
      final back = noteFromDiaryRow(
        {
          'sync_uuid': 'n2',
          'content': '手机正文',
          'created_at': '2026-10-20T09:00:00.000',
          'audio_path': '/data/record/new.m4a',
          'duration': 2,
          'is_archived': 0,
          'is_locked': 0,
          'updated_at': 2000,
        },
        seed: seed,
      );
      expect(back.tags, ['tag-a']);
      expect(back.extras, {'pc_only': 1});
      expect(back.rev, 6);
      // 本机录音替换远端旧音频；电脑端图片保留
      final audios = back.attachments.where((a) => a.isAudio).toList();
      expect(audios.single.name, 'new.m4a');
      expect(audios.single.uuid, audioAttachmentUuid('n2', 'new.m4a'));
      expect(
        back.attachments.singleWhere((a) => a.isImage).uuid,
        'remote-image',
      );
    });


    test('diaryRowFromV2Note：本地时间无 Z、时长转秒、归档行无排序', () {
      final v2 = note(
        'n3',
        content: '远端笔记',
        createdAt: DateTime.utc(2026, 10, 20, 9).millisecondsSinceEpoch,
        updatedAt: 2222,
        archived: true,
        sortOrder: -9,
        attachments: const [
          V2Attachment(
            uuid: 'a1',
            kind: 'audio',
            origin: 'record',
            name: 'rec.m4a',
            durationMs: 2500,
          ),
        ],
      );
      final row = diaryRowFromV2Note(v2);
      expect(row['sync_uuid'], 'n3');
      expect(row['created_at'], isNot(contains('Z')));
      expect(row['duration'], 3);
      expect(row['is_archived'], 1);
      expect(row['sort_order'], isNull);
      expect(row['updated_at'], 2222);

      final meta = metaRowFromV2Note(v2);
      expect(meta['base_hash'], v2.payloadHash);
      expect(meta['rev'], 1);
      expect(jsonDecode(meta['tags_json'] as String), isEmpty);
    });
  });

  group('sameJsonContent 通用比较', () {
    test('对象键序与嵌套差异不算变更', () {
      expect(
        sameJsonContent({
          'a': 1,
          'b': {
            'x': 1,
            'y': 2,
          },
        }, {
          'b': {
            'y': 2,
            'x': 1,
          },
          'a': 1,
        }),
        isTrue,
      );
    });

    test('数组顺序参与比较', () {
      expect(sameJsonContent([1, 2], [2, 1]), isFalse);
    });

    test('任一侧为 null 按不一致处理', () {
      expect(sameJsonContent(null, <String, dynamic>{}), isFalse);
      expect(sameJsonContent(<String, dynamic>{}, null), isFalse);
    });

    test('数值与字符串类型差异算变更', () {
      expect(sameJsonContent({'sort_order': 1}, {'sort_order': '1'}), isFalse);
    });
  });
}
