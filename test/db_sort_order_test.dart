// DbHelper sort_order（diary 自定义排序列，DB v16）数据层语义测试。
//
// 覆盖设计定稿的 7 个用例组（单一 test 内按阶段顺序执行——DbHelper._db 与
// dbFileName 是静态状态，多 test 会共享同一条打开的连接互相干扰，同
// db_restore_deleted_diary_test 的「文件内只跑一个 test」纪律）：
//   a. 首开回填：活跃区 NULL 行赋 min-1 递减系列（迭代方向 created_at
//      ASC——最新行拿系列最小值），显示顺序与升级前完全一致；归档行恒
//      NULL；幂等（无 NULL 行可再填）
//   b. insertDiary 新卡置顶（连续插入，后插的在前）
//   c. archiveDiary 清空 sort_order，归档区按 created_at DESC
//   d. restoreDiary 回活跃区顶部
//   e. restoreDeletedDiary 恢复原 sort_order（回原位置而非顶部）
//   f. reorderActiveDiaries：指定顺序规范重写 0..n-1 + 漏网行续排尾部
//      + 归档行不受影响
//   g. insertRemoteDiaries：空活跃区尊重远端 sort_order；非空活跃区
//      按 created_at 插进本机顺序（贴相邻行 sort_order，同值由
//      created_at DESC 兜底），不整批置顶、不改既有行
//
// ⚠️ 独立库文件名：sqflite_common_ffi 的库文件是磁盘上共享的真实文件，
// 多测试文件并行跑时共用 items.db 会互相撞锁（db_upgrade_v14_test 头注释）。
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/db_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('sort_order 全链路：回填/置顶插入/归档/恢复/撤销删除/重排/远端合并', () async {
    DbHelper.dbFileName = 'items_sort_order_test.db';
    final dbPath = p.join(
      await databaseFactory.getDatabasesPath(),
      DbHelper.dbFileName,
    );
    await databaseFactory.deleteDatabase(dbPath);
    // bump/snapshot 走 SharedPreferences（内部已 try/catch 静默容错），
    // mock 掉避免 MissingPluginException 噪声
    SharedPreferences.setMockInitialValues({});

    // ---- 准备：手工建 v16 schema 的库，写入 sort_order 全 NULL 的行
    //（模拟老库升级后、首开回填前的中间态）。不经过 DbHelper.onCreate，
    // 故无内置说明卡片，数据完全可控 ----
    final oldDb = await databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 16,
        onCreate: (db, version) async {
          await db.execute(
            "CREATE TABLE items(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, location TEXT, sync_uuid TEXT)",
          );
          await db.execute(
            "CREATE TABLE diary(id INTEGER PRIMARY KEY AUTOINCREMENT, content TEXT, created_at TEXT, audio_path TEXT, duration INTEGER, is_archived INTEGER DEFAULT 0, exported_at TEXT, tag TEXT, sync_uuid TEXT, is_locked INTEGER DEFAULT 0, sort_order INTEGER)",
          );
          await db.execute(
            "CREATE TABLE sync_deleted(uuid TEXT PRIMARY KEY, kind TEXT NOT NULL, deleted_at TEXT NOT NULL)",
          );
        },
      ),
    );
    Future<int> rawInsert(
      String content,
      String createdAt, {
      int archived = 0,
    }) => oldDb.insert('diary', {
      'content': content,
      'created_at': createdAt,
      'is_archived': archived,
      'sync_uuid': 'uuid-$content',
    });
    final idA = await rawInsert('A最旧', '2026-09-28T10:00:00.000');
    final idB = await rawInsert('B中间', '2026-09-28T11:00:00.000');
    final idC = await rawInsert('C最新', '2026-09-28T12:00:00.000');
    await rawInsert('X归档', '2026-09-28T09:00:00.000', archived: 1);
    await oldDb.close();

    final dbHelper = DbHelper();
    final db = await dbHelper.db;

    // ============ a. 首开回填 ============
    var diaries = await dbHelper.getDiaries();
    // 活跃区顺序 == created_at DESC（与升级前的纯时间序完全一致）
    expect(
      diaries.where((d) => d['is_archived'] == 0).map((d) => d['content']),
      ['C最新', 'B中间', 'A最旧'],
    );
    // 归档区行 sort_order 仍 NULL、排在活跃区之后
    expect(diaries.last['content'], 'X归档');
    expect(diaries.last['sort_order'], isNull);
    // 幂等：活跃区已无 NULL 行（再次回填找不到可填的行，返回 0 的前提）
    final nullActive = await db.query(
      'diary',
      where: 'is_archived = 0 AND sort_order IS NULL',
    );
    expect(nullActive, isEmpty);
    // 回填值是 min-1 递减系列且最新行最小（ASC 排序小=置顶）：
    // A=-1, B=-2, C=-3
    expect(diaries[0]['sort_order'], -3);
    expect(diaries[1]['sort_order'], -2);
    expect(diaries[2]['sort_order'], -1);

    // ============ b. insertDiary 新卡置顶 ============
    final idD = await dbHelper.insertDiary('D新卡1');
    final idE = await dbHelper.insertDiary('E新卡2');
    final idF = await dbHelper.insertDiary('F新卡3');
    diaries = await dbHelper.getDiaries();
    expect(
      diaries.where((d) => d['is_archived'] == 0).map((d) => d['content']),
      ['F新卡3', 'E新卡2', 'D新卡1', 'C最新', 'B中间', 'A最旧'],
    );

    // ============ c. archiveDiary 清空 sort_order ============
    await dbHelper.archiveDiary(idC);
    final archivedC = (await db.query(
      'diary',
      where: 'id = ?',
      whereArgs: [idC],
    )).single;
    expect(archivedC['is_archived'], 1);
    expect(archivedC['sort_order'], isNull); // 归档即清出排序域
    diaries = await dbHelper.getDiaries();
    // 归档区按 created_at DESC：C(12:00) 在 X(09:00) 之前
    expect(
      diaries.where((d) => d['is_archived'] == 1).map((d) => d['content']),
      ['C最新', 'X归档'],
    );

    // ============ d. restoreDiary 回活跃区顶部 ============
    await dbHelper.restoreDiary(idC);
    diaries = await dbHelper.getDiaries();
    expect(
      diaries.where((d) => d['is_archived'] == 0).map((d) => d['content']),
      ['C最新', 'F新卡3', 'E新卡2', 'D新卡1', 'B中间', 'A最旧'],
    );

    // ============ e. restoreDeletedDiary 回原位置（非顶部） ============
    final beforeF = Map<String, dynamic>.of(
      (await db.query('diary', where: 'id = ?', whereArgs: [idF])).single,
    );
    await dbHelper.deleteDiary(idF);
    final newIdF = await dbHelper.restoreDeletedDiary(beforeF);
    expect(newIdF, isNot(idF)); // 本地自增 id 重新分配
    diaries = await dbHelper.getDiaries();
    final activeAfterUndo = diaries
        .where((d) => d['is_archived'] == 0)
        .toList();
    expect(activeAfterUndo.map((d) => d['content']), [
      'C最新',
      'F新卡3',
      'E新卡2',
      'D新卡1',
      'B中间',
      'A最旧',
    ]);
    expect(activeAfterUndo[1]['id'], newIdF); // 回到原位置 index 1
    expect(activeAfterUndo[1]['sort_order'], beforeF['sort_order']);

    // ============ f. reorderActiveDiaries ============
    // 先造一条「漏网行」：重排列表里不含它，应按 created_at DESC 续排尾部
    final idG = await dbHelper.insertDiary('G漏网最新');
    // 指定顺序只给两个 id（C 提到顶、B 次之），其余活跃行全是漏网
    await dbHelper.reorderActiveDiaries([idC, idB]);
    diaries = await dbHelper.getDiaries();
    final activeAfterReorder = diaries
        .where((d) => d['is_archived'] == 0)
        .toList();
    // 指定的两个在最前（0、1）；漏网行按 created_at DESC 续排：
    // G(最新) > F > E > D > A（created_at 随插入时间递增）
    expect(activeAfterReorder.map((d) => d['content']), [
      'C最新',
      'B中间',
      'G漏网最新',
      'F新卡3',
      'E新卡2',
      'D新卡1',
      'A最旧',
    ]);
    // 事务内规范重写为 0..n-1
    expect(activeAfterReorder.map((d) => d['sort_order']), [
      0,
      1,
      2,
      3,
      4,
      5,
      6,
    ]);
    // 归档行不受影响（sort_order 恒 NULL）
    final archivedRows = diaries.where((d) => d['is_archived'] == 1).toList();
    expect(archivedRows.single['content'], 'X归档');
    expect(archivedRows.single['sort_order'], isNull);

    // ============ g1. insertRemoteDiaries：空活跃区尊重远端 sort_order ====
    // 把活跃区全部归档，制造「换机全量恢复」的空活跃区场景
    for (final id in [idC, idB, idG, newIdF, idE, idD, idA]) {
      await dbHelper.archiveDiary(id);
    }
    await dbHelper.insertRemoteDiaries([
      {
        'content': '远端R1',
        'created_at': '2026-09-28T13:00:00.000',
        'is_archived': 0,
        'sort_order': 10,
        'sync_uuid': 'uuid-remote-r1',
      },
      {
        'content': '远端R2',
        'created_at': '2026-09-28T14:00:00.000',
        'is_archived': 0,
        'sort_order': 5,
        'sync_uuid': 'uuid-remote-r2',
      },
    ]);
    diaries = await dbHelper.getDiaries();
    final activeG1 = diaries.where((d) => d['is_archived'] == 0).toList();
    // 空活跃区 → 远端 sort_order 原样落库：5 在前、10 在后
    expect(activeG1.map((d) => d['content']), ['远端R2', '远端R1']);
    expect(activeG1.map((d) => d['sort_order']), [5, 10]);

    // ============ g2. insertRemoteDiaries：非空活跃区按时间插位 ========
    await dbHelper.insertRemoteDiaries([
      // 故意按 created_at 升序传入（云端 JSON 文件序不可信），
      // 携带与本端撞值域的 sort_order（3/4 会插进 5/10 之间）——
      // 本端活跃区非空时远端值必须被丢弃，按 created_at 落位
      {
        'content': '远端R4较旧',
        'created_at': '2026-09-28T15:00:00.000',
        'is_archived': 0,
        'sort_order': 4,
        'sync_uuid': 'uuid-remote-r4',
      },
      {
        'content': '远端R3较新',
        'created_at': '2026-09-28T16:00:00.000',
        'is_archived': 0,
        'sort_order': 3,
        'sync_uuid': 'uuid-remote-r3',
      },
    ]);
    diaries = await dbHelper.getDiaries();
    final activeG2 = diaries.where((d) => d['is_archived'] == 0).toList();
    // 两条都比本机新 → 贴 R2 同值落顶部，行间按 created_at DESC；
    // 本端原有两条完整跟在后面，无交错
    expect(activeG2.map((d) => d['content']), [
      '远端R3较新',
      '远端R4较旧',
      '远端R2',
      '远端R1',
    ]);
    // 贴相邻行 sort_order（R2=5），既有行完全不动——R1 仍是 10
    expect(activeG2.map((d) => d['sort_order']), [5, 5, 5, 10]);

    // ============ g3. 新行插中间/落底部（用户反馈场景） ============
    await dbHelper.insertRemoteDiaries([
      {
        // 插在 R4(15:00) 与 R2(14:00) 之间
        'content': '远端R6中间',
        'created_at': '2026-09-28T14:30:00.000',
        'is_archived': 0,
        'sort_order': 99,
        'sync_uuid': 'uuid-remote-r6',
      },
      {
        // 比本机现有都旧 → 落底部
        'content': '远端R5最旧',
        'created_at': '2026-09-28T12:00:00.000',
        'is_archived': 0,
        'sort_order': 0,
        'sync_uuid': 'uuid-remote-r5',
      },
    ]);
    diaries = await dbHelper.getDiaries();
    final activeG3 = diaries.where((d) => d['is_archived'] == 0).toList();
    expect(activeG3.map((d) => d['content']), [
      '远端R3较新',
      '远端R4较旧',
      '远端R6中间',
      '远端R2',
      '远端R1',
      '远端R5最旧',
    ]);
    // R6 贴 R4 同值 5；R5 贴 R1 同值 10（同值组内按 created_at DESC）
    expect(activeG3.map((d) => d['sort_order']), [5, 5, 5, 5, 10, 10]);

    await db.close();
  });
}
