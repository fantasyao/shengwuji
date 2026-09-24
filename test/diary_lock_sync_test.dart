// 笔记锁定相关纯函数测试：云同步载荷的 locked 字段往返 + 局域网服务
// JSON 脱敏。不涉及磁盘库与 HTTP server（那两块分别由 db_upgrade_v15_test
// 与 diary_web_server_test 覆盖）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/sync/sync_models.dart';
import 'package:shengwuji_app/utils/note_unlock_session.dart'
    show kLockedMaskText;
import 'package:shengwuji_app/web_server/diary_web_server.dart';

void main() {
  test('DiarySyncEntry 锁定字段：fromRow/toRow/toJson/fromJson 全链路往返', () {
    final row = {
      'sync_uuid': 'u1',
      'content': '锁定笔记',
      'created_at': '2026-09-22T10:00:00.000',
      'duration': 5,
      'is_archived': 0,
      'is_locked': 1,
      'tag': null,
    };
    final entry = DiarySyncEntry.fromRow(row);
    expect(entry.isLocked, isTrue);
    expect(entry.toRow()['is_locked'], 1);
    expect(entry.toJson()['locked'], 1);

    final restored = DiarySyncEntry.fromJson(
      (entry.toJson()).cast<String, dynamic>(),
    );
    expect(restored.isLocked, isTrue);
    expect(restored.content, '锁定笔记');
  });

  test('DiarySyncEntry 未锁定行 omit-if-default：JSON 不出现 locked key（旧版本兼容）', () {
    final entry = DiarySyncEntry(
      uuid: 'u2',
      content: '普通笔记',
      createdAt: '2026-09-22T10:00:00.000',
    );
    expect(entry.toJson().containsKey('locked'), isFalse);
    expect(entry.isLocked, isFalse);
    expect(entry.toRow()['is_locked'], 0);
  });

  test('旧版本写入的 JSON（无 locked key）读入默认未锁定，不崩', () {
    final entry = DiarySyncEntry.fromJson({
      'uuid': 'u3',
      'content': '旧客户端笔记',
      'created_at': '2026-09-22T10:00:00.000',
    });
    expect(entry.isLocked, isFalse);
  });

  test('encode/decode 批量编解码保留 locked', () {
    final json = encodeDiaryEntries([
      {
        'sync_uuid': 'u4',
        'content': 'a',
        'created_at': '2026-09-22T10:00:00.000',
        'is_archived': 0,
        'is_locked': 1,
        'tag': null,
      },
    ]);
    final list = decodeDiaryEntries(json);
    expect(list.single.isLocked, isTrue);
  });

  test('局域网服务 JSON：锁定行 content 脱敏 + 音频 URL 不给；未锁定行不变', () {
    final locked = diaryNoteToJson({
      'id': 1,
      'content': '绝不外泄的隐私',
      'created_at': '2026-09-22T10:00:00.000',
      'duration': 5,
      'is_archived': 0,
      'is_locked': 1,
      'tag': null,
      'audio_path': '/x/diary_audio/a.wav',
    });
    expect(locked['content'], kLockedMaskText);
    expect(locked['isLocked'], isTrue);
    expect(locked['audioUrl'], isNull); // 录音内容=笔记内容，一并锁

    final unlocked = diaryNoteToJson({
      'id': 2,
      'content': '普通笔记',
      'created_at': '2026-09-22T10:00:00.000',
      'duration': 5,
      'is_archived': 0,
      'is_locked': 0,
      'tag': 'star',
      'audio_path': '/x/diary_audio/b.wav',
    });
    expect(unlocked['content'], '普通笔记');
    expect(unlocked['isLocked'], isFalse);
    expect(unlocked['audioUrl'], '/audio/2');
  });
}
