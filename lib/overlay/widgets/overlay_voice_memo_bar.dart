import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:shengwuji_app/overlay/overlay_constants.dart';
import 'package:shengwuji_app/overlay/overlay_voice_memo.dart';

/// 语音速记录音胶囊（悬浮窗语音速记态的整窗 UI）
///
/// - 数据源：[OverlayVoiceMemoController]（父级 OverlayHome 监听后 setState 驱动
///   本组件重建，100ms tick → 胶囊变长 + mm:ss 刷新）
/// - 录音态：贴屏幕右缘垂直居中的深色半透明胶囊，宽度随录音秒数增长
///   （min(基础宽 + 秒数×增速, 上限)，锤子"2s 和 5s 胶囊长度不同"的语义），
///   左侧红点闪烁 + mm:ss 计时
/// - 转写态：同位置固定宽度胶囊，"转写中" + 三点错峰跳动
/// - 窗口定位：原生 resizeOverlay 对非哨兵值高度使用 Gravity.CENTER_VERTICAL|END，
///   窗口天然贴右缘垂直居中；本组件在窗口内右对齐即可（Align.centerRight）
/// - 注意：胶囊本体可以有阴影（不透明实体，同日记卡片）；透明窗口背景不能画
///   boxShadow（会画出奇怪阴影框——项目教训）
/// - ⚠️ 性能审查 Top8：红点闪烁/三点跳动两个动画控制器不再同挂一个 State 里
///   同时无限 repeat（build 二选一渲染，不用的那个全程空转驱动逐帧）——拆成
///   两个子 widget 随分支挂载/销毁，**任一时刻只有一个控制器在转**；可见动画
///   一帧不变，只是看不见的那个不再空转烧帧
class OverlayVoiceMemoBar extends StatelessWidget {
  final OverlayVoiceMemoController controller;

  const OverlayVoiceMemoBar({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final isRecording =
        controller.state == OverlayVoiceMemoState.recording;
    return Align(
      // 胶囊贴屏幕右缘（窗口已由原生 gravity 钉在右缘垂直居中，这里只管右对齐，
      // 胶囊向左生长；未来左右侧切换时与面板 Stack 对齐一起镜像）
      alignment: Alignment.centerRight,
      // 两个胶囊各自持有自己的动画控制器，随分支挂载/销毁（Top8）
      child: isRecording
          ? _RecordingCapsule(controller: controller)
          : const _TranscribingCapsule(),
    );
  }
}

/// 录音态：变长胶囊（红点闪烁 + mm:ss 计时）
///
/// 红点闪烁控制器只在录音态存活：进入转写态本组件卸载、控制器 dispose。
class _RecordingCapsule extends StatefulWidget {
  final OverlayVoiceMemoController controller;

  const _RecordingCapsule({required this.controller});

  @override
  State<_RecordingCapsule> createState() => _RecordingCapsuleState();
}

class _RecordingCapsuleState extends State<_RecordingCapsule>
    with SingleTickerProviderStateMixin {
  /// 红点闪烁动画（600ms 呼吸循环）
  late final AnimationController _blinkController;

  @override
  void initState() {
    super.initState();
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _blinkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 宽度 = min(基础宽 + 秒数×增速, 上限)——时长上限兜底 min 防超界显示
    final elapsed = math.min(
      widget.controller.elapsedSeconds,
      OverlayConstants.voiceMemoMaxSeconds.toDouble(),
    );
    final width = math.min(
      OverlayConstants.voiceMemoBaseWidth +
          elapsed * OverlayConstants.voiceMemoGrowthPerSec,
      OverlayConstants.voiceMemoMaxWidth,
    );
    return AnimatedContainer(
      // 300ms 补间：100ms tick 间的宽度跳变被平滑成连续生长
      duration: const Duration(milliseconds: 300),
      curve: Curves.linear,
      width: width,
      height: OverlayConstants.voiceMemoCapsuleHeight,
      margin: const EdgeInsets.only(
        right: OverlayConstants.voiceMemoEdgeMargin,
      ),
      decoration: BoxDecoration(
        // 深色半透明背景 + 白字（对齐"随手记"面板头部风格）
        color: Colors.black.withValues(alpha: 0.72),
        // 全圆角胶囊：半径 = 高度一半（对齐日记卡片/把手的全圆角语言）
        borderRadius: BorderRadius.circular(
          OverlayConstants.voiceMemoCapsuleHeight / 2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 8,
            offset: const Offset(-2, 0),
          ),
        ],
      ),
      child: Row(
        // Row.min 收缩到内容宽（Align 族有限约束下撑满的教训：不能用 Container.alignment）
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 红点闪烁（录音中的经典视觉语言）
          FadeTransition(
            opacity: Tween<double>(begin: 0.25, end: 1.0).animate(
              CurvedAnimation(
                parent: _blinkController,
                curve: Curves.easeInOut,
              ),
            ),
            child: Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                // 取自卡片色板的红
                color: Color(0xFFFF6B6B),
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _formatClock(elapsed),
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  /// 秒数 → mm:ss
  String _formatClock(double seconds) {
    final total = seconds.floor();
    final m = total ~/ 60;
    final s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

/// 转写态：固定宽度胶囊（"转写中" + 三点错峰跳动）
///
/// 三点跳动控制器只在转写态存活：回到录音态/录音结束本组件卸载、控制器
/// dispose（原实现两个控制器同挂一个 State 同时无限 repeat、不用的那个
/// 全程空转——Top8 的问题根源）。
class _TranscribingCapsule extends StatefulWidget {
  const _TranscribingCapsule();

  @override
  State<_TranscribingCapsule> createState() => _TranscribingCapsuleState();
}

class _TranscribingCapsuleState extends State<_TranscribingCapsule>
    with SingleTickerProviderStateMixin {
  /// 转写态三点错峰跳动动画（900ms 循环）
  late final AnimationController _dotsController;

  @override
  void initState() {
    super.initState();
    _dotsController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _dotsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: OverlayConstants.voiceMemoTranscribingWidth,
      height: OverlayConstants.voiceMemoCapsuleHeight,
      margin: const EdgeInsets.only(
        right: OverlayConstants.voiceMemoEdgeMargin,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(
          OverlayConstants.voiceMemoCapsuleHeight / 2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 8,
            offset: const Offset(-2, 0),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            '转写中',
            style: TextStyle(fontSize: 14, color: Colors.white),
          ),
          const SizedBox(width: 6),
          AnimatedBuilder(
            animation: _dotsController,
            builder: (context, _) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < 3; i++)
                    Transform.translate(
                      // 三角波 0→1→0，三个点相位各错开 1/3，视觉上波浪跳动
                      offset: Offset(0, -3.5 * _dotWave(i)),
                      child: Container(
                        width: 4,
                        height: 4,
                        margin: const EdgeInsets.symmetric(horizontal: 1.5),
                        decoration: const BoxDecoration(
                          color: Colors.white70,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  /// 第 i 个跳点的三角波值（0→1→0，周期 = [_dotsController] 时长）
  double _dotWave(int i) {
    final phase = (_dotsController.value + i / 3) % 1.0;
    return phase < 0.5 ? phase * 2 : (1 - phase) * 2;
  }
}
