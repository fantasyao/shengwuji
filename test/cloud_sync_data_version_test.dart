// 云同步待同步检测单测：数据版本计数（bump/markSynced）+ pending 判定真值表
// + 入口行/二级页共用的状态文案。背景见 CloudSyncDataVersion 类注释
// （P1 手动同步下卡片只显示上次结果快照，用户会误以为一致——真机反馈）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/sync/cloud_sync_service.dart';
import 'package:shengwuji_app/utils/cloud_sync_data_version.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CloudSyncDataVersion 计数与快照', () {
    test('bump 自增跨读取可见，markSynced 后无 pending，再 bump 恢复 pending', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect(CloudSyncDataVersion.current(prefs), 0);

      await CloudSyncDataVersion.bump();
      await CloudSyncDataVersion.bump();
      final afterBump = await SharedPreferences.getInstance();
      await afterBump.reload();
      expect(CloudSyncDataVersion.current(afterBump), 2);

      await CloudSyncDataVersion.markSynced();
      final afterSync = await SharedPreferences.getInstance();
      await afterSync.reload();
      expect(
        CloudSyncDataVersion.hasPending(
          hasLastSync: true,
          syncedVersion: afterSync.getInt(CloudSyncDataVersion.syncedVersionKey),
          currentVersion: CloudSyncDataVersion.current(afterSync),
        ),
        isFalse,
      );

      await CloudSyncDataVersion.bump();
      final afterChange = await SharedPreferences.getInstance();
      await afterChange.reload();
      expect(
        CloudSyncDataVersion.hasPending(
          hasLastSync: true,
          syncedVersion: afterChange.getInt(CloudSyncDataVersion.syncedVersionKey),
          currentVersion: CloudSyncDataVersion.current(afterChange),
        ),
        isTrue,
      );
    });
  });

  group('hasPending 真值表', () {
    test('从未同步不算 pending（「尚未同步」文案已表意）', () {
      expect(
        CloudSyncDataVersion.hasPending(
          hasLastSync: false,
          syncedVersion: null,
          currentVersion: 5,
        ),
        isFalse,
      );
    });

    test('同步后无变更 → false；有变更 → true；快照缺失兜底 true', () {
      expect(
        CloudSyncDataVersion.hasPending(
          hasLastSync: true,
          syncedVersion: 3,
          currentVersion: 3,
        ),
        isFalse,
      );
      expect(
        CloudSyncDataVersion.hasPending(
          hasLastSync: true,
          syncedVersion: 3,
          currentVersion: 4,
        ),
        isTrue,
      );
      expect(
        CloudSyncDataVersion.hasPending(
          hasLastSync: true,
          syncedVersion: null,
          currentVersion: 0,
        ),
        isTrue,
      );
    });
  });

  group('buildEntrySubtitle 入口行文案', () {
    final t = DateTime(2026, 9, 22, 1, 1);

    test('未配置', () {
      expect(
        CloudSyncConfig.buildEntrySubtitle(
          configured: false,
          hasPending: true,
          lastSync: null,
        ),
        '未配置 · 支持 WebDAV 网盘（坚果云等）',
      );
    });

    test('已配置未同步', () {
      expect(
        CloudSyncConfig.buildEntrySubtitle(
          configured: true,
          hasPending: true,
          lastSync: null,
        ),
        '已配置 · 尚未同步',
      );
    });

    test('有待同步时优先提示（替代上次结果快照，防误以为一致）', () {
      expect(
        CloudSyncConfig.buildEntrySubtitle(
          configured: true,
          hasPending: true,
          lastSync: (t, '云端与本地一致，无新数据'),
        ),
        '有新数据待同步 · 上次同步：9月22日 01:01',
      );
    });

    test('无待同步显示上次时间+结果', () {
      expect(
        CloudSyncConfig.buildEntrySubtitle(
          configured: true,
          hasPending: false,
          lastSync: (t, '下载日记 1 条'),
        ),
        '9月22日 01:01 · 下载日记 1 条',
      );
    });
  });
}
