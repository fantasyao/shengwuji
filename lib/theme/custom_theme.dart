import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';
import 'app_theme_extension.dart';

/// 自定义主题在 `selected_theme` 里存的 ID（区别于 5 套预设的 ID）
const kCustomThemeId = 'custom';

/// 自定义主题配置在 SharedPreferences 里的 JSON key
const kCustomThemeDataKey = 'custom_theme_data';

/// 自定义主题配置：主色 + 三个可选微调项
///
/// - [seed]：用户在选色盘挑的主色（即"选中背景色"的推荐来源），
///   整套推荐色系由它经 HSL 派生（见 [generateCustomTheme]）。
/// - 三个覆盖项（背景色/按钮色/选中背景色）为 null = 用推荐值；
///   非 null = 用户用选色盘手调的任意色（允许反差搭配，用户自己负责观感）。
/// - 序列化只存 int 色值，不含派生结果——派生规则调整后旧配置自动
///   按新规则重建，无需迁移。
class CustomThemeConfig {
  final int seed;
  final int? scaffoldBackground; // 背景色覆盖
  final int? fabReady; // 按钮色覆盖
  final int? selectionBackground; // 选中背景色覆盖（槽 primaryLight）

  const CustomThemeConfig({
    required this.seed,
    this.scaffoldBackground,
    this.fabReady,
    this.selectionBackground,
  });

  Map<String, dynamic> toJson() => {
        'seed': seed,
        if (scaffoldBackground != null) 'scaffoldBackground': scaffoldBackground,
        if (fabReady != null) 'fabReady': fabReady,
        if (selectionBackground != null) 'selectionBackground': selectionBackground,
      };

  /// 解析失败（缺失/坏 JSON/类型不对/seed 越界）一律返回 null，调用方回退默认主题
  static CustomThemeConfig? tryParseJson(String raw) {
    try {
      final map = jsonDecode(raw);
      if (map is! Map<String, dynamic>) return null;
      final seed = map['seed'];
      if (seed is! int) return null;
      return CustomThemeConfig(
        seed: seed,
        scaffoldBackground: _optionalColor(map['scaffoldBackground']),
        fabReady: _optionalColor(map['fabReady']),
        selectionBackground: _optionalColor(map['selectionBackground']),
      );
    } catch (_) {
      return null;
    }
  }

  static int? _optionalColor(dynamic v) => v is int ? v : null;

  static Future<CustomThemeConfig?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(kCustomThemeDataKey);
    if (raw == null || raw.isEmpty) return null;
    return tryParseJson(raw);
  }

  static Future<void> save(CustomThemeConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kCustomThemeDataKey, jsonEncode(config.toJson()));
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kCustomThemeDataKey);
  }

  /// 是否已保存过配置（主题选择 sheet 决定"创建"还是"预览"样式）
  static Future<bool> exists() async => await load() != null;

  CustomThemeConfig copyWith({
    int? seed,
    bool clearScaffoldBackground = false,
    int? scaffoldBackground,
    bool clearFabReady = false,
    int? fabReady,
    bool clearSelectionBackground = false,
    int? selectionBackground,
  }) {
    return CustomThemeConfig(
      seed: seed ?? this.seed,
      scaffoldBackground: clearScaffoldBackground
          ? null
          : (scaffoldBackground ?? this.scaffoldBackground),
      fabReady:
          clearFabReady ? null : (fabReady ?? this.fabReady),
      selectionBackground: clearSelectionBackground
          ? null
          : (selectionBackground ?? this.selectionBackground),
    );
  }
}

/// WCAG 相对对比度（1~21），≥3.0 视为主色上白字可读
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final lighter = la > lb ? la : lb;
  final darker = la > lb ? lb : la;
  return (lighter + 0.05) / (darker + 0.05);
}

/// 由 [config] 派生完整的自定义主题
///
/// 派生策略（对齐既有预设的视觉惯例，参照 sky_blue 的注释先例）：
/// - 同色系浅化做背景/选中背景，加深做强调与启动页；
/// - `textOnPrimary` 按 WCAG 对比度自动选白/深色（sky_blue 用深蓝黑同款思路）；
/// - warning / danger / gold / fab 录音红·处理橙·禁用灰 固定不跟随主色
///   （5 套预设一致的惯例：语义色和品牌色不随主题色变化）；
/// - 恒非拟物（isNeumorphic=false），悬浮窗无需拟物降级。
AppThemeDefinition generateCustomTheme(CustomThemeConfig config) {
  final seed = Color(config.seed);
  final hsl = HSLColor.fromColor(seed);
  final s = hsl.saturation;
  final l = hsl.lightness;

  // --- 推荐色系（全部由 seed 派生）---
  final primary = seed;
  // 选中背景：浅化到 L≈0.82、饱和压半（默认青 #B2DFDB / 晴空蓝 #BFE2F9 的近似区间）
  final primaryLight = hsl
      .withSaturation((s * 0.55).clamp(0.0, 0.55))
      .withLightness(0.82)
      .toColor();
  // 强调/按下态：加深
  final primaryDark = hsl
      .withLightness((l * 0.72).clamp(0.15, 0.45))
      .toColor();
  // 全局背景：极浅低饱和同色调（L 0.965，S ≤0.12——有同色系氛围但不抢戏）
  final recScaffoldBackground = hsl
      .withSaturation((s * 0.2).clamp(0.0, 0.12))
      .withLightness(0.965)
      .toColor();
  // 查询答案区：比选中背景更浅的底 + 深字
  final positiveAccent = hsl
      .withSaturation((s * 0.35).clamp(0.0, 0.35))
      .withLightness(0.93)
      .toColor();
  // 启动页：同色系深底（避免黑底破坏调性，参照 sky_blue 注释）
  final splashBackground = hsl
      .withSaturation((s * 0.8).clamp(0.0, 0.45))
      .withLightness((l * 0.55).clamp(0.14, 0.30))
      .toColor();
  // 时间高亮背景：浅色底（文字用 primaryDark 保证可读）
  final timeHighlightBg = hsl
      .withSaturation((s * 0.5).clamp(0.0, 0.5))
      .withLightness(0.88)
      .toColor();
  // 主色上文字：白字对比度不够就换主色深版（深底亮字方向）
  final white = Colors.white;
  final textOnPrimary = contrastRatio(primary, white) >= 3.0
      ? white
      : hsl.withLightness(0.13).toColor();
  // 按钮推荐色：主色过浅时白图标不可读，自动落到加深版
  final recFabReady = l > 0.55 ? primaryDark : primary;

  // --- 用户微调覆盖 ---
  final scaffoldBackground = config.scaffoldBackground != null
      ? Color(config.scaffoldBackground!)
      : recScaffoldBackground;
  final fabReady =
      config.fabReady != null ? Color(config.fabReady!) : recFabReady;
  final selectionBackground = config.selectionBackground != null
      ? Color(config.selectionBackground!)
      : primaryLight;

  return AppThemeDefinition(
    id: kCustomThemeId,
    name: '自定义',
    seedColor: seed,
    isPro: true,
    extension: AppThemeExtension(
      primary: primary,
      primaryLight: selectionBackground,
      primaryDark: primaryDark,
      surface: Colors.white,
      cardBackground: Colors.white,
      scaffoldBackground: scaffoldBackground,
      textPrimary: const Color(0xDD000000),
      textSecondary: const Color(0x8A000000),
      textHint: Colors.grey,
      textOnPrimary: textOnPrimary,
      positiveAccent: positiveAccent,
      positiveText: primaryDark,
      warningAccent: const Color(0xFFFFF3E0),
      warningText: const Color(0xFFE65100),
      dangerAccent: const Color(0xFFE57373),
      timeHighlight: primaryDark,
      timeHighlightBg: timeHighlightBg,
      splashBackground: splashBackground,
      goldAccent: const Color(0xFFD4A437),
      goldLight: const Color(0xFFFFF8E7),
      goldBorder: const Color(0xFFE6C158),
      fabReady: fabReady,
      fabRecording: const Color(0xFFFF5252),
      fabProcessing: const Color(0xFFFFAB40),
      fabDisabled: Colors.grey,
      divider: const Color(0x14000000),
      isDarkOverlay: false,
    ),
  );
}

/// 按 `selected_theme` 的 ID 解析主题：预设走 [AppThemes.findById]，
/// 'custom' 解析 `custom_theme_data` 配置现建；解析失败返回 null
/// （调用方兜底默认主题）。主 App 启动链与悬浮窗加载共用。
Future<AppThemeDefinition?> loadThemeById(String? themeId) async {
  if (themeId == kCustomThemeId) {
    final config = await CustomThemeConfig.load();
    if (config == null) return null;
    return generateCustomTheme(config);
  }
  return AppThemes.findById(themeId);
}
