import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:shengwuji_app/overlay/accessibility_overlay.dart';
import 'package:shengwuji_app/overlay/overlay_constants.dart';
import 'package:shengwuji_app/overlay/overlay_voice_memo.dart';

/// 语音速记录音胶囊（悬浮窗语音速记态的整窗 UI）
///
/// - 数据源：[OverlayVoiceMemoController]（父级 OverlayHome 监听后 setState 驱动
///   本组件重建，100ms tick → 胶囊变长 + mm:ss 刷新）
/// - 录音态：贴屏幕停靠缘垂直居中的深色半透明胶囊，宽度随录音秒数增长
///   （min(基础宽 + 秒数×增速, 上限)，锤子"2s 和 5s 胶囊长度不同"的语义），
///   红点闪烁 + mm:ss 计时居中于内容区 + 贴屏端停止按钮（详见 [_RecordingCapsule]）；
///   前 [OverlayConstants.voiceMemoStopHintMaxShows] 次速记录音在胶囊正下方
///   追加停止提示胶囊（用户教育——停止不只按钮
///   一条路，展示计数持久化在 controller.showStopHint，文案随「单击键结束
///   录音」开关切换，详见 [_StopHintPill]）
/// - 转写态：同位置固定宽度胶囊，"转写中" + 三点错峰跳动（无停止按钮——
///   停止只在录音阶段有意义，转写一旦开始无法中断）
/// - 窗口定位：原生 resizeOverlay 对非哨兵值高度使用 Gravity.CENTER_VERTICAL|
///   START/END（按设置页停靠侧），窗口天然贴停靠缘垂直居中；本组件在窗口内
///   对齐停靠侧即可（Align.centerRight / centerLeft，见 [dockLeft]）
/// - 注意：胶囊本体可以有阴影（不透明实体，同日记卡片）；透明窗口背景不能画
///   boxShadow（会画出奇怪阴影框——项目教训）
/// - ⚠️ 性能审查 Top8：红点闪烁/三点跳动两个动画控制器不再同挂一个 State 里
///   同时无限 repeat（build 二选一渲染，不用的那个全程空转驱动逐帧）——拆成
///   两个子 widget 随分支挂载/销毁，**任一时刻只有一个控制器在转**；可见动画
///   一帧不变，只是看不见的那个不再空转烧帧
class OverlayVoiceMemoBar extends StatelessWidget {
  final OverlayVoiceMemoController controller;

  /// 停靠侧：false（默认）= 屏幕右缘（历史行为），true = 左缘。
  /// 胶囊对齐、距屏边距、停止钮贴屏端、阴影投射方向全部随侧镜像
  final bool dockLeft;

  const OverlayVoiceMemoBar({
    super.key,
    required this.controller,
    this.dockLeft = false,
  });

  @override
  Widget build(BuildContext context) {
    final isRecording = controller.state == OverlayVoiceMemoState.recording;
    return Align(
      // 胶囊贴屏幕停靠缘（窗口已由原生 gravity 钉在停靠缘垂直居中，这里只管
      // 同侧对齐：停靠右缘向左生长 / 停靠左缘向右生长）
      alignment: dockLeft ? Alignment.centerLeft : Alignment.centerRight,
      // 两个胶囊各自持有自己的动画控制器，随分支挂载/销毁（Top8）
      child: isRecording
          ? Column(
              mainAxisSize: MainAxisSize.min,
              // 中文应用恒 LTR，start/end 即停靠左缘/右缘——提示胶囊与录音胶囊
              // 的贴屏端边缘对齐（两者都自带停靠侧 12dp 边距，对齐后贴屏端
              // 视觉边缘同在距屏 12dp 处，提示不随胶囊变长而移动）
              crossAxisAlignment: dockLeft
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.end,
              children: [
                _RecordingCapsule(controller: controller, dockLeft: dockLeft),
                if (controller.showStopHint) ...[
                  const SizedBox(height: OverlayConstants.voiceMemoHintGap),
                  _StopHintPill(
                    dockLeft: dockLeft,
                    singleClickStop: controller.singleClickStopEnabled,
                  ),
                ],
              ],
            )
          : _TranscribingCapsule(dockLeft: dockLeft),
    );
  }
}

/// 录音态：变长胶囊（红点闪烁 + mm:ss 计时 + 贴屏端停止按钮）
///
/// 结构：胶囊本体（AnimatedContainer，宽度随录音秒数增长）内是一层 Stack——
/// - 计时内容（红点 + mm:ss）居中于「让出停止钮命中区后的剩余宽度」，随胶囊
///   变长继续向左漂移（既有行为，不变）
/// - 停止按钮命中区钉在贴屏端整列（Positioned right:0）：胶囊右缘锚定屏幕，
///   按钮位置从 0s 起固定不随变长移动（相对屏幕静止的稳定靶心，可肌肉记忆；
///   生长尖端在移动，不能放按钮——5.5s 内要跑 220dp，误触风险高）
///
/// 点击停止 = 震感反馈（heavy，对齐日记页停录）+ controller.stop()，与音量键/
/// 上限自动停走同一条 stop 路径（Kotlin voiceMemoStopped 是纯回执：复位 toggle
/// + 撤 watchdog，对"谁发起的 stop"无假设；300s 上限 Timer 早已在走 Dart 侧
/// 主动 stop 的先例）。
///
/// 红点闪烁控制器只在录音态存活：进入转写态本组件卸载、控制器 dispose。
class _RecordingCapsule extends StatefulWidget {
  final OverlayVoiceMemoController controller;

  /// 停靠侧（父层透传，决定计时区/分隔线/停止钮在胶囊内的贴屏端）
  final bool dockLeft;

  const _RecordingCapsule({required this.controller, required this.dockLeft});

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
    // 🔇 静音倒计时剩余秒数（null = 未启用自动停 / 说话中 / 未说话）：非 null
    // 时 mm:ss 换成「N 秒后自动停」告知用户即将自动停；100ms tick 驱动重建
    final countdown = widget.controller.silenceCountdownSeconds;
    // 宽度 = min(基础宽 + 秒数×增速, 上限)——时长上限兜底 min 防超界显示；
    // 倒计时态文字比 mm:ss 宽，短录音早期按公式算出的宽放不下，按下限兜底
    final elapsed = math.min(
      widget.controller.elapsedSeconds,
      OverlayConstants.voiceMemoMaxSeconds.toDouble(),
    );
    final width = math.max(
      math.min(
        OverlayConstants.voiceMemoBaseWidth +
            elapsed * OverlayConstants.voiceMemoGrowthPerSec,
        OverlayConstants.voiceMemoMaxWidth,
      ),
      countdown != null ? OverlayConstants.voiceMemoAutoStopMinWidth : 0.0,
    );
    return AnimatedContainer(
      // 300ms 补间：100ms tick 间的宽度跳变被平滑成连续生长
      duration: const Duration(milliseconds: 300),
      curve: Curves.linear,
      width: width,
      height: OverlayConstants.voiceMemoCapsuleHeight,
      // 距屏边距画在停靠侧：停靠右缘让出右缘（历史行为），停靠左缘镜像
      margin: EdgeInsets.only(
        left: widget.dockLeft ? OverlayConstants.voiceMemoEdgeMargin : 0,
        right: widget.dockLeft ? 0 : OverlayConstants.voiceMemoEdgeMargin,
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
            // 阴影朝屏幕内侧投射（背离停靠缘）：右缘停靠向左、左缘停靠向右
            offset: Offset(widget.dockLeft ? 2 : -2, 0),
          ),
        ],
      ),
      child: Stack(
        children: [
          // 计时内容：居中于「让出停止钮命中区后的剩余宽度」（width - 44）。
          // Row.min 收缩到内容宽（Align 族有限约束下撑满的教训：不能用
          // Container.alignment）
          Positioned.fill(
            left: widget.dockLeft ? OverlayConstants.voiceMemoStopZoneWidth : 0,
            right: widget.dockLeft
                ? 0
                : OverlayConstants.voiceMemoStopZoneWidth,
            child: Row(
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
                  // 🔇 静音倒计时中：mm:ss 换成倒计时告知（恢复说话自动回到计时）
                  countdown != null ? '$countdown 秒后自动停' : _formatClock(elapsed),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          // 内容区与停止钮的分隔线（细分隔声明"贴屏端是独立可点区域"）
          Positioned(
            left: widget.dockLeft
                ? OverlayConstants.voiceMemoStopZoneWidth
                : null,
            right: widget.dockLeft
                ? null
                : OverlayConstants.voiceMemoStopZoneWidth,
            top: 12,
            bottom: 12,
            child: Container(
              width: 1,
              color: Colors.white.withValues(alpha: 0.25),
            ),
          ),
          // 停止按钮：命中区钉在贴屏端整列（胶囊停靠缘锚定屏幕 → 位置从 0s 起
          // 固定不随变长移动）。opaque 让整个 44×44 都是命中区（视觉圆底只有 28）
          Positioned(
            left: widget.dockLeft ? 0 : null,
            right: widget.dockLeft ? null : 0,
            top: 0,
            bottom: 0,
            width: OverlayConstants.voiceMemoStopZoneWidth,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _stopRecording,
              child: Center(
                child: Semantics(
                  label: '停止录音',
                  button: true,
                  child: Container(
                    width: OverlayConstants.voiceMemoStopVisualSize,
                    height: OverlayConstants.voiceMemoStopVisualSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.18),
                    ),
                    child: const Icon(
                      Icons.stop,
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 停止按钮点击：震感反馈 + 走统一 stop 路径。
  ///
  /// 震感 tick 清脆（2026-09-17 用户拍板「开始嗡、停止清脆」——与 Kotlin 音量键
  /// toggle 停录的 performHaptic("tick") 同档，悬浮窗在独立 engine 够不着主 App
  /// 通道，走无障碍服务的 performHaptic 同参实现）。震动是尽力而为的附加反馈，
  /// 失败静默（.ignore()），不阻塞停录。
  ///
  /// stop 入口有 state 守卫（非录音态直接 return），与音量键/上限自动停并发
  /// 也幂等，无需额外防重
  void _stopRecording() {
    AccessibilityOverlay.performHaptic('tick').ignore();
    unawaited(widget.controller.stop());
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
  /// 停靠侧（父层透传，镜像距屏边距与阴影方向）
  final bool dockLeft;

  const _TranscribingCapsule({required this.dockLeft});

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
      // 距屏边距画在停靠侧（与录音态同规则）
      margin: EdgeInsets.only(
        left: widget.dockLeft ? OverlayConstants.voiceMemoEdgeMargin : 0,
        right: widget.dockLeft ? 0 : OverlayConstants.voiceMemoEdgeMargin,
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
            offset: Offset(widget.dockLeft ? 2 : -2, 0),
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

/// 停止提示胶囊（仅录音态 + 前
/// [OverlayConstants.voiceMemoStopHintMaxShows] 次速记展示，判定在
/// OverlayVoiceMemoController.shouldShowStopHint，计数跨会话持久化）
///
/// - 位置：录音胶囊正下方（窗口加高到 84dp 让出的下部条带，见
///   [OverlayConstants.voiceMemoWindowHeight]），贴屏端边缘与录音胶囊对齐
/// - 配色：与录音胶囊同款黑 72% 半透明底 + 白字——悬浮窗下垫的是任意壁纸/
///   应用，浅灰字裸放在白色背景的应用上会直接消失；自带深色底才有跨背景的
///   对比度保障（白字对黑 72% 底，即使垫纯白背景等效底色也接近 #4a4a4a，
///   对比度 ≈ 8:1），且与录音胶囊构成同一视觉家族，不像外来的悬浮元素
/// - 文案必须与实际交互一致，措辞不准会制造新困惑（用户照文案操作却看到
///   音量条、录音没停）。关 →「再次长按音量上键」（短按是系统音量）；
///   开（单击键结束录音）→「单击音量键」（短按已被 Kotlin 拦截停录，单击
///   音量加/减都停），快照在 controller.start() 读，见其 singleClickStopEnabled
class _StopHintPill extends StatelessWidget {
  /// 停靠侧（父层透传：贴屏端边距随侧镜像，与录音胶囊对齐规则一致）
  final bool dockLeft;

  /// 「单击键结束录音」开关的本次录音快照（true 时切单击文案）
  final bool singleClickStop;

  const _StopHintPill({required this.dockLeft, this.singleClickStop = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      // 贴屏端边距与录音胶囊同款（镜像规则一致），对齐后两枚胶囊贴屏端视觉
      // 边缘重合（同在距屏 12dp 处）
      margin: EdgeInsets.only(
        left: dockLeft ? OverlayConstants.voiceMemoEdgeMargin : 0,
        right: dockLeft ? 0 : OverlayConstants.voiceMemoEdgeMargin,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        // 圆角 12 超过半高（胶囊高 ≈21dp）时 Skia 自动缩到半高 = 全圆角胶囊，
        // 系统字体放大后胶囊变高也保持两端的圆头形态
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        singleClickStop ? '单击音量键，停止并转写' : '再次长按音量上键，停止并转写',
        style: const TextStyle(fontSize: 11, height: 1.2, color: Colors.white),
      ),
    );
  }
}
