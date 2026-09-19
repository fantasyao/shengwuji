import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/theme/app_theme.dart';
import 'package:shengwuji_app/widgets/swipe_dismiss_card.dart';

/// SwipeDismissCard 泛化参数回归：
/// 悬浮窗卡片划走归档/删除复用本组件（fullWidth=false 自适应宽 + 悬浮窗
/// 节奏时长 + onSwipeCollapse 朝停靠边缘快滑转发收起），主 App 日记页继续
/// 走默认全宽；停靠左缘时 dismissDirection=right 镜像划走方向。
/// 默认参数用例锁定主 App 历史行为不回归。
///
/// ⚠️ 测试事件语义（同 diary_floating_button_test）：按下后的第一个 move
/// 事件被手势竞技场消费成 dragStart（不产生 update、不积累偏移），所以每条
/// 拖拽用例先来一步「热身 move」烧掉 dragStart，再发真正计数的 move。
void main() {
  const childKey = Key('swipe-child');

  Future<void> pumpCard(
    WidgetTester tester, {
    bool fullWidth = true,
    bool enabled = true,
    bool showIcon = true,
    void Function()? onDismissed,
    void Function()? onSwipeCollapse,
    SwipeDismissDirection dismissDirection = SwipeDismissDirection.left,
  }) async {
    // 逻辑分辨率 400×800（dpr=1）：全宽模式阈值 = 400×0.5 = 200，
    // 自适应宽（卡片 100）阈值 = 100×0.5 = 50
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        // AppThemeExtension.of 经 Theme.extension 解析，必须挂应用主题
        theme: AppThemes.defaultTheme.toThemeData(),
        home: Scaffold(
          body: Center(
            child: SwipeDismissCard(
              fullWidth: fullWidth,
              enabled: enabled,
              showIcon: showIcon,
              onDismissed: onDismissed ?? () {},
              onSwipeCollapse: onSwipeCollapse,
              dismissDirection: dismissDirection,
              child: Container(
                key: childKey,
                width: 100,
                height: 46,
                color: const Color(0xFF6F9AF0),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<TestGesture> press(WidgetTester tester) {
    return tester.startGesture(tester.getCenter(find.byType(SwipeDismissCard)));
  }

  testWidgets('默认全宽模式：子组件强制铺满屏宽（主 App 历史行为回归）', (tester) async {
    await pumpCard(tester);
    // 子组件自身 width:100 被 SizedBox(width:400) 的紧约束覆盖成屏宽
    expect(tester.getSize(find.byKey(childKey)).width, 400);
  });

  testWidgets('fullWidth=false：子组件保持自身宽度（悬浮窗自适应卡宽）', (tester) async {
    await pumpCard(tester, fullWidth: false);
    expect(tester.getSize(find.byKey(childKey)).width, 100);
  });

  testWidgets('全宽默认：拖过 0.5×屏宽松手 → 划走回调 + 卡片移出渲染树', (tester) async {
    var dismissed = false;
    await pumpCard(tester, onDismissed: () => dismissed = true);

    final gesture = await press(tester);
    await gesture.moveBy(const Offset(-10, 0)); // 热身（消费为 dragStart）
    await gesture.moveBy(const Offset(-250, 0)); // 累计 250 ≥ 阈值 200
    await gesture.up();
    await tester.pumpAndSettle(); // 划走动画 250ms 走完

    expect(dismissed, isTrue);
    expect(find.byKey(childKey), findsNothing); // SizedBox.shrink 替换
  });

  testWidgets('未过阈值松手 → 弹回原位，不触发划走', (tester) async {
    var dismissed = false;
    await pumpCard(tester, onDismissed: () => dismissed = true);

    final topLeftBefore = tester.getTopLeft(find.byKey(childKey));
    final gesture = await press(tester);
    await gesture.moveBy(const Offset(-10, 0));
    await gesture.moveBy(const Offset(-50, 0)); // 累计 50 < 阈值 200
    await gesture.up();
    await tester.pumpAndSettle(); // 弹回动画走完

    expect(dismissed, isFalse);
    expect(tester.getTopLeft(find.byKey(childKey)), topLeftBefore);
  });

  testWidgets('fullWidth=false：阈值按卡片宽算（100 宽卡 → 50 触发）', (tester) async {
    var dismissed = false;
    await pumpCard(
      tester,
      fullWidth: false,
      onDismissed: () => dismissed = true,
    );

    final gesture = await press(tester);
    await gesture.moveBy(const Offset(-10, 0));
    await gesture.moveBy(const Offset(-60, 0)); // 累计 60 ≥ 阈值 50
    await gesture.up();
    await tester.pumpAndSettle();

    expect(dismissed, isTrue);
  });

  testWidgets('小位移快甩（velocity < -300）也触发划走', (tester) async {
    var dismissed = false;
    await pumpCard(tester, onDismissed: () => dismissed = true);

    final gesture = await press(tester);
    // 热身 move 消费为 dragStart（sourceTimeStamp=16ms）；
    // 第二步 40px/16ms = 2500px/s，远超 -300 速度线；累计位移 40 < 200
    await gesture.moveBy(
      const Offset(-10, 0),
      timeStamp: const Duration(milliseconds: 16),
    );
    await gesture.moveBy(
      const Offset(-40, 0),
      timeStamp: const Duration(milliseconds: 32),
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(dismissed, isTrue);
  });

  testWidgets('右向快甩触发 onSwipeCollapse（转发收起），不触发划走', (tester) async {
    var dismissed = false;
    var swipedRight = false;
    await pumpCard(
      tester,
      onDismissed: () => dismissed = true,
      onSwipeCollapse: () => swipedRight = true,
    );

    final gesture = await press(tester);
    await gesture.moveBy(
      const Offset(10, 0),
      timeStamp: const Duration(milliseconds: 16),
    );
    // 单事件 +40 > onSwipeCollapseThreshold(4) → 武装
    await gesture.moveBy(
      const Offset(40, 0),
      timeStamp: const Duration(milliseconds: 32),
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(swipedRight, isTrue);
    expect(dismissed, isFalse); // 右滑速度为正、位移被钳在 0
  });

  testWidgets('慢速右滑（单事件不超阈值）不触发 onSwipeCollapse（防误触）', (tester) async {
    var swipedRight = false;
    await pumpCard(tester, onSwipeCollapse: () => swipedRight = true);

    final gesture = await press(tester);
    // 多次小步移动：单事件 +3 均不超 4（与面板右滑同款"单事件超阈值"判定）
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(3, 0));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(swipedRight, isFalse);
  });

  testWidgets('enabled=false：不注册手势，拖拽零响应（编辑态降级）', (tester) async {
    var dismissed = false;
    var swipedRight = false;
    await pumpCard(
      tester,
      enabled: false,
      onDismissed: () => dismissed = true,
      onSwipeCollapse: () => swipedRight = true,
    );

    final gesture = await press(tester);
    await gesture.moveBy(const Offset(-10, 0));
    await gesture.moveBy(const Offset(-250, 0)); // 左滑够深也不触发
    await gesture.up();
    await tester.pumpAndSettle();

    final gesture2 = await press(tester);
    await gesture2.moveBy(const Offset(40, 0)); // 右滑也不转发
    await gesture2.up();
    await tester.pumpAndSettle();

    expect(dismissed, isFalse);
    expect(swipedRight, isFalse);
    expect(find.byKey(childKey), findsOneWidget); // 卡片原位保留
  });

  testWidgets('默认 showIcon=true：拖动中出现揭示图标（主 App 历史行为回归）', (tester) async {
    await pumpCard(tester);
    final gesture = await press(tester);
    await gesture.moveBy(const Offset(-10, 0)); // 热身（消费为 dragStart）
    await gesture.moveBy(const Offset(-60, 0)); // 拖出揭示区（>5px）
    await tester.pump();

    expect(find.byIcon(Icons.archive), findsOneWidget);
  });

  testWidgets('showIcon=false：拖动中不渲染揭示图标（悬浮窗无转圈+图标）', (tester) async {
    var dismissed = false;
    await pumpCard(
      tester,
      showIcon: false,
      onDismissed: () => dismissed = true,
    );
    final gesture = await press(tester);
    await gesture.moveBy(const Offset(-10, 0));
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();

    expect(find.byIcon(Icons.archive), findsNothing);
    // 组件内揭示层（圆圈进度 CustomPaint）整层不渲染（范围限定组件内，
    // 排除 Material 框架自带的 CustomPaint）
    expect(
      find.descendant(
        of: find.byType(SwipeDismissCard),
        matching: find.byType(CustomPaint),
      ),
      findsNothing,
    );

    // 触发逻辑不受影响：继续拖过阈值松手照常划走
    await gesture.moveBy(const Offset(-150, 0)); // 累计 210 ≥ 阈值 200
    await gesture.up();
    await tester.pumpAndSettle();
    expect(dismissed, isTrue);
  });

  testWidgets('dismissDirection=right（停靠左缘镜像）：右滑过阈值划走', (tester) async {
    var dismissed = false;
    await pumpCard(
      tester,
      fullWidth: false,
      dismissDirection: SwipeDismissDirection.right,
      onDismissed: () => dismissed = true,
    );

    final gesture = await press(tester);
    await gesture.moveBy(const Offset(10, 0)); // 热身（消费为 dragStart）
    await gesture.moveBy(const Offset(60, 0)); // 累计 60 ≥ 阈值 50（镜像方向 +x）
    await gesture.up();
    await tester.pumpAndSettle();

    expect(dismissed, isTrue, reason: '左缘停靠时右滑 = 朝屏幕内侧 = 归档划走');
    expect(find.byKey(childKey), findsNothing); // SizedBox.shrink 替换
  });

  testWidgets('dismissDirection=right：反方向（左滑）慢拖弹回不划走', (tester) async {
    var dismissed = false;
    await pumpCard(
      tester,
      fullWidth: false,
      dismissDirection: SwipeDismissDirection.right,
      onDismissed: () => dismissed = true,
    );

    final topLeftBefore = tester.getTopLeft(find.byKey(childKey));
    final gesture = await press(tester);
    await gesture.moveBy(const Offset(-10, 0));
    await gesture.moveBy(const Offset(-60, 0)); // 反方向累计，应被钳在 0
    await gesture.up();
    await tester.pumpAndSettle();

    expect(dismissed, isFalse);
    expect(
      tester.getTopLeft(find.byKey(childKey)),
      topLeftBefore,
      reason: '反方向拖动弹回原位',
    );
  });

  testWidgets('dismissDirection=right：左向快甩触发 onSwipeCollapse（镜像转发）', (
    tester,
  ) async {
    var dismissed = false;
    var collapsed = false;
    await pumpCard(
      tester,
      fullWidth: false,
      dismissDirection: SwipeDismissDirection.right,
      onDismissed: () => dismissed = true,
      onSwipeCollapse: () => collapsed = true,
    );

    final gesture = await press(tester);
    await gesture.moveBy(
      const Offset(-10, 0),
      timeStamp: const Duration(milliseconds: 16),
    );
    // 单事件 -40 < -onSwipeCollapseThreshold(4) → 武装（镜像方向的反向快滑）
    await gesture.moveBy(
      const Offset(-40, 0),
      timeStamp: const Duration(milliseconds: 32),
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(collapsed, isTrue, reason: '左缘停靠时朝停靠边缘（左）快滑转发收起');
    expect(dismissed, isFalse);
  });
}
