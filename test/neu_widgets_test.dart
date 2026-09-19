import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/theme/app_theme.dart';
import 'package:shengwuji_app/widgets/neu_widgets.dart';

/// 新拟物组件渲染冒烟
///
/// 背景：2026-09-18 真机反馈开关"灰/绿未铺满""像平面无立体感"两轮翻车
/// 后，NeuSwitch 定稿 canvas 内阴影（_InsetShadowPainter）+ CSS 同构
/// 三层结构（渐变底 → 内阴影 → 滑块）——用渲染冒烟+几何/颜色断言锁定。
void main() {
  Widget wrap(Widget child) => MaterialApp(
    theme: AppThemes.neumorphism.toThemeData(),
    home: Scaffold(body: Center(child: child)),
  );

  /// 滑块视觉圆：key Container 的 margin 属于外层 Padding（其 RenderBox
  /// 含 margin），几何断言须下钻一层量 DecoratedBox 才是圆的真实边界
  Finder thumbCircle() => find.descendant(
    of: find.byKey(const Key('neu_switch_thumb')),
    matching: find.byType(DecoratedBox),
  );

  testWidgets('NeuInset 三层硬边渲染冒烟（拟物主题）', (tester) async {
    await tester.pumpWidget(
      wrap(
        const NeuInset(
          radius: 16,
          child: SizedBox(width: 200, height: 48),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(NeuInset), findsOneWidget);
  });

  testWidgets('NeuSwitch 点击触发回调并滑块位移', (tester) async {
    var called = false;
    await tester.pumpWidget(wrap(NeuSwitch(value: false, onChanged: (v) => called = true)));
    await tester.tap(find.byType(NeuSwitch));
    await tester.pumpAndSettle();
    expect(called, isTrue);
  });

  testWidgets('NeuSwitch onChanged=null 禁用：点击不回调', (tester) async {
    // 禁用态 = onChanged 传 null（与 M3 Switch 语义一致，如日历弹层
    // 通知权限缺失时）。点击后回调不应被触发。
    var called = false;
    await tester.pumpWidget(
      wrap(
        NeuSwitch(
          value: false,
          onChanged: null,
        ),
      ),
    );
    await tester.tap(find.byType(NeuSwitch), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(called, isFalse);
  });

  testWidgets('NeuVoiceFab 拟物圆钮渲染冒烟（无环定稿版）', (tester) async {
    await tester.pumpWidget(
      wrap(const NeuVoiceFab(size: 94, child: Icon(Icons.mic, size: 46))),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(NeuVoiceFab), findsOneWidget);
    // 无凹环定稿：子树里不应再出现 NeuInset，图标直接落在凸面上
    expect(find.byType(NeuInset), findsNothing);
    expect(find.byIcon(Icons.mic), findsOneWidget);
  });

  testWidgets('NeuVoiceFab insetRing=true 回退凹环历史方案渲染冒烟', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const NeuVoiceFab(
          size: 94,
          insetRing: true,
          child: Icon(Icons.mic, size: 30),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    // 凹环历史方案：子树含 NeuInset
    expect(find.byType(NeuInset), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsOneWidget);
  });

  testWidgets('选中态滑块居轨道右端，沿弧留 2px 同心间隙（设计图样式）', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(NeuSwitch(value: true, onChanged: (_) {})));
    await tester.pumpAndSettle();
    // 几何：胶囊端弧半径 13；滑块视觉圆（margin 内层 DecoratedBox）
    // 右缘 = 轨道右缘 - 2。滑块圆半径 11 + margin 2 = 13（圆心与端弧
    // 圆心重合），沿弧间隙均匀、贴合紧密，染色青从间隙透出一圈光环
    final trackRight = tester.getTopRight(find.byType(NeuSwitch)).dx;
    final thumbRight = tester.getTopRight(thumbCircle()).dx;
    expect(trackRight - thumbRight, closeTo(2.0, 0.1));
  });

  testWidgets('未选中态滑块居轨道左端，沿弧留 2px 同心间隙', (tester) async {
    await tester.pumpWidget(wrap(NeuSwitch(value: false, onChanged: (_) {})));
    await tester.pumpAndSettle();
    final trackLeft = tester.getTopLeft(find.byType(NeuSwitch)).dx;
    final thumbLeft = tester.getTopLeft(thumbCircle()).dx;
    expect(thumbLeft - trackLeft, closeTo(2.0, 0.1));
  });

  testWidgets('选中态轨道为 CSS 同构结构：纯青渐变底 + 内阴影 painter', (
    tester,
  ) async {
    // 2026-09-18 两轮翻车锁定：NeuInset 中性实色壳（"灰/绿未铺满"）与
    // 对角渐变烘焙（只有角部明暗、"像平面"）均已废弃。定稿 = canvas
    // 内阴影（真 blur、半透明叠加）+ 纯 CSS 背景渐变底，滑块浮在阴影上。
    await tester.pumpWidget(wrap(NeuSwitch(value: true, onChanged: (_) {})));
    await tester.pumpAndSettle();
    expect(find.byType(NeuInset), findsNothing);
    // 底色层 = 普通 Container（颜色即时切换，无隐式动画），取带渐变的那个
    final track = tester
        .widget<Container>(
          find.byWidgetPredicate(
            (w) =>
                w is Container &&
                w.decoration is BoxDecoration &&
                (w.decoration! as BoxDecoration).gradient != null,
          ),
        )
        .decoration! as BoxDecoration;
    // 底 = CSS 背景渐变 145deg #00A896→#00806F（无烘焙色）
    expect(track.gradient, isNotNull);
    expect(
      (track.gradient! as LinearGradient).colors,
      const [Color(0xFF00A896), Color(0xFF00806F)],
    );
    // 内阴影 = CustomPaint painter（_InsetShadowPainter，真 blur 月牙环）
    expect(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter != null,
      ),
      findsWidgets,
    );
    // 滑块 22（贴合紧密，HTML 原版参数）
    expect(tester.getSize(thumbCircle()), const Size(22, 22));
  });
}
