import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/overlay/overlay_constants.dart';
import 'package:shengwuji_app/overlay/widgets/overlay_handle.dart';

/// 收起态把手（OverlayHandle）手势回归：点按/朝屏幕内侧滑展开为既有行为，
/// 长按拖动 = 位置调整入口——长按进入拖动态（描边视觉），
/// 纵向位移经 onDragUpdate 转发（父层→原生移窗），松手/取消收尾。
/// 停靠左缘（dockLeft）时"朝屏幕内侧"镜像为右滑。
///
/// 回调以事件序列捕获断言；组件本身不发通道消息（效果全在父层），无需 mock。
void main() {
  // 事件序列记录：'start' / dy 值（update）/ 'end' / 'cancel' / 'tap' / 'swipe'
  final events = <Object>[];

  Future<void> pumpHandle(WidgetTester tester, {bool dockLeft = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: OverlayHandle(
              onTap: () => events.add('tap'),
              onSwipeInward: () => events.add('swipe'),
              dockLeft: dockLeft,
              onDragStart: () => events.add('start'),
              onDragUpdate: (dy) => events.add(dy),
              onDragEnd: () => events.add('end'),
              onDragCancel: () => events.add('cancel'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  // 长按至识别成功（deadline 500ms，多等 100ms 余量）
  Future<TestGesture> longPressToStart(WidgetTester tester) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(OverlayHandle)),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    return gesture;
  }

  // 拖动态视觉 = AnimatedContainer 目标 decoration 带白色描边（补间目标即时生效，
  // 断言 widget 属性免 pumpAndSettle）
  Border? currentBorder(WidgetTester tester) {
    final decoration =
        tester
                .widget<AnimatedContainer>(find.byType(AnimatedContainer))
                .decoration
            as BoxDecoration?;
    return decoration?.border as Border?;
  }

  // 静置/拖动态整体不透明度（AnimatedOpacity 的补间目标值）
  double currentOpacity(WidgetTester tester) =>
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

  setUp(() => events.clear());

  testWidgets('点按 → onTap，不触发拖动（未到长按阈值）', (tester) async {
    await pumpHandle(tester);
    await tester.tap(find.byType(OverlayHandle));
    await tester.pump();

    expect(events, ['tap']);
    final border = currentBorder(tester);
    expect(border, isNotNull, reason: '静置态常驻细白描边（笔记卡片同款）');
    expect(border?.top.width, OverlayConstants.cardBorderWidth);
    expect(currentOpacity(tester), OverlayConstants.handleRestingOpacity,
        reason: '静置态整体稍透明');
  });

  testWidgets('停靠右缘：左滑超阈值 → onSwipeInward（既有展开手势保留）', (tester) async {
    await pumpHandle(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(OverlayHandle)),
    );
    // 真实滑动分多帧：首个超 slop 的 move 只完成竞技场接纳（该事件本身不产生
    // update 回调，实测探针验证），"单事件超阈值"判定靠接纳之后的后续 move
    await gesture.moveBy(const Offset(-8, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-16, 0)); // 累计 -24，越过 slop 接纳
    await tester.pump();
    await gesture.moveBy(const Offset(-6, 0)); // 接纳后首个 update，-6 < -4 阈值
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(events, ['swipe']);
  });

  testWidgets('停靠左缘（dockLeft）：右滑超阈值 → onSwipeInward（方向镜像）', (tester) async {
    await pumpHandle(tester, dockLeft: true);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(OverlayHandle)),
    );
    // 镜像方向：+x 为"朝屏幕内侧"，多帧构造超阈值右向单事件
    await gesture.moveBy(const Offset(8, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(16, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(6, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(events, ['swipe'], reason: '左缘停靠时右滑 = 朝屏内侧 = 展开');
  });

  testWidgets('停靠左缘（dockLeft）：左滑不展开（旧方向不误触）', (tester) async {
    await pumpHandle(tester, dockLeft: true);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(OverlayHandle)),
    );
    await gesture.moveBy(const Offset(-8, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-16, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-6, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(events, isEmpty, reason: '左缘停靠时左滑 = 朝屏外侧，不应触发展开');
  });

  testWidgets('长按 → 进入拖动态（描边）+ onDragStart', (tester) async {
    await pumpHandle(tester);
    await longPressToStart(tester);

    expect(events, ['start']);
    final border = currentBorder(tester);
    expect(border, isNotNull, reason: '拖动态出现白色描边视觉');
    expect(border?.top.width, 1.5, reason: '拖动态描边比静置态（1dp）加粗');
    expect(currentOpacity(tester), 1.0, reason: '拖动态满不透明');
  });

  testWidgets('长按后纵向拖动 → onDragUpdate 收到自原点累计位移（向下为正）', (tester) async {
    await pumpHandle(tester);
    final gesture = await longPressToStart(tester);

    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();

    final dys = events.whereType<double>().toList();
    expect(events.first, 'start');
    expect(dys.length, 2, reason: '两次 move 各转发一次');
    // offsetFromOrigin 自按下原点累计（非逐帧增量）：40 → 60
    expect(dys[0], closeTo(40, 0.5));
    expect(dys[1], closeTo(60, 0.5));
  });

  testWidgets('长按未拖动直接松手 → start + end，无 update', (tester) async {
    await pumpHandle(tester);
    final gesture = await longPressToStart(tester);
    await gesture.up();
    await tester.pump();

    expect(events, ['start', 'end']);
    expect(currentBorder(tester)?.top.width, OverlayConstants.cardBorderWidth,
        reason: '松手退出拖动态，描边回到静置常驻宽度');
    expect(currentOpacity(tester), OverlayConstants.handleRestingOpacity);
  });

  testWidgets('拖动中组件被移出树 → onDragCancel（语音速记打断路径）', (tester) async {
    await pumpHandle(tester);
    final gesture = await longPressToStart(tester);
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();

    // 父层切走（语音速记进录音态把把手换成胶囊 UI）= 组件在手势中旬被移除
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox())),
    );
    await tester.pump();

    final tail = events.skip(2).toList(); // start、首个 update 之后
    expect(tail.contains('cancel'), isTrue,
        reason: '识别器随组件销毁应触发 onLongPressCancel → onDragCancel 收尾');
    expect(tail.contains('end'), isFalse, reason: '未松手不应走 end');
  });

  testWidgets('药丸双色胶囊视觉：上白下绿正中切换 + 中缝横线 + 竖排「闪记」+ 本体内缩', (tester) async {
    await pumpHandle(tester);

    final decoration =
        tester
                .widget<AnimatedContainer>(find.byType(AnimatedContainer))
                .decoration
            as BoxDecoration;
    // 双色 hard-stop 渐变：上半白 / 下半绿在胶囊正中硬切
    final gradient = decoration.gradient as LinearGradient;
    expect(gradient.begin, Alignment.topCenter);
    expect(gradient.colors, const [
      OverlayConstants.handleCapsuleTopColor,
      OverlayConstants.handleCapsuleTopColor,
      OverlayConstants.handleCapsuleBottomColor,
      OverlayConstants.handleCapsuleBottomColor,
    ]);
    expect(gradient.stops, const [0.0, 0.5, 0.5, 1.0]);

    // 胶囊本体比窗口小一圈（窗口仍 28×88：原生硬编码副本与触控面积不动）
    expect(
      tester.getSize(find.byType(AnimatedContainer)),
      Size(
        OverlayConstants.handleWidth -
            2 * OverlayConstants.handleInsetHorizontal,
        OverlayConstants.handleHeight - 2 * OverlayConstants.handleInsetVertical,
      ),
    );

    // 中缝接缝线：1dp 高、横贯胶囊内宽的半透明黑
    final seam = tester.widget<Container>(
      find.byWidgetPredicate(
        (w) => w is Container && w.color == OverlayConstants.handleSeamColor,
      ),
    );
    expect(seam.constraints?.maxHeight, 1);

    // 文案改为「闪记」，中文逐字竖排（字符间换行）
    expect(find.text(OverlayConstants.handleLabel.characters.join('\n')),
        findsOneWidget);

    // 闪电图标用下半绿同色（落在白半区上呼应成对），尺寸走缩小后的常量
    final icon = tester.widget<Icon>(find.byIcon(Icons.bolt));
    expect(icon.size, OverlayConstants.handleIconSize);
    expect(icon.color, OverlayConstants.handleCapsuleBottomColor);
  });
}
