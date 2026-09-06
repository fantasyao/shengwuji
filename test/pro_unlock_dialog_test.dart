import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/widgets/pro_unlock_dialog.dart';

/// Pro 解锁弹窗三按钮布局回归：
/// 主按钮（金色实心）引导扫码付费 → 底部弹层选微信/支付宝 → 全屏付款码；
/// 已扫码按钮（金色描边+浅金底）给付完款用户一键解锁 → 写 is_pro_unlocked；
/// 次按钮（灰色描边弱化）君子协定先免费用 → 写 is_pro_unlocked。
/// 已解锁态：两个解锁出口整体隐藏、主按钮变灰禁用并切换文案。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> openDialog(WidgetTester tester, {required bool unlocked}) async {
    // 弹窗内容较高（寄语 6 行 + 付款码 + 双按钮），默认 800×600 测试面会溢出
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => ProUnlockDialog.show(
                  context,
                  isAlreadyUnlocked: unlocked,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('未解锁：三按钮并存，层级为主实心金/已扫码浅金底/君子协定纯描边', (tester) async {
    await openDialog(tester, unlocked: false);

    expect(find.text('扫码支付 ¥5 解锁'), findsOneWidget);
    expect(find.text('已扫码，点击解锁'), findsOneWidget);
    expect(find.text('先使用，后续再付费解锁'), findsOneWidget);

    final mainButton = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, '扫码支付 ¥5 解锁'),
    );
    expect(mainButton.onPressed, isNotNull);

    final scannedButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '已扫码，点击解锁'),
    );
    expect(scannedButton.onPressed, isNotNull);
    // 样式层级：已扫码按钮带浅金底，比纯描边的君子协定按钮显著
    expect(scannedButton.style?.backgroundColor, isNotNull);

    final skipButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '先使用，后续再付费解锁'),
    );
    expect(skipButton.onPressed, isNotNull);
    expect(skipButton.style?.backgroundColor, isNull);
  });

  testWidgets('点已扫码按钮：付完款回来一键写 is_pro_unlocked=true 并自动关窗', (tester) async {
    await openDialog(tester, unlocked: false);

    await tester.tap(find.text('已扫码，点击解锁'));
    await tester.pump(); // SnackBar 入场
    await tester.pump(const Duration(milliseconds: 800)); // 越过 700ms 延迟触发 pop
    await tester.pumpAndSettle(); // 弹窗退场动画

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('is_pro_unlocked'), true);
    expect(find.byType(ProUnlockDialog), findsNothing);
  });

  testWidgets('点次按钮：直接写 is_pro_unlocked=true 并自动关窗（无验证）', (tester) async {
    await openDialog(tester, unlocked: false);

    await tester.tap(find.text('先使用，后续再付费解锁'));
    await tester.pump(); // SnackBar 入场
    await tester.pump(const Duration(milliseconds: 800)); // 越过 700ms 延迟触发 pop
    await tester.pumpAndSettle(); // 弹窗退场动画

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('is_pro_unlocked'), true);
    expect(find.byType(ProUnlockDialog), findsNothing);
  });

  testWidgets('已解锁：两个解锁出口隐藏，主按钮变灰禁用显示感谢文案', (tester) async {
    await openDialog(tester, unlocked: true);

    expect(find.text('✓ 已解锁，感谢支持'), findsOneWidget);
    expect(find.text('已扫码，点击解锁'), findsNothing);
    expect(find.text('先使用，后续再付费解锁'), findsNothing);

    final mainButton = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, '✓ 已解锁，感谢支持'),
    );
    expect(mainButton.onPressed, isNull);
  });

  testWidgets('点主按钮：弹付款方式弹层，选微信后进全屏付款码', (tester) async {
    await openDialog(tester, unlocked: false);

    await tester.tap(find.text('扫码支付 ¥5 解锁'));
    await tester.pumpAndSettle();

    expect(find.text('选择付款方式（¥5）'), findsOneWidget);
    // 弹窗背后的付款码缩略图也有「支付宝」标签文字，弹层入口行需按 ListTile 定位
    final wechatTile = find.widgetWithText(ListTile, '微信支付');
    final alipayTile = find.widgetWithText(ListTile, '支付宝');
    expect(wechatTile, findsOneWidget);
    expect(alipayTile, findsOneWidget);

    await tester.tap(wechatTile);
    await tester.pumpAndSettle();

    // 弹层关闭，全屏查看器（黑底沉浸式）接管
    expect(find.text('选择付款方式（¥5）'), findsNothing);
    expect(find.text('微信 · 点击关闭 · 长按保存'), findsOneWidget);
  });
}
