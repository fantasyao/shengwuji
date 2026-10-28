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

  /// 正文可点击链接色：跟随各主题的时间高亮色（用户要求「像时间那样蓝色
  /// 下划线」，2026-10-27 随手记/悬浮窗正文链接）。只改色不参与布局测量
  Color get linkColor => timeHighlight;

  // ============ 特殊色 ============
  /// 启动页背景（原 #2C3E50）
  final Color splashBackground;

  /// 启动页背景渐变（2026-09-24 方案 B「深海极光」）：自上而下三段深蓝
  ///
  /// null = 用纯色 [splashBackground]。仅默认主题配了深海渐变，
  /// 其余主题维持各自同色系纯色底（见 app_theme.dart 各主题注释）。
  final List<Color>? splashGradient;

  /// 启动页图标辉光色（径向渐变中心色，向外淡出为全透明）；null = 不画辉光
  final Color? splashGlow;

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

  // ============ 系统层 ============
  /// 极淡分割线/边框（浅色主题用 black 8%，深色主题用 white 25%）
  ///
  /// 用于卡片边框、输入框边框等"几乎看不见但需要层次"的场景。
  /// 黑金主题下 Colors.black×8% 在深底上完全不可见，必须用白色 alpha。
  final Color divider;

  /// 是否使用浅色图标的状态栏样式（黑金等深色 scaffold 主题用 true）
  ///
  /// true → SystemUiOverlayStyle.light（状态栏图标白色，深底可见）
  /// false → SystemUiOverlayStyle.dark（状态栏图标深色，浅底可见）
  final bool isDarkOverlay;

  // ============ 新拟物（Neumorphism）专用 ============
  /// 拟物外阴影暗色（右下投影），配合 [neuShadowLight] 构成双向阴影
  ///
  /// 仅拟物主题（isNeumorphic=true）使用；其余主题给中性灰占位防误用。
  final Color neuShadowDark;

  /// 拟物外阴影亮色（左上高光）
  ///
  /// 仅拟物主题使用；其余主题给白色占位防误用。
  final Color neuShadowLight;

  /// 是否为新拟物主题
  ///
  /// 拟物组件（widgets/neu_widgets.dart）与页面拟物分支（随手记实底化等）
  /// 都按此标志走，保证旧 4 套主题渲染路径零变化。
  final bool isNeumorphic;

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
    this.splashGradient,
    this.splashGlow,
    required this.goldAccent,
    required this.goldLight,
    required this.goldBorder,
    required this.fabReady,
    required this.fabRecording,
    required this.fabProcessing,
    required this.fabDisabled,
    required this.divider,
    required this.isDarkOverlay,
    // 拟物色槽带默认值：旧 4 套主题无需传参（占位值），仅新拟物主题显式覆盖
    this.neuShadowDark = const Color(0x1A000000),
    this.neuShadowLight = Colors.white,
    this.isNeumorphic = false,
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
    List<Color>? splashGradient,
    Color? splashGlow,
    Color? goldAccent,
    Color? goldLight,
    Color? goldBorder,
    Color? fabReady,
    Color? fabRecording,
    Color? fabProcessing,
    Color? fabDisabled,
    Color? divider,
    bool? isDarkOverlay,
    Color? neuShadowDark,
    Color? neuShadowLight,
    bool? isNeumorphic,
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
      splashGradient: splashGradient ?? this.splashGradient,
      splashGlow: splashGlow ?? this.splashGlow,
      goldAccent: goldAccent ?? this.goldAccent,
      goldLight: goldLight ?? this.goldLight,
      goldBorder: goldBorder ?? this.goldBorder,
      fabReady: fabReady ?? this.fabReady,
      fabRecording: fabRecording ?? this.fabRecording,
      fabProcessing: fabProcessing ?? this.fabProcessing,
      fabDisabled: fabDisabled ?? this.fabDisabled,
      divider: divider ?? this.divider,
      isDarkOverlay: isDarkOverlay ?? this.isDarkOverlay,
      neuShadowDark: neuShadowDark ?? this.neuShadowDark,
      neuShadowLight: neuShadowLight ?? this.neuShadowLight,
      isNeumorphic: isNeumorphic ?? this.isNeumorphic,
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
      scaffoldBackground: Color.lerp(
        scaffoldBackground,
        other.scaffoldBackground,
        t,
      )!,
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
      splashBackground: Color.lerp(
        splashBackground,
        other.splashBackground,
        t,
      )!,
      // 启动页渐变/辉光是装饰层：不做逐色插值，t<0.5 取自身（与 bool 槽同策略）
      splashGradient: t < 0.5 ? splashGradient : other.splashGradient,
      splashGlow: t < 0.5 ? splashGlow : other.splashGlow,
      goldAccent: Color.lerp(goldAccent, other.goldAccent, t)!,
      goldLight: Color.lerp(goldLight, other.goldLight, t)!,
      goldBorder: Color.lerp(goldBorder, other.goldBorder, t)!,
      fabReady: Color.lerp(fabReady, other.fabReady, t)!,
      fabRecording: Color.lerp(fabRecording, other.fabRecording, t)!,
      fabProcessing: Color.lerp(fabProcessing, other.fabProcessing, t)!,
      fabDisabled: Color.lerp(fabDisabled, other.fabDisabled, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      // bool 不能渐变，t<0.5 用自己，否则用对方（SystemUiOverlayStyle 也不支持渐变）
      isDarkOverlay: t < 0.5 ? isDarkOverlay : other.isDarkOverlay,
      neuShadowDark: Color.lerp(neuShadowDark, other.neuShadowDark, t)!,
      neuShadowLight: Color.lerp(neuShadowLight, other.neuShadowLight, t)!,
      isNeumorphic: t < 0.5 ? isNeumorphic : other.isNeumorphic,
    );
  }

  /// 便捷访问器——在 widget 里用 `AppThemeExtension.of(context).primary`
  /// 而非冗长的 `Theme.of(context).extension<AppThemeExtension>()!`
  static AppThemeExtension of(BuildContext context) {
    return Theme.of(context).extension<AppThemeExtension>()!;
  }

  /// 深色界面判定（scaffold 亮度阈值）：深色主题 #121212 远低于 0.2，
  /// 浅色主题（含自定义极浅底）远高于——FAB 前景色/阴影自适应的唯一判据
  bool get isDarkSurface => scaffoldBackground.computeLuminance() < 0.2;

  /// 语音圆钮/主色大按钮的前景色（麦克风图标、确认保存文字）：
  /// - 浅色主题恒白（2026-09-23 恒白承诺：自定义主题主色偏浅时
  ///   textOnPrimary 按 WCAG 会落深色，麦克风变黑不一致，故语音钮不用该槽）
  /// - 深色主题近黑：白图标在深底界面太跳（2026-09-28 真机反馈「起码不能
  ///   亮色的白」）；black87 叠在品牌青 #009688 上视觉对比度 ≈4.7:1
  ///   （≥3:1 大图标/粗体 AA），录音红/处理橙底上更高，视觉也比纯白收敛
  Color get fabContentColor => isDarkSurface ? Colors.black87 : Colors.white;

  /// 黏土拟态 FAB 阴影（diary_floating_button / main.dart 查物品浮钮 /
  /// 录入页钉底栏三处共用，唯一真值——历史上靠注释约定「三处同步」，易漏）
  ///
  /// - 浅色主题：白高光（左上）+ 暗影（右下），光源从上方的黏土质感
  /// - 深色主题：白高光在深底上显形为一圈光晕（2026-09-28 真机反馈），
  ///   去掉高光只留一道稍重的暗影托底（Material 深色规范也只有暗影）
  List<BoxShadow> get fabClayShadow {
    return isDarkSurface
        ? [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              offset: const Offset(0, 4),
              blurRadius: 10,
            ),
          ]
        : [
            // 顶部高光阴影（模拟光源从上方）；高光固定白——自定义主题
            // textOnPrimary 是深色会把高光染成黑晕（2026-09-23 教训）
            BoxShadow(
              color: Colors.white.withValues(alpha: 0.4),
              offset: const Offset(-4, -4),
              blurRadius: 8,
            ),
            // 底部深色阴影（模拟凹陷感）
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              offset: const Offset(4, 4),
              blurRadius: 10,
            ),
          ];
  }
}
