import '../app_logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import '../models/time_entity.dart';
import '../theme/app_theme_extension.dart';
import '../utils/link_text.dart';

/// 支持时间高亮 + http(s) 链接的富文本组件
///
/// 时间实体与链接共用一套 TextSpan 切段：时间高亮点击 = 设闹钟，链接点击 =
/// 系统浏览器打开（[onLinkTap]）。两段区间重叠时链接优先——URL 里常带日期
///（`https://example.com/2026/10/27`），不能让时间解析把网址里的日期变成
/// 闹钟入口，点整段网址都应跳浏览器。
class TimeAwareText extends StatefulWidget {
  final String text;
  final List<TimeEntity> timeEntities;
  final TextStyle? baseStyle;
  final Function(TimeEntity)? onTimeTap;

  /// 链接点击回调；null 时不渲染链接下划线（避免「像链接但点不动」）
  final ValueChanged<Uri>? onLinkTap;

  /// 可选行数上限（长文折叠用）；⚠️ 与 overflow 必须成对切换——
  /// overflow:ellipsis 配 maxLines:null 会被 TextPainter 按单行渲染
  final int? maxLines;
  final TextOverflow? overflow;

  const TimeAwareText({
    super.key,
    required this.text,
    required this.timeEntities,
    this.baseStyle,
    this.onTimeTap,
    this.onLinkTap,
    this.maxLines,
    this.overflow,
  });

  @override
  State<TimeAwareText> createState() => _TimeAwareTextState();
}

class _TimeAwareTextState extends State<TimeAwareText> {
  TimeEntity? _hoveredEntity;

  @override
  Widget build(BuildContext context) {
    // 无时间实体、无链接（或未给链接回调）：显示普通文本
    final links = widget.onLinkTap == null
        ? const <TextLink>[]
        : findTextLinks(widget.text);
    if (widget.timeEntities.isEmpty && links.isEmpty) {
      return Text(
        widget.text,
        style: widget.baseStyle,
        maxLines: widget.maxLines,
        overflow: widget.overflow,
      );
    }

    // 读主题色槽（时间高亮文字 + 链接色跟随时间高亮）
    final ext = AppThemeExtension.of(context);

    // 按 start 排序时间实体；落在链接区间内的时间实体整段让位给链接
    final sortedEntities = List<TimeEntity>.from(widget.timeEntities)
      ..sort((a, b) => a.start.compareTo(b.start));
    final timeCandidates = sortedEntities.where((entity) {
      return !links.any(
        (link) => entity.start < link.end && entity.end > link.start,
      );
    }).toList();

    // 时间/链接区间合并排序后逐段渲染
    final ranges = <({int start, int end, TimeEntity? time, TextLink? link})>[
      for (final entity in timeCandidates)
        (start: entity.start, end: entity.end, time: entity, link: null),
      for (final link in links)
        (start: link.start, end: link.end, time: null, link: link),
    ]..sort((a, b) => a.start.compareTo(b.start));

    // 构建 TextSpan 列表
    final spans = <TextSpan>[];
    int lastEnd = 0;

    for (final range in ranges) {
      // 防御：区间重叠（脏实体）时跳过，避免重复输出同一段原文
      if (range.start < lastEnd) continue;

      // 添加普通文本（上个区间结束到当前区间开始）
      if (range.start > lastEnd) {
        spans.add(
          TextSpan(
            text: widget.text.substring(lastEnd, range.start),
            style: widget.baseStyle,
          ),
        );
      }

      final entity = range.time;
      final link = range.link;
      if (link != null) {
        // 链接：跟随主题的蓝色下划线；归档卡叠加删除线
        final linkStyle = (widget.baseStyle ?? const TextStyle()).copyWith(
          color: ext.linkColor,
          decoration: combineUnderline(widget.baseStyle?.decoration),
          decorationColor: ext.linkColor,
        );
        final recognizer = TapGestureRecognizer()
          ..onTap = () => widget.onLinkTap?.call(Uri.parse(link.url));
        spans.add(
          TextSpan(
            text: link.raw,
            style: linkStyle,
            recognizer: recognizer,
          ),
        );
      } else if (entity != null) {
        // 添加时间高亮文本
        final isHovered = identical(_hoveredEntity, entity);
        final gestureRecognizer = TapGestureRecognizer()
          ..onTap = () => _handleTimeTap(entity);

        gestureRecognizer.onTapDown = (_) {
          setState(() => _hoveredEntity = entity);
        };
        gestureRecognizer.onTapUp = (_) {
          setState(() => _hoveredEntity = null);
        };
        gestureRecognizer.onTapCancel = () {
          setState(() => _hoveredEntity = null);
        };

        spans.add(
          TextSpan(
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
          ),
        );
      }

      lastEnd = range.end;
    }

    // 添加剩余文本
    if (lastEnd < widget.text.length) {
      spans.add(
        TextSpan(text: widget.text.substring(lastEnd), style: widget.baseStyle),
      );
    }

    return Text.rich(
      TextSpan(children: spans),
      maxLines: widget.maxLines,
      overflow: widget.overflow,
    );
  }

  void _handleTimeTap(TimeEntity entity) {
    log('点击时间: ${entity.text} -> ${entity.value}');
    widget.onTimeTap?.call(entity);
  }
}
