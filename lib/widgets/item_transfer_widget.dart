import 'package:flutter/material.dart';
import '../theme/app_theme_extension.dart';

/// 物品转存横条
///
/// 在日记卡片正文下方独立显示，用于把"物品+位置"模式的日记一键转存到 items 表。
/// 与 LocationAnswerWidget 设计对称：
///   - LocationAnswerWidget：浅青，回答"XX在哪儿"查询
///   - ItemTransferWidget：浅橙，提示可转存为物品
///
/// 视觉：📦 物品名 → 位置              [✕]      [转存]
///
/// 用户交互：
///   - 点 [转存] → onTransfer（写入 items 表并删除原日记）
///   - 点 [✕]    → onDismiss（标记此 content 不再触发，入库 dismissed_splits）
class ItemTransferWidget extends StatelessWidget {
  final String itemName;
  final String location;
  final VoidCallback onTransfer;
  final VoidCallback onDismiss;  // ✕ 关闭回调：用户表示"这条不是物品记录"

  const ItemTransferWidget({
    super.key,
    required this.itemName,
    required this.location,
    required this.onTransfer,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    // 读主题色槽（浅橙背景 + 深橙文字跟随主题）
    final ext = AppThemeExtension.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: ext.warningAccent, // 浅橙背景，区别于查询答案区的浅青
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Text('📦', style: TextStyle(fontSize: 14)),
          const SizedBox(width: 6),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: TextStyle(fontSize: 14, color: ext.warningText),
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
          // ✕ 关闭按钮（左侧，与右侧"转存"形成对称操作）
          // ext.warningText 是运行时主题值，Padding 不能 const；但 padding 本身保持 const
          GestureDetector(
            onTap: onDismiss,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Icon(
                Icons.close,
                size: 16,
                color: ext.warningText,  // 与文字同色（深橙）
              ),
            ),
          ),
          GestureDetector(
            onTap: onTransfer,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: ext.warningText, // 转存按钮：与文字同色形成强对比
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                '转存',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white,
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
