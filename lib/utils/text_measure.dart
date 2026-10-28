import 'package:flutter/material.dart';

/// 实测文本在指定宽度下按 [maxLines] 截断后是否溢出。
///
/// 用途：日记卡片长文折叠判定——只有真实渲染超过阈值的卡片才显示
/// 「展开全文」按钮（按字符数估算对中英文混排/宽字符不准）。
/// 测量样式必须与渲染样式一致（字号/行高不同会错位一行）。
bool textExceedsLines({
  required String text,
  required TextStyle style,
  required double maxWidth,
  required int maxLines,
  // 系统字体缩放会改变行数实测结果，须与渲染环境取同一 textScaler
  // （TextPainter 默认 1.0，大字体用户会误判少一行）
  TextScaler textScaler = TextScaler.noScaling,
}) {
  if (text.isEmpty) return false;
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    maxLines: maxLines,
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
  )..layout(maxWidth: maxWidth);
  final exceeded = painter.didExceedMaxLines;
  painter.dispose();
  return exceeded;
}
