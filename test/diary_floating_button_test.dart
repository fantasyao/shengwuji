import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/theme/app_theme.dart';
import 'package:shengwuji_app/widgets/diary_floating_button.dart';

/// 日记页浮动麦克风按钮（性能审查 Top6 回归）：
/// ① 上滑「Aa」手势拖拽帧只重建本组件，外层宿主零重建（原实现拖拽每帧
///    MainScaffold 整页 setState，IndexedStack 四页陪跑）；
/// ② 手势语义保持：超阈值松手新建文本笔记、斜滑取消、锁定录音禁拖拽。
///
/// ⚠️ 测试事件语义：按下后的第一个 move 事件被手势竞技场消费成
/// dragStart（不产生 update、不积累偏移），真实手指的连续滑动后续每个
/// move 才是 dragUpdate——所以每条拖拽用例先来一步「热身 move」烧掉
/// dragStart，再断言偏移行为。
void main() {
  final statusText = '就绪';

  // 外层宿主重建计数器：Builder 包裹按钮，拖拽帧不应重建到这一层
  final counter = _BuildCounter();

  Future<void> pumpButton(
    WidgetTester tester, {
    bool isLockedRecording = false,
  }) async {
    counter.reset();
    await tester.pumpWidget(
      MaterialApp(
        // AppThemeExtension.of 经 Theme.extension 解析，必须挂应用主题
        theme: AppThemes.defaultTheme.toThemeData(),
        home: Scaffold(
          body: Stack(
            children: [
              Builder(
                builder: (context) {
                  counter.value++;
                  return DiaryFloatingButton(
                    modelAvailable: true,
                    isReady: true,
                    isListening: false,
                    isProcessing: false,
                    isLockedRecording: isLockedRecording,
                    statusText: statusText,
                    onStartListening: () => counter.startCalls++,
                    onStopListening: () => counter.stopCalls++,
                    onNewTextNote: () => counter.newTextNoteCalls++,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  // Aa 徽章的可见度（AnimatedOpacity 的目标 opacity）
  double badgeOpacity(WidgetTester tester) {
    final opacity = tester.widget<AnimatedOpacity>(
      find.ancestor(
        of: find.text('Aa'),
        matching: find.byType(AnimatedOpacity),
      ),
    );
    return opacity.opacity;
  }

  // 手势起点 = 麦克风图标中心（94×94 圆形按钮正中）；
  // 两步热身（4px + 30px，跨过 kTouchSlop 18px）：竞技场在接受那一刻把
  // 累计位移消费成 dragStart（不产生 update、不积累偏移），此后 move 才是
  // dragUpdate——见文件头测试事件语义说明
  Future<TestGesture> pressAndStartDrag(WidgetTester tester) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byIcon(Icons.mic)),
    );
    await gesture.moveBy(const Offset(0, -4));
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    expect(badgeOpacity(tester), 0.0, reason: 'dragStart 只置拖拽态，尚无位移');
    return gesture;
  }

  testWidgets('就绪态：麦克风图标 + 状态文字，徽章隐藏', (tester) async {
    await pumpButton(tester);
    expect(find.byIcon(Icons.mic), findsOneWidget);
    expect(find.text(statusText), findsOneWidget);
    expect(badgeOpacity(tester), 0.0);
  });

  testWidgets('上滑拖拽：外层宿主零重建，徽章跟手出现，超阈值切换「松手新建」', (tester) async {
    await pumpButton(tester);
    expect(counter.value, 1);

    final gesture = await pressAndStartDrag(tester);
    await gesture.moveBy(const Offset(0, -25)); // 累计 25px：渐显区间（10~35px）
    await tester.pump();
    expect(counter.value, 1, reason: '拖拽帧不得重建外层宿主（原实现整页 setState）');
    expect(badgeOpacity(tester), greaterThan(0.0));
    expect(find.text(statusText), findsOneWidget);

    await gesture.moveBy(const Offset(0, -50)); // 累计 75px，达到激活阈值
    await tester.pump();
    expect(counter.value, 1, reason: '激活帧同样只重建按钮子树');
    expect(find.text('松手新建文本笔记'), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(counter.newTextNoteCalls, 1, reason: '超阈值松手新建文本笔记');
    expect(find.text(statusText), findsOneWidget, reason: '松手后状态文字复位');
    expect(badgeOpacity(tester), 0.0, reason: 'Aa 徽章淡出复位');
  });

  testWidgets('斜滑：垂直识别器只送 dy（delta.dx 恒 0），按垂直分量继续跟踪', (tester) async {
    // ⚠️ 行为记录（重构前等价）：原实现的「水平位移 >24px 取消上滑」守卫读
    // details.delta.dx，而 VerticalDragGestureRecognizer 的 update delta 已做
    // 轴向过滤（dx 恒为 0，实测见本用例）——守卫自引入起即为死代码。
    // 本组件平移保持原行为不变；守卫去留（补 localPosition 版本或删除）
    // 留给产品决策，不在本次性能重构范围内。
    await pumpButton(tester);

    final gesture = await pressAndStartDrag(tester);
    for (var i = 0; i < 3; i++) {
      await gesture.moveBy(const Offset(12, -8)); // 斜着滑：dx 合计 36、dy 合计 24
    }
    await tester.pump();
    expect(badgeOpacity(tester), greaterThan(0.0), reason: 'dy=24 在渐显区间，徽章照常出现');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(counter.newTextNoteCalls, 0, reason: '24px < 70px 阈值不触发新建');
    expect(badgeOpacity(tester), 0.0);
  });

  testWidgets('未达阈值松手：徽章淡出复位，不触发新建', (tester) async {
    await pumpButton(tester);

    final gesture = await pressAndStartDrag(tester);
    await gesture.moveBy(const Offset(0, -40)); // 累计 40px < 70px 阈值
    await tester.pump();
    expect(badgeOpacity(tester), greaterThan(0.0));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(counter.newTextNoteCalls, 0, reason: '未达阈值不新建');
    expect(find.text(statusText), findsOneWidget, reason: '状态文字复位');
    expect(badgeOpacity(tester), 0.0, reason: 'Aa 徽章以 180ms 动画恢复默认');
  });

  testWidgets('锁定录音态：上滑禁用，点击按钮停止录音', (tester) async {
    await pumpButton(tester, isLockedRecording: true);
    expect(find.text('点击停止'), findsOneWidget);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byIcon(Icons.mic)),
    );
    await gesture.moveBy(const Offset(0, -4)); // dragStart（锁定态直接 return）
    await tester.pump();
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    expect(badgeOpacity(tester), 0.0, reason: '锁定录音模式下上滑手势禁用');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(counter.newTextNoteCalls, 0);

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pumpAndSettle();
    expect(counter.stopCalls, 1, reason: '锁定录音模式下点击停止录音');
  });

  testWidgets('普通态长按开始、松开停止（原交互语义保持）', (tester) async {
    await pumpButton(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byIcon(Icons.mic)),
    );
    await tester.pump(const Duration(milliseconds: 600)); // 越过长按阈值
    await tester.pumpAndSettle();
    expect(counter.startCalls, 1, reason: '长按开始录音');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(counter.stopCalls, 1, reason: '松开停止录音');
  });
}

class _BuildCounter {
  int value = 0;
  int newTextNoteCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;

  void reset() {
    value = 0;
    newTextNoteCalls = 0;
    startCalls = 0;
    stopCalls = 0;
  }
}
