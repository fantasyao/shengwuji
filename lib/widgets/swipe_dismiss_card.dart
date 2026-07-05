import '../app_logger.dart';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_theme_extension.dart';

/// 带圆圈闭合动效的侧滑删除组件
///
/// 左滑时，右侧露出一个圆圈图标，圆圈弧线随滑动进度逐渐闭合。
/// 滑动超过阈值或快速划动时触发删除。
///
/// 使用 GestureDetector 检测水平拖拽，赢得手势竞技场防止父 ListView 上下滚动。与子组件的 tap/longPress 手势兼容。
class SwipeDismissCard extends StatefulWidget {
  final Widget child;
  final VoidCallback onDismissed;
  final IconData icon;
  final Color iconColor;
  final Color circleColor;

  /// 触发删除的滑动距离占屏幕宽度的比例
  final double dismissThreshold;

  const SwipeDismissCard({
    super.key,
    required this.child,
    required this.onDismissed,
    this.icon = Icons.archive,
    this.iconColor = Colors.grey,
    this.circleColor = Colors.grey,
    this.dismissThreshold = 0.50,
  });

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
  double _lastX = 0;
  int _lastTime = 0;
  double _velocityX = 0;
  bool _dismissCompleted = false;

  @override
  void initState() {
    super.initState();
    _springController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
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

  double get _progress {
    if (!mounted) return 0;
    final screenWidth = MediaQuery.of(context).size.width;
    final threshold = screenWidth * widget.dismissThreshold;
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

  void _onHorizontalDragStart(DragStartDetails details) {
    if (_isDismissing) return;
    _dismissCompleted = false;
    _springController.stop();
    _lastX = details.globalPosition.dx;
    _lastTime = details.sourceTimeStamp?.inMilliseconds ?? DateTime.now().millisecondsSinceEpoch;
    _velocityX = 0;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (_isDismissing) return;

    final delta = details.delta.dx;
    final now = details.sourceTimeStamp?.inMilliseconds ?? DateTime.now().millisecondsSinceEpoch;

    if (now > _lastTime) {
      _velocityX = delta / (now - _lastTime) * 1000;
    }

    _lastX = details.globalPosition.dx;
    _lastTime = now;

    setState(() {
      _dragOffset += delta;
      if (_dragOffset > 0) _dragOffset = 0;
      final maxDrag = MediaQuery.of(context).size.width * 0.6;
      if (_dragOffset < -maxDrag) _dragOffset = -maxDrag;
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_isDismissing) return;

    final screenWidth = MediaQuery.of(context).size.width;
    final threshold = screenWidth * widget.dismissThreshold;
    final shouldDismiss =
        _dragOffset.abs() >= threshold || _velocityX < -300;

    log('[SwipeDismissCard] dragEnd: offset=${_dragOffset.toStringAsFixed(1)}, '
        'threshold=${threshold.toStringAsFixed(1)}, '
        'velocity=${_velocityX.toStringAsFixed(1)}, '
        'shouldDismiss=$shouldDismiss');

    if (shouldDismiss) {
      _dismiss();
    } else {
      _springBack();
    }
  }

  void _springBack() {
    _springAnimation = Tween<double>(
      begin: _dragOffset,
      end: 0,
    ).animate(CurvedAnimation(
      parent: _springController,
      curve: Curves.easeOutCubic,
    ));
    _springController.value = 0;
    _springController.forward();
  }

  void _dismiss() {
    _isDismissing = true;
    final screenWidth = MediaQuery.of(context).size.width;

    log('[SwipeDismissCard] dismiss started');

    _springAnimation = Tween<double>(
      begin: _dragOffset,
      end: -screenWidth,
    ).animate(CurvedAnimation(
      parent: _springController,
      curve: Curves.easeIn,
    ));
    _springController.value = 0;

    _springController.forward().then((_) {
      log('[SwipeDismissCard] dismiss animation done → 设置 _dismissCompleted=true → 调用 onDismissed');
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
      log('[SwipeDismissCard] build: _dismissCompleted=true → SizedBox.shrink()');
      return const SizedBox.shrink();
    }
    final progress = _progress;
    final screenWidth = MediaQuery.of(context).size.width;
    // 读一次主题色槽，避免下方 _lerpIconColor 内重复查找 Theme
    final dangerColor = AppThemeExtension.of(context).dangerAccent;

    return GestureDetector(
      onHorizontalDragStart: _onHorizontalDragStart,
      onHorizontalDragUpdate: _onHorizontalDragUpdate,
      onHorizontalDragEnd: _onHorizontalDragEnd,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          // 背景：圆圈 + 图标（只在拖拽时显示）
          if (_dragOffset < -5)
            Positioned(
              right: 24,
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
                    color: _lerpIconColor(progress, widget.iconColor, dangerColor),
                  ),
                ),
              ),
            ),
          // 前景：卡片
          Transform.translate(
            offset: Offset(_dragOffset, 0),
            child: SizedBox(
              width: screenWidth,
              child: widget.child,
            ),
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
