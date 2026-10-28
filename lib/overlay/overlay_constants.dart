import 'package:flutter/material.dart';

/// 悬浮窗（闪念胶囊）通用常量

/// 把手主题（皮肤）。三套（2026-09-22 用户定夺）：
/// - [duo] 双色药丸（默认，历史视觉）：上暖白 / 下绿，图标取下半色呼应成对
/// - [bluePurple] 蓝紫：与悬浮窗笔记卡片色系一致——上 = 卡片默认蓝
///   [OverlayConstants.defaultCardColor] / 下 = 默认「灵感」槽位紫（槽位外观
///   可在设置页「标签外观」改色，utils/diary_tag 的 DiaryTagStyles），图标文字白色
/// - [pill3d] 拟物胶囊💊：上白 / 下珊瑚红 + 左侧高光条 + 下半暗部渐变的
///   立体药丸，纯造型无图标无文字（用户定夺"没有文字的风格"）
enum HandleTheme { duo, bluePurple, pill3d }

/// 息屏（ACTION_SCREEN_OFF）时悬浮窗的去向（
/// [OverlayConstants.screenOffActionFor] 的返回值）
enum ScreenOffAction {
  /// 把手驻留穿越 AOD（「永久」档）：窗口仅由 Kotlin GONE/VISIBLE 随
  /// 息屏/亮屏切换可见性，Dart 不推进状态，亮屏后把手原样回来
  keepHandle,

  /// 缩成贴边竖线驻留（限时档 + 「隐藏后保留贴边竖线」开关开）
  enterEdgeLine,

  /// 彻底移除悬浮窗窗口（限时档 + 竖线开关关），只能音量键重新召唤
  closeOverlay,
}

/// [HandleTheme] 的渲染属性（色值与内容显隐），OverlayHandle 与设置页
/// 色板 avatar 共用唯一真值
extension HandleThemeVisuals on HandleTheme {
  /// 胶囊上半区色
  Color get capsuleTopColor => switch (this) {
    HandleTheme.duo => OverlayConstants.handleCapsuleTopColor,
    HandleTheme.bluePurple => OverlayConstants.defaultCardColor,
    HandleTheme.pill3d => const Color(0xFFF7F8F6),
  };

  /// 胶囊下半区色（拟物主题为基色，渲染时再叠受光/背光渐变）
  Color get capsuleBottomColor => switch (this) {
    HandleTheme.duo => OverlayConstants.handleCapsuleBottomColor,
    HandleTheme.bluePurple => const Color(0xFFAE82E4), // 灵感标注紫
    HandleTheme.pill3d => const Color(0xFFE0524E), // emoji💊 珊瑚红
  };

  /// 闪电图标色：双色药丸取下半色（落在白半区呼应成对，历史语言）；
  /// 蓝紫上下皆饱和彩色，白图标落上半蓝对比最稳
  Color get iconColor => switch (this) {
    HandleTheme.duo => capsuleBottomColor,
    _ => Colors.white,
  };

  /// 竖排「闪记」文字色（白字落在下半区）
  Color get labelColor => Colors.white;

  /// 是否渲染闪电图标：拟物纯造型无图标（无文字见 handleShowsLabel）
  bool get showsIcon => this != HandleTheme.pill3d;

  /// 拟物主题：叠高光条 + 下半暗部渐变（立体感三层）
  bool get isPill3d => this == HandleTheme.pill3d;
}

class OverlayConstants {
  OverlayConstants._();

  /// 收起态把手宽度（dp）。⚠️ 原生侧硬编码副本 HANDLE_WIDTH_DP（拖动守卫按
  /// 「窗口宽 == 把手宽」判定）与 showOverlay 初始建窗 (28, 88) 双处同步
  static const int handleWidth = 28;

  /// 收起态把手高度（dp）。语音胶囊窗口高（voiceMemoWindowHeight 84）必须
  /// 小于本值——overlay_home build 的硬不变量按 [isCapsuleHeightWindow]
  /// 判定 idle 帧渲染空白
  static const int handleHeight = 88;

  /// 把手窗口 vs 语音胶囊窗口的判定阈值（dp）：两设计高度（88/84）的中点。
  /// dp→px 换算取整误差恒 <1px（≤1dp，密度越高越小），把手窗实测最低 ≈87.0、
  /// 胶囊窗实测最高 ≈84.5，极端值都落在本阈值两侧安全区内
  static double get handleWindowHeightThreshold =>
      (handleHeight + voiceMemoWindowHeight) / 2;

  /// 窗口实测高度是否属于「语音胶囊高度档」（overlay_home 硬不变量用：
  /// idle 帧在胶囊高度窗口里渲染空白，防把手像素混进语音速记冷启动帧）。
  /// ⚠️ 不能用 maxHeight < handleHeight 判定——Kotlin dpToPx 取整会让把手
  /// 窗口实测比设计值小（88dp @density2.8125 → 247px → 87.8dp），真机反馈
  /// 「把手/竖线点按后变空白」即此误杀（详见 docs/architecture/
  /// floating-window.md「硬不变量高度误判」小节）
  static bool isCapsuleHeightWindow(double maxHeight) =>
      maxHeight < handleWindowHeightThreshold;

  /// ── 把手大小档位（2026-09-22，用户反馈把手胶囊有点大、可调）──
  ///
  /// 方案 A「只缩视觉不缩窗口」：窗口恒 28×88——原生硬编码副本 HANDLE_WIDTH_DP、
  /// 语音胶囊 84<88 不变量、dragHandle「窗口宽 == 把手宽」守卫、Kotlin
  /// EDGE_LINE_WIDTH_THRESHOLD_DP=24 宽度分流四者联动，动窗口任一都破（真缩到
  /// 一半宽 14 < 24 阈值还会与竖线态撞车）；胶囊本体在窗口内按档位缩放，触控
  /// 面积不变（把手越小越难点，命中区保住窗口整面积）
  /// prefs key（int 百分比；写入方：设置页悬浮窗二级页；读取方：overlay engine
  /// 的 _refreshSide/_scheduleAutoHide——跨 engine 各自读，无内存共享）
  static const String handleSizePrefKey = 'overlay_handle_size_percent';
  static const int handleSizeDefaultPercent = 100;

  /// 合法档位集合（设置页 ChoiceChip 与解析兜底共用）
  static const List<int> handleSizePercents = [100, 75, 50];

  /// 解析 prefs 档位值：非合法档（null/旧版本值/坏值）一律兜底默认 100%
  static int parseHandleSizePercent(int? raw) =>
      raw != null && handleSizePercents.contains(raw)
      ? raw
      : handleSizeDefaultPercent;

  /// 是否迷你档（最小档）：胶囊 12×40 放不下任何内容变体，图标缩为
  /// handleIconSizeMini（2026-09-22 起小档（75%）也不显示文字——真机反馈
  /// 18 宽胶囊竖排文字太挤，文字仅标准档保留，见 [handleShowsLabel]）
  static bool isMiniHandleSize(int percent) =>
      percent <= handleSizePercents.last;

  /// 档位 + 主题 → 是否显示竖排「闪记」文字：仅标准档（100%）且非拟物主题
  ///（拟物胶囊💊纯造型无文字，用户定夺 2026-09-22）
  static bool handleShowsLabel(int percent, HandleTheme theme) =>
      percent >= handleSizePercents.first && theme != HandleTheme.pill3d;

  /// ── 日记面板字体大小档位（2026-09-27，用户要求可调）──
  ///
  /// 五档：-2/-1/0（标准，历史视觉）/+1/+2，每档 = 1pt（0.5pt 档差真机不可辨，
  /// 2pt 档差最小档收起胶囊 12→8 跌破可读性下限，1pt 是档差可感知与下限可读
  /// 的折中）。作用范围 = 日记面板文字（收起胶囊/展开正文/时间行/重放行/删除
  /// 确认行/已归档分隔线/空态错误态）；不作用：把手「闪记」（有独立把手大小
  /// 档位管视觉缩放，叠加会双重缩放）、语音速记胶囊（宽度预算按 15 号字调过）、
  /// 各类临时提示胶囊（转瞬 UI）。
  /// prefs key（int；写入方：设置页悬浮窗二级页；读取方：overlay engine 的
  /// _refreshOverlayConfig/_scheduleAutoHide——跨 engine 各自读，无内存共享）
  static const String fontSizeStepPrefKey = 'overlay_font_size_step';
  static const int fontSizeStepMin = -2;
  static const int fontSizeStepMax = 2;
  static const int fontSizeStepDefault = 0;

  /// ── 「全部展开」状态持久化（2026-10-19，用户要求沿上次展开）──
  ///
  /// header「全部展开/收起」按钮的状态跨窗口会话保留：展开全部 → true，
  /// 收起全部 → false（缺省 false = 历史行为，下次打开全收起）。
  /// 写入方/读取方同为 overlay engine（_toggleExpandAll 写、_expand 收起态
  /// 主分支读），同一 isolate 的 prefs 内存缓存天然同步，读取无需 reload；
  /// 主 App 侧无入口
  static const String expandAllCardsPrefKey = 'overlay_expand_all_cards';

  /// 解析 prefs 档位值：null 兜底标准档，越界/坏值 clamp 到 [-2, 2]
  ///（范围语义，与把手大小的合法集合白名单不同——档位是连续刻度）
  static int parseFontSizeStep(int? raw) => raw == null
      ? fontSizeStepDefault
      : raw.clamp(fontSizeStepMin, fontSizeStepMax);

  /// 档位 → 实际字号：基准 + 档位（每档 1pt）。调用方传各基准常量/字面量，
  /// 文字测量（TextPainter）与渲染必须用同一缩放值，否则胶囊宽度估算偏窄
  /// 会把短文字顶出省略号（046fe0b 同款不变量）
  static double fontScaled(double base, int step) => base + step;

  /// ── 把手主题（皮肤，2026-09-22）──
  /// prefs key（string = enum name；写入方：设置页悬浮窗二级页；读取方：
  /// overlay engine 的 _refreshSide/_scheduleAutoHide——跨 engine 各自读，
  /// 无内存共享）
  static const String handleThemePrefKey = 'overlay_handle_theme';

  /// 解析 prefs 主题值：null/旧版本值/坏串一律兜底默认 [HandleTheme.duo]
  static HandleTheme parseHandleTheme(String? raw) =>
      raw != null && HandleTheme.values.asNameMap().containsKey(raw)
      ? HandleTheme.values.byName(raw)
      : HandleTheme.duo;

  /// 胶囊基准尺寸（100% 档视觉，dp）= 窗口 28×88 减历史内缩（横 2 / 纵 4，
  /// 2026-09-13「缩小一号」定下的值），各档视觉在此基准上等比缩放
  static const double _handleCapsuleBaseWidth = 24.0;
  static const double _handleCapsuleBaseHeight = 80.0;

  /// 档位 → 胶囊本体视觉尺寸（dp）：100% → 24×80（历史值）/ 75% → 18×60 /
  /// 50% → 12×40
  static double handleCapsuleWidth(int percent) =>
      _handleCapsuleBaseWidth * percent / 100;
  static double handleCapsuleHeight(int percent) =>
      _handleCapsuleBaseHeight * percent / 100;

  /// 档位 → 胶囊相对窗口的单侧内缩（dp）=（窗口 − 视觉）/ 2：
  /// 100% → (2, 4) / 75% → (5, 14) / 50% → (8, 24)
  static double handleInsetHorizontalOf(int percent) =>
      (handleWidth - handleCapsuleWidth(percent)) / 2;
  static double handleInsetVerticalOf(int percent) =>
      (handleHeight - handleCapsuleHeight(percent)) / 2;

  /// 迷你档闪电图标尺寸（dp）：12 宽胶囊减两侧描边（2×cardBorderWidth）净宽
  /// 10，标准档 13dp 超宽，缩到 9dp 安全
  static const double handleIconSizeMini = 9.0;

  /// 收起态把手文字（中文逐字竖排）
  static const String handleLabel = '闪记';

  /// 把手小图标尺寸（dp）
  static const double handleIconSize = 13.0;

  /// 把手字号（竖排小字）
  static const double handleFontSize = 10.0;

  /// ── 把手「药丸胶囊」双色皮肤 ──
  /// 用户定夺风格：中间一道接缝横线、上白下绿的双色胶囊（药丸观感），
  /// 具体色值授权自选。上半白取微暖灰白（与白描边保留一丝分界），下半绿
  /// 兼顾鲜亮与白字对比度（≈3.8:1，两字装饰性标签可接受）；闪电图标用
  /// 下半绿同色，落在白半区上呼应成对
  static const Color handleCapsuleTopColor = Color(0xFFF5F6F3);
  static const Color handleCapsuleBottomColor = Color(0xFF2E9F5C);

  /// 中缝接缝线的颜色（半透明黑，落在白/绿两半上都读作凹陷缝）
  static const Color handleSeamColor = Color(0x24000000);

  /// 静置态胶囊整体不透明度（用户要求「稍微透明一点点」，原完全无透明）；
  /// 拖动态回到满不透明（对齐「拖动 = 白描边 + 满不透明」的既有分层语言）
  static const double handleRestingOpacity = 0.93;

  /// 把手/空白区/面板边缘滑动手势的位移阈值（dp）。
  /// 引用方：OverlayHome 的把手/竖线分支（朝屏幕内侧滑展开）/ _buildBlankArea
  ///（任意方向滑收起）/ _buildPanel 面板手势（朝停靠边缘滑收起）/ 卡片
  /// SwipeDismissCard 的快滑转发（卡片上朝停靠边缘快滑收起，同款
  /// "单事件超阈值"判定）。方向判定统一走 [swipeExceeds]
  static const double edgeSwipeThreshold = 4;

  /// 单事件水平位移是否朝 [towardLeft] 方向越过 [threshold]（把手/竖线/
  /// 面板滑动方向判定的唯一出口，纯函数可测）。
  ///
  /// primaryDelta > 0 = 手指向右滑，< 0 = 向左滑。停靠侧决定"朝屏幕内侧"
  /// 的方向：停靠右缘时内侧 = 向左（towardLeft=true），停靠左缘时内侧 =
  /// 向右（towardLeft=false）——调用方用 `towardLeft: !dockLeft`（展开）
  /// 与 `towardLeft: dockLeft`（收起，朝停靠边缘）换算
  static bool swipeExceeds(
    double? primaryDelta, {
    required bool towardLeft,
    double threshold = edgeSwipeThreshold,
  }) {
    if (primaryDelta == null) return false;
    return towardLeft ? primaryDelta < -threshold : primaryDelta > threshold;
  }

  /// 展开态面板占屏幕宽度比例（面板宽度的唯一真值来源）
  ///
  /// 展开时窗口由原生侧铺满全屏（resizeOverlay 对哨兵值 -1 的宽度解释为
  /// MATCH_PARENT，Kotlin 侧不再持有比例），Dart 侧在 OverlayHome._buildPanel
  /// 里用本比例把停靠侧面板画成「窗口宽 × 0.72」，另一侧 28% 透明空白区承接
  /// 点击/滑动关闭手势。改面板宽度只动这里。
  /// 有卡展开时改用 expandedPanelWidthRatio（0.92），见该常量
  static const double expandedWidthRatio = 0.72;

  /// 有卡展开时的面板宽度比例：展开卡片需要比收起胶囊明显更宽（对齐闪念原型，
  /// 展开卡约占屏宽 88-90%）。窗口本是 MATCH_PARENT 全屏，面板加宽无需原生
  /// resize；收起卡内容自适应+贴停靠侧对齐，面板变宽不改变其渲染宽度/位置
  ///（停靠边缘不动），视觉零影响。读取方：OverlayHome._buildPanel
  ///（_expandedIds 非空时切换本比例，AnimatedContainer 补间宽度）
  static const double expandedPanelWidthRatio = 0.92;

  /// 收起/展开动画时长
  ///
  /// 引用方全链路同步复用本时长：OverlayDiaryCard 的 AnimatedContainer
  ///（constraints.maxWidth 横向补间 + 圆角/padding/背景色补间）/ 外层
  /// AnimatedSwitcher fade-through（cardFadeInInterval 区间挂在本时长的
  /// 时间轴上；其 transitionBuilder 内的收卷 heightFactor/ClipRect 窗口也
  /// 挂在同一时间轴）/ 展开内容根部的局部 AnimatedSize（稳态一次性高度
  /// 变化的平滑，收起路径上被 OverflowBox 冻结排版而全程惰性）+ 面板宽
  /// AnimatedContainer（OverlayHome._buildPanel）。
  /// 200ms 是用户定夺对齐 945be75 的补间节奏（400ms 拉长试验被否决——
  /// "像渐变"的真根因是当时的即时结构色块不收缩，已由恢复补间结构修复，
  /// 见 overlay_diary_card 的 AnimatedContainer 上方注释）
  static const Duration animationDuration = Duration(milliseconds: 200);

  /// 卡片内容 fade-through 淡入区间（补间后半程）。入场 child 的 animation
  /// 正向 0→1，前半程保持透明（外框在长大），后半程淡入——结束时刻与外层
  /// AnimatedSize/AnimatedContainer/面板宽补间（均 animationDuration）严格
  /// 对齐。引用方：OverlayDiaryCard 外层（展开↔收起）与内层（查看↔编辑）
  /// 两个 AnimatedSwitcher transitionBuilder 的 curve
  static const Interval cardFadeInInterval = Interval(0.5, 1.0);

  /// 卡片内容 fade-through 淡出区间（作为 reverseCurve 用）。出场 child 的
  /// 同一 animation 反向 1→0，前半程（0~100ms，animationDuration 200ms 的一半）
  /// 就淡完。与 cardFadeInInterval 端点映射一致（0→0、1→1），中途反向
  /// （快速连点）无透明度跳变
  static const Interval cardFadeOutInterval = Interval(0.5, 1.0);

  /// 查看↔编辑正文切换的淡化时长（独立于展开/收起的 animationDuration（200ms）：
  /// 编辑伴随软键盘弹出，短淡化避免 TextField 半透明窗口过长）。引用方：
  /// OverlayDiaryCard _buildExpandedContent 内层 AnimatedSwitcher 的 duration
  static const Duration cardEditFadeDuration = Duration(milliseconds: 120);

  /// 卡片收放补间曲线（展开/收起共用）。驱动方：OverlayDiaryCard 外层
  /// AnimatedSwitcher 的 transitionBuilder——收卷 progress 由本曲线 transform
  /// 得出，同时驱动 Align(heightFactor) 纵向收卷与 _CollapseWindowClipper
  /// 窗口（横向收卷），与 AnimatedContainer 的 maxWidth/padding 补间同拍。
  /// linear 绝对匀速是用户定夺：中段加速（easeInOut/Sine）与先快后慢
  ///（easeOut）均被真机否决，演进史见 git log（80ce6b3 → c9a3666 → 046fe0b）
  static const Curve cardResizeCurve = Curves.linear;

  /// 卡片固定高度（dp）。全圆角胶囊的圆角半径 = 高度一半
  static const double cardHeight = 46.0;

  /// 卡片最小宽度（dp）。胶囊宽度随内容自适应，短内容（如单字）不至于过小
  static const double cardMinWidth = 60.0;

  /// 卡片间距（dp）
  static const double cardSpacing = 10.0;

  /// 卡片内水平内边距（dp）。为收起态文字区腾宽度收窄到 10；此常量两态
  /// 共用，展开态也随之变窄，属预期
  static const double cardHPadding = 10.0;

  /// 卡片字号（展开/清单等场景通用；用户要求展开态也用 13 号）
  static const double cardFontSize = 13.0;

  /// 大爆炸分词层（展开卡正文长按唤起，big_bang_layer.dart）：
  /// 词块基准字号（比正文大两档，词块即触控目标；随字体大小档位 ±1pt 缩放）
  static const double bigBangFontSize = 17.0;

  /// 大爆炸层背景（浅色）：近不透明白色（2026-10-08 起由深色改浅色，对齐
  /// 锤子原版 Big Bang 白色卡片视觉；全屏模态盖住面板与空白区，留白 2%
  /// 透明让下层隐约在场，关闭时无跳变感）。文字/词块配色随之反转（深字
  /// 浅底）。深色模式改用 [bigBangBackgroundDark]
  static const Color bigBangBackground = Color(0xFAFFFFFF);

  /// 大爆炸层背景（深色）：近不透黑——2026-10-08 浅色化之前的深色底值
  /// 直接复用。读取方：BigBangLayer（isDark 时替代 [bigBangBackground]，主
  /// App 跟随 Theme brightness / 悬浮窗读 theme_mode prefs 显式传入）
  static const Color bigBangBackgroundDark = Color(0xFA101319);

  /// 大爆炸层顶部留白区/底部关闭条/四角圆角缺口的下层压暗遮罩（用户拍板：
  /// 透出下层画面但要明显压暗，明暗分层让白色主体浮出）。35% 黑——下层
  /// 内容仍隐约可辨，但明确退到「下一层」
  static const Color bigBangScrimColor = Color(0x59000000);

  /// 大爆炸层四角圆弧半径（用户拍板：四周边缘圆弧化，主 App/悬浮窗共用
  /// 本层一处生效）。圆角缺口透出下层画面，与顶部透明留白/底部透明关闭条
  /// 同一「层不撑满全屏」的视觉语言
  static const double bigBangCornerRadius = 20.0;

  /// 收起态胶囊字号（比展开态 cardFontSize 小 1：配合收窄后的两端控件与
  /// padding，胶囊达到最大宽度时单行可显示 9 个汉字 + 省略号——小米15
  /// 1200×2670 460ppi→density 3.0，用户开 125% 显示缩放→density 3.75→
  /// 逻辑宽 320dp，面板 320×0.72≈230dp，胶囊 maxWidth=230−28=202dp，
  /// padding 改 10 后文字区=202−20−28（勾选区）−34（播放区）=120dp，
  /// 12 号字 9 字+省略号需 120dp（省略号按全角 1 字宽的最坏情况）；加白描边
  /// 后文字区再让 2dp = 118dp，极端满宽时可能少显半字（可接受，长文本本就近满宽）。
  /// ⚠️ 容量前提是系统字体缩放 = 1.0：overlay 引擎跟随系统字体缩放，
  /// 系统字体放大后文字实际变宽，maxWidth 处可显字数按比例减少（胶囊
  /// 宽度估算已按实际 textScaler 对齐，短内容仍能全展示，见
  /// OverlayDiaryCard._estimateCollapsedWidth）
  static const double cardCollapsedFontSize = 12.0;

  /// 卡片展开态圆角（dp）：全圆角半径=高度一半在多行卡片上不再适用，展开态改固定小圆角
  static const double cardExpandedRadius = 16.0;

  /// 卡片白色描边宽度（dp）：对齐闪念原型"彩色胶囊 + 细白描边 + 柔影"的分层
  /// 策略（白边在复杂壁纸背景上分离胶囊与背景）。原型采样出的 3 层像素
  ///（内侧胶囊浅色混白 / 纯白 / 外侧灰）是白边两侧的抗锯齿过渡，非 3 条
  /// 刻意描边，无需逐层复刻。⚠️ 均匀 Border.all 会被 Container 计入有效
  /// 内边距（child 区两侧各缩本值）：宽度/排版估算须同步 ±2×本值
  ///（OverlayDiaryCard 的 _estimateCollapsedWidth 加项 / _estimateExpandedHeight
  /// 与 frozenWidth 减项 / 收起态内层 ConstrainedBox minHeight 补偿减项——
  /// 维持胶囊总高 = cardHeight 的不变量，圆角半径 cardHeight/2 才恒等于半高）
  static const double cardBorderWidth = 1.0;

  /// 卡片内语音播放按钮视觉直径（dp）：白底实心圆 + 深色图标（复选框勾选态同款
  /// 视觉语言）。语音卡的主操作，不能太小，比复选框(20)大一档
  static const double cardPlayButtonSize = 30.0;

  /// 播放按钮图标尺寸（dp）：play_arrow_rounded / pause_rounded 按播放态切换
  /// （同主 App diary_play_bar 图标，跨界面语义统一）
  static const double cardPlayIconSize = 20.0;

  /// 播放按钮命中区边长（dp）：同复选框 40×40，opaque 命中 + 内层手势竞技场
  /// 胜出，点按钮不冒泡触发卡片展开
  static const double cardPlayButtonHitSize = 40.0;

  /// 归档/恢复写库成功后、刷新列表前的停留时长（给划线反馈留被看见的时间）。
  /// 读取方：OverlayHome._toggleArchive
  static const Duration archiveRefreshDelay = Duration(milliseconds: 250);

  /// 面板展开/收起滑动动画时长（推屏式：收起先滑出再缩窗、展开先扩窗再滑入，
  /// 窗口尺寸切换被编排到动画边界，原生 resize 本身仍瞬时）。
  /// 读取方：OverlayHome 的 _panelAnim
  static const Duration panelSlideDuration = Duration(milliseconds: 240);

  /// 缩窗后把手回位动效总时长（延迟 + 滑入渐显）。缩窗时窗口 frame 从
  /// (0,0,全屏) 移到 (停靠缘,垂直居中,28×88)，移动期 Dart 感知不到完成时刻——
  /// 配合 curve Interval(0.625, 1.0)（见 _postResizeFadeCurve 构造处）：
  /// 前 60%（300ms）value 恒 0，把手完全透明，等窗口 frame 移动完成；
  /// 后 40%（180ms）把手从停靠缘滑入+渐显（平移 (±(1-value), 0) 符号随停靠侧，value=0 时
  /// 整块在小窗右侧外被 surface 裁剪=不可见，与面板推屏滑出同机制）。
  /// 扩窗方向不走此动效（旧原点与新帧把手位置重合，直接满显）
  static const Duration postResizeFadeDuration = Duration(milliseconds: 480);

  /// 面板日记列表区域高度的估算基准（张数）：列表区域限高 ≈ N 张收起卡的
  /// 纵向高度，超出部分在区域内滚动查看全部记录。
  /// 读取方：panelListMaxHeight
  static const int maxVisibleDiaryCards = 10;

  /// 面板日记列表区域的最大高度（dp）= maxVisibleDiaryCards × (卡片高+间距)
  /// + 列表顶部 padding（top 8，与 _buildPanel 的 ListView padding 保持一致）。
  /// 卡片按收起态估算，展开卡变高属预期、区域高度不变。
  /// ⚠️ 不加底部 padding 48：ListView/SliverPadding 的 padding 只计入滚动
  /// 范围不裁剪视口——滚动到顶时视口内卡片可见区 = 限高 − top padding，
  /// 底部 padding 要到滚到底才出现。历史上把 +48 也算进限高，导致实际可见
  /// 卡片数恒比 maxVisibleDiaryCards 多 1 张（48 > 卡高 46，第 N+1 张完整
  /// 露出），真机实测 10 档见 11 张 / 6 档见 7 张。
  /// 不变量：恒等于 panelListMaxHeightFor(panelMaxCardsDefault)（测试钉住）。
  /// 读取方：OverlayHome._buildPanel（经 panelListMaxHeightFor(_panelMaxCards)）
  static const double panelListMaxHeight =
      maxVisibleDiaryCards * (cardHeight + cardSpacing) + 8;

  /// ── 面板高度（可见条数档位，设置页「面板高度」选择器，2026-10-06）──
  /// 用户需求：大屏手机单手拿时，面板顶部的新建/展开按钮在屏幕上方够不着。
  /// 减少可见条数 = 列表限高变矮 + 面板顶部下压等量偏移（每少 1 条下压一张
  /// 卡高）——面板是**顶部锚定**布局，只缩列表限高只会让底边上移、按钮原地
  /// 不动；配上顶部下压偏移才兑现「整列底边位置不变、顶部按钮组下移进
  /// 拇指区」。单位用条数（比高/中/低档位直观）。
  /// prefs int，6~10 连续刻度 clamp 语义（同 fontSizeStep，非白名单）。
  /// 读取方：overlay engine 的 _refreshOverlayConfig/_scheduleAutoHide +
  /// _buildPanel；生效时机同把手大小——下一次展开/收起状态转换，已展开的
  /// 面板不瞬移
  static const String panelMaxCardsPrefKey = 'overlay_panel_max_cards';

  /// 面板 header 顶部固定避让（dp）：全屏窗口（FLAG_LAYOUT_NO_LIMITS）延伸到
  /// 状态栏下，overlay 窗口拿不到系统 insets，用固定 padding 避让状态栏。
  /// 读取方：OverlayHome._buildHeader（header Padding top）、大爆炸层顶边
  ///（再叠 panelTopOffsetFor 对齐 header 上缘）——两处必须同源
  static const double panelHeaderTopPadding = 40.0;

  /// 条数档下限：6 条再低列表区太矮（2 屏手势都难滚出内容），且顶部按钮
  /// 已下压 4 张卡高（224dp），继续下压收益递减
  static const int panelMaxCardsMin = 6;

  /// 条数档上限 = 历史默认（10 条 = 改动前的固定行为）
  static const int panelMaxCardsMax = maxVisibleDiaryCards;
  static const int panelMaxCardsDefault = maxVisibleDiaryCards;

  /// 解析可见条数档位：缺失兜底默认档，越界脏值 clamp 到 [6,10]
  static int parsePanelMaxCards(int? raw) => raw == null
      ? panelMaxCardsDefault
      : raw.clamp(panelMaxCardsMin, panelMaxCardsMax);

  /// 列表区域限高（dp）按可见条数档位计算；默认档结果 == panelListMaxHeight。
  /// 只加顶部 padding 8（bottom padding 48 在滚动范围末尾，不占视口——见
  /// panelListMaxHeight 注释的差一条说明）
  static double panelListMaxHeightFor(int cards) =>
      cards * (cardHeight + cardSpacing) + 8;

  /// 面板顶部下压偏移（dp）=（默认条数 − 当前档）× 一张卡高。
  /// 设计不变量：panelTopOffsetFor(n) + panelListMaxHeightFor(n) 对任意档位
  /// 为定值——满列表时整列底边位置不随档位变化（测试钉住）
  static double panelTopOffsetFor(int cards) =>
      (panelMaxCardsDefault - cards) * (cardHeight + cardSpacing);

  /// ── 面板按钮条位置（顶部/底部，2026-10-27 用户要求单手操作）──
  ///
  /// 设置项「按钮位置」：false（缺省）= 顶部（历史行为），true = 底部。
  /// 底部模式把面板整体改为**贴停靠侧下角锚定**、按钮条移到列表下方——
  /// 光把按钮挪到列表底部不够：面板仍是顶部锚定时，条目少的面板按钮仍停在
  /// 屏幕上方；只有底部锚定才让按钮贴到拇指区。顶部模式的面板高度档位下压
  /// 偏移（[panelTopOffsetFor]）在底部模式不适用（面板已贴底，下压无意义）。
  /// prefs key（bool；写入方：设置页悬浮窗二级页；读取方：overlay engine 的
  /// _refreshOverlayConfig/_scheduleAutoHide——跨 engine 各自读，无内存共享）
  static const String panelButtonsBottomPrefKey =
      'overlay_panel_buttons_bottom';

  /// 按钮条在底部时的下边距（dp）：全屏窗口延伸到导航栏下（窗口拿不到
  /// insets），用固定值避让导航栏，与列表原本的底部 padding 48 同值
  static const double panelHeaderBottomPadding = 48.0;

  /// 面板整体在窗口内的锚点：顶部模式贴停靠侧上角（历史行为）；底部模式
  /// 贴停靠侧下角（按钮条随面板落进拇指区）
  static Alignment panelAlignment({
    required bool dockLeft,
    required bool buttonsBottom,
  }) {
    if (buttonsBottom) {
      return dockLeft ? Alignment.bottomLeft : Alignment.bottomRight;
    }
    return dockLeft ? Alignment.topLeft : Alignment.topRight;
  }

  /// 按钮条内边距：顶部模式避让状态栏（[panelHeaderTopPadding]，固定 40，
  /// overlay 窗口拿不到系统 insets）；底部模式改为避让导航栏
  ///（[panelHeaderBottomPadding]）。左右 8/16 随停靠侧镜像（历史值）
  static EdgeInsets panelHeaderPadding({
    required bool dockLeft,
    required bool buttonsBottom,
  }) => buttonsBottom
      ? EdgeInsets.fromLTRB(
          dockLeft ? 8 : 16,
          4,
          dockLeft ? 16 : 8,
          panelHeaderBottomPadding,
        )
      : EdgeInsets.fromLTRB(
          dockLeft ? 8 : 16,
          panelHeaderTopPadding,
          dockLeft ? 16 : 8,
          4,
        );

  /// 日记列表滚动区的底部内边距：顶部模式 48（导航栏避让，历史行为，
  /// 卡片能滚到面板底缘之上）；底部模式 8——列表下方是按钮条，导航栏由
  /// 按钮条自身避让，列表再留 48 只会和按钮条之间多出一大段空白
  static double panelListBottomPadding(bool buttonsBottom) =>
      buttonsBottom ? 8.0 : 48.0;

  /// 主 App 大爆炸分词层顶边的参照条数档（用户拍板：主 App 没有「面板高度」
  /// 设置项，层顶边固定按悬浮窗 8 条档位的顶部高度取值——比「仅状态栏避让」
  /// 矮一截，单手够得着顶栏）
  static const int bigBangMainAppRefCards = 8;

  /// 主 App 大爆炸分词层顶边高度（dp）= 状态栏固定避让 + 参照条数档下压
  /// 偏移，与悬浮窗「面板高度」8 条档位时的大爆炸层顶边同源同值（152dp）。
  /// 读取方：diary_tab._openBigBang（BigBangLayer.topInset）
  static double get bigBangMainAppTopInset =>
      panelHeaderTopPadding + panelTopOffsetFor(bigBangMainAppRefCards);

  /// 卡片固定默认色（无标注的活跃卡片）。标注后整卡换标注色（4 槽位外观
  /// 唯一真值在 utils/diary_tag.dart 的 DiaryTagStyles，设置页「标签外观」
  /// 可换图标/颜色，主 App 日记页小色点与网页端共用），已归档卡片不参与
  /// 取色，固定灰色 + 删除线。取色方：OverlayDiaryCard.build
  static const Color defaultCardColor = Color(0xFF6F9AF0);

  /// 面板内边距
  static const EdgeInsets panelPadding = EdgeInsets.symmetric(horizontal: 8);

  /// 正文字号（比 App 内卡片小 2 号）
  static const double bodyFontSize = 14.0;

  /// 正文行高
  static const double bodyLineHeight = 1.5;

  /// 清单字号（比 App 内小 2 号）
  static const double checklistFontSize = 13.0;

  /// 清单行高
  static const double checklistLineHeight = 1.4;

  /// ── 语音速记录音胶囊（长按音量上键 action=record 场景）──
  /// 状态机在 OverlayVoiceMemoController，UI 在 OverlayVoiceMemoBar

  /// 录音胶囊基础宽度（dp）：录音 0s 时的起始宽度。0s 就要装下「计时内容
  /// （红点 10 + 间距 8 + mm:ss）居中 + 贴屏端停止钮命中区 44」。
  /// ⚠️ 内容宽度按**测试字体 Ahem** 的最坏情况预算：每字形恰好 = 字号，
  /// "0:00" 4 字形 × 15px = 60 → 内容 78~79；内容区 = 基宽 - 44 ≥ 79 →
  /// 基宽取 124（内容区 80，留 1dp 余量）。真机 Roboto 下 mm:ss ≈ 31dp，
  /// 内容仅 ~49dp 居中，两侧各余 ~15dp，视觉无挤压。此后随录音秒数继续
  /// 增长（对齐锤子闪念胶囊"2s 和 5s 胶囊长度不同"的语义）。
  /// ⚠️ 窗口宽 312（= voiceMemoMaxWidth + voiceMemoEdgeMargin）不变，无原生改动
  static const double voiceMemoBaseWidth = 124.0;

  /// 录音胶囊每秒增长宽度（dp）
  static const double voiceMemoGrowthPerSec = 40.0;

  /// 录音胶囊最大宽度（dp）：约 5.5s 后封顶不再变长
  static const double voiceMemoMaxWidth = 300.0;

  /// 录音胶囊本体高度（dp）
  static const double voiceMemoCapsuleHeight = 44.0;

  /// 录音胶囊内停止按钮命中区宽度（dp）：贴屏端整列 44×44（高=胶囊高），
  /// 录音态全程钉在贴屏端——胶囊停靠缘锚定屏幕，按钮位置从 0s 起固定不随变长
  /// 移动；点击 = controller.stop() 进转写（与音量键/上限自动停同一路径）。
  /// 仅录音态展示，转写态胶囊无此钮。⚠️ 按钮最外侧与系统全面屏返回手势区
  /// （贴屏端 ~20dp 窄条）重叠：点按不受影响，起始于按钮上的边缘横滑会
  /// 被手势抢走，真机验证项
  static const double voiceMemoStopZoneWidth = 44.0;

  /// 停止按钮视觉圆底直径（dp）：白 18% 半透明圆底 + 白色 stop 方块图标，
  /// 居中于命中区（视觉 28 / 命中 44×44，对齐卡片播放钮"视觉小、命中大"的先例）
  static const double voiceMemoStopVisualSize = 28.0;

  /// 录音胶囊距屏幕停靠缘的边距（dp）
  static const double voiceMemoEdgeMargin = 12.0;

  /// 🔇 静音倒计时态的胶囊宽度下限（dp）：mm:ss 换成「N 秒后自动停」文字
  /// （≈90dp）后，短录音早期按公式算出的胶囊宽（base 124 − 停止区 44 = 80dp
  /// 内容区）放不下，倒计时中按本值兜底防文字截断
  static const double voiceMemoAutoStopMinWidth = 170.0;

  /// ── 「再次长按音量上键停止」提示胶囊（录音态，前 N 次速记展示）──
  ///
  /// 用户教育：录音可再次长按音量上键停止并转写，不点停止钮也行。位置在
  /// 录音胶囊正下方（窗口加高让出的下部条带，见 [voiceMemoWindowHeight]），
  /// 视觉同款深色半透明胶囊 + 白字——悬浮窗背景是任意壁纸/应用，浅色文字
  /// 裸放会撞白色背景消失，只有自带深色底才有对比度保障

  /// 提示展示次数上限（跨会话持久化计数 ≥ 本值后永不再展示）。只展示前 2 次：
  /// 教育目的是"知道有这回事"，常驻反而喧宾夺主
  static const int voiceMemoStopHintMaxShows = 2;

  /// 提示已展示次数的 prefs key（int，写入方/读取方均为 overlay engine 的
  /// OverlayVoiceMemoController.start；悬浮窗引擎写 prefs 落同一
  /// FlutterSharedPreferences 文件，跨会话持久）。自增时机 = 录音成功开录
  /// （哪怕本次秒停/空录音丢弃也计为"已展示"，避免反复打扰）
  static const String voiceMemoStopHintCountPrefKey =
      'overlay_voice_memo_hint_shown_count';

  /// 提示胶囊与录音胶囊的纵向间距（dp）
  static const double voiceMemoHintGap = 3.0;

  /// 录音态悬浮窗宽度（dp）：= voiceMemoMaxWidth(300) + voiceMemoEdgeMargin(12)。
  /// ⚠️ 语音速记冷启动隐藏窗口以此尺寸（312×64，高=voiceMemoWindowHeight）直建
  ///（Kotlin 侧硬编码副本 VOICE_MEMO_OVERLAY_WIDTH_DP / VOICE_MEMO_OVERLAY_HEIGHT_DP
  /// 在 VolumeKeyAccessibilityService.kt，改尺寸必须双侧同步）——直建胶囊尺寸 =
  /// 把手尺寸的窗口在此路径中不存在，无 resize 无把手帧，根治冷启动把手一闪而过
  static const int voiceMemoWindowWidth = 312;

  /// 录音态悬浮窗高度（dp）：胶囊在其中垂直居中。
  /// 原生 resizeOverlay 对非哨兵值高度使用 Gravity.CENTER_VERTICAL|END
  /// （见 Kotlin resizeOverlay），窗口天然贴停靠缘垂直居中，与把手同款停靠。
  /// ⚠️ 同上：语音速记冷启动隐藏窗口的直建高度，Kotlin 侧有硬编码副本须同步。
  /// 84 = 历史值 64 + 下部提示条带 20：录音态展示「再次长按音量上键停止」提示
  /// 胶囊（见 [voiceMemoHintGap] 与 _StopHintPill），展示时"胶囊 + 间距 + 提示
  /// 胶囊"整块（≈68）在 84 高窗口内垂直居中，胶囊仅比历史位置上移 ~8dp；
  /// 不展示时单一胶囊居中。上限守卫：必须 < handleHeight(88)——overlay_home
  /// build 的硬不变量（idle 帧在胶囊窗口里渲染空白）按 [isCapsuleHeightWindow]
  /// 判定，≥88 会与把手窗高度档重叠、idle 帧误渲染把手
  static const int voiceMemoWindowHeight = 84;

  /// 转写态胶囊固定宽度（dp）
  static const double voiceMemoTranscribingWidth = 140.0;

  /// 语音速记录音时长上限（秒）：到点自动停（防按忘）。原对齐锤子闪念胶囊 60s
  /// 设计，后放宽到 5 分钟。⚠️ Kotlin 侧 VOICE_MEMO_MAX_DURATION_MS 是硬编码
  /// 副本（驱动四级 watchdog），改值须双侧同步。
  /// 读取方：OverlayVoiceMemoController.start 的上限 Timer
  static const int voiceMemoMaxSeconds = 300;

  /// 语音速记识别 worker idle 自动释放时长（秒）。
  /// 写方（排定/取消）：OverlayVoiceMemoController._scheduleWorkerIdleRelease
  /// （转写收尾排定）与 start（新录音开始取消作废）；读方：同一处 Timer 的
  /// Duration。主 App 的识别 worker 会话期常驻；overlay 场景突发偶发，闲置
  /// 此时长后 dispose 释放第二份模型内存（~229MB，主 engine 的 worker 不受
  /// 影响——两 isolate 各持独立实例），再次录音时 start 的懒启动会重建
  static const int voiceMemoWorkerIdleSeconds = 120;

  /// 手动停止时转写成功震动要求的最低录音时长（秒，2026-09-17 用户拍板）。
  /// 手动停（点停止按钮/音量键）自带停止操作震，短录音转写快、成功震会与
  /// 它贴脸干扰；≥此秒数转写耗时通常已拉开间隔，才补成功震。自动停/上限停
  /// 无停止操作震，不受此界线约束恒震（判定逻辑
  /// OverlayVoiceMemoController.shouldHapticOnTranscribeSuccess）。
  static const int voiceMemoSuccessHapticMinSeconds = 30;

  /// ── 收起后自动隐藏 ──

  /// 收起后自动隐藏秒数默认值（未写入过 prefs 时的兜底）。
  /// 读取方：settings_tab 加载 / OverlayHome._scheduleAutoHide
  static const int autoHideDefaultSeconds = 10;

  /// 「永久」不自动隐藏的哨兵值：设置页选「永久」时把本值写进
  /// `overlay_auto_hide_seconds`（与秒数同 key 同 int 通道存储，不另立
  /// bool key）；_scheduleAutoHide 读到本值即不起 Timer。取 -1 而非 0，
  /// 避免 0 被误读成"立即隐藏"
  static const int autoHideNeverSeconds = -1;

  /// 息屏（ACTION_SCREEN_OFF）时悬浮窗的去向分流（唯一权威，OverlayHome
  /// ._onScreenAutoHide 消费；展开面板在分流前已无条件跳终态收回把手，
  /// 面板永不穿越息屏）：
  /// - 「永久」档（autoHideSeconds == [autoHideNeverSeconds]）→ keepHandle：
  ///   把手驻留穿越 AOD——息屏期间窗口由 Kotlin 置 GONE 保 AOD 干净，亮屏
  ///   VISIBLE 把手原样回来，不再推进竖线/移除（2026-09-28 用户拍板，推翻
  ///   09-22「永久档息屏不生效」旧语义；竖线开关在永久档下对息屏不生效）
  /// - 限时档 → 按「隐藏后保留贴边竖线」开关：开 = enterEdgeLine /
  ///   关 = closeOverlay（09-22「进 AOD 必须收」语义不变）
  static ScreenOffAction screenOffActionFor(
    int autoHideSeconds, {
    required bool edgeLineEnabled,
  }) {
    if (autoHideSeconds == autoHideNeverSeconds) {
      return ScreenOffAction.keepHandle;
    }
    return edgeLineEnabled
        ? ScreenOffAction.enterEdgeLine
        : ScreenOffAction.closeOverlay;
  }

  /// ── 自动隐藏后的贴边竖线（隐藏态驻留提示，"把手的瘦身版"）──
  ///
  /// 自动隐藏不再只有"彻底移除窗口"一个终点：设置开关（[edgeLineEnabledPrefKey]）
  /// 打开时，隐藏计时到期把窗口从把手（28×88）缩成一条贴停靠缘垂直居中的
  /// 半透明细线（4×64），点按/左滑随时重新展开。关闭时维持旧行为
  ///（closeOverlay 移除窗口，只能靠音量键重新召唤）。

  /// 竖线视觉宽度（dp）：用户定夺 ≈1mm（1mm @160dpi 基准 ≈ 3.78dp，取整 4）。
  /// 2026-09-14 起与窗口宽度分离——此前窗口宽即线宽（4dp），触摸区同样只有
  /// 4dp，手指起点很难按中，按偏后落在窗口外的边缘滑动被系统当作返回手势，
  /// 用户感知为"竖线很难触发、和侧滑返回冲突"（真机反馈）。现在线只管画，
  /// 窗口/触摸区交给 [edgeLineWindowWidth]
  static const double edgeLineWidth = 4.0;

  /// 竖线窗口宽度（dp）＝透明触摸缓冲区宽度：窗口加宽到 20dp（≈3mm），视觉
  /// 线仍 4dp 贴停靠缘绘制（Align 贴缘，见 _buildEdgeLine），其余区域透明但
  /// 可命中（GestureDetector 的 HitTestBehavior.opaque）。透明缓冲区不牺牲
  /// 下层触摸：贴边 ~24dp 本来就是系统返回手势区（systemGestureInsets），
  /// 手势导航下该条带的触摸到不了下层应用；三键导航挡住的也只是边缘一条
  /// 无可点控件的条带。推翻当年"窗口宽=线宽防挡下层"的决策（方案调研见
  /// 2026-09-14 评估：微信浮窗/悬浮球类产品均为"窄视觉+宽触摸"路数，
  /// 第三方无法用 systemGestureExclusionRects 抢边缘手势）
  static const double edgeLineWindowWidth = 20.0;

  /// 竖线高度（dp）：比把手（88）短一截，与语音胶囊本体高度（44）的两倍
  /// 同档，贴边细线的视觉重心与把手一致（垂直居中）
  static const double edgeLineHeight = 64.0;

  /// 档位 → 竖线视觉高度（dp）：跟随把手大小档位等比缩（用户定夺 2026-09-22：
  /// 把手变小竖线同步缩、只缩高不缩宽——把手视觉缩到 40 高后竖线 64 会反超
  /// 把手，视觉层级颠倒；宽 4dp ≈1mm 是可见性下限不缩，2026-09-14 渐变对比
  /// 度专项基于此宽度）。窗口仍 20×64（触摸缓冲区不变），视觉线在窗口内垂直
  /// 居中：100% → 64 / 75% → 48 / 50% → 32
  static double edgeLineVisualHeight(int percent) =>
      edgeLineHeight * percent / 100;

  /// 竖线渐变色（2026-09-14 起替代旧的单一半透明白 0x73FFFFFF）：屏内端深灰
  /// → 贴缘端浅灰的横向渐变（两端各 85% alpha），方向随停靠侧镜像（见
  /// _buildEdgeLine）。动机：旧半透明白在白色/浅色背景下数学上恒为白
  ///（白+白=白）不可见（真机反馈）；「自动随背景变色」做不到（悬浮窗拿不到
  /// 下层像素），故让线自带明暗两成分——白底看深端、黑底看浅端，任何背景
  /// 至少一端可见（地图/字幕同思路；WCAG 对比度 白底 6.1:1 / 纯黑 9.0:1，
  /// 方案评估与预览见 docs/previews/edge_line_contrast_preview.html，用户
  /// 拍板方案 D）。⚠️ 纯灰背景（≈#808080）两端对比都弱（≈2:1），属已知取舍
  static const Color edgeLineGradientDeep = Color(0xD9464646); // 屏内端
  static const Color edgeLineGradientLight = Color(0xD9C8C8C8); // 贴缘端

  /// 设置开关的 prefs key（写入方：settings_tab；读取方：
  /// OverlayHome._scheduleAutoHide——跨 engine 各自读，无内存共享）。
  /// 缺省视为开启（bool 通道，非 Pro 用户本就读不到悬浮窗配置，无迁移问题）
  static const String edgeLineEnabledPrefKey = 'overlay_edge_line_enabled';

  /// 线态「点按展开把手」开关的 prefs key（写入方：settings_tab；读取方：
  /// OverlayHome._onEdgeLineTap——跨 engine 各自读，无内存共享）。
  /// 缺省视为开启；关闭后点按竖线无反应，仅朝屏幕内侧滑动或音量键可展开
  static const String edgeLineTapEnabledPrefKey =
      'overlay_edge_line_tap_enabled';

  /// ── 竖线距屏幕边缘的内移间距档位（2026-09-29）──
  ///
  /// 用户反馈：贴带黑边的钢化膜后，完全贴边的竖线可能被膜边遮住看不见。
  /// 三档：0（贴边，缺省=历史行为）/ 4（内移）/ 8（最里，用户实测拍板——
  /// 首版 0/8/16 的 16 档内移过多，整体下调为 0/4/8）。**纯 Dart 视觉内移**：窗口 20×64 与透明触摸缓冲区不动
  ///（同把手大小「只缩视觉不缩窗口」思路），竖线在窗口内向屏内侧偏移——
  /// 窗口内可内移的硬上限 = [edgeLineWindowWidth] − [edgeLineWidth] = 16，
  /// 当前档位最大只用 8。⚠️ 不要靠加宽窗口换更大间距：窗口宽 >24 会撞
  /// Kotlin `EDGE_LINE_WIDTH_THRESHOLD_DP`=24 的线态判定（音量键 toggle
  /// 分流），且边缘触摸带加宽会多挡下层

  /// 间距档位的 prefs key（写入方：悬浮窗设置二级页 overlay_settings_page；
  /// 读取方：OverlayHome._refreshOverlayConfig/_scheduleAutoHide——跨 engine
  /// 各自 reload 读，下一次状态转换生效，已驻留的竖线不瞬移）
  static const String edgeLineMarginPrefKey = 'overlay_edge_line_margin_dp';

  /// 缺省档位：贴边（历史行为）
  static const int edgeLineMarginDefault = 0;

  /// 合法档位集合（dp，设置页 ChoiceChip 与解析兜底共用）
  static const List<int> edgeLineMarginChoices = [0, 4, 8];

  /// 解析 prefs 间距档位：非合法档（null/旧版本值/坏值）一律兜底贴边
  static int parseEdgeLineMargin(int? raw) =>
      raw != null && edgeLineMarginChoices.contains(raw)
      ? raw
      : edgeLineMarginDefault;

  /// 档位 + 停靠侧 → 竖线的靠边侧内边距（停靠右缘内移 = right padding，
  /// 左缘镜像）。供 OverlayHome._buildEdgeLine 与单测共用唯一真值
  static EdgeInsets edgeLinePadding({
    required bool sideLeft,
    required int marginDp,
  }) => sideLeft
      ? EdgeInsets.only(left: marginDp.toDouble())
      : EdgeInsets.only(right: marginDp.toDouble());

  /// ── 悬浮窗停靠侧（左/右切换）──
  ///
  /// 设置页「停靠侧」选择器的 prefs key（bool 通道）：false（缺省）= 停靠
  /// 屏幕右缘（历史行为），true = 停靠左缘。三端共读同一 key：
  /// - 写方：settings_tab（同走悬浮窗 Pro 门禁）
  /// - overlay engine（Dart）：OverlayHome._refreshSide（reload 后读）——
  ///   驱动把手/竖线/面板/胶囊的全部镜像（对齐、滑入方向、滑动手势方向、
  ///   卡片划走方向），见各 dockLeft 参数
  /// - 原生（Kotlin）：VolumeKeyAccessibilityService 读
  ///   `flutter.overlay_side_left`（同文件 FlutterSharedPreferences，
  ///   `flutter.` 前缀为 Flutter SharedPreferences 落盘约定）决定窗口
  ///   Gravity START/END——每次建窗/resize 实时读
  /// 生效时机：原生建窗/resize 与 Dart 状态切换时各自生效，故切换设置后
  /// 下一次展开/收起整体换到新侧；已显示中的收起把手不瞬移（跨 engine
  /// 无推送通道，不做轮询）
  static const String overlaySideLeftPrefKey = 'overlay_side_left';

  /// ── 滑动直接删除（替代滑动归档）──
  ///
  /// 设置开关「滑动直接删除笔记」的 prefs key（写入方：悬浮窗设置二级页
  /// overlay_settings_page；读取方：OverlayHome._onCardSwipeDismissed——
  /// 动作型开关，划走回调里现场 reload 读，即时生效，同
  /// edgeLineTapEnabledPrefKey 的 _onEdgeLineTap 模式）。
  /// 缺省 false = 划走归档（历史行为）；true = 活跃卡划走直接删除，
  /// 面板顶部弹撤销胶囊（[swipeDeleteUndoWindow] 内可撤销，真删后重插），
  /// 归档入口由卡片顶端勾选框保留。已归档卡划走=删除的行为不受本开关影响
  static const String swipeDeletePrefKey = 'overlay_swipe_delete_enabled';

  /// 滑动删除的撤销窗口时长：到期后删除落定（录音文件此刻才从磁盘补删；
  /// 窗口内撤销靠把库行原样插回，音频不删才能连录音一起还原）
  static const Duration swipeDeleteUndoWindow = Duration(seconds: 3);

  /// 截图附件完成后是否自动唤出悬浮窗并展开当前卡（设置页「截图附件」开关）。
  /// 写入方：overlay_settings_page；读取方：OverlayHome._onCardCopyLongPress
  /// ——动作型开关，截图成功收尾现场 reload 读，即时生效。缺省 false =
  /// 历史行为（只 Toast 提示、保持收起）；true = 提示后展开面板并展开该卡，
  /// 方便核对截图效果或继续编辑
  static const String screenshotExpandCardPrefKey =
      'overlay_screenshot_expand_card';
}
