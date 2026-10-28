import 'package:flutter/material.dart';
import 'app_font.dart';
import 'app_theme_extension.dart';

/// 单套主题的定义数据
///
/// 每个主题包含：
/// - 唯一 ID（用于持久化）
/// - 用户可见名称
/// - 种子色（用于 ColorScheme.fromSeed）
/// - 是否 Pro 付费主题
/// - 完整的语义化色槽（AppThemeExtension）
class AppThemeDefinition {
  /// 持久化用的唯一 ID（如 'default_teal'）
  final String id;

  /// 用户可见名称（如 '默认青'）
  final String name;

  /// ColorScheme.fromSeed 的种子色
  final Color seedColor;

  /// 是否 Pro 付费主题（true 时未解锁点击会触发 ProUnlockDialog）
  final bool isPro;

  /// ColorScheme 亮度（浅色主题恒 light；唯一的深色主题 [AppThemes.dark] 为 dark）
  final Brightness brightness;

  /// 该主题的完整语义化色槽
  final AppThemeExtension extension;

  const AppThemeDefinition({
    required this.id,
    required this.name,
    required this.seedColor,
    this.isPro = false,
    this.brightness = Brightness.light,
    required this.extension,
  });

  /// 构建 ThemeData
  ///
  /// [font] 由设置页「字体」选项驱动（默认霞鹜文楷）。系统默认档传
  /// fontFamily=null——Flutter 的两个字体层级（ThemeData.fontFamily 与
  /// TextTheme 各 style）必须同时置空，见 CLAUDE.md「主题字体配置陷阱」。
  ThemeData toThemeData({AppFontChoice font = kDefaultAppFontChoice}) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
    );
    final family = font.fontFamily;

    return ThemeData(
      fontFamily: family,
      textTheme: _buildTextTheme(family),
      colorScheme: colorScheme,
      useMaterial3: true,
      extensions: [extension],
    );
  }

  /// 生成 TextTheme（显式配置所有 15 种文本样式避免 Roboto 回退）
  static TextTheme _buildTextTheme(String? family) => TextTheme(
    bodyLarge: TextStyle(fontFamily: family),
    bodyMedium: TextStyle(fontFamily: family),
    bodySmall: TextStyle(fontFamily: family),
    displayLarge: TextStyle(fontFamily: family),
    displayMedium: TextStyle(fontFamily: family),
    displaySmall: TextStyle(fontFamily: family),
    headlineLarge: TextStyle(fontFamily: family),
    headlineMedium: TextStyle(fontFamily: family),
    headlineSmall: TextStyle(fontFamily: family),
    titleLarge: TextStyle(fontFamily: family),
    titleMedium: TextStyle(fontFamily: family),
    titleSmall: TextStyle(fontFamily: family),
    labelLarge: TextStyle(fontFamily: family),
    labelMedium: TextStyle(fontFamily: family),
    labelSmall: TextStyle(fontFamily: family),
  );
}

/// 所有预设主题注册表
///
/// 新增主题只需在 `_all` 里加一项即可，设置页会自动遍历显示。
class AppThemes {
  /// 所有预设主题列表（顺序即设置页显示顺序）
  static const all = [
    defaultTeal,
    warmOrange,
    forestGreen,
    skyBlue,
    neumorphism,
  ];

  /// 默认主题（应用首次启动时使用）
  static const defaultTheme = defaultTeal;

  /// 按 ID 查找主题，找不到返回 null（调用方兜底用 defaultTheme）
  static AppThemeDefinition? findById(String? id) {
    if (id == null) return null;
    for (final t in all) {
      if (t.id == id) return t;
    }
    return null;
  }

  // ==================== 主题定义 ====================

  /// 默认青主题——精确还原当前视觉的基准主题
  static const defaultTeal = AppThemeDefinition(
    id: 'default_teal',
    name: '默认青',
    seedColor: Color(0xFF009688),
    isPro: false,
    extension: AppThemeExtension(
      primary: Color(0xFF009688),
      primaryLight: Color(0xFFB2DFDB),
      primaryDark: Color(0xFF00796B),
      surface: Colors.white,
      cardBackground: Colors.white,
      scaffoldBackground: Color(0xFFF5F5F5),
      textPrimary: Color(0xDD000000),
      textSecondary: Color(0x8A000000),
      textHint: Colors.grey,
      textOnPrimary: Colors.white,
      positiveAccent: Color(0xFFE0F2F1),
      positiveText: Color(0xFF00796B),
      warningAccent: Color(0xFFFFF3E0),
      warningText: Color(0xFFE65100),
      dangerAccent: Color(0xFFE57373),
      timeHighlight: Color(0xFF1976D2),
      timeHighlightBg: Color(0xFFBBDEFB),
      // 2026-09-24 启动页重设计走方案 B「深海极光」（用户从配色预览中选定）：
      // 深海三段渐变 #0D1B2E→#13253C→#16304A + 图标冷蓝辉光 rgba(94,158,220,0.35)，
      // 搭配藏青版启动页图标（原薄荷绿渐变图标与藏青背景撞色）。
      // splashBackground 降级为兜底纯色（渐变层之下/系统导航栏区域）+ 授权按钮文字色
      splashBackground: Color(0xFF13253C),
      splashGradient: [Color(0xFF0D1B2E), Color(0xFF13253C), Color(0xFF16304A)],
      splashGlow: Color(0x5A5E9EDC),
      goldAccent: Color(0xFFD4A437),
      goldLight: Color(0xFFFFF8E7),
      goldBorder: Color(0xFFE6C158),
      fabReady: Color(0xFF009688),
      fabRecording: Color(0xFFFF5252),
      fabProcessing: Color(0xFFFFAB40),
      fabDisabled: Colors.grey,
      divider: Color(0x14000000),
      isDarkOverlay: false,
    ),
  );

  /// 暖橙主题
  static const warmOrange = AppThemeDefinition(
    id: 'warm_orange',
    name: '暖橙',
    seedColor: Color(0xFFE65100),
    isPro: false,
    extension: AppThemeExtension(
      primary: Color(0xFFE65100),
      primaryLight: Color(0xFFFFCC80),
      primaryDark: Color(0xFFBF360C),
      surface: Colors.white,
      cardBackground: Color(0xFFFFFBF5),
      scaffoldBackground: Color(0xFFFFF8E1),
      textPrimary: Color(0xDD000000),
      textSecondary: Color(0x8A000000),
      textHint: Colors.grey,
      textOnPrimary: Colors.white,
      positiveAccent: Color(0xFFFFF3E0),
      positiveText: Color(0xFFE65100),
      warningAccent: Color(0xFFFFF8E1),
      warningText: Color(0xFFBF360C),
      dangerAccent: Color(0xFFEF5350),
      timeHighlight: Color(0xFFE65100),
      timeHighlightBg: Color(0xFFFFE0B2),
      splashBackground: Color(0xFF3E2723),
      goldAccent: Color(0xFFD4A437),
      goldLight: Color(0xFFFFF8E7),
      goldBorder: Color(0xFFE6C158),
      fabReady: Color(0xFFE65100),
      fabRecording: Color(0xFFFF5252),
      fabProcessing: Color(0xFFFFAB40),
      fabDisabled: Colors.grey,
      divider: Color(0x14000000),
      isDarkOverlay: false,
    ),
  );

  /// 墨绿主题
  static const forestGreen = AppThemeDefinition(
    id: 'forest_green',
    name: '墨绿',
    seedColor: Color(0xFF2E7D32),
    isPro: false,
    extension: AppThemeExtension(
      primary: Color(0xFF2E7D32),
      primaryLight: Color(0xFFA5D6A7),
      primaryDark: Color(0xFF1B5E20),
      surface: Colors.white,
      cardBackground: Color(0xFFF1F8E9),
      scaffoldBackground: Color(0xFFF5F5F0),
      textPrimary: Color(0xDD000000),
      textSecondary: Color(0x8A000000),
      textHint: Colors.grey,
      textOnPrimary: Colors.white,
      positiveAccent: Color(0xFFE8F5E9),
      positiveText: Color(0xFF2E7D32),
      warningAccent: Color(0xFFFFF3E0),
      warningText: Color(0xFFE65100),
      dangerAccent: Color(0xFFEF5350),
      timeHighlight: Color(0xFF2E7D32),
      timeHighlightBg: Color(0xFFC8E6C9),
      splashBackground: Color(0xFF1B5E20),
      goldAccent: Color(0xFFD4A437),
      goldLight: Color(0xFFFFF8E7),
      goldBorder: Color(0xFFE6C158),
      fabReady: Color(0xFF2E7D32),
      fabRecording: Color(0xFFFF5252),
      fabProcessing: Color(0xFFFFAB40),
      fabDisabled: Colors.grey,
      divider: Color(0x14000000),
      isDarkOverlay: false,
    ),
  );

  /// 晴空蓝主题（Pro 付费）
  ///
  /// 灵感：晴朗天空的淡蓝色（#7CCAF4）。浅色主题，所有 primary 色背景上用深蓝黑文字/图标。
  /// 关键决策：
  /// - textOnPrimary=#0D2A40（深蓝黑）：#7CCAF4 较浅，白字对比度仅 1.8:1 不达标，
  ///   深蓝黑对比度 8.2:1（AAA），且与晴空蓝同色系视觉协调
  /// - cardBackground/scaffoldBackground 微淡蓝（#F8FBFE/#F0F6FB）：与 primary 同色系但不抢戏
  /// - splashBackground=#2C5A7C（深蓝）：与晴空蓝同色系，避免黑底破坏调性
  /// - 保留 warning 橙 / danger 红 / gold 金：语义色和品牌色不跟随主题色变化
  static const skyBlue = AppThemeDefinition(
    id: 'sky_blue',
    name: '晴空蓝',
    seedColor: Color(0xFF7CCAF4),
    isPro: true,
    extension: AppThemeExtension(
      primary: Color(0xFF7CCAF4),
      primaryLight: Color(0xFFBFE2F9),
      primaryDark: Color(0xFF4FA6E0),
      surface: Colors.white,
      cardBackground: Color(0xFFF8FBFE),
      scaffoldBackground: Color(0xFFF0F6FB),
      textPrimary: Color(0xDD000000),
      textSecondary: Color(0x8A000000),
      textHint: Colors.grey,
      textOnPrimary: Color(0xFF0D2A40), // 深蓝黑（#7CCAF4 上对比度 8.2:1 AAA）
      positiveAccent: Color(0xFFE0F2FB),
      positiveText: Color(0xFF1976D2),
      warningAccent: Color(0xFFFFF3E0),
      warningText: Color(0xFFE65100),
      dangerAccent: Color(0xFFE57373),
      timeHighlight: Color(0xFF1976D2),
      timeHighlightBg: Color(0xFFBBDEFB),
      splashBackground: Color(0xFF2C5A7C), // 深蓝（同色系，替代默认黑底）
      goldAccent: Color(0xFFD4A437),
      goldLight: Color(0xFFFFF8E7),
      goldBorder: Color(0xFFE6C158),
      fabReady: Color(0xFF7CCAF4),
      fabRecording: Color(0xFFFF5252),
      fabProcessing: Color(0xFFFFAB40),
      fabDisabled: Colors.grey,
      divider: Color(0x14000000),
      isDarkOverlay: false,
    ),
  );

  /// 新拟物主题（Neumorphism）
  ///
  /// 2026-09-17 用户拍板：经典拟物灰底 + 轻盈阴影（外 4px/blur8、凹 2px/blur4）、
  /// 主 CTA 纯同色凸起、开关凹槽轨道+凸滑块、随手记实底化（仅本主题下）。
  /// 关键不变量：scaffoldBackground == cardBackground == surface（#E0E5EC）——
  /// 拟物"背景与组件同色"是双阴影成立的前提，三槽必须保持一致。
  /// 悬浮窗不适用本主题（透明窗口会裁剪外扩散阴影，见 overlay_app.dart 降级逻辑）。
  /// 2026-09-19 Pro 化：isPro=true，与晴空蓝同走 ProGate 门禁（授权码解锁/7 天试用）。
  static const neumorphism = AppThemeDefinition(
    id: 'neumorphism',
    name: '新拟物',
    seedColor: Color(0xFF009688),
    isPro: true,
    extension: AppThemeExtension(
      primary: Color(0xFF009688),
      primaryLight: Color(0xFFB2DFDB),
      primaryDark: Color(0xFF00806F),
      surface: Color(0xFFE0E5EC),
      cardBackground: Color(0xFFE0E5EC),
      scaffoldBackground: Color(0xFFE0E5EC),
      textPrimary: Color(0xFF3D4A5C),
      textSecondary: Color(0xFF7D8AA0),
      textHint: Color(0xFF9DABBD),
      textOnPrimary: Colors.white,
      positiveAccent: Color(0xFFDEEBE8),
      positiveText: Color(0xFF00806F),
      warningAccent: Color(0xFFF0E8DC),
      warningText: Color(0xFFE65100),
      dangerAccent: Color(0xFFE57373),
      timeHighlight: Color(0xFF1976D2),
      timeHighlightBg: Color(0xFFD6E4F5),
      splashBackground: Color(0xFF2C3E50),
      goldAccent: Color(0xFFD4A437),
      goldLight: Color(0xFFFFF8E7),
      goldBorder: Color(0xFFE6C158),
      fabReady: Color(0xFF009688),
      fabRecording: Color(0xFFFF5252),
      fabProcessing: Color(0xFFFFAB40),
      fabDisabled: Colors.grey,
      divider: Color(0x1F3D4A5C),
      isDarkOverlay: false,
      neuShadowDark: Color(0xFFAEB9C9),
      neuShadowLight: Color(0xFFFFFFFF),
      isNeumorphic: true,
    ),
  );

  /// 深色主题（全 App 唯一一套，2026-09-28 用户拍板）
  ///
  /// 定位：不是任何浅色主题的"深色变体"，而是深色模式下替换全部浅色主题的
  /// 唯一深色皮肤——`MaterialApp.darkTheme` 专用，不进 [all]（主题选择器只
  /// 选浅色皮肤，深浅切换由「深色模式」三档设置驱动，见 kThemeModePrefKey）。
  ///
  /// 配色按 Material 深色规范 + 品牌青保留（微信深色模式同款思路——关键按钮
  /// 维持品牌色 + 白图标，不换成浅色主色 + 深图标）：
  /// - 背景双层：scaffold #121212（规范基准面）/ 卡片 #1E1E1E（等效 elevation 1）
  /// - primary 保持 #009688：白字对比度 3.3:1（大图标/粗体可用），深底上可见；
  ///   primaryDark 反转为亮青 #80CBC4（语义是"强调文字色"，深底上深色文字不可读）
  /// - primaryLight（选中背景）压暗为深青容器 #1E3A38
  /// - 文字白 alpha 三档 87%/60%/38%（Material dark on-surface 规范）
  /// - 语义色（warning 橙/danger 红/gold 金/fab 录音红）与浅色主题同款不随深浅变化
  /// - 启动页沿用默认主题的深海渐变（本来就是深底，深浅两态视觉一致）
  static const dark = AppThemeDefinition(
    id: 'dark_standard',
    name: '深色',
    seedColor: Color(0xFF009688),
    isPro: false,
    brightness: Brightness.dark,
    extension: AppThemeExtension(
      primary: Color(0xFF009688),
      primaryLight: Color(0xFF1E3A38),
      primaryDark: Color(0xFF80CBC4),
      surface: Color(0xFF1E1E1E),
      cardBackground: Color(0xFF1E1E1E),
      scaffoldBackground: Color(0xFF121212),
      textPrimary: Color(0xDEFFFFFF),
      textSecondary: Color(0x99FFFFFF),
      textHint: Color(0x61FFFFFF),
      textOnPrimary: Colors.white,
      positiveAccent: Color(0xFF1B3A37),
      positiveText: Color(0xFF80CBC4),
      warningAccent: Color(0xFF3D2E1A),
      warningText: Color(0xFFFFCC80),
      dangerAccent: Color(0xFFEF5350),
      timeHighlight: Color(0xFF90CAF9),
      timeHighlightBg: Color(0xFF1A2E44),
      splashBackground: Color(0xFF13253C),
      splashGradient: [Color(0xFF0D1B2E), Color(0xFF13253C), Color(0xFF16304A)],
      splashGlow: Color(0x5A5E9EDC),
      goldAccent: Color(0xFFD4A437),
      goldLight: Color(0xFFFFF8E7),
      goldBorder: Color(0xFFE6C158),
      fabReady: Color(0xFF009688),
      fabRecording: Color(0xFFFF5252),
      fabProcessing: Color(0xFFFFAB40),
      fabDisabled: Colors.grey,
      divider: Color(0x1FFFFFFF),
      isDarkOverlay: true,
    ),
  );
}

/// 深色模式档位的 prefs key（string：'system' / 'light' / 'dark'）。
/// 写入方：设置页外观区「深色模式」选择器；读取方：main() 启动预读。
/// 悬浮窗是独立 engine 且面板固定浅色视觉（跨背景对比度设计，不做深色系），
/// 仅大爆炸分词层（全屏白底模态，深色下刺眼）消费本 key——唤起时由
/// overlay_home._openBigBang reload 后解析，system 档按系统亮度裁决
const kThemeModePrefKey = 'theme_mode';

/// 解析深色模式档位：null/旧版本值/坏串一律兜底跟随系统
ThemeMode parseThemeMode(String? raw) => switch (raw) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => ThemeMode.system,
};
