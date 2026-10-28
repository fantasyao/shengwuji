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
                      style: TextStyle(fontSize: 15, color: ext.textPrimary),
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
                    style: TextStyle(fontSize: 12, color: ext.textSecondary),
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

/// 单选 chip 分流：拟物主题用 [NeuChoiceChip]（凸起/凹陷胶囊），其余保持
/// M3 ChoiceChip（默认主题渲染路径零变化）
///
/// [icon] 为常规单图标；[iconSize] 供「图标本身暗示档位」的选择器（字号/
/// 面板条数/把手大小/边距）按档位缩放；[avatar] 为完全自定义预览（如把手
/// 主题的双色圆点），传了则忽略 [icon]。点击回调统一为 [onTap]，点已选中项
/// 也照常触发（原各选择器的保存语义不变）。
Widget buildSettingsChoiceChip(
  BuildContext context, {
  required Widget label,
  IconData? icon,
  double iconSize = 16,
  Widget? avatar,
  bool showCheckmark = true,
  EdgeInsetsGeometry? labelPadding,
  required bool selected,
  required VoidCallback onTap,
}) {
  final ext = AppThemeExtension.of(context);
  if (ext.isNeumorphic) {
    return NeuChoiceChip(
      selected: selected,
      onSelected: (_) => onTap(),
      avatar: avatar ?? (icon == null ? null : Icon(icon, size: iconSize)),
      label: label,
    );
  }
  return ChoiceChip(
    avatar:
        avatar ??
        (icon == null
            ? null
            : Icon(
                icon,
                size: iconSize,
                color: selected ? ext.textOnPrimary : ext.primary,
              )),
    label: label,
    labelPadding: labelPadding,
    showCheckmark: showCheckmark,
    selected: selected,
    selectedColor: ext.primary,
    labelStyle: TextStyle(
      color: selected ? ext.textOnPrimary : ext.textPrimary,
      fontSize: 13,
    ),
    onSelected: (_) => onTap(),
  );
}

/// 主按钮分流：拟物主题 = 同色凸起 + 品牌青文字 + 按住凹陷（设计规范
/// 2026-09-17 拍板「主 CTA 纯同色凸起，不用彩色渐变底」）；其余主题保持
/// 既有 ElevatedButton 样式
///
/// [expand] = true 时占满父级宽度（等宽设置卡按钮行）；false 用于内联按钮。
/// [busy] 只替换图标为加载圈并禁点，文案不变（原测试连接/立即同步语义）。
Widget buildSettingsPrimaryButton(
  BuildContext context, {
  required IconData icon,
  required String label,
  required VoidCallback? onPressed,
  bool busy = false,
  double minHeight = 46,
  bool expand = true,
}) {
  final ext = AppThemeExtension.of(context);
  final disabled = onPressed == null;
  if (ext.isNeumorphic) {
    final fg = disabled ? ext.textHint : ext.primaryDark;
    final button = NeuPressable(
      onTap: busy ? null : onPressed,
      radius: 12,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: fg),
            )
          else
            Icon(icon, size: 20, color: fg),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: fg,
            ),
          ),
        ],
      ),
    );
    return expand
        ? SizedBox(width: double.infinity, height: minHeight, child: button)
        : button;
  }
  return ElevatedButton.icon(
    onPressed: busy ? null : onPressed,
    icon: busy
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(icon, size: 20),
    label: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
    style: ElevatedButton.styleFrom(
      backgroundColor: ext.primary,
      foregroundColor: ext.textOnPrimary,
      disabledBackgroundColor: ext.primary.withValues(alpha: 0.4),
      disabledForegroundColor: ext.textOnPrimary,
      elevation: 0,
      minimumSize: expand ? Size.fromHeight(minHeight) : Size(0, minHeight),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );
}

/// 次级按钮分流：拟物主题 = 同色凸起 + 品牌青文字（按住凹陷），其余主题
/// 保持既有描边 OutlinedButton（对齐 settings_tab._buildSecondaryBtn 的
/// 拟物分支，2026-09-18 真机反馈描边按钮没有拟物突出效果）
Widget buildSettingsSecondaryButton(
  BuildContext context, {
  required IconData icon,
  required String label,
  required VoidCallback? onPressed,
  bool busy = false,
  double minHeight = 46,
  bool expand = true,
}) {
  final ext = AppThemeExtension.of(context);
  if (ext.isNeumorphic) {
    final fg = onPressed == null ? ext.textHint : ext.primary;
    final button = NeuPressable(
      onTap: busy ? null : onPressed,
      radius: 12,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: fg),
            )
          else
            Icon(icon, size: 20, color: fg),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ],
      ),
    );
    return expand
        ? SizedBox(width: double.infinity, height: minHeight, child: button)
        : button;
  }
  return OutlinedButton.icon(
    onPressed: busy ? null : onPressed,
    icon: busy
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(icon, size: 20),
    label: Text(label),
    style: OutlinedButton.styleFrom(
      foregroundColor: ext.primary,
      side: BorderSide(color: ext.primary),
      minimumSize: expand ? Size.fromHeight(minHeight) : Size(0, minHeight),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  );
}

/// 拟物主题输入框外壳：同色凹陷（NeuInset）+ 无填充无边框的 TextField；
/// 其余主题原样返回（调用方自行保持既有 filled 白卡样式）
///
/// 拟物主题下 scaffold/card 同色，TextField 若继续 filled=cardBackground 会
/// 与卡片粘连成一块平面；外层 NeuInset 的晕影 painter 画在 child 之下，因此
/// 拟物分支必须 `filled: false` 让内阴影透出来（与 record_tab 现代输入框、
/// 随手记搜索框同款约束）。
///
/// ⚠️ 拟物分支不要传 `InputDecoration.labelText`（2026-10-28 用户真机反馈
/// WebDAV 输入框「文字一半在边框里、边框变高」）：浮动标签会压在上边框线上
/// 并为标签切口预留上内边距，而拟物壳没有可见边框，标签就悬在凹陷上沿、
/// 被内阴影切掉半截。改为把标签交给本函数的 [label] 画在凹陷**外**上方
/// （12px 小标题），调用方在拟物分支把 labelText 置空即可。
Widget buildSettingsFieldShell(
  BuildContext context, {
  required Widget field,
  String? label,
}) {
  final ext = AppThemeExtension.of(context);
  if (!ext.isNeumorphic) return field;
  final inset = NeuInset(radius: 15, child: field);
  if (label == null) return inset;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 6),
        child: Text(
          label,
          style: TextStyle(fontSize: 12, color: ext.textSecondary),
        ),
      ),
      inset,
    ],
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
