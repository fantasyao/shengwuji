import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme_extension.dart';

/// 日记页浮动麦克风按钮（长在 MainScaffold 外层 Stack——Scaffold 之外，
/// 键盘弹起时被覆盖不上浮、相对物理屏幕定位不飞起）。
///
/// 【性能审查 Top6】上滑手势的全部拖拽状态（偏移/激活态）由本组件自有
/// State 持有，拖拽帧只重建「徽章+按钮+状态文字」子树，不再 MainScaffold
/// 整页 setState（IndexedStack 四页 build 陪跑）。按钮颜色/启用状态
///（就绪/录音中/处理中三态）由父层读 DiaryTabState 传入，tab 状态翻转时
/// 经外层 ValueListenableBuilder（tick 计数）重建本组件，同样不碰 IndexedStack。
///
/// 交互（自 main.dart 原样平移，视觉/手感零变化）：
/// - 点击：锁定录音模式下停止录音
/// - 长按：普通模式下开始录音，松开停止
/// - 上滑：从按钮上方拉出「↑ Aa」徽章（新建文本笔记的视觉反馈），松手超
///   阈值新建文本笔记；下滑无反馈不触发；水平位移明显判定斜滑取消
class DiaryFloatingButton extends StatefulWidget {
  /// 模型文件是否存在（RecognizerSingleton.hasModel，父层读取传入便于测试）。
  /// 与 [isReady] 共同决定启用态：两者皆否 → 灰色禁用
  final bool modelAvailable;
  final bool isReady;
  final bool isListening;
  final bool isProcessing;

  /// 锁定录音模式：点击停止录音、上滑手势禁用、状态文字固定「点击停止」
  final bool isLockedRecording;

  /// DiaryTab 状态文案（录音中/识别中…），非锁定模式且未触发上滑时显示
  final String statusText;

  final VoidCallback onStartListening;
  final VoidCallback onStopListening;

  /// 达到上滑阈值（或快速上甩）松手 → 新建文本笔记（DiaryTabState.startNewTextNote）
  final VoidCallback onNewTextNote;

  const DiaryFloatingButton({
    super.key,
    required this.modelAvailable,
    required this.isReady,
    required this.isListening,
    required this.isProcessing,
    required this.isLockedRecording,
    required this.statusText,
    required this.onStartListening,
    required this.onStopListening,
    required this.onNewTextNote,
  });

  @override
  State<DiaryFloatingButton> createState() => _DiaryFloatingButtonState();
}

class _DiaryFloatingButtonState extends State<DiaryFloatingButton> {
  // 上滑新建文本笔记的拖拽状态（自 main.dart MainScaffold 字段平移）
  // 设计原则：麦克风按钮位置始终固定，上滑时「↑ Aa」徽章从按钮上方被拉出
  static const double _kSwipeThreshold = 70.0; // 触发新建笔记的上滑距离阈值
  static const double _kSwipeVelocity = 250.0; // 快速滑动兜底速度阈值（仅向上，向上速度为负）
  static const double _kMaxDragDistance = 72.0; // 最大拖动距离
  static const double _kAaDamping = 0.65; // Aa 徽章视觉阻尼系数（手指移 70px 徽章只移约 46px）
  static const double _kAaAppearStart = 10.0; // Aa 开始出现的拖动距离（之前无反馈，防点击误触）
  static const double _kAaAppearFull = 35.0; // Aa 完全显示的拖动距离
  static const double _kAaTriggerScale = 1.08; // 激活态 Aa 徽章放大
  static const double _kMicTriggerScale = 0.96; // 激活态麦克风按钮轻微缩小（位置不动）

  double _dragOffset = 0.0; // 垂直拖动累计位移（上滑为负值），手势回调写入，_buildAaBadge 读取
  double _dragOffsetX = 0.0; // 水平位移累计（>24px 取消本次滑动，防斜滑/横滑误触）
  bool _isDragging = false; // 是否处于垂直拖拽中（拖拽中动画 duration=0 即时跟手）
  bool _isTriggered = false; // 上滑是否达到激活阈值（✓+震动+松手新建），手势回调写入，徽章/按钮/状态文字读取

  /// 复位上滑手势的全部状态（dragEnd 触发后 / dragCancel / 水平取消 三处共用）
  void _resetSwipeState() {
    _isDragging = false;
    _dragOffset = 0.0;
    _dragOffsetX = 0.0;
    _isTriggered = false;
  }

  @override
  Widget build(BuildContext context) {
    final ext = AppThemeExtension.of(context);

    // 颜色和图标逻辑
    Color btnColor = ext.fabReady;
    Widget btnChild = const Icon(
      Icons.mic,
      color: Colors.white,
      size: 46,
    );

    if (!widget.isReady && !widget.modelAvailable) {
      // 模型文件不存在 → 禁用按钮
      btnColor = ext.fabDisabled;
    } else if (widget.isListening) {
      btnColor = ext.fabRecording;
      btnChild = Icon(
        Icons.fiber_manual_record,
        color: Colors.white,
        size: 46,
      );
    } else if (widget.isProcessing) {
      btnColor = ext.fabProcessing;
      btnChild = SizedBox(
        width: 40,
        height: 40,
        child: CircularProgressIndicator(
          color: Colors.white,
          strokeWidth: 3,
        ),
      );
    } else {
      // 就绪状态：纯麦克风图标
      // 滑动提示由上滑拉出的「↑ Aa」徽章承担（见 _buildAaBadge）；下滑暂无功能，不做对称提示以免误导。
      // ⚠️ 本按钮位于 Scaffold 外层 Stack（无 Material 祖先），Text 若不给完整样式会
      // fallback 到黄色双下划线警示样式（_buildAaBadge 已按此防护）
      btnChild = const Icon(Icons.mic, color: Colors.white, size: 46);
    }

    return Positioned(
      left: 0,
      right: 0,
      bottom: 90,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            // 外层：只负责垂直拖拽（上滑），拉出 Aa 后松手新建文本笔记
            onVerticalDragStart: (details) {
              if (widget.isLockedRecording) return;
              setState(() {
                _isDragging = true;
                _dragOffset = 0.0;
                _dragOffsetX = 0.0;
                _isTriggered = false;
              });
            },
            onVerticalDragUpdate: (details) {
              if (!_isDragging) return;
              // 先算目标位移与激活态（上滑距离为正值；下滑 clamp 为 0 → 无反馈不触发）
              final newOffset = (_dragOffset + details.delta.dy).clamp(
                -_kMaxDragDistance,
                _kMaxDragDistance,
              );
              final upDistance = (-newOffset).clamp(0.0, _kMaxDragDistance);
              final willTrigger = upDistance >= _kSwipeThreshold;
              // 激活瞬间一次轻震动，不持续震动（回退到阈值以下可重新激活）
              if (willTrigger && !_isTriggered) {
                HapticFeedback.lightImpact();
              }
              setState(() {
                _dragOffsetX += details.delta.dx;
                // 如果水平位移明显，取消本次上滑，避免斜滑/横滑误触发
                if (_dragOffsetX.abs() > 24.0) {
                  _resetSwipeState();
                  return;
                }
                _dragOffset = newOffset;
                _isTriggered = willTrigger;
              });
            },
            onVerticalDragEnd: (details) {
              if (!_isDragging) return;
              // 触发条件：达到激活阈值，或快速向上甩动兜底（向上速度为负值）
              final shouldTrigger =
                  _isTriggered ||
                  (details.primaryVelocity ?? 0) < -_kSwipeVelocity;

              if (shouldTrigger && !widget.isLockedRecording) {
                // 状态归零（Aa 徽章淡出），再触发新建笔记
                setState(_resetSwipeState);
                widget.onNewTextNote();
                return;
              }

              // 未达阈值：不执行任何操作，Aa 徽章以 180ms 动画恢复默认
              setState(_resetSwipeState);
            },
            onVerticalDragCancel: () {
              // 系统打断手势（如页面被移除）时复位，防止拖拽状态卡死
              if (!_isDragging) return;
              setState(_resetSwipeState);
            },
            child: SizedBox(
              width: 94,
              height: 94,
              child: Stack(
                // 关键：clipBehavior none，允许 Aa 徽章溢出按钮上方渲染
                clipBehavior: Clip.none,
                children: [
                  // 「↑ Aa」徽章：下缘锚定在按钮上缘外 2px（bottom: 96 = 按钮高 94 + 2）
                  // 随上滑阻尼上移（见 _buildAaBadge），按钮本体位置始终固定
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 96,
                    child: Center(child: _buildAaBadge(ext)),
                  ),
                  // 麦克风按钮本体：位置固定不动（不再随拖动平移），激活时轻微缩小
                  AnimatedScale(
                    scale: _isTriggered ? _kMicTriggerScale : 1.0,
                    duration: const Duration(milliseconds: 120),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 94,
                      height: 94,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: btnColor,
                        // 🎨 黏土拟态阴影：顶部高光 + 底部深色阴影
                        boxShadow: [
                          // 顶部高光阴影（模拟光源从上方）
                          BoxShadow(
                            color: ext.textOnPrimary.withValues(
                              alpha: 0.4,
                            ),
                            offset: const Offset(-4, -4),
                            blurRadius: 8,
                          ),
                          // 底部深色阴影（模拟凹陷感）
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.2),
                            offset: const Offset(4, 4),
                            blurRadius: 10,
                          ),
                        ],
                      ),
                      child: GestureDetector(
                        // 内层：保留原有 onTap / onLongPressStart / onLongPressEnd
                        onTap: () {
                          // 锁定录音模式下，点击停止录音
                          if (widget.isLockedRecording) {
                            widget.onStopListening();
                          }
                        },
                        onLongPressStart: (_) {
                          // 普通模式下，长按开始录音
                          if (!widget.isLockedRecording) {
                            widget.onStartListening();
                          }
                        },
                        onLongPressEnd: (_) {
                          // 普通模式下，松开停止录音
                          if (!widget.isLockedRecording) {
                            widget.onStopListening();
                          }
                        },
                        child: Center(child: btnChild),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          // 用固定高度容器包裹文字：文字出现/消失都不改变 Column 总高度
          // 按钮位置完全稳定，不再抖动（修复"录音时按钮被撑高"问题）
          SizedBox(
            height: 22, // 中文字体 fontSize 16 行高约 22，预留固定空间
            child: Center(
              child: Text(
                _isTriggered
                    ? '松手新建文本笔记'
                    : (widget.isLockedRecording
                          ? '点击停止'
                          : widget.statusText),
                textAlign: TextAlign.center,
                style: TextStyle(
                  // 显式指定霞鹜文楷字体，避免在部分 widget 链路中 Roboto 回退
                  fontFamily: 'LXGWWenKaiMonoGBScreen',
                  fontSize: 16,
                  color: ext.textHint,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 上滑时从麦克风按钮上方拉出的「↑ Aa」徽章（新建文本笔记的视觉反馈）
  // 设计原则：麦克风按钮位置固定不动，只有 Aa 徽章随上滑距离阻尼上移，
  // 营造"从按钮上方拉出文本输入功能"的手感，而不是拖动按钮本身
  // 上下游：_dragOffset / _isTriggered / _isDragging 由外层 GestureDetector 回调写入
  Widget _buildAaBadge(AppThemeExtension ext) {
    // 上滑距离（正值）；下滑 clamp 为 0 → 无反馈不触发
    final distance = (-_dragOffset).clamp(0.0, _kMaxDragDistance);
    // 阻尼位移：手指移 70px，徽章只移约 46px
    final visualOffset = distance * _kAaDamping;
    // 10px 内无反馈（防点击误触），10→35px 渐显
    final opacity =
        ((distance - _kAaAppearStart) / (_kAaAppearFull - _kAaAppearStart))
            .clamp(0.0, 1.0);
    // 拖动中 0ms 即时跟手；松手后 180ms 平滑淡出恢复默认
    final Duration animDur = _isDragging
        ? Duration.zero
        : const Duration(milliseconds: 180);

    return IgnorePointer(
      // 徽章是纯视觉反馈，不参与命中测试，避免在按钮上方扩大隐形手势热区
      child: AnimatedOpacity(
        opacity: opacity,
        duration: animDur,
        child: AnimatedContainer(
          transform: Matrix4.translationValues(0, -visualOffset, 0),
          duration: animDur,
          child: AnimatedScale(
            scale: _isTriggered ? _kAaTriggerScale : 1.0,
            duration: const Duration(milliseconds: 120),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                // 浅青胶囊底（fabReady 低透明度），复用主题色槽，不引入新颜色体系
                color: ext.fabReady.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.keyboard_arrow_up,
                    size: 18,
                    color: ext.fabReady,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    'Aa',
                    style: TextStyle(
                      // ⚠️ 本区域位于 Scaffold 外层 Stack（无 Material 祖先），
                      // Text 不给完整样式会 fallback 到黄色双下划线警示样式，
                      // decoration 必须显式置 none（同下方状态文字的处理）
                      fontFamily: 'LXGWWenKaiMonoGBScreen',
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: ext.fabReady,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  // 激活态才显示 ✓（达到阈值，松手即新建）
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 120),
                    child: _isTriggered
                        ? Padding(
                            key: const ValueKey('aa-check'),
                            padding: const EdgeInsets.only(left: 3),
                            child: Icon(
                              Icons.check,
                              size: 16,
                              color: ext.fabReady,
                            ),
                          )
                        : const SizedBox.shrink(key: ValueKey('aa-no-check')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
