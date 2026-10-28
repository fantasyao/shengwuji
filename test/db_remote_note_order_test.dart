// 云同步远端新笔记的活跃区落位测试（用户反馈：电脑端补同步的旧笔记
// 会被一口气塞到手机列表最前面，时间正确但顺序不按时间）。
//
// 语义：本地活跃区非空时，远端新行按 created_at 插进本机当前顺序——
// 取显示顺序中「最后一条比它新的行」的 sort_order 同值落位（同值由
// getDiaries 的 created_at DESC 兜底），任何既有行的 sort_order 都不动。
//
// ⚠️ 独立库文件名 + 单个 test：DbHelper 是静态连接，多 test 会互相干扰
//（同 db_sort_order_test 头注释）。
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Map<String, dynamic> _remoteRow(
  String uuid,
  String content,
  String createdAt, {
  int? sortOrder,
  int archived = 0,
}) => {
  'sync_uuid': uuid,
  'content': content,
  'created_at': createdAt,
  'updated_at': DateTime.tryParse(createdAt)?.millisecondsSinceEpoch ?? 0,
  'duration': 0,
  'is_archived': archived,
  'is_locked': 0,
  'tag': null,
  'sort_order': sortOrder,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('远端新行按 created_at 插进本机顺序，不整批置顶', () async {
    DbHelper.dbFileName = 'items_remote_note_order_test.db';
    final dbPath = p.join(
      await databaseFactory.getDatabasesPath(),
      DbHelper.dbFileName,
    );
    await databaseFactory.deleteDatabase(dbPath);
    SharedPreferences.setMockInitialValues({});

    final dbHelper = DbHelper();
    final db = await dbHelper.db;
    // 清掉内置说明卡，时间线完全可控（说明卡 created_at = 建库时刻）
    await db.delete('diary');

    Future<void> seedLocal(
      String uuid,
      String content,
      String createdAt,
      int sortOrder,
    ) async {
      await db.insert('diary', {
        'sync_uuid': uuid,
        'content': content,
        'created_at': createdAt,
        'updated_at': DateTime.tryParse(createdAt)!.millisecondsSinceEpoch,
        'duration': 0,
        'is_archived': 0,
        'sort_order': sortOrder,
      });
    }

    Future<void> apply(List<Map<String, dynamic>> rows) =>
        dbHelper.applySyncV2Notes(
          upserts: rows,
          deletes: const [],
          metaRows: [
            for (final row in rows)
              {
                'note_uuid': row['sync_uuid'],
                'base_hash': 'base-${row['sync_uuid']}',
                'rev': 1,
                'tags_json': '[]',
                'attachments_json': '[]',
                'extras_json': '{}',
              },
          ],
        );

    // 手机本地：14:27 最新一条置顶（sort_order 越小越靠前），10:00 一条在后
    await seedLocal('phone-1427', '手机14:27', '2026-10-25T14:27:00.000', -1);
    await seedLocal('phone-1000', '手机10:00', '2026-10-25T10:00:00.000', 0);

    // 电脑端补同步：14:15、昨天、更早各一条，外加一条归档。
    // 远端 sort_order 一律给 0——本机活跃区非空时必须被忽略，按时间插位
    await apply([
      _remoteRow(
        'desk-yesterday',
        '电脑昨天',
        '2026-10-24T21:00:00.000',
        sortOrder: 0,
      ),
      _remoteRow(
        'desk-1415',
        '电脑14:15',
        '2026-10-25T14:15:00.000',
        sortOrder: 0,
      ),
      _remoteRow(
        'desk-old',
        '电脑更早',
        '2026-10-20T09:00:00.000',
        sortOrder: 0,
      ),
      _remoteRow(
        'desk-archived',
        '电脑归档',
        '2026-10-23T09:00:00.000',
        sortOrder: 0,
        archived: 1,
      ),
    ]);

    final diaries = await dbHelper.getDiaries();
    final active = diaries.where((d) => d['is_archived'] == 0).toList();
    expect(active.map((d) => d['content']), [
      '手机14:27',
      '电脑14:15',
      '手机10:00',
      '电脑昨天',
      '电脑更早',
    ]);
    // 既有两行 sort_order 不动；新行与相邻行同值，同值靠 created_at DESC
    // 兜底——不整区重编号，避免所有笔记载荷指纹变化后下轮全量重传
    expect(active.map((d) => d['sort_order']), [-1, -1, 0, 0, 0]);
    // 归档行恒 NULL，且排在活跃区之后
    final archived = diaries.where((d) => d['is_archived'] == 1).toList();
    expect(archived.single['content'], '电脑归档');
    expect(archived.single['sort_order'], isNull);
  });
}
