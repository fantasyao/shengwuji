// v1 数据文件 write-if-changed 判断（CloudSyncService.v1FileUnchanged）：
// 老版本 App 只认 v1，四个数据文件仍必须回传，这里只省掉「内容完全一致
// 的重复 PUT」。规则与边界见 docs/architecture/cloud-sync.md「合并策略」。
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/sync/cloud_sync_service.dart';

void main() {
  group('v1FileUnchanged', () {
    test('云端没有该文件（首次同步）按有变更处理', () {
      expect(
        CloudSyncService.v1FileUnchanged(previousRaw: null, next: '[]'),
        isFalse,
      );
    });

    test('逐字符相同直接判定未变（热词纯文本走这条）', () {
      const text = '影视 = 隐私\n代办 = 待办\n';
      expect(
        CloudSyncService.v1FileUnchanged(previousRaw: text, next: text),
        isTrue,
      );
    });

    test('文本尾随换行差异算变更（照旧回传，不做宽容归一）', () {
      expect(
        CloudSyncService.v1FileUnchanged(previousRaw: '影视 = 隐私', next: '影视 = 隐私\n'),
        isFalse,
      );
    });

    test('JSON 键序与缩进差异不算变更', () {
      const previous = '''
[
  { "created_at": "2026-10-24 10:00:00.000", "uuid": "u1", "content": "买盐" }
]''';
      const next = '[{"content":"买盐","uuid":"u1","created_at":"2026-10-24 10:00:00.000"}]';
      expect(
        CloudSyncService.v1FileUnchanged(previousRaw: previous, next: next),
        isTrue,
      );
    });

    test('JSON 数组行序不同算变更（宁可多 PUT 也不漏写）', () {
      const previous = '[{"uuid":"u1"},{"uuid":"u2"}]';
      const next = '[{"uuid":"u2"},{"uuid":"u1"}]';
      expect(
        CloudSyncService.v1FileUnchanged(previousRaw: previous, next: next),
        isFalse,
      );
    });

    test('本机多出条目算变更', () {
      expect(
        CloudSyncService.v1FileUnchanged(
          previousRaw: '[{"uuid":"u1","content":"买盐"}]',
          next: '[{"uuid":"u1","content":"买盐"},{"uuid":"u2","content":"买醋"}]',
        ),
        isFalse,
      );
    });

    test('字段值不同算变更（录音回填 audio_path 后必须回传）', () {
      expect(
        CloudSyncService.v1FileUnchanged(
          previousRaw: '[{"uuid":"u1","audio":null}]',
          next: '[{"uuid":"u1","audio":"a_1.wav"}]',
        ),
        isFalse,
      );
    });

    test('云端 JSON 损坏按有变更整包覆盖（本机是合并后的超集）', () {
      expect(
        CloudSyncService.v1FileUnchanged(previousRaw: '{坏掉的云端文件', next: '[]'),
        isFalse,
      );
    });

    test('空数组等价', () {
      expect(
        CloudSyncService.v1FileUnchanged(previousRaw: '[]', next: '[]'),
        isTrue,
      );
    });
  });
}
