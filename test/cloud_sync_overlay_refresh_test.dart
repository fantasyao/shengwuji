// 云同步 → 悬浮窗刷新单测：下载合并出远端新日记/物品后必须 bump
// DiarySyncBridge 计数。悬浮窗在独立 engine，展开时只比对计数才重查库
// （overlay_home._syncDiariesIfChanged）；不 bump 会出现电脑端同步来的
// 日记随手记可见、悬浮窗一直显示旧列表（2026-10-23 真机反馈）。
//
// 直接驱动 sync 的下载合并段 mergeDownloadedText，不依赖 WebDAV 网络。
//
// ⚠️ 独立库文件名：sqflite_common_ffi 的库文件是磁盘上共享的真实文件，
// 与其他 db_*_test 并行跑会撞锁（同 db_sort_order_test 头注释）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/db_helper.dart';
import 'package:shengwuji_app/sync/cloud_sync_service.dart';
import 'package:shengwuji_app/sync/sync_models.dart';
import 'package:shengwuji_app/text_processor.dart';
import 'package:shengwuji_app/utils/diary_sync_bridge.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('云同步下载远端日记/物品后 bump 计数，悬浮窗展开能刷新', () async {
    DbHelper.dbFileName = 'items_cloud_sync_overlay_refresh_test.db';
    final dbPath = p.join(
      await databaseFactory.getDatabasesPath(),
      DbHelper.dbFileName,
    );
    await databaseFactory.deleteDatabase(dbPath);
    SharedPreferences.setMockInitialValues({});

    final helper = DbHelper();
    final service = CloudSyncService(
      dbHelper: helper,
      processor: TextProcessor(),
    );

    // 远端载荷走云端 JSON 解码（与真实同步同路径）
    final remoteDiary = decodeDiaryEntries(jsonEncode([
      {
        'uuid': 'uuid-pc-diary-1',
        'content': '电脑端写的一条日记',
        'created_at': '2026-10-23T09:00:00.000',
        'archived': 0,
        'sort_order': 0,
      },
    ]));
    final remoteItems = decodeItemEntries(jsonEncode([
      {'uuid': 'uuid-pc-item-1', 'name': '护照', 'location': '书桌抽屉'},
    ]));

    // 悬浮窗上次展开时见到的计数
    final prefsBefore = await SharedPreferences.getInstance();
    await prefsBefore.reload();
    final seenByOverlay = DiarySyncBridge.current(prefsBefore);

    final stats = await service.mergeDownloadedText(
      remoteDiary: remoteDiary,
      remoteItems: remoteItems,
      tombstones: const {},
    );
    expect(stats, ['下载日记 1 条', '下载物品 1 条']);

    // 数据可见性：悬浮窗 _loadDiaries 的数据源能查到
    expect(
      (await helper.queryAllDiaries())
          .any((d) => d['content'] == '电脑端写的一条日记'),
      isTrue,
    );
    expect(
      (await helper.queryAll()).any((i) => i['name'] == '护照'),
      isTrue,
    );

    // 刷新信号：展开时 reload 后计数与上次已见不同 → 会重查库
    final prefsAfter = await SharedPreferences.getInstance();
    await prefsAfter.reload();
    final counter = DiarySyncBridge.current(prefsAfter);
    expect(counter, seenByOverlay + 1);

    // 重复同步（云端无新条目）不 bump：无变更零开销，不触发无谓重查
    final again = await service.mergeDownloadedText(
      remoteDiary: remoteDiary,
      remoteItems: remoteItems,
      tombstones: const {},
    );
    expect(again, isEmpty);
    await prefsAfter.reload();
    expect(DiarySyncBridge.current(prefsAfter), counter);
  });
}
