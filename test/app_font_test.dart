import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/theme/app_font.dart';
import 'package:shengwuji_app/theme/app_theme.dart';

/// 字体选项（霞鹜文楷 / 平台默认）回归
///
/// 关键陷阱（CLAUDE.md「主题字体配置陷阱」）：ThemeData 有两个字体层级，
/// ThemeData.fontFamily 与 TextTheme 各 style 的 fontFamily 必须同时设置。
/// 只设前者时部分场景仍回退原字体，只设后者时 Scaffold 等默认文字不回退。
void main() {
  group('parseAppFontChoice', () {
    test('system 解析为系统默认', () {
      expect(parseAppFontChoice('system'), AppFontChoice.system);
      expect(AppFontChoice.system.fontFamily, isNull);
    });

    test('wenkai / null / 坏串一律回退霞鹜文楷', () {
      expect(parseAppFontChoice('wenkai'), AppFontChoice.wenkai);
      expect(parseAppFontChoice(null), kDefaultAppFontChoice);
      expect(parseAppFontChoice(''), kDefaultAppFontChoice);
      expect(parseAppFontChoice('not_a_font'), kDefaultAppFontChoice);
      expect(kDefaultAppFontChoice, AppFontChoice.wenkai);
    });

    test('持久化 ID 稳定（prefs 已有值与枚举 id 一致）', () {
      expect(AppFontChoice.wenkai.id, 'wenkai');
      expect(AppFontChoice.system.id, 'system');
      expect(kAppFontPrefKey, 'app_font_family');
    });
  });

  group('toThemeData 字体两层', () {
    test('默认（不传参）= 霞鹜文楷，ThemeData 与 15 个 TextTheme style 全一致', () {
      final themeData = AppThemes.defaultTeal.toThemeData();
      const family = 'LXGWWenKaiMonoGBScreen';
      expect(themeData.textTheme.bodyMedium?.fontFamily, family);
      for (final entry in _textStyles(themeData.textTheme).entries) {
        expect(
          entry.value.fontFamily,
          family,
          reason: '${entry.key} 未设字体（Roboto 回退陷阱）',
        );
      }
    });

    test('system = 两层都不带霞鹜文楷（落到平台默认 Roboto）', () {
      final themeData = AppThemes.defaultTeal.toThemeData(
        font: AppFontChoice.system,
      );
      // 传 fontFamily=null 后 ThemeData 用 Typography 默认字体填充各 style
      expect(themeData.textTheme.bodyMedium?.fontFamily, 'Roboto');
      for (final entry in _textStyles(themeData.textTheme).entries) {
        expect(
          entry.value.fontFamily,
          isNot('LXGWWenKaiMonoGBScreen'),
          reason: entry.key,
        );
        expect(entry.value.fontFamily, 'Roboto', reason: entry.key);
      }
    });

    test('明暗主题传同一字体档，字体系一致', () {
      final light = AppThemes.defaultTeal.toThemeData(
        font: AppFontChoice.system,
      );
      final dark = AppThemes.dark.toThemeData(font: AppFontChoice.system);
      expect(light.textTheme.bodyLarge?.fontFamily, 'Roboto');
      expect(dark.textTheme.bodyLarge?.fontFamily, 'Roboto');
    });
  });
}

/// TextTheme 全部 15 个样式（与 AppThemeDefinition._buildTextTheme 对齐）
Map<String, TextStyle> _textStyles(TextTheme t) => {
  'bodyLarge': t.bodyLarge!,
  'bodyMedium': t.bodyMedium!,
  'bodySmall': t.bodySmall!,
  'displayLarge': t.displayLarge!,
  'displayMedium': t.displayMedium!,
  'displaySmall': t.displaySmall!,
  'headlineLarge': t.headlineLarge!,
  'headlineMedium': t.headlineMedium!,
  'headlineSmall': t.headlineSmall!,
  'titleLarge': t.titleLarge!,
  'titleMedium': t.titleMedium!,
  'titleSmall': t.titleSmall!,
  'labelLarge': t.labelLarge!,
  'labelMedium': t.labelMedium!,
  'labelSmall': t.labelSmall!,
};
