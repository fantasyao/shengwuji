import 'package:flutter/material.dart';
import '../theme/app_theme_extension.dart';

/// 日记卡片底部：播放/暂停 + 响度波纹进度条。
///
/// 设计要点：
/// - **不实时 seek**：audioplayers 在 Android 上 seek() 有 50-200ms 延迟，
///   实时拖动会队列堆积、爆音、游标抖动。改为「拖动期间本地预览（_dragFraction）
///   + 松手/单击才调一次 onSeek」。
/// - **ValueListenableBuilder 配合**：父级传入的 position/duration/isPlaying 来自
///   页面级 `ValueNotifier<PlaybackState>`，~5Hz 高频更新只走 notifier，不走 setState。
///   本组件内部除了拖动局部 setState，不会因 position 流引发重建。
/// - **CustomPainter.shouldRepaint 精细比较**：identical(peaks) + playedFraction + 颜色。
///   非活动卡（isActive=false）position 始终 0 → fraction 0 → shouldRepaint 返回 false。
/// - **duration==0 时禁手势**：未知总时长无法 seek，但保留 onTogglePlay（仍可点播放）。
class DiaryPlayBar extends StatefulWidget {
  final bool isActive;
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final List<double>? peaks;
  final ValueChanged<Duration>? onSeek;
  final VoidCallback? onTogglePlay;
  final VoidCallback? onHapticTick;

  const DiaryPlayBar({
    super.key,
    required this.isActive,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.peaks,
    required this.onSeek,
    required this.onTogglePlay,
    required this.onHapticTick,
  });

  @override
  State<DiaryPlayBar> createState() => _DiaryPlayBarState();
}

class _DiaryPlayBarState extends State<DiaryPlayBar> {
  bool _isDragging = false;
  double _dragFraction = 0.0; // 拖动期间用这个，忽略父级 position

  double get _effectiveFraction {
    final totalMs = widget.duration.inMilliseconds;
    if (totalMs <= 0) return 0.0;
    if (_isDragging) return _dragFraction;
    return (widget.position.inMilliseconds / totalMs).clamp(0.0, 1.0);
  }

  void _updateDrag(Offset localPos, double width) {
    if (width <= 0) return;
    setState(() {
      _dragFraction = (localPos.dx / width).clamp(0.0, 1.0);
    });
  }

  bool get _gesturesEnabled => widget.duration.inMilliseconds > 0;

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    // LayoutBuilder：拿整行宽度以决定窄屏（maxWidth<=180）隐藏尾部时间文本
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          final showText = constraints.maxWidth > 180;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 小播放/暂停图标（取代原圆形大按钮）
              SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  icon: Icon(
                    widget.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    color: ext.primary,
                  ),
                  onPressed: widget.onTogglePlay,
                ),
              ),
              const SizedBox(width: 6),
              // 波纹 + 进度区域
              Expanded(
                child: SizedBox(
                  height: 24,
                  child: LayoutBuilder(
                    builder: (ctx, barConstraints) {
                      final barWidth = barConstraints.maxWidth;
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragStart: _gesturesEnabled
                            ? (d) {
                                setState(() => _isDragging = true);
                                _updateDrag(d.localPosition, barWidth);
                              }
                            : null,
                        onHorizontalDragUpdate: _gesturesEnabled
                            ? (d) => _updateDrag(d.localPosition, barWidth)
                            : null,
                        onHorizontalDragEnd: _gesturesEnabled
                            ? (_) {
                                final totalMs = widget.duration.inMilliseconds;
                                final pos = Duration(
                                  milliseconds: (_dragFraction * totalMs)
                                      .round(),
                                );
                                setState(() => _isDragging = false);
                                widget.onSeek?.call(pos);
                                widget.onHapticTick?.call();
                              }
                            : null,
                        onTapUp: _gesturesEnabled
                            ? (d) {
                                if (barWidth <= 0) return;
                                final frac = (d.localPosition.dx / barWidth)
                                    .clamp(0.0, 1.0);
                                final totalMs = widget.duration.inMilliseconds;
                                final pos = Duration(
                                  milliseconds: (frac * totalMs).round(),
                                );
                                widget.onSeek?.call(pos);
                                widget.onHapticTick?.call();
                              }
                            : null,
                        child: CustomPaint(
                          painter: _WaveformPainter(
                            peaks: widget.peaks,
                            playedFraction: _effectiveFraction,
                            primaryColor: ext.primary,
                            hintColor: ext.textHint,
                            cursorColor: ext.primaryDark,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              if (showText) ...[
                const SizedBox(width: 6),
                Text(
                  _formatPos(widget.isActive ? widget.position : Duration.zero),
                  style: TextStyle(fontSize: 11, color: ext.textHint),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// m:ss 时间格式化
String _formatPos(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds.remainder(60);
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// 波纹 + 进度绘制器。
///
/// 分层（顺序决定 z-order）：
/// 1. 未播放柱：textHint × alpha 0.35
/// 2. 已播放柱（下标 < playedFraction×n）：primary 覆盖
/// 3. 游标竖线（1.5dp 宽）：primaryDark
///
/// **静态**：不做浮动动画，避免与 5Hz position 流叠加引起频繁重绘。
class _WaveformPainter extends CustomPainter {
  final List<double>? peaks;
  final double playedFraction;
  final Color primaryColor;
  final Color hintColor;
  final Color cursorColor;

  _WaveformPainter({
    required this.peaks,
    required this.playedFraction,
    required this.primaryColor,
    required this.hintColor,
    required this.cursorColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;
    final midY = h / 2;
    final peaksList = peaks;
    final n = peaksList?.length ?? 0;
    final frac = playedFraction.clamp(0.0, 1.0);

    if (n == 0) {
      // 无波纹数据：纯色进度条（背景 hint + 已播放 primary + 游标）
      final bgPaint = Paint()..color = hintColor.withValues(alpha: 0.35);
      _drawBar(canvas, Rect.fromLTWH(0, midY - 1.5, w, 3), bgPaint);
      final playedW = w * frac;
      if (playedW > 0) {
        final fgPaint = Paint()..color = primaryColor;
        _drawBar(canvas, Rect.fromLTWH(0, midY - 1.5, playedW, 3), fgPaint);
      }
      _drawCursor(canvas, w * frac, midY);
      return;
    }

    // 每柱宽度（含 1dp 间隙）
    const gap = 1.0;
    final barW = (w - gap * (n - 1)) / n;
    if (barW <= 0) return;
    final playedCount = (frac * n).round();

    final bgPaint = Paint()..color = hintColor.withValues(alpha: 0.35);
    final fgPaint = Paint()..color = primaryColor;
    for (int i = 0; i < n; i++) {
      final x = i * (barW + gap);
      final peak = peaksList![i];
      final barH = (peak * h).clamp(1.0, h);
      final rect = Rect.fromLTWH(x, midY - barH / 2, barW, barH);
      canvas.drawRect(rect, i < playedCount ? fgPaint : bgPaint);
    }

    _drawCursor(canvas, w * frac, midY);
  }

  void _drawBar(Canvas canvas, Rect rect, Paint paint) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(1.5)),
      paint,
    );
  }

  void _drawCursor(Canvas canvas, double x, double midY) {
    final cursorPaint = Paint()..color = cursorColor;
    // 1.5dp 宽 × 12dp 高的竖线，居中于 midY
    canvas.drawRect(Rect.fromLTWH(x - 0.75, midY - 6, 1.5, 12), cursorPaint);
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter old) =>
      !identical(old.peaks, peaks) ||
      old.playedFraction != playedFraction ||
      old.primaryColor != primaryColor ||
      old.hintColor != hintColor ||
      old.cursorColor != cursorColor;
}
