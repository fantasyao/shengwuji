import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/overlay/overlay_constants.dart';

/// 悬浮窗「按钮位置」顶部/底部两档回归（2026-10-27，用户要求按钮切到底部
/// 便于单手操作）：prefs `overlay_panel_buttons_bottom`（bool，缺省 false =
/// 顶部，历史行为）。
/// 核心设计：底部模式不只是把按钮条挪到列表下方——面板整体改贴停靠侧下角
/// 锚定（panelAlignment）。只挪按钮而面板仍顶部锚定的话，条目少时按钮仍停
/// 在屏幕上方，单手问题没解决。顶部模式的「面板高度」下压偏移（
/// panelTopOffsetFor）在底部模式不适用，列表底部内边距也从 48 收到 8。
void main() {
  group('prefs key', () {
    test('key 与缺省语义钉住（false = 顶部，历史行为）', () {
      expect(
        OverlayConstants.panelButtonsBottomPrefKey,
        'overlay_panel_buttons_bottom',
      );
      // 读取方为 `prefs.getBool(key) ?? false`（bool 通道无解析函数），
      // 缺省 false 与历史布局一致，无需迁移
      expect(OverlayConstants.panelHeaderBottomPadding, 48.0);
    });
  });

  group('面板锚点（panelAlignment）', () {
    test('顶部模式：贴停靠侧上角（历史行为）', () {
      expect(
        OverlayConstants.panelAlignment(dockLeft: false, buttonsBottom: false),
        Alignment.topRight,
      );
      expect(
        OverlayConstants.panelAlignment(dockLeft: true, buttonsBottom: false),
        Alignment.topLeft,
      );
    });

    test('底部模式：贴停靠侧下角（按钮落进拇指区）', () {
      expect(
        OverlayConstants.panelAlignment(dockLeft: false, buttonsBottom: true),
        Alignment.bottomRight,
      );
      expect(
        OverlayConstants.panelAlignment(dockLeft: true, buttonsBottom: true),
        Alignment.bottomLeft,
      );
    });

    test('底部模式仍随停靠侧镜像（左右下角对称）', () {
      final right = OverlayConstants.panelAlignment(
        dockLeft: false,
        buttonsBottom: true,
      );
      final left = OverlayConstants.panelAlignment(
        dockLeft: true,
        buttonsBottom: true,
      );
      expect(left.x, -right.x);
      expect(left.y, right.y);
    });
  });

  group('按钮条内边距（panelHeaderPadding）', () {
    test('顶部模式：避让状态栏（top=40/bottom=4），左右随侧镜像', () {
      final right = OverlayConstants.panelHeaderPadding(
        dockLeft: false,
        buttonsBottom: false,
      );
      expect(right.top, OverlayConstants.panelHeaderTopPadding);
      expect(right.bottom, 4);
      expect(right.left, 16);
      expect(right.right, 8);

      final left = OverlayConstants.panelHeaderPadding(
        dockLeft: true,
        buttonsBottom: false,
      );
      expect(left.left, 8);
      expect(left.right, 16);
    });

    test('底部模式：改为避让导航栏（top=4/bottom=48），左右不变', () {
      final right = OverlayConstants.panelHeaderPadding(
        dockLeft: false,
        buttonsBottom: true,
      );
      expect(right.top, 4);
      expect(right.bottom, OverlayConstants.panelHeaderBottomPadding);
      expect(right.bottom, 48);
      expect(right.left, 16);
      expect(right.right, 8);

      final left = OverlayConstants.panelHeaderPadding(
        dockLeft: true,
        buttonsBottom: true,
      );
      expect(left.left, 8);
      expect(left.right, 16);
    });
  });

  group('列表底部内边距（panelListBottomPadding）', () {
    test('顶部模式保留历史 48（导航栏避让）', () {
      expect(OverlayConstants.panelListBottomPadding(false), 48.0);
    });

    test('底部模式收到 8（导航栏由下方按钮条自身避让）', () {
      expect(OverlayConstants.panelListBottomPadding(true), 8.0);
      // 底部模式列表下方是按钮条，再留 48 会多出一大段空白
      expect(
        OverlayConstants.panelListBottomPadding(true),
        lessThan(OverlayConstants.panelListBottomPadding(false)),
      );
    });
  });
}
