import '../app_logger.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_theme_extension.dart';

/// 划走方向（水平，组件内绝对方向：left=向左、right=向右）
///
/// - [SwipeDismissDirection.left]（默认）：向左拖划走（主 App 日记页历史
///   方向），单事件右向快滑武装转发回调
/// - [SwipeDismissDirection.right]：向右拖划走（悬浮窗停靠左缘时的镜像
///   方向——归档方向永远朝屏幕内侧），单事件左向快滑武装转发回调
enum SwipeDismissDirection { left, right }

/// 带圆圈闭合动效的侧滑删除组件
///
/// 朝 [dismissDirection] 方向滑动时露出一个圆圈图标，圆圈弧线随滑动进度
/// 逐渐闭合。滑动超过阈值或快速划动时触发删除。
///
/// 使用 GestureDetector 检测水平拖拽，赢得手势竞技场防止父 ListView 上下滚动。与子组件的 tap/longPress 手势兼容。
///
/// 两种宽度模式（[fullWidth]）：
/// - 全宽（默认，主 App 日记列表）：子组件强制铺满屏宽，阈值/划出距离按屏宽
///   算（历史行为，默认参数下与泛化前逐字节等价）
/// - 自适应宽（悬浮窗贴停靠侧自适应卡片用）：Stack 贴合子组件自身宽度不拉宽，
///   阈值 = 子宽 × [dismissThreshold]、划出距离 = 子宽 + 48，图标揭示区钉在
///   子宽划走方向侧（卡片划走后在原位露出）
class SwipeDismissCard extends StatefulWidget {
  final Widget child;
  final VoidCallback onDismissed;
  final IconData icon;
  final Color iconColor;
  final Color circleColor;

  /// 触发划走的拖动距离占卡片宽度的比例。全宽模式下卡片宽=屏宽，
  /// 与历史"占屏宽比例"语义一致
  final double dismissThreshold;

  /// 全宽模式开关（见类注释），默认 true 保持主 App 历史行为
  final bool fullWidth;

  /// 回弹动画时长/曲线：未达阈值松手时卡片弹回原位。悬浮窗传
  /// OverlayConstants.animationDuration(200ms)+easeOutCubic 对齐卡片级补间
  /// 节奏；默认 250ms+easeOutCubic 为主 App 历史值
  final Duration springDuration;
  final Curve springCurve;

  /// 划走动画时长/曲线：达阈值松手后卡片滑出。悬浮窗传
  /// OverlayConstants.panelSlideDuration(240ms)+easeInCubic 对齐面板收起滑出
  /// 的加速推出感；默认 250ms+easeIn 为主 App 历史值
  final Duration dismissDuration;
  final Curve dismissCurve;

  /// 是否显示拖拽揭示图标（右侧圆圈进度弧线 + 图标，默认 true = 主 App
  /// 日记页历史行为）。悬浮窗传 false：不要揭示效果，只保留卡片跟手滑动与
  /// 阈值/快甩触发（悬浮窗小卡片上转圈+图标显得多余——用户定夺）
  final bool showIcon;

  /// 手势开关（默认 true）。false 时不注册水平拖拽回调（本组件退出手势
  /// 竞技场，拖拽事件落回父层）。悬浮窗编辑态传 false：滑动降级为只收键盘
  ///（由父层面板手势负责），与面板朝停靠边缘滑收起的编辑态降级规则一致。
  /// 切换只更新回调不改变树结构，子组件 State 不丢失
  final bool enabled;

  /// 划走方向（默认 left = 主 App 历史左滑）。悬浮窗停靠左缘时传 right：
  /// 归档/删除改为右滑（朝屏幕内侧），镜像语义见 [SwipeDismissDirection]
  final SwipeDismissDirection dismissDirection;

  /// 反方向快滑转发回调（默认 null）。朝划走方向相反侧快速滑动（单次位移
  /// 事件超过 [onSwipeCollapseThreshold]，与面板朝停靠边缘滑收起同款
  /// "单事件超阈值"判定）松手时触发。悬浮窗必须转发：卡片内水平拖拽在
  /// 手势竞技场赢过面板层收起手势，不转发则「卡片上朝停靠边缘快滑收起
  /// 悬浮窗」失效
  final VoidCallback? onSwipeCollapse;

  /// [onSwipeCollapse] 的单次位移事件阈值（逻辑 dp）。悬浮窗传
  /// OverlayConstants.edgeSwipeThreshold 与面板手势对齐；默认 4.0 与其同值
  final double onSwipeCollapseThreshold;

  const SwipeDismissCard({
    super.key,
    required this.child,
    required this.onDismissed,
    this.icon = Icons.archive,
    this.iconColor = Colors.grey,
    this.circleColor = Colors.grey,
    this.dismissThreshold = 0.50,
    this.fullWidth = true,
    this.springDuration = const Duration(milliseconds: 250),
    this.springCurve = Curves.easeOutCubic,
    this.dismissDuration = const Duration(milliseconds: 250),
    this.dismissCurve = Curves.easeIn,
    this.showIcon = true,
    this.enabled = true,
    this.dismissDirection = SwipeDismissDirection.left,
    this.onSwipeCollapse,
    this.onSwipeCollapseThreshold = 4.0,
  });

  /// 划走方向是否向右（镜像分支的判定便捷位）
  bool get _dismissesRight => dismissDirection == SwipeDismissDirection.right;

  @override
  State<SwipeDismissCard> createState() => _SwipeDismissCardState();
}

class _SwipeDismissCardState extends State<SwipeDismissCard>
    with SingleTickerProviderStateMixin {
  double _dragOffset = 0;
  bool _isDismissing = false;
  late AnimationController _springController;
  late Animation<double> _springAnimation;

  // 速度追踪
  int _lastTime = 0;
  double _velocityX = 0;
  bool _dismissCompleted = false;

  // 反方向快滑转发：本次拖拽中出现过超阈值的"划走方向相反"单事件即武装，
  // 松手触发（划走方向 left = 右滑武装 / right = 左滑武装）
  bool _swipeCollapseArmed = false;

  // 拖拽开始时捕获的卡片盒宽度（布局完成后读本组件渲染对象——Stack 贴合
  // 非 Positioned 子组件，其宽 = 卡片盒宽；全宽模式下=屏宽）。整个拖拽会话
  // 复用，避免 build 期间访问渲染对象；0 = 未拖拽，计算退回屏宽兜底
  double _dragCardWidth = 0;

  @override
  void initState() {
    super.initState();
    _springController = AnimationController(
      vsync: this,
      duration: widget.springDuration,
    );
    _springController.addListener(_onSpringUpdate);
  }

  @override
  void dispose() {
    _springController.dispose();
    super.dispose();
  }

  void _onSpringUpdate() {
    setState(() {
      _dragOffset = _springAnimation.value;
    });
  }

  /// 拖拽会话内生效的卡片宽度（实测值优先，屏宽兜底）
  double get _effectiveCardWidth {
    if (_dragCardWidth > 0) return _dragCardWidth;
    return MediaQuery.of(context).size.width;
  }

  double get _progress {
    if (!mounted) return 0;
    final threshold = _effectiveCardWidth * widget.dismissThreshold;
    return (_dragOffset.abs() / threshold).clamp(0.0, 1.0);
  }

  /// 图标颜色：进度 >60% 时从基础色渐变到柔红
  ///
  /// dangerColor 由调用方传入（来自 [AppThemeExtension.dangerAccent]），
  /// 避免本方法内依赖 [BuildContext]，保持纯函数特性。
  Color _lerpIconColor(double progress, Color baseColor, Color dangerColor) {
    if (progress < 0.6) return baseColor;
    final t = ((progress - 0.6) / 0.4).clamp(0.0, 1.0);
    return Color.lerp(baseColor, dangerColor, t)!;
  }

  /// 读本组件渲染对象宽度（手势回调时机在布局后，可安全读取）
  double _measureCardWidth() {
    if (!mounted) return 0;
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize && box.size.width > 0) {
      return box.size.width;
    }
    return 0;
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    if (_isDismissing) return;
    _dismissCompleted = false;
    _swipeCollapseArmed = false;
    _dragCardWidth = _measureCardWidth();
    _springController.stop();
    _lastTime =
        details.sourceTimeStamp?.inMilliseconds ??
        DateTime.now().millisecondsSinceEpoch;
    _velocityX = 0;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (_isDismissing) return;

    final delta = details.delta.dx;
    final now =
        details.sourceTimeStamp?.inMilliseconds ??
        DateTime.now().millisecondsSinceEpoch;

    if (now > _lastTime) {
      _velocityX = delta / (now - _lastTime) * 1000;
    }

    _lastTime = now;

    // 反方向快滑转发武装：单次位移事件超阈值即算（与面板朝停靠边缘滑收起
    // 同款判定——快速滑动才会触发，慢拖不误触）。划走 left 时反方向 = 右
    //（delta>0），划走 right 时反方向 = 左（delta<0）
    if (widget.onSwipeCollapse != null) {
      final bool armsForward = widget._dismissesRight
          ? delta < -widget.onSwipeCollapseThreshold
          : delta > widget.onSwipeCollapseThreshold;
      if (armsForward) _swipeCollapseArmed = true;
    }

    final cardWidth = _effectiveCardWidth;
    // 拖跟手最大位移：全宽=0.6 屏宽（历史值）；自适应宽=卡片盒宽+48（划过
    // 卡片盒即被裁剪不可见，余量给进度环走满后的"死区行程"）
    final maxDrag = widget.fullWidth ? cardWidth * 0.6 : cardWidth + 48;

    setState(() {
      _dragOffset += delta;
      // 划走方向的位移才累计（符号随方向镜像），反方向一律弹回 0
      if (widget._dismissesRight) {
        if (_dragOffset < 0) _dragOffset = 0;
        if (_dragOffset > maxDrag) _dragOffset = maxDrag;
      } else {
        if (_dragOffset > 0) _dragOffset = 0;
        if (_dragOffset < -maxDrag) _dragOffset = -maxDrag;
      }
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_isDismissing) return;

    final cardWidth = _effectiveCardWidth;
    final threshold = cardWidth * widget.dismissThreshold;
    // 快甩速度按划走方向取号（left 划走看负速、right 划走看正速）
    final bool flungAway = widget._dismissesRight
        ? _velocityX > 300
        : _velocityX < -300;
    final shouldDismiss = _dragOffset.abs() >= threshold || flungAway;

    log(
      '[SwipeDismissCard] dragEnd: offset=${_dragOffset.toStringAsFixed(1)}, '
      'threshold=${threshold.toStringAsFixed(1)}, '
      'velocity=${_velocityX.toStringAsFixed(1)}, '
      'shouldDismiss=$shouldDismiss',
    );

    // 反方向快滑转发优先于弹回（松手即收起面板，卡片原地弹回与面板滑出并行无冲突）
    if (_swipeCollapseArmed && widget.onSwipeCollapse != null) {
      _swipeCollapseArmed = false;
      widget.onSwipeCollapse!();
    }

    if (shouldDismiss) {
      _dismiss();
    } else {
      _springBack();
    }
  }

  /// 拖拽被系统打断（无 End 回调，如父层滚动抢占）：弹回原位防卡片停在半途
  /// + 清快滑武装
  void _onHorizontalDragCancel() {
    _swipeCollapseArmed = false;
    if (_isDismissing || _dragOffset == 0) return;
    _springBack();
  }

  void _springBack() {
    _springAnimation = Tween<double>(begin: _dragOffset, end: 0).animate(
      CurvedAnimation(parent: _springController, curve: widget.springCurve),
    );
    _springController
      ..duration = widget.springDuration
      ..value = 0
      ..forward();
  }

  void _dismiss() {
    _isDismissing = true;
    final cardWidth = _effectiveCardWidth;

    log('[SwipeDismissCard] dismiss started');

    // 划走终点（符号随方向镜像）：全宽=整屏宽（历史行为）；自适应宽=卡片盒
    // 宽+48（被 Stack 裁剪=完全不可见）
    final double end = widget._dismissesRight
        ? (widget.fullWidth ? cardWidth : cardWidth + 48)
        : (widget.fullWidth ? -cardWidth : -(cardWidth + 48));
    _springAnimation = Tween<double>(begin: _dragOffset, end: end).animate(
      CurvedAnimation(parent: _springController, curve: widget.dismissCurve),
    );
    _springController
      ..duration = widget.dismissDuration
      ..value = 0;

    _springController.forward().then((_) {
      log(
        '[SwipeDismissCard] dismiss animation done → 设置 _dismissCompleted=true → 调用 onDismissed',
      );
      if (mounted) {
        setState(() {
          _dismissCompleted = true;
        });
      }
      widget.onDismissed();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissCompleted) {
      log(
        '[SwipeDismissCard] build: _dismissCompleted=true → SizedBox.shrink()',
      );
      return const SizedBox.shrink();
    }
    final progress = _progress;
    // 读一次主题色槽，避免下方 _lerpIconColor 内重复查找 Theme
    final dangerColor = AppThemeExtension.of(context).dangerAccent;

    return GestureDetector(
      // enabled=false 时回调置 null：本组件退出手势竞技场（拖拽落回父层），
      // 且只更新回调不改变树结构，子组件 State 不丢失
      onHorizontalDragStart: widget.enabled ? _onHorizontalDragStart : null,
      onHorizontalDragUpdate: widget.enabled ? _onHorizontalDragUpdate : null,
      onHorizontalDragEnd: widget.enabled ? _onHorizontalDragEnd : null,
      onHorizontalDragCancel: widget.enabled ? _onHorizontalDragCancel : null,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          // 背景：圆圈 + 图标（只在拖拽时显示；showIcon=false 整层不渲染）。
          // 钉在划走方向侧（划走后原位露出）：向左划走钉右侧（全宽 right:24
          // 历史位置 / 自适应宽 right:4），向右划走镜像钉左侧
          if (widget.showIcon && _dragOffset.abs() > 5)
            Positioned(
              right: !widget._dismissesRight
                  ? (widget.fullWidth ? 24 : 4)
                  : null,
              left: widget._dismissesRight ? 4 : null,
              top: 0,
              bottom: 0,
              width: 44,
              child: CustomPaint(
                painter: _CircleProgressPainter(
                  progress: progress,
                  color: widget.circleColor,
                  strokeWidth: 2.5,
                ),
                size: const Size(44, 44),
                child: Center(
                  child: Icon(
                    widget.icon,
                    size: 22,
                    color: _lerpIconColor(
                      progress,
                      widget.iconColor,
                      dangerColor,
                    ),
                  ),
                ),
              ),
            ),
          // 前景：卡片（全宽强制铺满屏宽；自适应宽保持子组件自身宽度）
          Transform.translate(
            offset: Offset(_dragOffset, 0),
            child: widget.fullWidth
                ? SizedBox(
                    width: MediaQuery.of(context).size.width,
                    child: widget.child,
                  )
                : widget.child,
          ),
        ],
      ),
    );
  }
}

/// 圆圈进度画笔
///
/// progress 从 0→1 时，弧线从顶部顺时针逐渐闭合为完整圆圈。
class _CircleProgressPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double strokeWidth;

  _CircleProgressPainter({
    required this.progress,
    required this.color,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;

    // 底层淡灰圆圈（完整）
    final bgPaint = Paint()
      ..color = color.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawCircle(center, radius, bgPaint);

    // 进度弧线
    if (progress > 0) {
      final fgPaint = Paint()
        ..color = color.withValues(alpha: 0.3 + progress * 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;

      // 从顶部（-90°）顺时针画弧
      final startAngle = -math.pi / 2;
      final sweepAngle = 2 * math.pi * progress;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle,
        false,
        fgPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_CircleProgressPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}
