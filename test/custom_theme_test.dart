import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shengwuji_app/theme/app_theme.dart';
import 'package:shengwuji_app/theme/custom_theme.dart';

void main() {
  // 默认青主色（与出厂主题衔接的兜底 seed）
  const teal = 0xFF009688;
  // 浅黄主色（L>0.55 的浅色分支用例：#FFE082）
  const lightYellow = 0xFFFFE082;

  group('contrastRatio', () {
    test('同色对比度 1，黑白约 21，白底白字不可读', () {
      final white = Colors.white;
      expect(contrastRatio(white, white), closeTo(1.0, 0.001));
      expect(contrastRatio(Colors.black, Colors.white), closeTo(21.0, 0.5));
      expect(contrastRatio(Colors.white, Colors.white), lessThan(3.0));
    });
  });

  group('generateCustomTheme 基础派生', () {
    final theme = generateCustomTheme(const CustomThemeConfig(seed: teal));
    final ext = theme.extension;

    test('id/名称/Pro 标记', () {
      expect(theme.id, kCustomThemeId);
      expect(theme.name, '自定义');
      expect(theme.isPro, isTrue);
      expect(theme.seedColor, const Color(teal));
    });

    test('背景保持主色色相且极浅（同色系浅化）', () {
      final seedH = HSLColor.fromColor(const Color(teal)).hue;
      final bgHsl = HSLColor.fromColor(ext.scaffoldBackground);
      // 容差放宽到 25°：L≈0.97 的近白色 RGB 每通道仅剩 ~7 级，
      // 1 bit 量化抖动即可折算出十几度色相偏移（物理舍入，非派生错误）
      expect(bgHsl.hue, closeTo(seedH, 25.0));
      expect(bgHsl.lightness, greaterThan(0.9));
      expect(bgHsl.saturation, lessThan(0.13));
    });

    test('选中背景是浅色、强调色比主色深', () {
      final l = HSLColor.fromColor(const Color(teal)).lightness;
      expect(
        HSLColor.fromColor(ext.primaryLight).lightness,
        greaterThan(0.75),
      );
      expect(HSLColor.fromColor(ext.primaryDark).lightness, lessThan(l));
    });

    test('深色主色 → 白字；浅色主色 → 深字（WCAG 对比度自动切换）', () {
      final dark = generateCustomTheme(const CustomThemeConfig(seed: teal));
      expect(dark.extension.textOnPrimary, Colors.white);

      final light = generateCustomTheme(
        const CustomThemeConfig(seed: lightYellow),
      );
      final onPrimary = light.extension.textOnPrimary;
      expect(contrastRatio(const Color(lightYellow), onPrimary),
          greaterThanOrEqualTo(3.0));
      // 深字方向：亮度应明显低于主色
      expect(HSLColor.fromColor(onPrimary).lightness, lessThan(0.3));
    });

    test('按钮推荐色：浅主色自动落到加深版保证白图标可读', () {
      final dark = generateCustomTheme(const CustomThemeConfig(seed: teal));
      expect(dark.extension.fabReady, const Color(teal));

      final light =
          generateCustomTheme(const CustomThemeConfig(seed: lightYellow));
      expect(light.extension.fabReady, light.extension.primaryDark);
      expect(light.extension.fabReady, isNot(const Color(lightYellow)));
    });

    test('语义色/品牌色固定不跟随主色（5 套预设一致的惯例）', () {
      final a = generateCustomTheme(const CustomThemeConfig(seed: teal));
      final b =
          generateCustomTheme(const CustomThemeConfig(seed: lightYellow));
      for (final e in [a.extension, b.extension]) {
        expect(e.warningText, const Color(0xFFE65100));
        expect(e.warningAccent, const Color(0xFFFFF3E0));
        expect(e.dangerAccent, const Color(0xFFE57373));
        expect(e.fabRecording, const Color(0xFFFF5252));
        expect(e.fabProcessing, const Color(0xFFFFAB40));
        expect(e.goldAccent, const Color(0xFFD4A437));
      }
      // 两种主色下这些槽完全一致
      expect(a.extension.warningText, b.extension.warningText);
      expect(a.extension.fabRecording, b.extension.fabRecording);
    });

    test('时间高亮跟随主色（暖橙/墨绿预设先例），高亮背景为浅底', () {
      expect(ext.timeHighlight, ext.primaryDark);
      expect(HSLColor.fromColor(ext.timeHighlightBg).lightness, greaterThan(0.8));
    });

    test('启动页是同色系深底（避免黑底破坏调性）', () {
      expect(HSLColor.fromColor(ext.splashBackground).lightness, lessThan(0.35));
      final seedH = HSLColor.fromColor(const Color(teal)).hue;
      // 深色量化抖动远小于浅色，8° 容差足够
      expect(HSLColor.fromColor(ext.splashBackground).hue, closeTo(seedH, 8.0));
    });

    test('恒非拟物（悬浮窗无需拟物降级）', () {
      expect(ext.isNeumorphic, isFalse);
      expect(ext.isDarkOverlay, isFalse);
    });
  });

  group('generateCustomTheme 用户微调覆盖', () {
    test('覆盖值生效于对应槽位', () {
      const bg = 0xFFFFF0F0, fab = 0xFF112233, sel = 0xFFAABBCC;
      final theme = generateCustomTheme(const CustomThemeConfig(
        seed: teal,
        scaffoldBackground: bg,
        fabReady: fab,
        selectionBackground: sel,
      ));
      expect(theme.extension.scaffoldBackground, const Color(bg));
      expect(theme.extension.fabReady, const Color(fab));
      expect(theme.extension.primaryLight, const Color(sel));
    });

    test('无覆盖 = 纯推荐；恢复推荐后槽位与派生值一致', () {
      const bg = 0xFFFFF0F0;
      final overridden = generateCustomTheme(
        const CustomThemeConfig(seed: teal, scaffoldBackground: bg),
      );
      final recommended =
          generateCustomTheme(const CustomThemeConfig(seed: teal));
      // 清掉覆盖后回到推荐值（编辑页"恢复推荐"按钮的语义）
      final restored = generateCustomTheme(
        const CustomThemeConfig(seed: teal)
            .copyWith(clearScaffoldBackground: true, scaffoldBackground: bg),
      );
      expect(overridden.extension.scaffoldBackground, const Color(bg));
      expect(restored.extension.scaffoldBackground,
          recommended.extension.scaffoldBackground);
    });

    test('反差搭配允许：覆盖后槽位与主色无派生关系', () {
      // 深紫背景 + 暖橙主色，覆盖值原样落地不做"纠正"
      final theme = generateCustomTheme(const CustomThemeConfig(
        seed: 0xFFE65100,
        scaffoldBackground: 0xFF2A1040,
      ));
      expect(theme.extension.scaffoldBackground, const Color(0xFF2A1040));
    });
  });

  group('CustomThemeConfig JSON 往返', () {
    test('含覆盖项的完整往返', () {
      const config = CustomThemeConfig(
        seed: teal,
        scaffoldBackground: 0xFFFFF0F0,
        fabReady: 0xFF112233,
        selectionBackground: 0xFFAABBCC,
      );
      final parsed = CustomThemeConfig.tryParseJson(jsonEncode(config.toJson()));
      expect(parsed, isNotNull);
      expect(parsed!.seed, teal);
      expect(parsed.scaffoldBackground, 0xFFFFF0F0);
      expect(parsed.fabReady, 0xFF112233);
      expect(parsed.selectionBackground, 0xFFAABBCC);
    });

    test('无覆盖项序列化不含 null 字段，解析回 null', () {
      const config = CustomThemeConfig(seed: teal);
      final map = config.toJson();
      expect(map.containsKey('scaffoldBackground'), isFalse);
      expect(map.containsKey('fabReady'), isFalse);
      final parsed = CustomThemeConfig.tryParseJson(jsonEncode(map));
      expect(parsed!.scaffoldBackground, isNull);
      expect(parsed.fabReady, isNull);
      expect(parsed.selectionBackground, isNull);
    });

    test('坏输入一律返回 null（调用方回退默认主题）', () {
      expect(CustomThemeConfig.tryParseJson('not json'), isNull);
      expect(CustomThemeConfig.tryParseJson('[1,2,3]'), isNull);
      expect(CustomThemeConfig.tryParseJson('{"seed":"abc"}'), isNull);
      expect(CustomThemeConfig.tryParseJson('{"scaffoldBackground":1}'), isNull);
    });
  });

  group('loadThemeById（启动/悬浮窗共用加载链）', () {
    test('预设 ID 走注册表，未知 ID 返回 null', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await loadThemeById('default_teal'), same(AppThemes.defaultTheme));
      expect(await loadThemeById('no_such_theme'), isNull);
      expect(await loadThemeById(null), isNull);
    });

    test('custom ID 按保存配置现建主题', () async {
      SharedPreferences.setMockInitialValues({
        kCustomThemeDataKey:
            jsonEncode(const CustomThemeConfig(seed: teal).toJson()),
      });
      final theme = await loadThemeById(kCustomThemeId);
      expect(theme, isNotNull);
      expect(theme!.id, kCustomThemeId);
      expect(theme.extension.fabReady, const Color(teal));
    });

    test('custom ID 但配置坏/缺失 → null（调用方兜底默认青）', () async {
      SharedPreferences.setMockInitialValues({
        kCustomThemeDataKey: '{broken',
        'selected_theme': kCustomThemeId,
      });
      expect(await loadThemeById(kCustomThemeId), isNull);
    });
  });

  group('CustomThemeConfig.load/save/clear（SharedPreferences 封装）', () {
    test('save 后 load 读回同值，clear 后为 null', () async {
      SharedPreferences.setMockInitialValues({});
      const config = CustomThemeConfig(seed: teal, fabReady: 0xFF112233);
      await CustomThemeConfig.save(config);
      expect(await CustomThemeConfig.exists(), isTrue);
      final loaded = await CustomThemeConfig.load();
      expect(loaded!.seed, teal);
      expect(loaded.fabReady, 0xFF112233);

      await CustomThemeConfig.clear();
      expect(await CustomThemeConfig.exists(), isFalse);
      expect(await CustomThemeConfig.load(), isNull);
    });
  });
}
