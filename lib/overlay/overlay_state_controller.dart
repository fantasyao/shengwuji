import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'overlay_constants.dart';

/// 悬浮窗面板状态
enum OverlayPanelState {
  /// 收起态：只显示边缘小把手
  collapsed,

  /// 展开态：显示完整日记列表
  expanded,

  /// 线态：自动隐藏后的贴边竖线（"把手的瘦身版"，半透明细线驻留提示）。
  /// 点按竖线 → exitEdgeLine() 回把手态（设置开关可关）；朝屏幕内侧滑或
  /// 音量键召唤 → expand() 直接进展开态（不经过把手态）
  edgeLine,
}

/// 控制悬浮窗收起/展开状态，并计算对应窗口尺寸
class OverlayStateController extends ChangeNotifier {
  OverlayPanelState _state = OverlayPanelState.collapsed;

  OverlayPanelState get state => _state;

  /// 非展开态（收起把手或贴边竖线）。
  /// 竖线归入本语义：展开/收起流程的一切守卫（_expand 主路径、_collapse
  /// 幂等、_scheduleAutoHide 的状态双保险、_startNewNote 的放弃聚焦）对
  /// "窗口是小尺寸"的理解一致，只有 build 渲染分支和 panelSize 需要区分
  /// 把手与竖线
  bool get isCollapsed => _state != OverlayPanelState.expanded;

  /// 是否处于线态（build 渲染分支用；常规流程守卫一律用 [isCollapsed]）
  bool get isEdgeLine => _state == OverlayPanelState.edgeLine;

  bool get isExpanded => _state == OverlayPanelState.expanded;

  /// 切换收起/展开
  void toggle() {
    if (isCollapsed) {
      expand();
    } else {
      collapse();
    }
  }

  /// 展开面板（从把手态或线态均可；线态展开即离开驻留提示）
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

  /// 收起为贴边竖线（自动隐藏计时到期且设置开关打开时调用；
  /// 已是线态时幂等）。与 collapse 一样只在稳定态间跳转，动画编排
  ///（空白帧守卫）由调用方 OverlayHome._enterEdgeLine 负责
  void enterEdgeLine() {
    if (_state == OverlayPanelState.edgeLine) return;
    _state = OverlayPanelState.edgeLine;
    notifyListeners();
  }

  /// 线态回把手（点按竖线且设置开关放行时调用；非线态时幂等 no-op）。
  /// 与 enterEdgeLine 对偶：只在稳定态间跳转，动画编排（空白帧守卫）由
  /// 调用方 OverlayHome._exitEdgeLine 负责——竖线→把手是扩窗方向，须防
  /// 旧竖线纹理被 TextureView 重投影拉伸（同 _expand 的空白帧协议）
  void exitEdgeLine() {
    if (_state != OverlayPanelState.edgeLine) return;
    _state = OverlayPanelState.collapsed;
    notifyListeners();
  }

  /// 根据当前状态计算悬浮窗尺寸（dp）
  ///
  /// 收起态：细长把手；线态：贴边半透明竖线；展开态：铺满全屏高度、宽度为
  /// 屏宽 72% 的侧栏（尺寸由原生侧解释，这里只返回哨兵值）
  Size get panelSize {
    return switch (_state) {
      OverlayPanelState.collapsed => Size(
        OverlayConstants.handleWidth.toDouble(),
        OverlayConstants.handleHeight.toDouble(),
      ),
      OverlayPanelState.edgeLine => Size(
        // 窗口宽 = 触摸缓冲区宽（20），视觉线宽（4）只管绘制，见常量注释
        OverlayConstants.edgeLineWindowWidth,
        OverlayConstants.edgeLineHeight,
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
