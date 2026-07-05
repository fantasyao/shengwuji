import 'package:flutter/material.dart';
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

  /// 该主题的完整语义化色槽
  final AppThemeExtension extension;

  const AppThemeDefinition({
    required this.id,
    required this.name,
    required this.seedColor,
    this.isPro = false,
    required this.extension,
  });

  /// 构建 ThemeData（保留霞鹜文楷字体配置）
  ThemeData toThemeData() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.light,
    );

    return ThemeData(
      fontFamily: _kFontFamily,
      textTheme: _kTextTheme,
      colorScheme: colorScheme,
      useMaterial3: true,
      extensions: [extension],
    );
  }

  /// 全部主题共用的字体名（霞鹜文楷等宽屏幕版）
  static const _kFontFamily = 'LXGWWenKaiMonoGBScreen';

  /// 全部主题共用的 TextTheme（显式配置所有 14 种文本样式避免 Roboto 回退）
  static const TextTheme _kTextTheme = TextTheme(
    bodyLarge: TextStyle(fontFamily: _kFontFamily),
    bodyMedium: TextStyle(fontFamily: _kFontFamily),
    bodySmall: TextStyle(fontFamily: _kFontFamily),
    displayLarge: TextStyle(fontFamily: _kFontFamily),
    displayMedium: TextStyle(fontFamily: _kFontFamily),
    displaySmall: TextStyle(fontFamily: _kFontFamily),
    headlineLarge: TextStyle(fontFamily: _kFontFamily),
    headlineMedium: TextStyle(fontFamily: _kFontFamily),
    headlineSmall: TextStyle(fontFamily: _kFontFamily),
    titleLarge: TextStyle(fontFamily: _kFontFamily),
    titleMedium: TextStyle(fontFamily: _kFontFamily),
    titleSmall: TextStyle(fontFamily: _kFontFamily),
    labelLarge: TextStyle(fontFamily: _kFontFamily),
    labelMedium: TextStyle(fontFamily: _kFontFamily),
    labelSmall: TextStyle(fontFamily: _kFontFamily),
  );
}

/// 所有预设主题注册表
///
/// 新增主题只需在 `_all` 里加一项即可，设置页会自动遍历显示。
class AppThemes {
  /// 所有预设主题列表（顺序即设置页显示顺序）
  static const all = [defaultTeal, warmOrange, forestGreen, skyBlue];

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
      splashBackground: Color(0xFF2C3E50),
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
}
