import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/overlay/overlay_constants.dart';
import 'package:shengwuji_app/overlay/widgets/overlay_handle.dart';

/// 把手大小档位回归（2026-09-22，用户反馈把手胶囊有点大可调）：
/// 方案 A「只缩视觉不缩窗口」——窗口恒 28×88（原生硬编码副本 HANDLE_WIDTH_DP、
/// 语音胶囊 84<88 不变量、dragHandle 宽守卫、EDGE_LINE_WIDTH_THRESHOLD_DP=24
/// 分流四者联动不动），胶囊本体按档位缩放、触控面积不变；
/// 迷你档（50%）胶囊 12×40 放不下竖排文字，只渲染闪电图标；
/// 竖线视觉高度跟随档位等比缩（64/48/32），宽 4dp 与窗口 20×64 不动。
void main() {
  group('档位解析与派生（纯函数）', () {
    test('parseHandleSizePercent：合法档原样，null/旧值/坏值兜底默认 100%', () {
      expect(OverlayConstants.parseHandleSizePercent(null), 100);
      expect(OverlayConstants.parseHandleSizePercent(100), 100);
      expect(OverlayConstants.parseHandleSizePercent(75), 75);
      expect(OverlayConstants.parseHandleSizePercent(50), 50);
      // 非法档兜底：0/33/200 都不在合法集合（含旧版本可能写入的任意 int）
      expect(OverlayConstants.parseHandleSizePercent(0), 100);
      expect(OverlayConstants.parseHandleSizePercent(33), 100);
      expect(OverlayConstants.parseHandleSizePercent(200), 100);
    });

    test('胶囊视觉尺寸三档：24×80（历史值）/ 18×60 / 12×40', () {
      expect(OverlayConstants.handleCapsuleWidth(100), 24.0);
      expect(OverlayConstants.handleCapsuleHeight(100), 80.0);
      expect(OverlayConstants.handleCapsuleWidth(75), 18.0);
      expect(OverlayConstants.handleCapsuleHeight(75), 60.0);
      expect(OverlayConstants.handleCapsuleWidth(50), 12.0);
      expect(OverlayConstants.handleCapsuleHeight(50), 40.0);
    });

    test('内缩派生三档：(2,4)（历史值）/ (5,14) / (8,24)，且 视觉+2×内缩=窗口', () {
      expect(OverlayConstants.handleInsetHorizontalOf(100), 2.0);
      expect(OverlayConstants.handleInsetVerticalOf(100), 4.0);
      expect(OverlayConstants.handleInsetHorizontalOf(75), 5.0);
      expect(OverlayConstants.handleInsetVerticalOf(75), 14.0);
      expect(OverlayConstants.handleInsetHorizontalOf(50), 8.0);
      expect(OverlayConstants.handleInsetVerticalOf(50), 24.0);
      // 不变量：胶囊恒在窗口正中（防派生公式与窗口常量漂移）
      for (final percent in OverlayConstants.handleSizePercents) {
        expect(
          OverlayConstants.handleCapsuleWidth(percent) +
              2 * OverlayConstants.handleInsetHorizontalOf(percent),
          OverlayConstants.handleWidth.toDouble(),
        );
        expect(
          OverlayConstants.handleCapsuleHeight(percent) +
              2 * OverlayConstants.handleInsetVerticalOf(percent),
          OverlayConstants.handleHeight.toDouble(),
        );
      }
    });

    test('竖线视觉高度跟随档位：64（历史值）/ 48 / 32，宽与窗口常量不动', () {
      expect(OverlayConstants.edgeLineVisualHeight(100), 64.0);
      expect(OverlayConstants.edgeLineVisualHeight(75), 48.0);
      expect(OverlayConstants.edgeLineVisualHeight(50), 32.0);
      // 宽 4dp 是可见性下限（2026-09-14 渐变对比度专项），不随档位缩
      expect(OverlayConstants.edgeLineWidth, 4.0);
      // 窗口尺寸（触摸缓冲区）不随档位变——方案 A 只缩视觉
      expect(OverlayConstants.edgeLineWindowWidth, 20.0);
      expect(OverlayConstants.edgeLineHeight, 64.0);
    });

    test('isMiniHandleSize：仅最小档（50%）为迷你', () {
      expect(OverlayConstants.isMiniHandleSize(100), isFalse);
      expect(OverlayConstants.isMiniHandleSize(75), isFalse);
      expect(OverlayConstants.isMiniHandleSize(50), isTrue);
    });
  });

  group('把手渲染（widget）', () {
    var taps = 0;
    Future<void> pumpHandle(WidgetTester tester, int sizePercent) async {
      taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: OverlayHandle(
                onTap: () => taps++,
                onSwipeInward: () {},
                sizePercent: sizePercent,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('迷你档（50%）：胶囊 12×40，只渲染闪电图标（9dp）、文字隐藏',
        (tester) async {
      await pumpHandle(tester, 50);

      expect(
        tester.getSize(find.byType(AnimatedContainer)),
        const Size(12.0, 40.0),
      );
      expect(find.text('闪\n记'), findsNothing,
          reason: '迷你档放不下竖排文字，用户定夺文字隐藏');
      final icon = tester.widget<Icon>(find.byIcon(Icons.bolt));
      expect(icon.size, OverlayConstants.handleIconSizeMini);
    });

    testWidgets('75% 档：胶囊 18×60，不显示文字（真机反馈太挤）、图标保留', (tester) async {
      await pumpHandle(tester, 75);

      expect(
        tester.getSize(find.byType(AnimatedContainer)),
        const Size(18.0, 60.0),
      );
      expect(find.text('闪\n记'), findsNothing,
          reason: '仅标准档显示文字，小档竖排文字太挤（2026-09-22 用户定夺）');
      expect(
        tester.widget<Icon>(find.byIcon(Icons.bolt)).size,
        OverlayConstants.handleIconSize,
      );
    });

    testWidgets('标准档（100%）：文字与图标齐全（文字仅此档保留）', (tester) async {
      await pumpHandle(tester, 100);

      expect(find.text('闪\n记'), findsOneWidget);
      expect(
        tester.widget<Icon>(find.byIcon(Icons.bolt)).size,
        OverlayConstants.handleIconSize,
      );
    });

    testWidgets('点击视觉胶囊外的透明环仍触发 onTap（opaque 整窗命中——'
        '真机反馈"缩小后点空隙唤不出"的回归钉）', (tester) async {
      await pumpHandle(tester, 75);

      // 75% 档内缩 (横 5, 纵 14)：距窗口左上角 (2,2) 落在透明内缩环上（视觉
      // 胶囊 18×60 之外）。修复前 GestureDetector 默认 deferToChild，此处
      // 命中失败=点按落空；opaque 后触控区=整窗 28×88
      final corner =
          tester.getTopLeft(find.byType(OverlayHandle)) + const Offset(2, 2);
      await tester.tapAt(corner);
      await tester.pump();

      expect(taps, 1, reason: '透明环上的点按必须命中（触控面积不随档位缩）');
    });
  });
}
