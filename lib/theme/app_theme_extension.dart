import 'package:flutter/material.dart';

/// 主题语义化色槽定义
///
/// 所有 UI 组件只引用这里的语义槽，不直接写 `Color(0xFF...)` 或 `Colors.xxx`。
/// 这样切换主题时整个 APP 颜色才会统一变化。
///
/// 设计原则：
/// - 命名按"用途"而非"颜色"，例如 positiveAccent（积极反馈背景）
///   而非 lightTeal（浅青色）
/// - 一个语义槽对应一个 UI 用途，避免不同组件复用同一槽导致联动改色
/// - 与现有硬编码颜色一对一映射，迁移期可安全共存
@immutable
class AppThemeExtension extends ThemeExtension<AppThemeExtension> {
  // ============ 基础语义 ============
  /// 主色调（导航栏选中色、按钮主色等）
  final Color primary;
  /// 主色浅色变体（选中态浅色背景、徽章底色）
  final Color primaryLight;
  /// 主色深色变体（强调文字、按下态）
  final Color primaryDark;

  /// 卡片/面板背景
  final Color surface;
  /// 列表项卡片背景
  final Color cardBackground;
  /// Scaffold 全局背景
  final Color scaffoldBackground;

  // ============ 文字 ============
  /// 主要文字（原 Colors.black87）
  final Color textPrimary;
  /// 次要文字（原 Colors.black54）
  final Color textSecondary;
  /// 占位/提示文字（原 Colors.grey）
  final Color textHint;
  /// 主色背景上的文字（通常白色）
  final Color textOnPrimary;

  // ============ 功能色（与 UI 组件一一映射）============
  /// 查询答案区背景（原 #E0F2F1 浅青）
  final Color positiveAccent;
  /// 查询答案区文字（原 #00796B 深青）
  final Color positiveText;
  /// 物品转存横条背景（原 #FFF3E0 浅橙）
  final Color warningAccent;
  /// 物品转存横条文字（原 #E65100 深橙）
  final Color warningText;
  /// 侧滑删除渐变末端色（原 #E57373 柔红）
  final Color dangerAccent;
  /// 时间表达式高亮文字（原 Colors.blue.shade700）
  final Color timeHighlight;
  /// 时间表达式高亮背景（原 Colors.blue.shade50）
  final Color timeHighlightBg;

  // ============ 特殊色 ============
  /// 启动页背景（原 #2C3E50）
  final Color splashBackground;
  /// Pro 金色主色（原 #D4A437）
  final Color goldAccent;
  /// Pro 金色浅底（原 #FFF8E7）
  final Color goldLight;
  /// Pro 金色边框（原 #E6C158）
  final Color goldBorder;

  // ============ 浮动按钮状态色 ============
  /// 就绪态（原 Colors.teal）
  final Color fabReady;
  /// 录音中（原 Colors.redAccent）
  final Color fabRecording;
  /// 处理中（原 Colors.orangeAccent）
  final Color fabProcessing;
  /// 禁用态（原 Colors.grey）
  final Color fabDisabled;

  const AppThemeExtension({
    required this.primary,
    required this.primaryLight,
    required this.primaryDark,
    required this.surface,
    required this.cardBackground,
    required this.scaffoldBackground,
    required this.textPrimary,
    required this.textSecondary,
    required this.textHint,
    required this.textOnPrimary,
    required this.positiveAccent,
    required this.positiveText,
    required this.warningAccent,
    required this.warningText,
    required this.dangerAccent,
    required this.timeHighlight,
    required this.timeHighlightBg,
    required this.splashBackground,
    required this.goldAccent,
    required this.goldLight,
    required this.goldBorder,
    required this.fabReady,
    required this.fabRecording,
    required this.fabProcessing,
    required this.fabDisabled,
  });

  @override
  AppThemeExtension copyWith({
    Color? primary,
    Color? primaryLight,
    Color? primaryDark,
    Color? surface,
    Color? cardBackground,
    Color? scaffoldBackground,
    Color? textPrimary,
    Color? textSecondary,
    Color? textHint,
    Color? textOnPrimary,
    Color? positiveAccent,
    Color? positiveText,
    Color? warningAccent,
    Color? warningText,
    Color? dangerAccent,
    Color? timeHighlight,
    Color? timeHighlightBg,
    Color? splashBackground,
    Color? goldAccent,
    Color? goldLight,
    Color? goldBorder,
    Color? fabReady,
    Color? fabRecording,
    Color? fabProcessing,
    Color? fabDisabled,
  }) {
    return AppThemeExtension(
      primary: primary ?? this.primary,
      primaryLight: primaryLight ?? this.primaryLight,
      primaryDark: primaryDark ?? this.primaryDark,
      surface: surface ?? this.surface,
      cardBackground: cardBackground ?? this.cardBackground,
      scaffoldBackground: scaffoldBackground ?? this.scaffoldBackground,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textHint: textHint ?? this.textHint,
      textOnPrimary: textOnPrimary ?? this.textOnPrimary,
      positiveAccent: positiveAccent ?? this.positiveAccent,
      positiveText: positiveText ?? this.positiveText,
      warningAccent: warningAccent ?? this.warningAccent,
      warningText: warningText ?? this.warningText,
      dangerAccent: dangerAccent ?? this.dangerAccent,
      timeHighlight: timeHighlight ?? this.timeHighlight,
      timeHighlightBg: timeHighlightBg ?? this.timeHighlightBg,
      splashBackground: splashBackground ?? this.splashBackground,
      goldAccent: goldAccent ?? this.goldAccent,
      goldLight: goldLight ?? this.goldLight,
      goldBorder: goldBorder ?? this.goldBorder,
      fabReady: fabReady ?? this.fabReady,
      fabRecording: fabRecording ?? this.fabRecording,
      fabProcessing: fabProcessing ?? this.fabProcessing,
      fabDisabled: fabDisabled ?? this.fabDisabled,
    );
  }

  @override
  AppThemeExtension lerp(AppThemeExtension other, double t) {
    return AppThemeExtension(
      primary: Color.lerp(primary, other.primary, t)!,
      primaryLight: Color.lerp(primaryLight, other.primaryLight, t)!,
      primaryDark: Color.lerp(primaryDark, other.primaryDark, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      cardBackground: Color.lerp(cardBackground, other.cardBackground, t)!,
      scaffoldBackground: Color.lerp(scaffoldBackground, other.scaffoldBackground, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textHint: Color.lerp(textHint, other.textHint, t)!,
      textOnPrimary: Color.lerp(textOnPrimary, other.textOnPrimary, t)!,
      positiveAccent: Color.lerp(positiveAccent, other.positiveAccent, t)!,
      positiveText: Color.lerp(positiveText, other.positiveText, t)!,
      warningAccent: Color.lerp(warningAccent, other.warningAccent, t)!,
      warningText: Color.lerp(warningText, other.warningText, t)!,
      dangerAccent: Color.lerp(dangerAccent, other.dangerAccent, t)!,
      timeHighlight: Color.lerp(timeHighlight, other.timeHighlight, t)!,
      timeHighlightBg: Color.lerp(timeHighlightBg, other.timeHighlightBg, t)!,
      splashBackground: Color.lerp(splashBackground, other.splashBackground, t)!,
      goldAccent: Color.lerp(goldAccent, other.goldAccent, t)!,
      goldLight: Color.lerp(goldLight, other.goldLight, t)!,
      goldBorder: Color.lerp(goldBorder, other.goldBorder, t)!,
      fabReady: Color.lerp(fabReady, other.fabReady, t)!,
      fabRecording: Color.lerp(fabRecording, other.fabRecording, t)!,
      fabProcessing: Color.lerp(fabProcessing, other.fabProcessing, t)!,
      fabDisabled: Color.lerp(fabDisabled, other.fabDisabled, t)!,
    );
  }

  /// 便捷访问器——在 widget 里用 `AppThemeExtension.of(context).primary`
  /// 而非冗长的 `Theme.of(context).extension<AppThemeExtension>()!`
  static AppThemeExtension of(BuildContext context) {
    return Theme.of(context).extension<AppThemeExtension>()!;
  }
}
