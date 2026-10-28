import 'package:flutter/material.dart';

import '../sync/webdav_request_counter.dart';
import '../theme/app_theme_extension.dart';

/// 云同步设置页的请求预算行：最近 30 分钟本机 WebDAV 请求数。
///
/// 数字来自 [WebDavRequestCounter]：主 App 与悬浮窗各记一份日志，这里显示
/// 的是两次读取合并后的「本机合计」，所以文案必须写明只统计这台手机——
/// 坚果云按账号限流，电脑端/其它客户端消耗的额度无法从本机看到。
class WebDavBudgetLine extends StatelessWidget {
  const WebDavBudgetLine({super.key, required this.counter});

  final WebDavRequestCounter counter;

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    return ListenableBuilder(
      listenable: counter,
      builder: (context, _) {
        final used = counter.recentCount;
        final limit = counter.limit;
        final remaining = counter.remaining;
        final nearLimit = limit > 0 && used * 5 >= limit * 4;
        final color = nearLimit ? ext.warningText : ext.textSecondary;
        final expiry = nearLimit ? counter.untilNextExpiry : null;
        final seconds = expiry?.inSeconds;
        final minutes = seconds == null
            ? null
            : ((seconds + 59) ~/ 60).clamp(1, 30).toInt();
        final message = nearLimit
            ? '最近 30 分钟：这台手机已发出 $used 次请求（含悬浮窗），'
                  '接近坚果云免费版上限 $limit 次，建议降低同步频率或暂停同步。'
            : '最近 30 分钟：这台手机共发出 $used 次请求（含悬浮窗），'
                  '按免费版估算还剩 $remaining 次。';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(Icons.speed_rounded, size: 15, color: color),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    minutes == null
                        ? message
                        : '$message最早一批约 $minutes 分钟后滑出窗口。',
                    style: TextStyle(fontSize: 12, height: 1.5, color: color),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '按坚果云免费版 $limit 次估算，付费版上限 1500 次；'
              '只统计这台手机，电脑端和其它客户端不计入。',
              style: TextStyle(fontSize: 11, height: 1.5, color: ext.textHint),
            ),
          ],
        );
      },
    );
  }
}
