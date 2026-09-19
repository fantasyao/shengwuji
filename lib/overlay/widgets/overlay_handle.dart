import 'package:flutter/material.dart';
import '../overlay_constants.dart';

/// 收起态边缘把手（闪记双色胶囊）
///
/// 视觉：药丸式双色胶囊——上半白 / 下半绿、中间一道接缝横线（配色见
/// OverlayConstants handleCapsule*），外围细白描边与笔记卡片的
/// cardBorderWidth 白描边同语言；静置态整体稍透明（handleRestingOpacity）。
/// 胶囊本体比窗口小一圈（handleInset* 内缩）：窗口 28×88 是原生硬编码副本
/// 与语音胶囊 84<88 不变量的联动值不动，触控面积也不变，仅视觉缩小
///
/// 手势（识别在本组件，效果回调给父层 OverlayHome）：
/// - 点按 / 向屏幕内侧滑动 → 展开面板（既有行为，从 _buildHandle 原样迁入；
///   停靠右缘时内侧 = 左滑，停靠左缘时内侧 = 右滑，见 [dockLeft]）
/// - 长按 → 进入拖动模式，上下拖动调整把手在屏幕停靠缘的纵向位置——移动由
///   父层经 AccessibilityOverlay.dragHandle 转发给原生窗口（Flutter 窗口只有
///   28×88，位置真值在原生 LayoutParams），本组件只负责手势识别与拖动态视觉
///
/// 拖动态视觉：满不透明（静置态 0.93 → 1.0）+ 描边加粗到 1.5——沿用「拖动 =
/// 满不透明 + 白描边」的既有分层语言。刻意不用放大——窗口即把手尺寸，放大
/// 部分会被窗口边缘硬裁剪（同「无 boxShadow」的既有决策）。原生拖动开始另有
/// EFFECT_TICK 震感反馈
class OverlayHandle extends StatefulWidget {
  const OverlayHandle({
    super.key,
    required this.onTap,
    required this.onSwipeInward,
    this.dockLeft = false,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onDragCancel,
  });

  /// 点按 → 展开面板（OverlayHome._expand）
  final VoidCallback onTap;

  /// 向屏幕内侧滑动超阈值 → 展开面板（与点按同效）。
  /// 停靠右缘 = 左滑展开（历史行为）；停靠左缘 = 右滑展开（镜像）
  final VoidCallback onSwipeInward;

  /// 停靠侧：false（默认）= 屏幕右缘（历史行为），true = 左缘。
  /// 只影响"朝屏幕内侧"滑动的方向判定（展开手势镜像），拖动为纵向不受影响
  final bool dockLeft;

  /// 长按识别成功 → 进入拖动模式（父层：暂停自动隐藏 + 震感 + beginHandleDrag）
  final VoidCallback? onDragStart;

  /// 拖动更新：自按下原点的纵向累计位移（dp，向下为正），逐帧转发
  final ValueChanged<double>? onDragUpdate;

  /// 拖动松手（父层：endHandleDrag 落盘 + 恢复自动隐藏计时）
  final VoidCallback? onDragEnd;

  /// 拖动被取消：组件在手势中旬被移出树（语音速记打断切胶囊 UI）或系统
  /// 抢走指针时触发，与 [onDragEnd] 同款收尾
  final VoidCallback? onDragCancel;

  @override
  State<OverlayHandle> createState() => _OverlayHandleState();
}

class _OverlayHandleState extends State<OverlayHandle> {
  /// 长按拖动中（描边视觉真值；位移转发仅在 true 时进行——cancel 后不再外发）
  bool _dragging = false;

  /// 滑动待展开标记（"单事件超阈值"判定，原 OverlayHome._willExpand 把手分支迁入）
  bool _willExpand = false;

  void _onLongPressStart(LongPressStartDetails details) {
    setState(() => _dragging = true);
    widget.onDragStart?.call();
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    if (!_dragging) return;
    widget.onDragUpdate?.call(details.offsetFromOrigin.dy);
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    if (!_dragging) return;
    setState(() => _dragging = false);
    widget.onDragEnd?.call();
  }

  void _onLongPressCancel() {
    if (!_dragging) return;
    setState(() => _dragging = false);
    widget.onDragCancel?.call();
  }

  @override
  void dispose() {
    // 组件在手势中旬被移出树（语音速记打断把手切胶囊 UI）时，识别器随
    // GestureDetector 直接销毁、框架不回调 onLongPressCancel（没有 cancel
    // 指针事件可达）——这里补发收尾，父层的 endHandleDrag 落盘与恢复自动
    // 隐藏计时和松手路径对称。拖动中旬不会 setState，dispose 里调回调安全
    if (_dragging) widget.onDragCancel?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onHorizontalDragUpdate: (details) {
        // 朝屏幕内侧滑动超过阈值，标记为待展开：停靠右缘 = 向左（历史行为），
        // 停靠左缘 = 向右（镜像）。方向判定统一走 swipeExceeds
        if (OverlayConstants.swipeExceeds(
          details.primaryDelta,
          towardLeft: !widget.dockLeft,
        )) {
          _willExpand = true;
        }
      },
      onHorizontalDragEnd: (_) {
        if (_willExpand) {
          _willExpand = false;
          widget.onSwipeInward();
        }
      },
      // drag 被取消时清掉残留标记（对齐 _buildEdgeLine 的既有清理）
      onHorizontalDragCancel: () => _willExpand = false,
      onLongPressStart: _onLongPressStart,
      onLongPressMoveUpdate: _onLongPressMoveUpdate,
      onLongPressEnd: _onLongPressEnd,
      onLongPressCancel: _onLongPressCancel,
      // 窗口（28×88）不变，胶囊本体向内缩一圈：视觉缩小但触控面积不丢
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: OverlayConstants.handleInsetHorizontal,
          vertical: OverlayConstants.handleInsetVertical,
        ),
        // 拖动态满不透明（静置稍透明），沿用「拖动 = 满不透明」分层语言
        child: AnimatedOpacity(
          duration: OverlayConstants.animationDuration,
          opacity: _dragging ? 1.0 : OverlayConstants.handleRestingOpacity,
          child: AnimatedContainer(
            duration: OverlayConstants.animationDuration,
            width:
                OverlayConstants.handleWidth -
                2 * OverlayConstants.handleInsetHorizontal,
            height:
                OverlayConstants.handleHeight -
                2 * OverlayConstants.handleInsetVertical,
            decoration: BoxDecoration(
              // 药丸双色：上半白 / 下半绿在胶囊正中硬切（hard-stop 渐变，
              // BoxDecoration 的 borderRadius 自动裁出胶囊轮廓，无需 ClipRRect）
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  OverlayConstants.handleCapsuleTopColor,
                  OverlayConstants.handleCapsuleTopColor,
                  OverlayConstants.handleCapsuleBottomColor,
                  OverlayConstants.handleCapsuleBottomColor,
                ],
                stops: [0.0, 0.5, 0.5, 1.0],
              ),
              // 全圆角胶囊：半径 = 胶囊宽度一半，随内缩后的宽度自动适配
              borderRadius: BorderRadius.circular(
                (OverlayConstants.handleWidth -
                        2 * OverlayConstants.handleInsetHorizontal) /
                    2,
              ),
              // 细白描边与笔记卡片同款（cardBorderWidth），静置态常驻；
              // 拖动态加粗到 1.5 作为拖动反馈（描边画在胶囊内侧不溢出窗口）
              border: Border.all(
                color: Colors.white,
                width: _dragging ? 1.5 : OverlayConstants.cardBorderWidth,
              ),
              // 无 boxShadow：窗口尺寸=把手尺寸，阴影向胶囊外扩散会被窗口
              // 边缘硬裁剪成灰色矩形色块（同面板"透明背景不留 boxShadow"
              // 的既有决策）；层次感由白描边 + 双色胶囊自身承担
            ),
            // 上半区闪电 / 中缝接缝线 / 下半区竖排「闪记」——两个 Expanded
            // 把内容各钉在自己的色半区，接缝天然落在胶囊正中
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: Icon(
                      Icons.bolt,
                      size: OverlayConstants.handleIconSize,
                      // 图标取下半绿同色：落在白半区上与绿半区呼应成对
                      color: OverlayConstants.handleCapsuleBottomColor,
                    ),
                  ),
                ),
                // 中缝接缝线：双色胶囊（药丸）两半的接合处的平面投影，
                // 半透明黑在白/绿两半上都读作凹陷缝
                Container(
                  width: double.infinity,
                  height: 1,
                  color: OverlayConstants.handleSeamColor,
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      // 中文逐字竖排：字符间插入换行，每个汉字独占一行
                      OverlayConstants.handleLabel.characters.join('\n'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: OverlayConstants.handleFontSize,
                        height: 1.25,
                        fontWeight: FontWeight.w500,
                        // 白字落在绿半区（与白描边同语言）
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
