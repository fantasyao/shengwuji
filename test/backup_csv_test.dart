// 全量备份 CSV 编解码单测：导出→原封导入往返零重复、归档位不丢、
// 老格式备份（2026-09 之前：秒级时间串、无归档列）兼容。
// 修复背景见 lib/utils/backup_csv.dart 文件头注释。
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/utils/backup_csv.dart';

void main() {
  group('generateDiaryCsv → parseDiaryCsv 往返', () {
    test('内容、创建时间原串、标注、归档位逐字还原', () {
      final rows = <Map<String, dynamic>>[
        {
          'id': 1,
          'content': 'A 活跃笔记',
          'created_at': '2026-09-20T10:00:00.123456',
          'audio_path': '/data/diary_audio/a.m4a',
          'duration': 8,
          'tag': null,
          'is_archived': 0,
        },
        {
          'id': 2,
          'content': 'B 归档笔记',
          'created_at': '2026-09-20T11:00:00.654321',
          'audio_path': '/data/diary_audio/b.m4a',
          'duration': 9,
          'tag': 'star',
          'is_archived': 1,
        },
      ];

      final parsed = parseDiaryCsv(generateDiaryCsv(rows));

      expect(parsed.length, 2);
      expect(parsed[0]['created_at'], '2026-09-20T10:00:00.123456');
      expect(parsed[0]['is_archived'], 0);
      expect(parsed[0]['tag'], isNull);
      expect(parsed[0]['audio_path'], 'a.m4a');
      expect(parsed[1]['created_at'], '2026-09-20T11:00:00.654321');
      expect(parsed[1]['is_archived'], 1);
      expect(parsed[1]['tag'], 'star');
    });

    test('用户复现场景：A 活跃 + B/C 归档，原封再导入全部命中去重', () {
      final dbRows = <Map<String, dynamic>>[
        {
          'id': 1,
          'content': 'A',
          'created_at': '2026-09-20T10:00:00.123456',
          'audio_path': '/x/a.m4a',
          'duration': 8,
          'tag': null,
          'is_archived': 0,
        },
        {
          'id': 2,
          'content': 'B',
          'created_at': '2026-09-20T11:00:00.654321',
          'audio_path': '/x/b.m4a',
          'duration': 9,
          'tag': null,
          'is_archived': 1,
        },
        {
          'id': 3,
          'content': 'C',
          'created_at': '2026-09-20T12:00:00.111111',
          'audio_path': null,
          'duration': 3,
          'tag': 'idea',
          'is_archived': 1,
        },
      ];

      final dbKeys = dbRows
          .map(
            (r) => diaryDedupeKey(
              r['content'] as String,
              r['created_at'] as String,
            ),
          )
          .toSet();
      final reparsed = parseDiaryCsv(generateDiaryCsv(dbRows));
      final hitCount = reparsed
          .where(
            (d) => dbKeys.contains(
              diaryDedupeKey(
                d['content'] as String,
                d['created_at'] as String,
              ),
            ),
          )
          .length;

      // 修复前：created_at 被格式化改写 → 3 条全部判新，活跃区凭空多出重复行
      expect(hitCount, 3, reason: '原封导入必须整包命中去重');
      expect(reparsed.map((d) => d['is_archived']), [0, 1, 1]);
    });

    test('内容含逗号/引号/换行经转义后完整还原（不被换行腰斩）', () {
      final rows = <Map<String, dynamic>>[
        {
          'id': 1,
          'content': '第一行\n第二行, 带逗号 "带引号"',
          'created_at': '2026-09-20T10:00:00.123456',
          'audio_path': null,
          'duration': null,
          'tag': null,
          'is_archived': 0,
        },
      ];

      final parsed = parseDiaryCsv(generateDiaryCsv(rows));

      expect(parsed.length, 1);
      expect(parsed.single['content'], '第一行\n第二行, 带逗号 "带引号"');
    });
  });

  group('老格式备份兼容（2026-09 之前导出）', () {
    test('秒级时间串归一化为 ISO、缺归档列按活跃处理、标注列照常解析', () {
      final csv = [
        'ID,内容,创建时间,音频文件,时长(秒),标注',
        '3,"老备份行",2026-08-01 10:20:30,old.m4a,5,urgent',
      ].join('\n');

      final parsed = parseDiaryCsv(csv);

      expect(parsed.single['created_at'], '2026-08-01T10:20:30.000');
      expect(parsed.single['is_archived'], 0);
      expect(parsed.single['tag'], 'urgent');
    });

    test('老备份时间与库内亚秒原行在去重键下同键（不再整包判新）', () {
      final dbKey = diaryDedupeKey('同文', '2026-08-01T10:20:30.123456');
      final oldBackupKey = diaryDedupeKey(
        '同文',
        normalizeCreatedAt('2026-08-01 10:20:30'),
      );

      expect(oldBackupKey, dbKey);
    });
  });

  group('diaryDedupeKey', () {
    test('不同创建时间异键、同内容同秒同键', () {
      expect(
        diaryDedupeKey('x', '2026-09-20T10:00:00.123456'),
        isNot(diaryDedupeKey('x', '2026-09-20T10:00:01.123456')),
      );
      expect(
        diaryDedupeKey('x', '2026-09-20T10:00:00.123456'),
        diaryDedupeKey('x', '2026-09-20T10:00:00.999999'),
      );
    });

    test('解析失败的时间串原样入键不抛异常', () {
      expect(diaryDedupeKey('x', '垃圾串'), 'x|垃圾串');
    });

    test('normalizeCreatedAt 解析失败原样返回', () {
      expect(normalizeCreatedAt('垃圾串'), '垃圾串');
    });
  });

  group('items CSV', () {
    test('生成与解析往返，含逗号/换行的字段', () {
      final rows = <Map<String, dynamic>>[
        {'name': '钥匙', 'location': '玄关, 第二个抽屉'},
        {'name': '发票\n（报销用）', 'location': '"办公室"'},
      ];

      final parsed = parseItemsCsv(generateItemsCsv(rows));

      expect(parsed.length, 2);
      expect(parsed[0]['name'], '钥匙');
      expect(parsed[0]['location'], '玄关, 第二个抽屉');
      expect(parsed[1]['name'], '发票\n（报销用）');
      expect(parsed[1]['location'], '"办公室"');
    });
  });
}
