import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/overlay/overlay_constants.dart';
import 'package:shengwuji_app/overlay/widgets/overlay_handle.dart';

/// 把手主题回归（2026-09-22，三套皮肤）：双色药丸（默认，历史视觉）/ 蓝紫
///（笔记卡片色系：默认蓝 #6F9AF0 + 灵感标注紫 #AE82E4）/ 拟物胶囊💊（白 +
/// 珊瑚红立体造型，无图标无文字）。文字仅标准档显示（75%/50% 档太挤，
/// 2026-09-22 用户定夺），与主题正交——拟物主题任何档位都无文字。
void main() {
  group('主题解析与属性（纯函数/extension）', () {
    test('parseHandleTheme：合法值原样，null/坏串兜底双色药丸', () {
      expect(OverlayConstants.parseHandleTheme(null), HandleTheme.duo);
      expect(OverlayConstants.parseHandleTheme('duo'), HandleTheme.duo);
      expect(
        OverlayConstants.parseHandleTheme('bluePurple'),
        HandleTheme.bluePurple,
      );
      expect(OverlayConstants.parseHandleTheme('pill3d'), HandleTheme.pill3d);
      // 坏串兜底（含旧版本可能写入的任意 string）
      expect(OverlayConstants.parseHandleTheme(''), HandleTheme.duo);
      expect(OverlayConstants.parseHandleTheme('red'), HandleTheme.duo);
    });

    test('蓝紫主题与笔记卡片色系一致：上=卡片默认蓝，下=灵感标注紫', () {
      expect(
        HandleTheme.bluePurple.capsuleTopColor,
        OverlayConstants.defaultCardColor, // #6F9AF0，色系一致的钉子
      );
      expect(
        HandleTheme.bluePurple.capsuleBottomColor,
        const Color(0xFFAE82E4),
      );
    });

    test('双色药丸主题沿用历史色值（默认视觉不变）', () {
      expect(
        HandleTheme.duo.capsuleTopColor,
        OverlayConstants.handleCapsuleTopColor,
      );
      expect(
        HandleTheme.duo.capsuleBottomColor,
        OverlayConstants.handleCapsuleBottomColor,
      );
      expect(HandleTheme.duo.iconColor, OverlayConstants.handleCapsuleBottomColor,
          reason: '图标取下半色呼应成对（历史语言）');
    });

    test('拟物胶囊：珊瑚红下半 + 无图标无文字 + 拟物标记', () {
      expect(HandleTheme.pill3d.capsuleBottomColor, const Color(0xFFE0524E));
      expect(HandleTheme.pill3d.showsIcon, isFalse);
      expect(HandleTheme.pill3d.isPill3d, isTrue);
      expect(HandleTheme.duo.isPill3d, isFalse);
      expect(HandleTheme.bluePurple.isPill3d, isFalse);
    });

    test('文字显示 = 标准档 且 非拟物主题（档位与主题正交）', () {
      // 档位维度（duo 主题）
      expect(
        OverlayConstants.handleShowsLabel(100, HandleTheme.duo),
        isTrue,
      );
      expect(
        OverlayConstants.handleShowsLabel(75, HandleTheme.duo),
        isFalse,
        reason: '小档竖排文字太挤，2026-09-22 用户定夺不显示',
      );
      expect(OverlayConstants.handleShowsLabel(50, HandleTheme.duo), isFalse);
      // 主题维度（标准档）
      expect(
        OverlayConstants.handleShowsLabel(100, HandleTheme.pill3d),
        isFalse,
        reason: '拟物胶囊纯造型，任何档位无文字',
      );
      expect(
        OverlayConstants.handleShowsLabel(100, HandleTheme.bluePurple),
        isTrue,
      );
    });
  });

  group('把手主题渲染（widget）', () {
    Future<void> pumpHandle(
      WidgetTester tester, {
      HandleTheme theme = HandleTheme.duo,
      int sizePercent = OverlayConstants.handleSizeDefaultPercent,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: OverlayHandle(
                onTap: () {},
                onSwipeInward: () {},
                sizePercent: sizePercent,
                theme: theme,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    LinearGradient currentGradient(WidgetTester tester) =>
        (tester.widget<AnimatedContainer>(find.byType(AnimatedContainer))
                .decoration as BoxDecoration)
            .gradient as LinearGradient;

    testWidgets('蓝紫主题：胶囊渐变为卡片蓝/灵感紫，标准档白色文字保留',
        (tester) async {
      await pumpHandle(tester, theme: HandleTheme.bluePurple);

      final gradient = currentGradient(tester);
      expect(gradient.colors, [
        HandleTheme.bluePurple.capsuleTopColor,
        HandleTheme.bluePurple.capsuleTopColor,
        HandleTheme.bluePurple.capsuleBottomColor,
        HandleTheme.bluePurple.capsuleBottomColor,
      ]);
      expect(find.text('闪\n记'), findsOneWidget);
      // 蓝紫上下皆饱和彩色，图标白色（区别于双色药丸的下半色图标）
      expect(
        tester.widget<Icon>(find.byIcon(Icons.bolt)).color,
        Colors.white,
      );
    });

    testWidgets('拟物胶囊（标准档）：无图标无文字，纯造型叠高光层',
        (tester) async {
      await pumpHandle(tester, theme: HandleTheme.pill3d);

      expect(find.byIcon(Icons.bolt), findsNothing);
      expect(find.text('闪\n记'), findsNothing);
      // 高光条：拟物立体感的标志层（白色渐变）
      expect(
        find.byWidgetPredicate(
          (w) => w is DecoratedBox && _hasHighlightGradient(w.decoration),
        ),
        findsOneWidget,
      );
    });

    testWidgets('拟物胶囊 + 迷你档：同样无图标无文字（档位与主题正交）',
        (tester) async {
      await pumpHandle(
        tester,
        theme: HandleTheme.pill3d,
        sizePercent: 50,
      );

      expect(find.byIcon(Icons.bolt), findsNothing);
      expect(find.text('闪\n记'), findsNothing);
    });
  });
}

bool _hasHighlightGradient(Decoration? decoration) {
  if (decoration is! BoxDecoration) return false;
  final gradient = decoration.gradient;
  return gradient is LinearGradient &&
      gradient.colors.contains(const Color(0xA6FFFFFF));
}
