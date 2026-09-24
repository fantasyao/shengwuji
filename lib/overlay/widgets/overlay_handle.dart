import 'package:flutter/material.dart';
import '../overlay_constants.dart';

/// 收起态边缘把手（闪记双色胶囊）
///
/// 视觉：药丸式双色胶囊——上半白 / 下半绿、中间一道接缝横线（配色见
/// OverlayConstants handleCapsule*），外围细白描边与笔记卡片的
/// cardBorderWidth 白描边同语言；静置态整体稍透明（handleRestingOpacity）。
/// 胶囊本体比窗口小一圈（按把手大小档位内缩，handleInsetXxxOf 派生）：窗口
/// 28×88 是原生硬编码副本与语音胶囊 84<88 不变量的联动值不动，触控面积也不
/// 变，仅视觉缩小；文字仅标准档显示（75%/50% 档太挤），拟物胶囊💊主题
/// （HandleTheme.pill3d）纯造型无图标无文字、叠高光/暗部两层出立体感
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
    this.sizePercent = OverlayConstants.handleSizeDefaultPercent,
    this.theme = HandleTheme.duo,
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

  /// 把手大小档位（百分比）：胶囊本体视觉缩放，窗口 28×88 与触控面积不变
  ///（设置页「把手大小」三档 100/75/50，读取方 OverlayHome 传入；75%/50% 档
  /// 不显示竖排文字——真机反馈小胶囊文字太挤，仅标准档保留）
  final int sizePercent;

  /// 把手主题（皮肤）：色值与内容显隐见 [HandleThemeVisuals]；拟物胶囊💊
  /// 另叠高光条 + 下半暗部渐变（立体感），纯造型无图标无文字
  final HandleTheme theme;

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
    // 档位派生值集中算一次：胶囊视觉尺寸 = 基准 × 档位，窗口恒 28×88 只变内缩
    final capsuleWidth = OverlayConstants.handleCapsuleWidth(widget.sizePercent);
    final capsuleHeight = OverlayConstants.handleCapsuleHeight(
      widget.sizePercent,
    );
    final mini = OverlayConstants.isMiniHandleSize(widget.sizePercent);
    final theme = widget.theme;
    final showLabel = OverlayConstants.handleShowsLabel(widget.sizePercent, theme);
    return GestureDetector(
      // ⚠️ 必须 opaque 整窗命中（同 _buildEdgeLine 竖线的既有做法）：默认
      // deferToChild 时命中区=有 decoration 的胶囊本体，胶囊外的透明内缩环
      // 不可点——档位缩小后环越宽（75% 档纵向空隙 14dp），用户点视觉胶囊
      // 附近的透明区全部落空，感知为"触发区变小/有空隙唤不出"（真机反馈
      // 2026-09-22）。opaque 后触控区=整窗 28×88，兑现"视觉缩、触控不缩"
      behavior: HitTestBehavior.opaque,
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
      // 窗口（28×88）不变，胶囊本体按档位向内缩：视觉变小但触控面积不丢
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: OverlayConstants.handleInsetHorizontalOf(
            widget.sizePercent,
          ),
          vertical: OverlayConstants.handleInsetVerticalOf(widget.sizePercent),
        ),
        // 拖动态满不透明（静置稍透明），沿用「拖动 = 满不透明」分层语言
        child: AnimatedOpacity(
          duration: OverlayConstants.animationDuration,
          opacity: _dragging ? 1.0 : OverlayConstants.handleRestingOpacity,
          child: AnimatedContainer(
            duration: OverlayConstants.animationDuration,
            width: capsuleWidth,
            height: capsuleHeight,
            decoration: BoxDecoration(
              // 药丸双色：上半 / 下半在胶囊正中硬切（hard-stop 渐变，
              // BoxDecoration 的 borderRadius 自动裁出胶囊轮廓，无需 ClipRRect）
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  theme.capsuleTopColor,
                  theme.capsuleTopColor,
                  theme.capsuleBottomColor,
                  theme.capsuleBottomColor,
                ],
                stops: const [0.0, 0.5, 0.5, 1.0],
              ),
              // 全圆角胶囊：半径 = 胶囊宽度一半，随档位缩放自动适配
              borderRadius: BorderRadius.circular(capsuleWidth / 2),
              // 细白描边与笔记卡片同款（cardBorderWidth），静置态常驻；
              // 拖动态加粗到 1.5 作为拖动反馈（描边画在胶囊内侧不溢出窗口）
              border: Border.all(
                color: Colors.white,
                width: _dragging ? 1.5 : OverlayConstants.cardBorderWidth,
              ),
              // 无 boxShadow：窗口尺寸=把手尺寸，阴影向胶囊外扩散会被窗口
              // 边缘硬裁剪成灰色矩形色块（同面板"透明背景不留 boxShadow"
              // 的既有决策）；层次感由白描边 + 主题色胶囊自身承担
            ),
            // 拟物胶囊💊：纯造型（无图标无文字）——中缝分界 + 下半暗部渐变
            //（50% 起加深、上半白不受影响）+ 左侧高光条（圆柱反光），三层叠
            // 出立体感；其余主题走「图标/中缝/竖排文字」三段 Column
            child: theme.isPill3d
                ? Stack(
                    children: [
                      Positioned(
                        left: 0,
                        right: 0,
                        top: capsuleHeight / 2 - 0.5,
                        child: Container(
                          height: 1,
                          color: OverlayConstants.handleSeamColor,
                        ),
                      ),
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius:
                                BorderRadius.circular(capsuleWidth / 2),
                            gradient: const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Color(0x00000000),
                                Color(0x14000000),
                                Color(0x33000000),
                              ],
                              stops: [0.0, 0.5, 1.0],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: capsuleWidth * 0.14,
                        top: capsuleHeight * 0.07,
                        width: capsuleWidth * 0.2,
                        height: capsuleHeight * 0.6,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius:
                                BorderRadius.circular(capsuleWidth * 0.1),
                            gradient: const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0xA6FFFFFF), Color(0x00FFFFFF)],
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      Expanded(
                        child: Center(
                          child: theme.showsIcon
                              ? Icon(
                                  Icons.bolt,
                                  size: mini
                                      ? OverlayConstants.handleIconSizeMini
                                      : OverlayConstants.handleIconSize,
                                  color: theme.iconColor,
                                )
                              : const SizedBox.shrink(),
                        ),
                      ),
                      // 中缝接缝线：双色胶囊（药丸）两半的接合处的平面投影，
                      // 半透明黑在两半上都读作凹陷缝
                      Container(
                        width: double.infinity,
                        height: 1,
                        color: OverlayConstants.handleSeamColor,
                      ),
                      Expanded(
                        child: Center(
                          // 75%/50% 档不显示文字（真机反馈小胶囊太挤）、
                          // 三段结构与中缝位置保持不变（视觉语言连续）
                          child: showLabel
                              ? Text(
                                  // 中文逐字竖排：字符间插入换行，每个汉字独占一行
                                  OverlayConstants.handleLabel.characters
                                      .join('\n'),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: OverlayConstants.handleFontSize,
                                    height: 1.25,
                                    fontWeight: FontWeight.w500,
                                    color: theme.labelColor,
                                  ),
                                )
                              : const SizedBox.shrink(),
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
