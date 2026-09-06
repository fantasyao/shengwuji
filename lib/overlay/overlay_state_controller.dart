import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'overlay_constants.dart';

/// 悬浮窗面板状态
enum OverlayPanelState {
  /// 收起态：只显示边缘小把手
  collapsed,

  /// 展开态：显示完整日记列表
  expanded,
}

/// 控制悬浮窗收起/展开状态，并计算对应窗口尺寸
class OverlayStateController extends ChangeNotifier {
  OverlayPanelState _state = OverlayPanelState.collapsed;

  OverlayPanelState get state => _state;

  bool get isCollapsed => _state == OverlayPanelState.collapsed;

  bool get isExpanded => _state == OverlayPanelState.expanded;

  /// 切换收起/展开
  void toggle() {
    if (isCollapsed) {
      expand();
    } else {
      collapse();
    }
  }

  /// 展开面板
  void expand() {
    if (_state == OverlayPanelState.expanded) return;
    _state = OverlayPanelState.expanded;
    notifyListeners();
  }

  /// 收起为把手
  void collapse() {
    if (_state == OverlayPanelState.collapsed) return;
    _state = OverlayPanelState.collapsed;
    notifyListeners();
  }

  /// 根据当前状态计算悬浮窗尺寸（dp）
  ///
  /// 收起态：细长把手；展开态：铺满全屏高度、宽度为屏宽 72% 的侧栏
  ///（尺寸由原生侧解释，这里只返回哨兵值）
  Size get panelSize {
    return switch (_state) {
      OverlayPanelState.collapsed => Size(
        OverlayConstants.handleWidth.toDouble(),
        OverlayConstants.handleHeight.toDouble(),
      ),
      // 展开态返回哨兵值 Size(-1, -1)：宽度/高度交由原生侧解释
      //（宽度 = 屏宽 × 0.72，高度 = MATCH_PARENT 铺满全屏）。
      //
      // 根因：overlay engine 里 PlatformDispatcher.instance.views.first
      // 的 physicalSize 是悬浮窗窗口自身尺寸，不是屏幕尺寸——收起态窗口
      // 只有 28×88dp，在 Dart 侧算"屏高 × 比例"会得到 88×0.85≈75dp 的
      // 扁条窗口，导致展开面板一直是 ~300×75dp。屏幕真实尺寸只有原生
      // WindowManager 拿得到，因此展开尺寸改为原生决定、Dart 传哨兵值。
      OverlayPanelState.expanded => const Size(-1, -1),
    };
  }
}
