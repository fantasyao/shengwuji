import 'package:shared_preferences/shared_preferences.dart';

/// 云同步「本地数据版本」信号（设置页云端同步入口行的待同步检测）。
///
/// 背景：P1 是手动同步，卡片上的「云端与本地一致」只是上次同步那一刻的
/// 结果快照——之后本地新增/删除/改标注，卡片毫无感知，用户会误以为已
/// 一致（真机反馈 2026-09-22）。
///
/// 原理：写方（DbHelper / TextProcessor 的用户侧写库路径）每次写成功后
/// bump 计数器；CloudSyncService 同步成功后把当前计数快照为「已同步版本」；
/// 读方（设置入口行 / 二级页）比较两值——当前 > 快照即本地有未上云的变更。
///
/// 与 DiarySyncBridge 同款纪律：主 App 与悬浮窗是两个 isolate（statics
/// 互不相通），bump 前必须 prefs.reload() 防另一 engine 覆盖计数；
/// 读方取值前也须已 reload。
class CloudSyncDataVersion {
  CloudSyncDataVersion._();

  /// 本地数据版本（每次用户侧写库 +1，跨重启持久）
  static const String dataVersionKey = 'cloud_sync_data_version';

  /// 已同步快照（每次同步成功 = 快照当时的数据版本）
  static const String syncedVersionKey = 'cloud_sync_synced_data_version';

  /// 写方：fire-and-forget。失败可容忍（漏计一次只影响提示及时性，
  /// 下一个变更仍会 bump），静默不污染业务日志
  static Future<void> bump() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload(); // 另一 engine 可能刚写过，必须 reload 再 +1 防覆盖
      final current = prefs.getInt(dataVersionKey) ?? 0;
      await prefs.setInt(dataVersionKey, current + 1);
    } catch (_) {
      // 提示信号失败不影响写库结果
    }
  }

  /// 读方：调用前须已 prefs.reload()（防读到另一 isolate 写前的旧值）
  static int current(SharedPreferences prefs) =>
      prefs.getInt(dataVersionKey) ?? 0;

  /// 同步成功后调用：把当前数据版本快照为「已同步版本」
  static Future<void> markSynced() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    await prefs.setInt(syncedVersionKey, current(prefs));
  }

  /// 是否有本地变更未同步（纯函数，单测覆盖）。
  /// 有上次同步记录 且（无快照 或 当前版本 > 快照）→ 有待同步。
  /// 从未同步过（hasLastSync=false）不算 pending：「尚未同步」文案已表意
  static bool hasPending({
    required bool hasLastSync,
    required int? syncedVersion,
    required int currentVersion,
  }) {
    if (!hasLastSync) return false;
    return syncedVersion == null || currentVersion > syncedVersion;
  }
}
