import 'package:flutter/material.dart';

import '../theme/app_theme_extension.dart';
import '../widgets/neu_widgets.dart';

/// 设置页共享小组件（分组标题 / 卡片容器 / 入口行 / Pro 徽章）
///
/// settings_tab 主页与 lib/settings/ 各二级页共用，保证下沉改造后
/// 主页入口行与二级页内部条目视觉一致（对照 settings_tab 原
/// _buildSectionTitle/_buildCard/_buildThemeEntry/_buildProBadge 的样式）。

/// 分组标题（原 _buildSectionTitle）
class SettingsSectionTitle extends StatelessWidget {
  const SettingsSectionTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 10),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.bold,
          color: ext.textSecondary,
        ),
      ),
    );
  }
}

/// 卡片容器（原 _buildCard）
class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    // 新拟物主题：凸起卡片（圆角档 18，双向阴影），分隔线由调用方用凹槽细线替代
    if (ext.isNeumorphic) {
      return Container(
        decoration: neuRaisedDecoration(context, radius: 18),
        padding: padding ?? const EdgeInsets.all(16),
        child: child,
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: ext.cardBackground,
        borderRadius: BorderRadius.circular(15),
        boxShadow: [
          BoxShadow(
            color: ext.textPrimary.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: padding ?? const EdgeInsets.all(16),
      child: child,
    );
  }
}

/// 设置入口行（原 _buildThemeEntry/_buildCorrectionEntry 视觉）：
/// 左图标 + 标题（可带后缀徽章/状态点）+ 副标题摘要 + 右箭头，点击整行跳转
class SettingsEntryRow extends StatelessWidget {
  const SettingsEntryRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.titleSuffix,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  /// 标题文字后的附加小部件（Pro 徽章 / 无障碍状态点等）
  final Widget? titleSuffix;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(icon, color: ext.primary, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        color: ext.textPrimary,
                      ),
                    ),
                    if (titleSuffix != null) ...[
                      const SizedBox(width: 6),
                      titleSuffix!,
                    ],
                  ],
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 12,
                      color: ext.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: ext.textHint, size: 22),
        ],
      ),
    );
    // 新拟物主题：整行按住凹陷（预览拍板的入口行交互），替代水波纹
    if (ext.isNeumorphic) {
      return NeuPressable(
        onTap: onTap,
        radius: 18,
        padding: EdgeInsets.zero,
        child: content,
      );
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(15),
      child: content,
    );
  }
}

/// 开关行分流：拟物主题用 NeuSwitchTile（凹槽开关），其余主题用 SwitchListTile
///
/// 统一旧主题侧的既有约定（dense + contentPadding.zero + controlAffinity.leading），
/// 替换处只传 title/subtitle/value/onChanged 四参，避免 11 处调用各写一遍分支。
Widget buildSettingsSwitchTile(
  BuildContext context, {
  required Widget title,
  Widget? subtitle,
  required bool value,
  required ValueChanged<bool>? onChanged,
}) {
  final ext = AppThemeExtension.of(context);
  if (ext.isNeumorphic) {
    return NeuSwitchTile(
      title: title,
      subtitle: subtitle,
      value: value,
      onChanged: onChanged,
    );
  }
  return SwitchListTile(
    title: title,
    subtitle: subtitle,
    value: value,
    onChanged: onChanged,
    dense: true,
    contentPadding: EdgeInsets.zero,
    controlAffinity: ListTileControlAffinity.leading,
  );
}

/// Pro 徽章（金色胶囊，原 _buildProBadge，与主题卡片 Pro 角标同视觉）
class SettingsProBadge extends StatelessWidget {
  const SettingsProBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppThemeExtension.of(context).goldAccent,
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text(
        'Pro',
        style: TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
