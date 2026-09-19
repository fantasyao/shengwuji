import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/overlay/overlay_constants.dart';
import 'package:shengwuji_app/overlay/widgets/pro_locked_hint_pill.dart';

/// Pro 未解锁提示胶囊回归：主/副文案齐全（被 Kotlin 门禁拦截后渲染在
/// 312×84 提示窗中央），贴屏端边距随停靠侧镜像（与录音胶囊对齐规则一致）。
void main() {
  Widget wrap(Widget child) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: OverlayConstants.voiceMemoWindowWidth.toDouble(),
            height: OverlayConstants.voiceMemoWindowHeight.toDouble(),
            child: child,
          ),
        ),
      );

  testWidgets('渲染主文案「暂未解锁，无法使用」与解锁引导副文案', (tester) async {
    await tester.pumpWidget(wrap(const ProLockedHintPill(dockLeft: true)));
    expect(find.text('暂未解锁，无法使用'), findsOneWidget);
    expect(find.text('悬浮窗是 Pro 功能，请在声物记设置页解锁'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });

  testWidgets('停靠侧镜像：左停靠贴左缘边距，右停靠贴右缘边距', (tester) async {
    final edge = OverlayConstants.voiceMemoEdgeMargin.toDouble();
    await tester.pumpWidget(wrap(const ProLockedHintPill(dockLeft: true)));
    final leftPill = tester.widget<Container>(
      find.ancestor(of: find.text('暂未解锁，无法使用'), matching: find.byType(Container)).first,
    );
    expect((leftPill.margin as EdgeInsets).left, edge);
    expect((leftPill.margin as EdgeInsets).right, 0);

    await tester.pumpWidget(wrap(const ProLockedHintPill(dockLeft: false)));
    final rightPill = tester.widget<Container>(
      find.ancestor(of: find.text('暂未解锁，无法使用'), matching: find.byType(Container)).first,
    );
    expect((rightPill.margin as EdgeInsets).left, 0);
    expect((rightPill.margin as EdgeInsets).right, edge);
  });
}
