import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';

import '../accessibility_overlay.dart';
import '../big_bang_tokenizer.dart';
import '../overlay_constants.dart';

/// 大爆炸分词层（锤子 Big Bang 式交互）：展开卡正文长按唤起，白底
/// 模态把一大段文字炸成词块（深字浅底，2026-10-08 起由深色改浅色，
/// 对齐锤子原版白色卡片视觉），点选/滑选后一键复制。
/// **深色模式适配**（2026-10-08 用户拍板，防深色模式下白底刺眼）：
/// [isDark] = true 换深色配色（近黑底 [OverlayConstants.bigBangBackgroundDark]
/// + 浅字浅底词块，选中词块维持主题蓝底白字不变）；null = 跟随
/// `Theme.of(context).brightness` 自动判定（主 App 路由在 MaterialApp
/// 树下天然正确）；悬浮窗 engine 固定浅色主题（跨背景对比度设计），
/// 由 overlay_home 读 theme_mode prefs 显式传入。
///
/// 层顶边对齐面板 header 上缘（[topInset]，随「面板高度」档位联动），
/// 不撑满全屏——单手够得着顶栏；顶边上方与底部关闭条透出下层画面但
/// 加压暗遮罩（[OverlayConstants.bigBangScrimColor]，明暗分层让白色
/// 主体浮出，用户拍板）。白色主体四角圆弧化
///（[OverlayConstants.bigBangCornerRadius]，缺口透出压暗的下层画面）。
/// 词块区内容纵向居中（短内容居中展示、长内容仍可滚动，
/// 见 [_buildTokenArea]）。底部为透明关闭条（点击任意位置或中间 ✕
/// 按钮关闭本层，见 [_buildCloseStrip]）。
///
/// 分词走 [BigBangTokenizer]（jieba 词级，失败回退字符级）；
/// 测试经 [initialTokens] 直通词块、跳过异步加载。
///
/// 手势模型（点选 + 滑动连选并存）：
/// - **点选**：词块自带 GestureDetector(onTap) toggle；
/// - **滑选**：外层 [Listener] 不参与手势竞技场、全量收指针事件，按下落
///   在可选词块上时记录候选锚点，位移超 kTouchSlop 才进入连选（与 tap
///   识别器的 slop 同阈值——未超阈值松手 = tap 照常 toggle，互不抢）；
///   连选中按"锚点 → 当前命中词块"的 index 区间操作（只动可选词块，
///   标点/空白跳过——它们的原文由 joinSelected 在区间拼接时带出）。
///   模式由**锚点词块的选中态**决定（锤子原版语义）：
///   - 锚点未选中 → **追加置选**：本轮起步时快照已有选择为基线
///     [_dragBase]，区间与基线取并集——松手后再次滑选是追加新词而不是
///     覆盖旧选（真机反馈：先滑选开头几个词、再到末尾滑选追加，开头的
///     不能丢）；
///   - 锚点已选中 → **滑动取消**：区间从基线中剔除——在已连选的词块上
///     滑过即取消选择。同一轮内拖回缩小区间可恢复（基线不动，只影响
///     本轮划到的范围）。
/// - **与滚动的仲裁**：Listener 不抢竞技场，ScrollView 垂直滚动照常；
///   按下落在词块上时同步把 physics 换成 NeverScrollable（该次手势变成
///   纯连选，不边选边滚），松手恢复——滚动起点选在词块间隙/空白区即可。
/// - 震动：每次选择变化走 EFFECT_TICK 线性马达家族（与卡片 AI 对话按钮
///   的复制震动同档），40ms 节流防快速划过连续嗡。
///
/// 二次爆炸（底栏刀按钮 [_doExplode]）：jieba 词级切分不合心意时把**选中
/// 词块**就地再炸成单字（中文逐字、英文逐字母，emoji 不劈代理对），炸出
/// 的单字保持选中；选中全是单字时按钮禁用（幂等）。不做撤销。
class BigBangLayer extends StatefulWidget {
  /// 原文（jieba 异步加载后切分；加载期间词块区显示"分词中…"）
  final String text;

  /// 测试直通：非 null 时跳过异步分词直接渲染
  final List<BigBangToken>? initialTokens;

  /// 字体大小档位（-2~+2，与面板卡片同源，词块字号经 fontScaled 缩放）
  final int fontSizeStep;

  /// 层顶边距窗口顶的距离（dp）：overlay_home 传「状态栏固定避让
  ///（panelHeaderTopPadding）+ 面板高度档下压偏移（panelTopOffsetFor）」，
  /// 让层顶边与面板 header（新增按钮所在工具条）上缘对齐、随「面板高度」
  /// 档位联动下移——层不再撑满全屏，顶栏进拇指区。顶边上方留白透出下层
  /// 画面但加压暗遮罩（bigBangScrimColor），点按/滑动就地吸收不穿透到
  /// 底层空白区收起手势
  final double topInset;

  final VoidCallback onClose;

  /// 复制选中文字（父层走原生 copyText 通道，自带 EFFECT_TICK + 剪贴板）。
  /// 返回是否成功——成功即关闭本层
  final Future<bool> Function(String text) onCopy;

  /// 联网搜索选中文字（父层读搜索配置后经原生 openUrl 通道拉起浏览器）。
  /// 返回是否成功——成功即关闭本层；null = 不渲染搜索按钮
  final Future<bool> Function(String text)? onSearch;

  /// 触感回调（测试注入记录器；缺省走原生 performHaptic 通道）
  final void Function(String type)? onHaptic;

  /// 深色配色开关：true = 近黑底浅字（深色模式防白底刺眼）；null = 跟随
  /// Theme brightness 自动判定（主 App 路径）。悬浮窗 engine 固定浅色主题，
  /// 自动判定恒为浅色，须由 overlay_home 显式传入
  final bool? isDark;

  const BigBangLayer({
    super.key,
    required this.text,
    this.initialTokens,
    this.fontSizeStep = 0,
    this.topInset = OverlayConstants.panelHeaderTopPadding,
    required this.onClose,
    required this.onCopy,
    this.onSearch,
    this.onHaptic,
    this.isDark,
  });

  @override
  State<BigBangLayer> createState() => _BigBangLayerState();
}

class _BigBangLayerState extends State<BigBangLayer> {
  List<BigBangToken>? _tokens; // null = 分词中
  final Set<int> _selected = {};

  /// 词块命中换算：可选词块的 GlobalKey 表 + 首帧后缓存的 Rect（相对词块
  /// 区容器 [_areaKey]——同一坐标系随滚动整体平移，滚动不失效）。
  /// 指针全局坐标经容器 globalToLocal 换算后与缓存 Rect 求交
  final GlobalKey _areaKey = GlobalKey();
  List<GlobalKey> _tokenKeys = const [];
  final Map<int, Rect> _rects = {};

  // 连选手势状态（见类注释的手势模型）
  int? _pressedToken; // 按下命中的可选词块（null = 空白/标点区）
  Offset _downPosition = Offset.zero;
  int? _dragAnchor; // 非 null = 已进入连选
  // 本轮连选起步时的已有选择快照：置选轮区间与基线取并集（追加语义——
  // 松手后再次滑选不丢旧选）；取消轮从基线剔除区间。同一轮内锚点→当前
  // 位置的区间仍可整体调整（拖回缩小区间只影响本轮范围，基线不动）
  Set<int> _dragBase = const {};
  // 本轮是否为「滑动取消」：起步时锚点词块已选中则置位（锤子原版语义——
  // 在已选词块上滑动 = 取消选择），区间从基线剔除而非并集
  bool _dragDeselect = false;
  bool _scrollLocked = false;

  bool _copying = false;
  bool _searching = false;
  DateTime _lastTick = DateTime.fromMillisecondsSinceEpoch(0);

  // --- 深浅双色板（浅色 = 锤子原版白底深字；深色 = 近黑底浅字防刺眼，
  // 2026-10-08 用户拍板）。选中词块恒主题蓝底白字，不随深浅变化 ---
  static Color _primaryText(bool d) =>
      d ? Colors.white.withValues(alpha: 0.87) : Colors.black87;
  static Color _secondaryText(bool d) => d ? Colors.white38 : Colors.black38;
  static Color _actionText(bool d) => d ? Colors.white60 : Colors.black54;
  static Color _unselectedBg(bool d) => d
      ? Colors.white.withValues(alpha: 0.07)
      : Colors.black.withValues(alpha: 0.05);
  static Color _unselectedBorder(bool d) => d
      ? Colors.white.withValues(alpha: 0.14)
      : Colors.black.withValues(alpha: 0.10);
  static Color _disabledBg(bool d) => d
      ? Colors.white.withValues(alpha: 0.08)
      : Colors.black.withValues(alpha: 0.06);
  static Color _disabledIcon(bool d) => d ? Colors.white30 : Colors.black26;
  static Color _barBg(bool d) => d
      ? Colors.white.withValues(alpha: 0.06)
      : Colors.black.withValues(alpha: 0.05);
  static Color _barBorder(bool d) => d
      ? Colors.white.withValues(alpha: 0.10)
      : Colors.black.withValues(alpha: 0.08);

  @override
  void initState() {
    super.initState();
    if (widget.initialTokens != null) {
      _tokens = widget.initialTokens;
      _prepareKeys();
      _scheduleRecacheRects();
    } else {
      _loadTokens();
    }
  }

  Future<void> _loadTokens() async {
    final tokens = await BigBangTokenizer.tokenize(widget.text);
    if (!mounted) return;
    setState(() => _tokens = tokens);
    _prepareKeys();
    _scheduleRecacheRects();
  }

  void _prepareKeys() {
    _tokenKeys = [for (var i = 0; i < _tokens!.length; i++) GlobalKey()];
    // tokens 更换（二次爆炸）后旧 index 的 Rect 全部失效——setState 到
    // postFrame 重缓存之间 _hitToken 会拿旧 Rect 命中新词块，这里同步清掉
    //（_loadTokens 路径 rects 本为空，清空无害）
    _rects.clear();
  }

  void _scheduleRecacheRects() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _recacheRects());
  }

  void _recacheRects() {
    if (!mounted || _tokens == null) return;
    final areaBox = _areaKey.currentContext?.findRenderObject() as RenderBox?;
    if (areaBox == null || !areaBox.hasSize) return;
    _rects.clear();
    for (var i = 0; i < _tokenKeys.length; i++) {
      if (!_tokens![i].selectable) continue;
      final box =
          _tokenKeys[i].currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final topLeft = box.localToGlobal(Offset.zero, ancestor: areaBox);
      // inflate(2)：命中区比视觉词块外扩 2dp 容错（词块间距 6dp，不串邻居）
      _rects[i] = (topLeft & box.size).inflate(2);
    }
  }

  int? _hitToken(Offset globalPosition) {
    final areaBox = _areaKey.currentContext?.findRenderObject() as RenderBox?;
    if (areaBox == null) return null;
    final local = areaBox.globalToLocal(globalPosition);
    for (final entry in _rects.entries) {
      if (entry.value.contains(local)) return entry.key;
    }
    return null;
  }

  void _tick() {
    final now = DateTime.now();
    if (now.difference(_lastTick).inMilliseconds < 40) return;
    _lastTick = now;
    (widget.onHaptic ?? AccessibilityOverlay.performHaptic)('tick');
  }

  void _toggle(int i) {
    setState(() {
      if (!_selected.remove(i)) _selected.add(i);
    });
    _tick();
  }

  /// 连选区间应用：置选轮 = 区间与本轮基线 [_dragBase] 取并集（追加语义）；
  /// 取消轮（[_dragDeselect]）= 基线剔除区间。返回是否有变化（有变化才震）
  bool _applyRange(int a, int b) {
    final lo = math.min(a, b), hi = math.max(a, b);
    final range = [
      for (var i = lo; i <= hi; i++)
        if (_tokens![i].selectable) i,
    ];
    final next = <int>{..._dragBase};
    if (_dragDeselect) {
      next.removeAll(range);
    } else {
      next.addAll(range);
    }
    if (next.length == _selected.length && next.containsAll(_selected)) {
      return false;
    }
    setState(
      () => _selected
        ..clear()
        ..addAll(next),
    );
    return true;
  }

  void _onPointerDown(PointerDownEvent e) {
    _pressedToken = _hitToken(e.position);
    _downPosition = e.position;
    _dragAnchor = null;
    // 按下在词块上：锁滚动（该次手势留给连选，防边选边滚）；
    // 空白/标点区按下不锁，垂直滚动照走 ScrollView
    if (_pressedToken != null && !_scrollLocked) {
      setState(() => _scrollLocked = true);
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    final pressed = _pressedToken;
    if (pressed == null) return;
    if (_dragAnchor == null) {
      // 未超 tap 识别器同阈值 = 仍可能是点按，不进连选（tap 照常 toggle）
      if ((e.position - _downPosition).distance < kTouchSlop) return;
      _dragAnchor = pressed;
      // 起步快照已有选择为基线；锚点已选中 → 本轮为滑动取消（原版语义：
      // 在已选词块上滑过即取消），锚点未选中 → 区间与基线并集追加
      _dragBase = {..._selected};
      _dragDeselect = _dragBase.contains(pressed);
      // 起步即按当前命中位置求区间（不能 return——单事件跨过多个词块时
      // 区间必须一步铺满，真机逐帧 move 与测试单 moveTo 是同一语义）
    }
    // 划出词块区：端点保持原位（拖回去继续）；刚起步尚在锚点上落回锚点
    final idx = _hitToken(e.position) ?? _dragAnchor!;
    if (_applyRange(_dragAnchor!, idx)) _tick();
  }

  void _onPointerUpOrCancel() {
    _pressedToken = null;
    _dragAnchor = null;
    _dragBase = const {};
    _dragDeselect = false;
    if (_scrollLocked) setState(() => _scrollLocked = false);
  }

  Future<void> _doCopy() async {
    final text = BigBangTokenizer.joinSelected(_tokens!, _selected);
    if (text.isEmpty || _copying) return;
    _copying = true;
    final ok = await widget.onCopy(text);
    if (!mounted) return;
    _copying = false;
    if (ok) widget.onClose();
  }

  Future<void> _doSearch() async {
    final onSearch = widget.onSearch;
    if (onSearch == null) return;
    final text = BigBangTokenizer.joinSelected(_tokens!, _selected);
    if (text.isEmpty || _searching) return;
    _searching = true;
    _tick();
    final ok = await onSearch(text);
    if (!mounted) return;
    _searching = false;
    if (ok) widget.onClose();
  }

  int get _selectedCharCount =>
      _selected.fold(0, (sum, i) => sum + _tokens![i].text.length);

  /// 二次爆炸可用性：选中词块中至少一个多字词才可再炸（选中全是单字/
  /// 无选中/分词中 → 底栏刀按钮禁用）
  bool get _canExplode =>
      _tokens != null &&
      _selected.any((i) => _tokens![i].text.runes.length > 1);

  /// 二次爆炸：选中的词块就地炸成单字（中文逐字、英文逐字母），炸出的
  /// 可选单字**保持选中**——用户可立刻复制/搜索，或点掉多余单字；未选中
  /// 的词块原样不动。不做撤销：爆炸是追加式变换（可逐字点选修正），
  /// 重炸成本仅一次长按
  void _doExplode() {
    if (!_canExplode) return;
    final old = _tokens!;
    final indices = _selected.toList()..sort();
    final next = <BigBangToken>[];
    final nextSelected = <int>{};
    var cursor = 0; // 旧序列扫描游标
    for (final i in indices) {
      while (cursor < i) {
        next.add(old[cursor++]); // 未选中段原样搬运
      }
      for (final p in BigBangTokenizer.explodeToChars(old[i].text)) {
        // 词内夹的标点/emoji 不可选、不进选中集，但留在序列——joinSelected
        // 区间拼接照样带出原文
        if (p.selectable) nextSelected.add(next.length);
        next.add(p);
      }
      cursor = i + 1;
    }
    while (cursor < old.length) {
      next.add(old[cursor++]); // 尾部原样搬运
    }
    setState(() {
      _tokens = next;
      _selected
        ..clear()
        ..addAll(nextSelected);
      _scrollLocked = false; // 连选状态防御性复位（多指：一手按词块一手点刀）
    });
    _pressedToken = null;
    _dragAnchor = null;
    _dragBase = const {};
    _dragDeselect = false;
    _prepareKeys(); // index 全漂移：keys/rects 同步重建
    _scheduleRecacheRects();
    _tick();
  }

  @override
  Widget build(BuildContext context) {
    // null = 自动判定：主 App 路由在 MaterialApp 树下，Theme brightness 已
    // 解析好「跟随系统」；悬浮窗 engine 固定浅色主题，须显式传 isDark
    final isDark =
        widget.isDark ?? Theme.of(context).brightness == Brightness.dark;
    final fs = OverlayConstants.fontScaled(
      OverlayConstants.bigBangFontSize,
      widget.fontSizeStep,
    );
    return Column(
      children: [
        // 顶部留白（层顶边 = 面板 header 上缘，见 topInset 注释）：透出下层
        // 画面但加压暗遮罩（bigBangScrimColor，明暗分层让白色主体浮出）。
        // opaque 命中 + onTap 吸收触摸——底层是面板空白区的收起手势，穿透
        // 会把面板连同本层一起收掉；横滑无识别器认领（空白区不在命中路径
        // 内），天然无操作
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {},
          // 必须显式撑满宽：Column 交叉轴默认 center，SizedBox 只给高度会
          // 收缩到 0 宽，「吸收触摸」形同虚设
          child: Container(
            width: double.infinity,
            height: widget.topInset,
            color: OverlayConstants.bigBangScrimColor,
          ),
        ),
        Expanded(
          // 圆角缺口同样吸收触摸：裁切外的角落区域若不接住，overlay 侧穿
          // 透会命中面板空白区收起手势（把面板连同本层一起收掉），主 App
          // 侧（opaque:false 路由无 barrier）穿透会点到下层日记卡。
          // 缺口区同样铺压暗遮罩（白色 Material 覆盖区不受影响）
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: Container(
              color: OverlayConstants.bigBangScrimColor,
              child: Material(
                color: isDark
                    ? OverlayConstants.bigBangBackgroundDark
                    : OverlayConstants.bigBangBackground,
                // 四角圆弧（用户拍板）：Material 的 borderRadius 只影响背景
                // 形状，子内容须显式 clipBehavior 才会随圆角裁切
                borderRadius:
                    BorderRadius.circular(OverlayConstants.bigBangCornerRadius),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    _buildTopBar(isDark),
                    Expanded(
                      child: _tokens == null
                          ? Center(
                              child: Text(
                                '分词中…',
                                style: TextStyle(
                                  color: _secondaryText(isDark),
                                  fontSize: 14,
                                ),
                              ),
                            )
                          : _buildTokenArea(fs, isDark),
                    ),
                    _buildBottomBar(isDark),
                  ],
                ),
              ),
            ),
          ),
        ),
        _buildCloseStrip(),
      ],
    );
  }

  /// 底部关闭条（原 48dp 深色避让条把底部「完全盖住」——改透出下层画面，
  /// 点击条带任意位置或中间 ✕ 按钮都关闭本层，单手大拇指在底部即可关层；
  /// 2026-10-08 起透出部分加压暗遮罩 bigBangScrimColor，与顶部留白同一
  /// 明暗分层语言）。视觉透明但 opaque 命中吸收触摸：overlay 侧穿透会命
  /// 中面板空白区收起手势把面板连同本层一起收掉，主 App 侧穿透会点到下
  /// 层日记卡。高度 48 沿用原底部避让惯例（FLAG_LAYOUT_NO_LIMITS 窗口
  /// 拿不到系统 insets）
  Widget _buildCloseStrip() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onClose,
      child: Container(
        width: double.infinity,
        height: 48,
        color: OverlayConstants.bigBangScrimColor,
        child: Center(
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            ),
            child: const Icon(Icons.close, color: Colors.white70, size: 18),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(bool isDark) {
    final count = _tokens == null ? 0 : _selectedCharCount;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          const SizedBox(width: 8),
          Text(
            '大爆炸',
            style: TextStyle(color: _primaryText(isDark), fontSize: 14),
          ),
          const SizedBox(width: 10),
          Text(
            '已选 $count 字',
            style: TextStyle(color: _secondaryText(isDark), fontSize: 12),
          ),
          const Spacer(),
          _buildTopAction(isDark, '全选', () {
            setState(
              () => _selected
                ..clear()
                ..addAll([
                  for (var i = 0; i < _tokens!.length; i++)
                    if (_tokens![i].selectable) i,
                ]),
            );
            _tick();
          }),
          _buildTopAction(isDark, '清空', () {
            if (_selected.isEmpty) return;
            setState(_selected.clear);
            _tick();
          }),
          IconButton(
            icon: Icon(Icons.close, color: _actionText(isDark), size: 22),
            tooltip: '关闭',
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }

  Widget _buildTopAction(bool isDark, String label, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _tokens == null ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Text(
          label,
          style: TextStyle(color: _actionText(isDark), fontSize: 13),
        ),
      ),
    );
  }

  Widget _buildTokenArea(double fs, bool isDark) {
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: (_) => _onPointerUpOrCancel(),
      onPointerCancel: (_) => _onPointerUpOrCancel(),
      // 词块内容纵向居中（用户拍板，主 App/悬浮窗共用本层一处生效）：短
      // 内容在词块区居中展示而非从顶往下排；长内容超出视口仍可滚动。
      // 滚动视图内居中的标准结构：LayoutBuilder 取视口高 → ConstrainedBox
      // (minHeight) 保底撑满视口 → Center 居中（Center 在无界高度下收缩到
      // 内容、被 minHeight 钳到视口高，内容超高时居中自然退化为不变）
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: _scrollLocked
              ? const NeverScrollableScrollPhysics()
              : const ClampingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              // 扣除 ScrollView 上下 padding（12×2）才是内容可用视口高；
              // 矮视口 clamp 到 0 防负约束
              minHeight: math.max(0, constraints.maxHeight - 24),
            ),
            child: Center(
              child: SizedBox(
                key: _areaKey,
                // 撑满可用宽：短行右侧空白区也能作为滚动起点
                width: double.infinity,
                child: Wrap(
                  children: [
                    for (var i = 0; i < _tokens!.length; i++)
                      _buildToken(i, fs, isDark),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToken(int i, double fs, bool isDark) {
    final token = _tokens![i];
    // 空白 token：不渲染词块（流式布局天然留白），仅占位透出间距
    if (BigBangTokenizer.isWhitespace(token.text)) {
      return const SizedBox(width: 6);
    }
    if (!token.selectable) {
      // 标点：降级渲染、不可选（原文由 joinSelected 区间拼接时带出）
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 1, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Text(
          token.text,
          style: TextStyle(color: _secondaryText(isDark), fontSize: fs, height: 1.2),
        ),
      );
    }
    final selected = _selected.contains(i);
    return GestureDetector(
      onTap: () => _toggle(i),
      child: Container(
        key: _tokenKeys[i],
        margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          // 明暗反转：未选 = 浅灰底深字（深色模式 = 深灰底浅字），选中 =
          // 主题蓝底白字（滑选/点选即高亮，与锤子原版选中同语义，不随深浅变）
          color: selected
              ? OverlayConstants.defaultCardColor
              : _unselectedBg(isDark),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? OverlayConstants.defaultCardColor
                : _unselectedBorder(isDark),
          ),
        ),
        child: Text(
          token.text,
          style: TextStyle(
            color: selected ? Colors.white : _primaryText(isDark),
            fontSize: fs,
            height: 1.2,
          ),
        ),
      ),
    );
  }

  /// 底栏圆形图标胶囊（刀/搜索按钮共用）：启用 = defaultCardColor 底白图标，
  /// 禁用 = 浅灰底 + 灰图标（深色模式反转为深灰底浅灰图标），onTap 置 null
  Widget _buildCapsuleIcon({
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required VoidCallback onTap,
    required bool isDark,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: enabled
                ? OverlayConstants.defaultCardColor
                : _disabledBg(isDark),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Icon(
            icon,
            size: 20,
            color: enabled ? Colors.white : _disabledIcon(isDark),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar(bool isDark) {
    final hasSelection = _tokens != null && _selected.isNotEmpty;
    final preview = _tokens == null
        ? ''
        : BigBangTokenizer.joinSelected(_tokens!, _selected);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _barBg(isDark),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _barBorder(isDark)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              hasSelection ? preview : '点选或滑动选择词块',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: hasSelection
                    ? _primaryText(isDark)
                    : _secondaryText(isDark),
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 二次爆炸刀按钮（锤子原版同款位置语义：底栏工具位）：把选中词块
          // 再炸成单字；选中全是单字/无选中时禁用（无可炸）
          _buildCapsuleIcon(
            icon: Icons.content_cut,
            tooltip: '再炸成单字',
            enabled: _canExplode,
            onTap: _doExplode,
            isDark: isDark,
          ),
          // 搜索按钮（onSearch 注入时才渲染）
          if (widget.onSearch != null) ...[
            const SizedBox(width: 8),
            _buildCapsuleIcon(
              icon: Icons.search,
              tooltip: '搜索',
              enabled: hasSelection,
              onTap: _doSearch,
              isDark: isDark,
            ),
          ],
          const SizedBox(width: 8),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: hasSelection ? _doCopy : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
              decoration: BoxDecoration(
                color: hasSelection
                    ? OverlayConstants.defaultCardColor
                    : _disabledBg(isDark),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '复制',
                style: TextStyle(
                  color: hasSelection
                      ? Colors.white
                      : _secondaryText(isDark),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
