// 下拉刷新结果文案单测：随手记 SnackBar 与悬浮窗原生 Toast 共用同一句话
// （CloudSyncResult.pullRefreshMessage），保证两处反馈语义一致。
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/sync/cloud_sync_service.dart';

void main() {
  test('下拉刷新文案：成功无新增 / 成功带分项统计 / 失败沿用友好错误', () {
    expect(
      const CloudSyncResult(ok: true, message: '同步完成').pullRefreshMessage,
      '同步完成，云端与本地一致',
    );
    expect(
      const CloudSyncResult(
        ok: true,
        message: '同步完成',
        details: ['下载日记 2 条', '下载物品 1 条'],
      ).pullRefreshMessage,
      '同步完成：下载日记 2 条，下载物品 1 条',
    );
    expect(
      const CloudSyncResult(ok: false, message: '账号或应用密码错误').pullRefreshMessage,
      '账号或应用密码错误',
    );
  });
}
