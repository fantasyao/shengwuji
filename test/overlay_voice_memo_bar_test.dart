import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/overlay/overlay_voice_memo.dart';
import 'package:shengwuji_app/overlay/widgets/overlay_voice_memo_bar.dart';

/// 语音速记录音胶囊（性能审查 Top8 回归）：
/// 红点闪烁（录音态）与三点跳动（转写态）两个动画控制器改为随分支挂载/销毁，
/// 任一时刻只有一个在转——不用的那个不再空转驱动逐帧；可见动画一帧不变。
///
/// 事件语义：胶囊切换依赖父层重建（生产中 OverlayHome 监听 controller 后
/// setState；测试里用重新 pumpWidget 等价模拟）。查找全部限定在胶囊子树内
/// （MaterialApp 路由过渡自带 FadeTransition/Transform，不能按类型全局找）。
void main() {
  final bar = find.byType(OverlayVoiceMemoBar);

  Future<void> pumpBar(WidgetTester tester, OverlayVoiceMemoController c) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: OverlayVoiceMemoBar(controller: c)),
      ),
    );
  }

  testWidgets('录音态：红点闪烁动画在跑，无「转写中」', (tester) async {
    final c = OverlayVoiceMemoController()
      ..setStateForTest(OverlayVoiceMemoState.recording);
    await pumpBar(tester, c);
    await tester.pump();

    expect(find.descendant(of: bar, matching: find.text('转写中')), findsNothing,
        reason: '录音态不渲染转写胶囊');
    final fade = find.descendant(of: bar, matching: find.byType(FadeTransition));
    expect(fade, findsOneWidget, reason: '红点闪烁 = 胶囊内唯一 FadeTransition');
    final t1 = tester.widget<FadeTransition>(fade).opacity.value;
    await tester.pump(const Duration(milliseconds: 150));
    final t2 = tester.widget<FadeTransition>(fade).opacity.value;
    expect(t2, isNot(t1), reason: '录音态红点闪烁动画持续运行');
  });

  testWidgets('录音→转写：胶囊切换，红点动画随分支销毁、三点跳动接管', (tester) async {
    final c = OverlayVoiceMemoController()
      ..setStateForTest(OverlayVoiceMemoState.recording);
    await pumpBar(tester, c);
    await tester.pump();
    expect(
      find.descendant(of: bar, matching: find.byType(FadeTransition)),
      findsOneWidget,
    );

    c.setStateForTest(OverlayVoiceMemoState.transcribing);
    await pumpBar(tester, c); // 父层重建 → 分支切换
    await tester.pump();

    expect(find.descendant(of: bar, matching: find.text('转写中')), findsOneWidget);
    expect(
      find.descendant(of: bar, matching: find.byType(FadeTransition)),
      findsNothing,
      reason: '录音胶囊卸载，红点闪烁控制器随分支销毁',
    );

    // 三点跳动：三个 Transform 的 y 偏移随帧变化（波浪相位推进）
    List<double> dotOffsets() => tester
        .widgetList<Transform>(
          find.descendant(of: bar, matching: find.byType(Transform)),
        )
        .map((t) => t.transform.getTranslation().y)
        .toList();
    expect(dotOffsets().length, 3, reason: '三个跳动点');
    final y1 = dotOffsets();
    await tester.pump(const Duration(milliseconds: 150));
    final y2 = dotOffsets();
    expect(y2, isNot(y1), reason: '转写态三点跳动动画持续运行');
  });

  testWidgets('转写→录音：切回红点闪烁，三点动画随分支销毁', (tester) async {
    final c = OverlayVoiceMemoController()
      ..setStateForTest(OverlayVoiceMemoState.transcribing);
    await pumpBar(tester, c);
    await tester.pump();
    expect(find.descendant(of: bar, matching: find.text('转写中')), findsOneWidget);

    c.setStateForTest(OverlayVoiceMemoState.recording);
    await pumpBar(tester, c);
    await tester.pump();

    expect(find.descendant(of: bar, matching: find.text('转写中')), findsNothing);
    expect(
      find.descendant(of: bar, matching: find.byType(Transform)),
      findsNothing,
      reason: '转写胶囊卸载，三点跳动控制器随分支销毁',
    );
    expect(
      find.descendant(of: bar, matching: find.byType(FadeTransition)),
      findsOneWidget,
      reason: '切回红点闪烁',
    );
  });
}
