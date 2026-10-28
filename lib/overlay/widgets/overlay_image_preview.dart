import 'dart:io';

import 'package:flutter/material.dart';

/// 图片附件全屏预览层（2026-10-21，2026-10-24 扩展为多图图集）。
///
/// 黑底 + 双指缩放（最大 4 倍）+ 右上角关闭；用户要求补上「预览内返回」：
/// - **单击**：点图片任意位置或黑底关闭（与右上角 ✕ 同语义）
/// - **右滑**：仅单图时横向拖动超过 [_kSwipeDismissDistance] 关闭；
///   多图时右滑交给 PageView 翻到上一张
/// - **左右翻页**：多图用 PageView 切换，底部显示「当前 / 总数」
///
/// **删除入口（2026-10-25 用户要求）**：左上角 🗑（与 ✕ 同款命中区），只对
/// 手机自拍截图生效——[ownImagePath] 为空时整个按钮不渲染（父层：这组图里没有
/// 本机能删的）。翻到电脑端同步来的那张再点 🗑 走 [onForeignImageTap] 提示，
/// 不在本机删：图片索引按设备所有权合并，本机摘掉别人的条目会被来源端下轮
/// 重发布，删不干净（见 cloud-sync.md「删除边界」）。确认态沿用卡片
/// 「确认删除？✓✗」整行替换先例，只替换左上角那格。
///
/// ⚠️ 侧滑用 [Listener] 追踪原始指针，不用外层 GestureDetector 的
/// onHorizontalDrag：InteractiveViewer 的缩放/平移手势识别器在子层，拖拽
/// 竞技场会被它截走，外层水平拖拽在真机上收不到事件；原始指针事件不参与
/// 竞技场，可与缩放/平移共存。放大态（scale > 1）不响应侧滑/翻页——此时
/// 横向拖动是平移图片，误退出或误翻页会打断查看；多指期间也立即作废滑动
/// 起点。
///
/// 关闭职责交回父层（[onClose]）：预览是 OverlayHome 面板 Stack 的模态层，
/// 父层清空路径列表即卸载本组件，组件内不持有显隐状态。
class OverlayImagePreview extends StatefulWidget {
  const OverlayImagePreview({
    super.key,
    required this.imagePaths,
    required this.onClose,
    this.initialIndex = 0,
    this.ownImagePath,
    this.onOwnImageDelete,
    this.onForeignImageTap,
  });

  /// 待展示的图片绝对路径（至少一张；调用方已过滤不存在的文件）
  final List<String> imagePaths;
  final int initialIndex;
  final VoidCallback onClose;

  /// 本机自拍截图路径（= `diary.image_path`）；null 或列表里没有它 = 没有可删
  /// 的图，左上角删除钮不渲染（主 App 日记页不传，行为与历史一致）
  final String? ownImagePath;

  /// 确认态点 ✓：删除本机截图（写库/删文件/关图集都在父层，本组件不持有数据）
  final VoidCallback? onOwnImageDelete;

  /// 当前页不是本机截图时点 🗑：父层弹「请在电脑端删除」一类提示
  final VoidCallback? onForeignImageTap;

  @override
  State<OverlayImagePreview> createState() => _OverlayImagePreviewState();
}

/// 右滑关闭位移阈值（逻辑像素）：约预览宽度的 1/4，兼顾误触与手感
const double _kSwipeDismissDistance = 88;

class _OverlayImagePreviewState extends State<OverlayImagePreview> {
  late final PageController _pageController;
  final TransformationController _transform = TransformationController();

  /// 当前按下的指针集合：多指（缩放）期间作废侧滑，松完才允许下一次
  final Set<int> _pointers = <int>{};

  /// 单指侧滑起点；null = 本轮不参与侧滑（多指/放大态/未按下）
  Offset? _swipeStart;

  /// 多图翻页起点与位移：PageView 的拖动识别器会被 InteractiveViewer
  /// 的缩放手势截走（真机实测，panEnabled=false 仍会竞争），翻页改用同一
  /// 套原始指针跟踪，松手超过阈值后动画切页
  Offset? _pageSwipeStart;
  double _pageSwipeDx = 0;
  double _pageSwipeDy = 0;

  /// 侧滑水平位移（右为正），拖动中实时跟手
  double _swipeDx = 0;

  late int _index;

  /// 删除确认态（仅本机截图页可进入）；翻页即作废——确认的是上一页那张
  bool _deleteConfirming = false;

  /// 当前页是否放大（放大时禁用翻页，横向拖动用于平移图片）
  bool _zoomed = false;

  int get _count => widget.imagePaths.length;

  /// 左上角删除钮是否渲染：父层给了删除回调，且这组图里确有本机自拍截图
  /// （全是电脑端同步来的图时不给按钮——本机能删的那张不存在）
  bool get _canDeleteOwn =>
      widget.onOwnImageDelete != null &&
      widget.ownImagePath != null &&
      widget.imagePaths.contains(widget.ownImagePath);

  /// 当前页是否本机自拍截图（决定 🗑 进确认态，还是交给父层提示「去电脑端删」）
  bool get _currentIsOwn =>
      _index < _count && widget.imagePaths[_index] == widget.ownImagePath;

  void _onTapDelete() {
    if (_currentIsOwn) {
      setState(() => _deleteConfirming = true);
      return;
    }
    widget.onForeignImageTap?.call();
  }

  @override
  void initState() {
    super.initState();
    final maxIndex = _count == 0 ? 0 : _count - 1;
    _index = widget.initialIndex.clamp(0, maxIndex);
    _pageController = PageController(initialPage: _index);
    _transform.addListener(_onTransformChanged);
  }

  @override
  void dispose() {
    _transform.removeListener(_onTransformChanged);
    _transform.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _onTransformChanged() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointers.add(event.pointer);
    if (_pointers.length > 1) {
      _swipeStart = null;
      _pageSwipeStart = null;
      _resetSwipeDx();
      return;
    }
    if (_zoomed) {
      _swipeStart = null;
      _pageSwipeStart = null;
      return;
    }
    if (_count > 1) {
      _pageSwipeStart = event.position;
      _pageSwipeDx = 0;
      _pageSwipeDy = 0;
      return;
    }
    _swipeStart = event.position;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_count > 1) {
      final start = _pageSwipeStart;
      if (start == null || _pointers.length != 1) return;
      _pageSwipeDx = event.position.dx - start.dx;
      _pageSwipeDy = event.position.dy - start.dy;
      return;
    }
    final start = _swipeStart;
    if (start == null || _pointers.length != 1) return;
    final dx = event.position.dx - start.dx;
    final dy = event.position.dy - start.dy;
    // 只认右滑且横向占主导：左滑/纵向拖动留给 InteractiveViewer
    if (dx <= 0 || dx.abs() < dy.abs()) {
      _resetSwipeDx();
      return;
    }
    setState(() => _swipeDx = dx);
  }

  void _onPointerUp(PointerUpEvent event) {
    _pointers.remove(event.pointer);
    if (_count > 1) {
      _finishPageSwipe();
      return;
    }
    _finishSwipe();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    _swipeStart = null;
    _pageSwipeStart = null;
    _pageSwipeDx = 0;
    _pageSwipeDy = 0;
    _resetSwipeDx();
  }

  /// 多图翻页阈值（逻辑像素）：太小会让点击抖动误翻页
  static const double _kPageSwipeDistance = 56;

  void _finishPageSwipe() {
    final start = _pageSwipeStart;
    _pageSwipeStart = null;
    if (start == null) return;
    final dx = _pageSwipeDx;
    final dy = _pageSwipeDy;
    _pageSwipeDx = 0;
    _pageSwipeDy = 0;
    if (dx.abs() < _kPageSwipeDistance || dx.abs() <= dy.abs()) return;
    _goToPage(dx < 0 ? _index + 1 : _index - 1);
  }

  void _goToPage(int index) {
    if (index < 0 || index >= _count) return;
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _finishSwipe() {
    if (_swipeStart == null) return;
    _swipeStart = null;
    if (_swipeDx >= _kSwipeDismissDistance) {
      widget.onClose();
      return;
    }
    // 未过阈值：`_swipeStart` 已清空，AnimatedContainer 切回 160ms 回弹
    _resetSwipeDx();
  }

  void _resetSwipeDx() {
    if (_swipeDx == 0) return;
    setState(() => _swipeDx = 0);
  }

  void _onPageChanged(int index) {
    // 翻页后还原缩放，否则上一页的放大态会锁死下一页的翻页手势
    _transform.value = Matrix4.identity();
    setState(() {
      _index = index;
      _deleteConfirming = false;
    });
  }

  /// 顶栏左上角一格：🗑 删除钮 →（在本机截图页点过之后）整格替换成
  /// 「确认删除？✓✗」——对齐卡片删除确认行的整行替换先例；✗ 只退出确认态，
  /// 不关预览（关预览仍走右上角 ✕/单击/右滑）
  Widget _buildDeleteSlot() {
    if (!_canDeleteOwn) return const SizedBox(width: 48, height: 48);
    if (!_deleteConfirming) {
      return _buildTopButton(Icons.delete_outline, _onTapDelete);
    }
    return Row(
      key: const Key('imageDeleteConfirm'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '确认删除？',
          style: TextStyle(
            fontSize: 13,
            color: Colors.white.withValues(alpha: 0.9),
          ),
        ),
        _buildTopButton(Icons.check, widget.onOwnImageDelete),
        _buildTopButton(
          Icons.close,
          () => setState(() => _deleteConfirming = false),
        ),
      ],
    );
  }

  /// 顶栏 48×48 图标钮（与右上角 ✕ 同款命中区，opaque 接住点击不冒泡到
  /// 「单击关闭」的父层 GestureDetector）
  Widget _buildTopButton(IconData icon, VoidCallback? onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 48,
        height: 48,
        child: Center(child: Icon(icon, size: 26, color: Colors.white)),
      ),
    );
  }

  Widget _buildPage(String path) {
    return InteractiveViewer(
      transformationController: _transform,
      minScale: 1,
      maxScale: 4,
      // 未放大时关掉平移，把横向拖动让给 PageView 翻页；放大后平移优先
      panEnabled: _zoomed,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onClose,
        child: Center(
          child: Image.file(
            File(path),
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => const Icon(
              Icons.broken_image_outlined,
              size: 48,
              color: Colors.white70,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onClose,
              child: Container(color: Colors.black.withValues(alpha: 0.92)),
            ),
          ),
          SafeArea(
            child: AnimatedContainer(
              // 拖动中零时长跟手；松手回弹/归位走 easeOut
              duration: _swipeStart == null
                  ? const Duration(milliseconds: 160)
                  : Duration.zero,
              curve: Curves.easeOut,
              transform: Matrix4.translationValues(_swipeDx, 0, 0),
              child: Column(
                children: [
                  Padding(
                    // 左右各留 4dp：确认行含三个 48 宽命中区，窄屏也不顶边
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _buildDeleteSlot(),
                        _buildTopButton(Icons.close, widget.onClose),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Stack(
                      children: [
                        PageView.builder(
                          controller: _pageController,
                          // 翻页由外层原始指针跟踪驱动（InteractiveViewer
                          // 会抢走 PageView 的水平拖动识别器），PageView
                          // 自身不参与手势竞技场
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _count,
                          onPageChanged: _onPageChanged,
                          itemBuilder: (context, index) =>
                              _buildPage(widget.imagePaths[index]),
                        ),
                        if (_count > 1)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 16,
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.55),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '${_index + 1} / $_count',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.white,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
