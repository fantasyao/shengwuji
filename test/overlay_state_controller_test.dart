import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/overlay/overlay_constants.dart';
import 'package:shengwuji_app/overlay/overlay_state_controller.dart';

void main() {
  group('OverlayStateController 三态（把手/展开/贴边竖线）', () {
    test('初始态为把手收起态，panelSize = 把手尺寸', () {
      final controller = OverlayStateController();
      expect(controller.state, OverlayPanelState.collapsed);
      expect(controller.isCollapsed, isTrue);
      expect(controller.isEdgeLine, isFalse);
      expect(controller.panelSize, const Size(28, 88));
    });

    test('enterEdgeLine 进入线态：isCollapsed 语义保持非展开，panelSize = 线尺寸', () {
      final controller = OverlayStateController();
      var notified = 0;
      controller.addListener(() => notified++);

      controller.enterEdgeLine();

      expect(notified, 1);
      expect(controller.state, OverlayPanelState.edgeLine);
      // 线态归入"非展开"语义：展开/收起流程守卫无需感知线态
      expect(controller.isCollapsed, isTrue);
      expect(controller.isEdgeLine, isTrue);
      // panelSize 用窗口宽（触摸缓冲区），不是视觉线宽
      expect(
        controller.panelSize,
        const Size(
          OverlayConstants.edgeLineWindowWidth,
          OverlayConstants.edgeLineHeight,
        ),
      );
    });

    test('线态幂等：重复 enterEdgeLine 不再通知', () {
      final controller = OverlayStateController();
      var notified = 0;
      controller.addListener(() => notified++);

      controller.enterEdgeLine();
      controller.enterEdgeLine();

      expect(notified, 1);
    });

    test('线态 expand 直接进展开态（不经过把手态），panelSize = 哨兵值', () {
      final controller = OverlayStateController()..enterEdgeLine();

      controller.expand();

      expect(controller.state, OverlayPanelState.expanded);
      expect(controller.isCollapsed, isFalse);
      expect(controller.panelSize, const Size(-1, -1));
    });

    test('线态 collapse 归把手态（reset 复位路径的状态归一）', () {
      final controller = OverlayStateController()..enterEdgeLine();

      controller.collapse();

      expect(controller.state, OverlayPanelState.collapsed);
      expect(controller.isEdgeLine, isFalse);
      expect(controller.panelSize, const Size(28, 88));
    });

    test('exitEdgeLine 线态回把手（点按竖线路径）：通知 + panelSize = 把手尺寸', () {
      final controller = OverlayStateController()..enterEdgeLine();
      var notified = 0;
      controller.addListener(() => notified++);

      controller.exitEdgeLine();

      expect(notified, 1);
      expect(controller.state, OverlayPanelState.collapsed);
      expect(controller.isEdgeLine, isFalse);
      expect(controller.isCollapsed, isTrue);
      expect(controller.panelSize, const Size(28, 88));
    });

    test('exitEdgeLine 非线态幂等：把手态/展开态调用不通知不改状态', () {
      final controller = OverlayStateController();
      var notified = 0;
      controller.addListener(() => notified++);

      controller.exitEdgeLine(); // 初始把手态
      expect(notified, 0);
      expect(controller.state, OverlayPanelState.collapsed);

      controller.expand();
      controller.exitEdgeLine(); // 展开态
      expect(notified, 1); // 仅 expand 通知过
      expect(controller.state, OverlayPanelState.expanded);
    });
  });

  group('贴边竖线常量约束', () {
    test('线比把手窄且矮（"把手的瘦身版"，窗口宽同样窄于把手）', () {
      expect(
        OverlayConstants.edgeLineWidth,
        lessThan(OverlayConstants.handleWidth),
      );
      expect(
        OverlayConstants.edgeLineWindowWidth,
        lessThan(OverlayConstants.handleWidth),
      );
      expect(
        OverlayConstants.edgeLineHeight,
        lessThan(OverlayConstants.handleHeight),
      );
    });

    test('视觉线宽 ≈1mm（160dpi 基准 3.78dp，4dp ±1）', () {
      expect(OverlayConstants.edgeLineWidth, inExclusiveRange(3.0, 5.0));
    });

    test('窗口宽 = 透明触摸缓冲区，明显宽于视觉线（4dp 难触发的修复），'
        '但不遮把手宽（贴边驻留的低存在感不变）', () {
      expect(
        OverlayConstants.edgeLineWindowWidth,
        greaterThanOrEqualTo(OverlayConstants.edgeLineWidth * 3),
      );
      expect(OverlayConstants.edgeLineWindowWidth, lessThan(20.0 + 1));
    });

    test('渐变双色都半透明（alpha < 1），且屏内端深于贴缘端（"白底看深端、黑底看浅端"）', () {
      expect(OverlayConstants.edgeLineGradientDeep.a, lessThan(1.0));
      expect(OverlayConstants.edgeLineGradientDeep.a, greaterThan(0.0));
      expect(OverlayConstants.edgeLineGradientLight.a, lessThan(1.0));
      expect(OverlayConstants.edgeLineGradientLight.a, greaterThan(0.0));
      expect(
        OverlayConstants.edgeLineGradientDeep.computeLuminance(),
        lessThan(OverlayConstants.edgeLineGradientLight.computeLuminance()),
      );
    });
  });
}
