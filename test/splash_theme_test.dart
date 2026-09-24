import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:shengwuji_app/splash_screen.dart';
import 'package:shengwuji_app/theme/app_theme.dart';

void main() {
  // 2026-09-24 启动页重设计（方案 B「深海极光」）：
  // 默认主题带深海三段渐变 + 图标冷蓝辉光，其余主题维持纯色 splashBackground 回落
  group('启动页深海主题槽', () {
    test('默认主题：深海三段渐变 + 冷蓝辉光 + 兜底纯色', () {
      final ext = AppThemes.defaultTeal.extension;
      expect(ext.splashGradient, hasLength(3));
      expect(
        ext.splashGradient,
        const [
          Color(0xFF0D1B2E),
          Color(0xFF13253C),
          Color(0xFF16304A),
        ],
      );
      expect(ext.splashGlow, const Color(0x5A5E9EDC));
      // splashBackground 降级为兜底纯色/授权按钮文字色，仍属渐变色系
      expect(ext.splashBackground, const Color(0xFF13253C));
    });

    test('其余预设主题：渐变/辉光为 null（维持各自同色系纯色底）', () {
      for (final t in [
        AppThemes.warmOrange,
        AppThemes.forestGreen,
        AppThemes.skyBlue,
        AppThemes.neumorphism,
      ]) {
        expect(t.extension.splashGradient, isNull, reason: '${t.name} 不应带渐变');
        expect(t.extension.splashGlow, isNull, reason: '${t.name} 不应带辉光');
      }
    });

    test('主题切换插值：装饰槽 t<0.5 取自身、t≥0.5 取对方（与 bool 槽同策略）', () {
      final a = AppThemes.defaultTeal.extension;
      final b = AppThemes.warmOrange.extension;
      expect(a.lerp(b, 0.4).splashGradient, a.splashGradient);
      expect(a.lerp(b, 0.4).splashGlow, a.splashGlow);
      expect(a.lerp(b, 0.6).splashGradient, b.splashGradient);
      expect(a.lerp(b, 0.6).splashGlow, b.splashGlow);
      expect(b.lerp(a, 0.4).splashGlow, isNull);
    });

    test('copyWith 可覆盖渐变/辉光', () {
      const g = [Color(0xFF111111)];
      final c = AppThemes.warmOrange.extension.copyWith(
        splashGradient: g,
        splashGlow: const Color(0xFF222222),
      );
      expect(c.splashGradient, g);
      expect(c.splashGlow, const Color(0xFF222222));
    });
  });

  group('SplashShell 渲染', () {
    testWidgets('默认主题：铺深海渐变 + 辉光层', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemes.defaultTeal.toThemeData(),
          home: const SplashShell(child: SizedBox.shrink()),
        ),
      );

      final decorations = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((d) => d.decoration)
          .whereType<BoxDecoration>()
          .where((d) => d.gradient != null)
          .toList();

      final linear = decorations
          .map((d) => d.gradient)
          .whereType<LinearGradient>()
          .single;
      expect(linear.begin, Alignment.topCenter);
      expect(linear.end, Alignment.bottomCenter);
      expect(
        linear.colors,
        const [
          Color(0xFF0D1B2E),
          Color(0xFF13253C),
          Color(0xFF16304A),
        ],
      );

      final radial = decorations
          .map((d) => d.gradient)
          .whereType<RadialGradient>()
          .single;
      expect(radial.colors.first, const Color(0x5A5E9EDC));
      expect((radial.colors.last.a * 255.0).round(), 0);
    });

    testWidgets('暖橙主题：无渐变/辉光，回落纯色 splashBackground', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemes.warmOrange.toThemeData(),
          home: const SplashShell(child: SizedBox.shrink()),
        ),
      );

      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(
        scaffold.backgroundColor,
        AppThemes.warmOrange.extension.splashBackground,
      );

      final withGradient = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .map((d) => d.decoration)
          .whereType<BoxDecoration>()
          .where((d) => d.gradient != null);
      expect(withGradient, isEmpty);
    });
  });
}
