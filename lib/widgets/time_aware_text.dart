import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import '../models/time_entity.dart';
import '../theme/app_theme_extension.dart';

/// 支持时间高亮的富文本组件
class TimeAwareText extends StatefulWidget {
  final String text;
  final List<TimeEntity> timeEntities;
  final TextStyle? baseStyle;
  final Function(TimeEntity)? onTimeTap;

  const TimeAwareText({
    super.key,
    required this.text,
    required this.timeEntities,
    this.baseStyle,
    this.onTimeTap,
  });

  @override
  State<TimeAwareText> createState() => _TimeAwareTextState();
}

class _TimeAwareTextState extends State<TimeAwareText> {
  int? _hoveredIndex;

  @override
  Widget build(BuildContext context) {
    // 如果没有时间实体，显示普通文本
    if (widget.timeEntities.isEmpty) {
      return Text(widget.text, style: widget.baseStyle);
    }

    // 读主题色槽（时间高亮文字 + 背景跟随主题）
    final ext = AppThemeExtension.of(context);

    // 按 start 排序时间实体
    final sortedEntities = List<TimeEntity>.from(widget.timeEntities)
      ..sort((a, b) => a.start.compareTo(b.start));

    // 构建 TextSpan 列表
    final spans = <TextSpan>[];
    int lastEnd = 0;

    for (int i = 0; i < sortedEntities.length; i++) {
      final entity = sortedEntities[i];

      // 添加普通文本（上个时间实体结束到当前时间实体开始）
      if (entity.start > lastEnd) {
        spans.add(TextSpan(
          text: widget.text.substring(lastEnd, entity.start),
          style: widget.baseStyle,
        ));
      }

      // 添加时间高亮文本
      final isHovered = _hoveredIndex == i;
      final gestureRecognizer = TapGestureRecognizer()
        ..onTap = () => _handleTimeTap(entity);

      gestureRecognizer.onTapDown = (_) {
        setState(() => _hoveredIndex = i);
      };
      gestureRecognizer.onTapUp = (_) {
        setState(() => _hoveredIndex = null);
      };
      gestureRecognizer.onTapCancel = () {
        setState(() => _hoveredIndex = null);
      };

      spans.add(TextSpan(
        text: entity.text,
        style: (widget.baseStyle ?? const TextStyle()).copyWith(
          color: ext.timeHighlight,
          fontWeight: FontWeight.bold,
          // hover 时背景往高亮色方向加深 40%，保留原 Colors.blue.shade100 vs shade50 的视觉反馈
          backgroundColor: isHovered
              ? Color.lerp(ext.timeHighlightBg, ext.timeHighlight, 0.4)
              : ext.timeHighlightBg,
          decoration: TextDecoration.underline,
          decorationColor: ext.timeHighlight,
        ),
        recognizer: gestureRecognizer,
      ));

      lastEnd = entity.end;
    }

    // 添加剩余文本
    if (lastEnd < widget.text.length) {
      spans.add(TextSpan(
        text: widget.text.substring(lastEnd),
        style: widget.baseStyle,
      ));
    }

    return Text.rich(
      TextSpan(children: spans),
    );
  }

  void _handleTimeTap(TimeEntity entity) {
    print('点击时间: ${entity.text} -> ${entity.value}');
    widget.onTimeTap?.call(entity);
  }
}
