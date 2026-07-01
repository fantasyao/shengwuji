import 'package:flutter/material.dart';
import '../theme/app_theme_extension.dart';

/// 物品位置查询答案展示
///
/// 在日记卡片底部独立显示，不修改笔记 content。
///
/// 三种显示状态：
///   - matches.isEmpty → 灰色背景："❓ 没找到「itemName」"
///   - matches.length == 1 → 浅青背景："📍 itemName → location"
///   - matches.length >= 2 → 浅青背景："📍 itemName → location  +N"
///     其中 N = matches.length - 1，点击 "+N" 调用 onViewMore
class LocationAnswerWidget extends StatelessWidget {
  final String itemName;

  /// 按 id 倒序的匹配列表（来自 DbHelper.searchItemsByName）
  final List<Map<String, dynamic>> matches;

  /// 点击 "+N" 跳转到 ListTab 的回调
  final VoidCallback? onViewMore;

  const LocationAnswerWidget({
    super.key,
    required this.itemName,
    required this.matches,
    this.onViewMore,
  });

  @override
  Widget build(BuildContext context) {
    // 读主题色槽（浅青背景 + 深青文字跟随主题）
    final ext = AppThemeExtension.of(context);

    // 状态 1：无匹配
    if (matches.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: ext.scaffoldBackground,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Text('❓', style: TextStyle(fontSize: 14)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '没找到「$itemName」',
                style: TextStyle(fontSize: 14, color: ext.textHint),
              ),
            ),
          ],
        ),
      );
    }

    // 状态 2/3：有匹配，取最近的一条
    final firstMatch = matches.first;
    final location = firstMatch['location']?.toString() ?? '';
    final extraCount = matches.length - 1;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: ext.positiveAccent, // 浅青背景，区别于笔记正文
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.location_on, size: 16, color: ext.positiveText),
          const SizedBox(width: 4),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: TextStyle(fontSize: 14, color: ext.positiveText),
                children: [
                  TextSpan(
                    text: itemName,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const TextSpan(text: ' → '),
                  TextSpan(text: location),
                ],
              ),
            ),
          ),
          // "+N" 标签：多于 1 条匹配时显示
          if (extraCount > 0)
            GestureDetector(
              onTap: onViewMore,
              child: Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: ext.positiveText.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '+$extraCount',
                  style: TextStyle(
                    fontSize: 12,
                    color: ext.positiveText,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
