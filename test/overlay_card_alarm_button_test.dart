import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/overlay/widgets/overlay_diary_card.dart';

/// 悬浮窗卡片闹钟按钮接线回归：onAlarm 传入后按钮从「恒禁用占位」变可用，
/// 点击触发回调；onAlarm 为 null 保持禁用占位（按钮仍渲染但无回调）。
/// 完整闹钟流程（解析→权限→sheet→写日历）在 OverlayHome，属 engine 集成层，
/// 单测只锁卡片层的回调契约
void main() {
  Future<void> pumpCard(WidgetTester tester, {VoidCallback? onAlarm}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 296,
            child: ListView(
              children: [
                OverlayDiaryCard(
                  diary: const {
                    'id': 1,
                    'content': '周六晚上八点提醒我去看电影',
                    'is_archived': 0,
                  },
                  maxWidth: 268,
                  expanded: true,
                  onAlarm: onAlarm,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('onAlarm 非空：点击闹钟按钮触发回调', (tester) async {
    var tapped = false;
    await pumpCard(tester, onAlarm: () => tapped = true);
    await tester.tap(find.byIcon(Icons.alarm));
    await tester.pumpAndSettle();
    expect(tapped, true);
  });

  testWidgets('onAlarm 为 null：按钮仍渲染（禁用占位语义保留），点击无回调',
      (tester) async {
    await pumpCard(tester);
    // 无回调路径：点击不抛异常、卡片保持稳定即通过
    await tester.tap(find.byIcon(Icons.alarm));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.alarm), findsOneWidget);
  });
}
