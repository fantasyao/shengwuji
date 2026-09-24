// 云同步纯逻辑单测：热词行级合并 / 日记·物品插入计划（uuid+自然键+墓碑）
// / 四类数据编解码 round-trip / manifest 与软锁超时。
// 合并策略详见 docs/architecture/cloud-sync.md。
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/sync/sync_merge.dart';
import 'package:shengwuji_app/sync/sync_models.dart';

void main() {
  group('mergeHotwordContent 热词行级合并', () {
    test('远端新行追加到本地末尾，原有内容原样保留', () {
      final local = '智谱 = 质谱\n# 注释\n';
      final remote = '智谱 = 质谱\n豆包 = 都保\n';
      final merged = mergeHotwordContent(local, remote);
      expect(merged, '智谱 = 质谱\n# 注释\n豆包 = 都保\n');
    });

    test('同错词不同正词：保留本地（用户显式配置本地意图优先）', () {
      final local = ' wrong = 本地正词 \n';
      final remote = 'wrong = 远端正词\n';
      final merged = mergeHotwordContent(local, remote);
      expect(merged.contains('远端正词'), isFalse);
      expect(merged.contains('本地正词'), isTrue);
    });

    test('音素行（ | 格式）整行精确去重', () {
      final local = '目标 | 别名1 | 别名2\n';
      final remote = '目标|别名1|别名2\n目标 | 别名3\n';
      final merged = mergeHotwordContent(local, remote);
      // trim 后「目标 | 别名1 | 别名2」与「目标|别名1|别名2」不同行，后者补入；
      // 第二条是新别名行也补入
      expect(merged, '目标 | 别名1 | 别名2\n目标|别名1|别名2\n目标 | 别名3\n');
    });

    test('注释行/空行不参与合并（远端注释不进本地）', () {
      final local = 'a = b\n';
      final remote = '# 头注释\n\na = b\nc = d\n';
      final merged = mergeHotwordContent(local, remote);
      expect(merged, 'a = b\nc = d\n');
    });

    test('本地为空：合并结果就是远端有效行', () {
      final merged = mergeHotwordContent('', 'x = y\n');
      expect(merged, 'x = y\n');
    });

    test('无新增：原文原样返回（不加重排尾换行）', () {
      final local = 'a = b';
      expect(mergeHotwordContent(local, 'a = b\n'), 'a = b');
      expect(mergeHotwordContent(local, ''), 'a = b');
    });

    test('同批远端内重复错词只补第一条', () {
      final merged = mergeHotwordContent('', 'w = 1\nw = 2\n');
      expect(merged, 'w = 1\n');
    });
  });

  Map<String, dynamic> diaryRow(String uuid, String content, String createdAt) =>
      {'sync_uuid': uuid, 'content': content, 'created_at': createdAt};

  group('planDiaryInserts 日记插入计划', () {
    final remote = [
      const DiarySyncEntry(
          uuid: 'u1', content: '买菜', createdAt: '2026-09-21T10:00:00.000'),
      const DiarySyncEntry(
          uuid: 'u2', content: '散步', createdAt: '2026-09-21T11:00:00.000'),
      const DiarySyncEntry(
          uuid: 'u3', content: '读书', createdAt: '2026-09-21T12:00:00.000'),
    ];

    test('uuid 与自然键都不在本地 → 插入', () {
      final plan = planDiaryInserts(
        localRows: [diaryRow('local1', '跑步', '2026-09-20T09:00:00.000')],
        remoteEntries: remote,
        tombstones: {},
      );
      expect(plan.map((e) => e.uuid), ['u1', 'u2', 'u3']);
    });

    test('uuid 已在本地 → 跳过（同一身份不重复）', () {
      final plan = planDiaryInserts(
        localRows: [diaryRow('u1', '买菜', '2026-09-21T10:00:00.000')],
        remoteEntries: remote,
        tombstones: {},
      );
      expect(plan.map((e) => e.uuid), ['u2', 'u3']);
    });

    test('内容相同但 uuid 不同（备份导入复原）→ 自然键挡住不重复', () {
      final plan = planDiaryInserts(
        localRows: [diaryRow('other-uuid', '买菜', '2026-09-21T10:00:00.000')],
        remoteEntries: remote,
        tombstones: {},
      );
      expect(plan.map((e) => e.uuid), ['u2', 'u3']);
    });

    test('墓碑 uuid → 跳过（本地删过防复活）', () {
      final plan = planDiaryInserts(
        localRows: const [],
        remoteEntries: remote,
        tombstones: {'u1', 'u3'},
      );
      expect(plan.map((e) => e.uuid), ['u2']);
    });

    test('uuid 为空的坏条目 → 跳过', () {
      final plan = planDiaryInserts(
        localRows: const [],
        remoteEntries: const [
          DiarySyncEntry(uuid: '', content: 'x', createdAt: 't'),
        ],
        tombstones: {},
      );
      expect(plan, isEmpty);
    });
  });

  group('planItemInserts 物品插入计划', () {
    test('自然键 name|location 去重 + 墓碑防复活', () {
      final remote = const [
        ItemSyncEntry(uuid: 'i1', name: '牙刷', location: '卫生间'),
        ItemSyncEntry(uuid: 'i2', name: '伞', location: '门口'),
      ];
      final plan = planItemInserts(
        localRows: [
          {'sync_uuid': 'other', 'name': '牙刷', 'location': '卫生间'},
        ],
        remoteEntries: remote,
        tombstones: {'i2'},
      );
      expect(plan, isEmpty);
    });

    test('全新条目 → 插入', () {
      final plan = planItemInserts(
        localRows: [
          {'sync_uuid': 'i1', 'name': '牙刷', 'location': '卫生间'},
        ],
        remoteEntries: const [
          ItemSyncEntry(uuid: 'i2', name: '伞', location: '门口'),
        ],
        tombstones: {},
      );
      expect(plan.map((e) => e.uuid), ['i2']);
    });
  });

  group('编解码 round-trip', () {
    test('日记：DB 行 → JSON → 解码保真；audio 存 basename、落库 audio_path 为空', () {
      final rows = [
        {
          'sync_uuid': 'u1',
          'content': '内容',
          'created_at': '2026-09-21T10:00:00.000',
          'audio_path': '/data/diary_audio/a1.m4a',
          'duration': 12,
          'is_archived': 1,
          'tag': 'star',
        },
        {
          'sync_uuid': 'u2',
          'content': '无音频',
          'created_at': '2026-09-21T11:00:00.000',
          'audio_path': null,
          'duration': null,
          'is_archived': 0,
          'tag': null,
        },
      ];
      final decoded = decodeDiaryEntries(encodeDiaryEntries(rows));
      expect(decoded.length, 2);
      expect(decoded[0].uuid, 'u1');
      expect(decoded[0].audioName, 'a1.m4a');
      expect(decoded[0].isArchived, isTrue);
      expect(decoded[0].tag, 'star');
      expect(decoded[0].duration, 12);
      final row = decoded[0].toRow();
      expect(row['audio_path'], isNull); // P1 不同步音频，落库置空
      expect(row['is_archived'], 1);
      expect(decoded[1].audioName, isNull);
      expect(decoded[1].isArchived, isFalse);
    });

    test('物品与修正对 round-trip', () {
      final items = [
        {'sync_uuid': 'i1', 'name': '牙刷', 'location': '卫生间'},
      ];
      final decodedItems = decodeItemEntries(encodeItemEntries(items));
      expect(decodedItems.single.toJson(),
          {'uuid': 'i1', 'name': '牙刷', 'location': '卫生间'});

      final pairs = [
        {
          'error_text': '饰品',
          'corrected_text': '视频',
          'hit_count': 7,
          'created_at': '2026-09-20T08:00:00.000',
          'last_used_at': '2026-09-21T09:00:00.000',
        },
      ];
      final decodedPairs = decodePairEntries(encodePairRows(pairs));
      expect(decodedPairs.single.error, '饰品');
      expect(decodedPairs.single.hitCount, 7);
      expect(decodedPairs.single.lastUsedAt, '2026-09-21T09:00:00.000');
      expect(decodedPairs.single.toDbRow()['error_text'], '饰品');
    });

    test('坏 JSON / 非 List / 缺 uuid 的条目宽容跳过不抛', () {
      expect(decodeDiaryEntries('not json'), isEmpty);
      expect(decodeDiaryEntries('{"a":1}'), isEmpty);
      expect(decodeDiaryEntries('[{"content":"no uuid"}]'), isEmpty);
      expect(decodePairEntries('[]'), isEmpty);
    });
  });

  group('manifest 与软锁', () {
    test('round-trip + counts 解析', () {
      const m = SyncManifest(
        deviceId: 'dev-1',
        updatedAt: '2026-09-21T12:00:00.000',
        lock: SyncLock(deviceId: 'dev-1', at: '2026-09-21T12:00:00.000'),
        counts: {'diary': 3, 'items': 1},
      );
      final parsed = SyncManifest.tryParse(
        '{"v":1,"device_id":"dev-1","updated_at":"2026-09-21T12:00:00.000",'
        '"lock":{"device_id":"dev-1","at":"2026-09-21T12:00:00.000"},'
        '"counts":{"diary":3,"items":1}}',
      );
      expect(parsed!.deviceId, m.deviceId);
      expect(parsed.lock!.deviceId, 'dev-1');
      expect(parsed.counts, {'diary': 3, 'items': 1});
    });

    test('坏 manifest 返回 null（首次同步/被其他工具写过不崩）', () {
      expect(SyncManifest.tryParse('garbage'), isNull);
      expect(SyncManifest.tryParse('[]'), isNull);
    });

    test('锁 10 分钟超时：他机新锁挡同步，死锁超时自动放行', () {
      final now = DateTime.parse('2026-09-21T12:09:00.000');
      final fresh =
          SyncLock(deviceId: 'other', at: '2026-09-21T12:00:00.000');
      expect(fresh.isStale(now), isFalse); // 9 分钟内视为持锁中
      final stale =
          SyncLock(deviceId: 'other', at: '2026-09-21T11:58:00.000');
      expect(stale.isStale(now), isTrue); // 11 分钟前 → 死锁放行
      expect(
        SyncLock(deviceId: 'other', at: 'bad-date').isStale(now),
        isTrue,
      );
    });
  });

  group('countHotwordRules 条数口径', () {
    test('非空非注释行数（与设置页入口行摘要一致）', () {
      expect(countHotwordRules('a = b\n# c\n\nd\n'), 2);
      expect(countHotwordRules(''), 0);
    });
  });

  group('planAudioUploads 录音上传计划', () {
    test('不在索引里的本地文件全排入；已上传的跳过', () {
      final (batch, overflow) = planAudioUploads(
        localAudioNames: ['a.wav', 'b.wav', 'c.wav'],
        uploadedIndex: {'b.wav'},
      );
      expect(batch, ['a.wav', 'c.wav']);
      expect(overflow, 0);
    });

    test('超出单批上限 → 截断并返回剩余数（坚果云限流分批）', () {
      final names = List.generate(85, (i) => 'f$i.wav');
      final (batch, overflow) =
          planAudioUploads(localAudioNames: names, uploadedIndex: {});
      expect(batch.length, kAudioSyncBatchLimit);
      expect(overflow, 5);
    });

    test('入参内重复文件名去重（同名两行只传一次）', () {
      final (batch, _) = planAudioUploads(
        localAudioNames: ['a.wav', 'a.wav'],
        uploadedIndex: {},
      );
      expect(batch, ['a.wav']);
    });

    test('含路径分隔符/上级目录的可疑名跳过（云端 JSON 不可信）', () {
      final (batch, _) = planAudioUploads(
        localAudioNames: ['../evil.wav', 'sub/x.wav', 'ok.wav'],
        uploadedIndex: {},
      );
      expect(batch, ['ok.wav']);
    });
  });

  group('planAudioDownloads 录音下载计划', () {
    List<DiarySyncEntry> entries(List<(String, String?)> pairs) => [
      for (final (uuid, audio) in pairs)
        DiarySyncEntry(uuid: uuid, content: 'c', createdAt: 't', audioName: audio),
    ];

    test('远端带 audio 名且本地缺 → 排入；本地已有/无音频/墓碑行跳过', () {
      final (batch, overflow) = planAudioDownloads(
        remoteEntries: entries([
          ('u1', 'a.wav'), // 本地缺 → 下载
          ('u2', 'b.wav'), // 本地已有 → 跳过
          ('u3', null), // 无音频 → 跳过
          ('u4', 'c.wav'), // 墓碑 → 跳过
        ]),
        localExistingNames: {'b.wav'},
        tombstones: {'u4'},
      );
      expect(batch.map((e) => e.uuid), ['u1']);
      expect(batch.single.name, 'a.wav');
      expect(overflow, 0);
    });

    test('超出上限截断，超出部分留待下次', () {
      final remote = entries(
        List.generate(83, (i) => ('u$i', 'f$i.wav')),
      );
      final (batch, overflow) = planAudioDownloads(
        remoteEntries: remote,
        localExistingNames: {},
        tombstones: {},
      );
      expect(batch.length, kAudioSyncBatchLimit);
      expect(overflow, 3);
    });

    test('同名多条日记只排一次队', () {
      final (batch, _) = planAudioDownloads(
        remoteEntries: entries([('u1', 'a.wav'), ('u2', 'a.wav')]),
        localExistingNames: {},
        tombstones: {},
      );
      expect(batch, hasLength(1));
    });
  });

  group('decodeStringList 音频上传索引编解码', () {
    test('round-trip 与坏数据宽容', () {
      expect(decodeStringList('["a.wav","b.wav"]'), ['a.wav', 'b.wav']);
      expect(decodeStringList('["a.wav",1,null,"b.wav"]'), ['a.wav', 'b.wav']);
      expect(decodeStringList('not json'), isEmpty);
      expect(decodeStringList('{"a":1}'), isEmpty);
      expect(decodeStringList('[]'), isEmpty);
    });
  });
}
