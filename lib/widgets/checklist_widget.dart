import 'package:flutter/material.dart';
import '../theme/app_theme_extension.dart';

/// 清单渲染组件
///
/// 解析 markdown 任务列表格式（`- [ ]` / `- [x]`）并渲染为可交互的勾选列表。
/// 视觉风格与 diary_tab.dart 中 _buildListCard 保持一致。
class ChecklistWidget extends StatelessWidget {
  /// markdown 格式的清单内容
  final String content;

  /// 勾选/取消勾选回调，参数为原始行索引
  final Function(int lineIndex) onToggle;

  /// 可选的文字样式覆盖
  final TextStyle? textStyle;

  const ChecklistWidget({
    super.key,
    required this.content,
    required this.onToggle,
    this.textStyle,
  });

  // 匹配 `- [ ] xxx` 或 `- [x] xxx` 格式
  static final RegExp _checklistLineRegex = RegExp(r'^- \[([ xX])] (.+)$');

  /// 检测内容是否为清单格式（至少有一行 `- [ ]` 或 `- [x]`）
  static bool isChecklist(String content) {
    final lines = content.split('\n');
    for (final line in lines) {
      if (_checklistLineRegex.hasMatch(line.trim())) {
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final lines = content.split('\n');

    // 读主题色槽（清单勾选状态颜色跟随主题）
    final ext = AppThemeExtension.of(context);

    // 过滤出清单行，同时保留原始行索引
    final List<(int lineIndex, bool checked, String text)> checklistItems = [];
    for (int i = 0; i < lines.length; i++) {
      final match = _checklistLineRegex.firstMatch(lines[i].trim());
      if (match != null) {
        final checked = match.group(1)!.toLowerCase() == 'x';
        final text = match.group(2)!;
        checklistItems.add((i, checked, text));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: checklistItems.map((item) {
        final (lineIndex, checked, text) = item;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onToggle(lineIndex),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  checked ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 20,
                  color: checked ? ext.primary : ext.textHint,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    style: textStyle?.merge(
                      TextStyle(
                        color: checked ? ext.textHint : ext.textPrimary,
                        decoration: checked ? TextDecoration.lineThrough : null,
                      ),
                    ) ??
                    TextStyle(
                      fontSize: 15,
                      height: 1.4,
                      color: checked ? ext.textHint : ext.textPrimary,
                      decoration: checked ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}
