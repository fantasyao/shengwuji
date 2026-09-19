import 'package:flutter/material.dart';
import '../overlay_constants.dart';

/// Pro 未解锁提示胶囊：悬浮窗系动作被 Pro 门禁拦截时的反馈 UI。
///
/// 替代旧 Toast：Kotlin 侧直建 312×84 隐藏窗（与录音胶囊同位置同尺寸），
/// 通知渲染本组件首帧后揭示，3 秒后 Kotlin 收窗。视觉沿用 _StopHintPill 家族
/// （黑 72% 半透明底 + 白字），跨背景对比度已验证。
///
/// ⚠️ 渲染位置：OverlayHome.build 的 Pro 提示分支必须排在「84 < 88 硬不变量」
/// 判定之前——提示态下 voiceMemo 仍为 idle 且窗口高 84 < 把手高 88，不短路
/// 会被硬不变量渲染成空白（见 overlay_home.dart 该判定注释）。
class ProLockedHintPill extends StatelessWidget {
  /// 停靠侧（父层透传：贴屏端边距随侧镜像，与录音胶囊对齐规则一致）
  final bool dockLeft;

  const ProLockedHintPill({super.key, required this.dockLeft});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        // 贴屏端边距与录音胶囊同款（镜像规则一致）
        margin: EdgeInsets.only(
          left: dockLeft ? OverlayConstants.voiceMemoEdgeMargin : 0,
          right: dockLeft ? 0 : OverlayConstants.voiceMemoEdgeMargin,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          // 圆角 16 超过半高时 Skia 自动缩到半高 = 全圆角胶囊
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, size: 14, color: Colors.white),
                SizedBox(width: 6),
                Text(
                  '暂未解锁，无法使用',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.2,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
            SizedBox(height: 2),
            Text(
              '悬浮窗是 Pro 功能，请在声物记设置页解锁',
              style: TextStyle(fontSize: 10, height: 1.2, color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}
