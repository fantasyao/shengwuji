import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/theme/app_theme.dart';
import 'package:shengwuji_app/theme/app_theme_extension.dart';

/// 新拟物主题（第 5 套）注册与不变量回归
///
/// 背景：2026-09-17 新增 Neumorphism 主题（feature/neumorphism-theme）。
/// 关键不变量：拟物"背景与组件同色"是双向阴影成立的前提，
/// scaffoldBackground == cardBackground == surface 三槽必须一致。
void main() {
  group('AppThemes 注册表', () {
    test('包含 5 套主题且新拟物可按 ID 查到', () {
      expect(AppThemes.all.length, 5);
      final found = AppThemes.findById('neumorphism');
      expect(found, isNotNull);
      expect(found!.name, '新拟物');
      // 2026-09-19 拍板：新拟物 Pro 化（原免费），与晴空蓝同走 ProGate 门禁
      expect(found.isPro, isTrue, reason: '拍板：新拟物主题 Pro 化，未解锁/试用过期拦截');
    });

    test('findById 兜底行为不回归（未知 ID 返回 null）', () {
      expect(AppThemes.findById('not_exist'), isNull);
    });
  });

  group('新拟物主题不变量', () {
    final ext = AppThemes.neumorphism.extension;

    test('背景三槽同色（拟物双阴影成立的前提）', () {
      expect(ext.scaffoldBackground, ext.cardBackground);
      expect(ext.cardBackground, ext.surface);
      expect(ext.scaffoldBackground, const Color(0xFFE0E5EC));
    });

    test('isNeumorphic=true 且阴影槽为拍板色值', () {
      expect(ext.isNeumorphic, isTrue);
      expect(ext.neuShadowDark, const Color(0xFFAEB9C9));
      expect(ext.neuShadowLight, const Color(0xFFFFFFFF));
    });

    test('toThemeData 后 AppThemeExtension.of 可解析', () {
      final themeData = AppThemes.neumorphism.toThemeData();
      final resolved = themeData.extension<AppThemeExtension>();
      expect(resolved, isNotNull);
      expect(resolved!.isNeumorphic, isTrue);
    });
  });

  group('旧 4 套主题默认路径', () {
    for (final t in [
      AppThemes.defaultTeal,
      AppThemes.warmOrange,
      AppThemes.forestGreen,
      AppThemes.skyBlue,
    ]) {
      test('${t.name} 不受拟物改造影响（isNeumorphic 默认 false + 阴影占位值）', () {
        expect(t.extension.isNeumorphic, isFalse);
        expect(t.extension.neuShadowDark, const Color(0x1A000000));
        expect(t.extension.neuShadowLight, Colors.white);
        // 背景三槽不要求同色（旧主题白卡+灰底结构保持）
        expect(t.extension.isDarkOverlay, isFalse);
      });
    }
  });

  group('ThemeExtension 契约', () {
    test('copyWith 可覆盖拟物字段', () {
      final copied = AppThemes.defaultTeal.extension.copyWith(
        isNeumorphic: true,
        neuShadowDark: const Color(0xFF112233),
      );
      expect(copied.isNeumorphic, isTrue);
      expect(copied.neuShadowDark, const Color(0xFF112233));
      // 未覆盖字段保持原值
      expect(copied.primary, AppThemes.defaultTeal.extension.primary);
    });

    test('lerp 中点混合颜色，bool 槽按 t<0.5 取值', () {
      final a = AppThemes.defaultTeal.extension;
      final b = AppThemes.neumorphism.extension;
      // 与 isDarkOverlay 同款语义：t<0.5 取 a 侧，t>=0.5 取 b 侧（t=0.5 即 b）
      final at049 = a.lerp(b, 0.49);
      expect(at049.isNeumorphic, a.isNeumorphic, reason: 't<0.5 取 a 侧');
      expect(at049.isNeumorphic, isFalse);
      final mid = a.lerp(b, 0.5);
      expect(mid.isNeumorphic, b.isNeumorphic, reason: 't>=0.5 取 b 侧');
      expect(mid.isNeumorphic, isTrue);
      expect(mid.neuShadowDark, isA<Color>());
    });
  });
}
