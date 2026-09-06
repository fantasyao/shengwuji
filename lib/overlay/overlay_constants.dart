import 'package:flutter/material.dart';

/// 悬浮窗（闪念胶囊）通用常量
class OverlayConstants {
  OverlayConstants._();

  /// 收起态把手宽度（dp）
  static const int handleWidth = 28;

  /// 收起态把手高度（dp）
  static const int handleHeight = 88;

  /// 收起态把手文字（中文逐字竖排）
  static const String handleLabel = '记一笔';

  /// 把手小图标尺寸（dp）
  static const double handleIconSize = 16.0;

  /// 把手字号（竖排小字）
  static const double handleFontSize = 11.0;

  /// 把手/空白区/面板边缘滑动手势的位移阈值（dp）。
  /// 引用方：OverlayHome 的 _buildHandle（左滑展开）/ _buildBlankArea
  ///（任意方向滑收起）/ _buildPanel 面板手势（右滑收起）
  static const double edgeSwipeThreshold = 4;

  /// 展开态面板占屏幕宽度比例（面板宽度的唯一真值来源）
  ///
  /// 展开时窗口由原生侧铺满全屏（resizeOverlay 对哨兵值 -1 的宽度解释为
  /// MATCH_PARENT，Kotlin 侧不再持有比例），Dart 侧在 OverlayHome._buildPanel
  /// 里用本比例把右侧面板画成「窗口宽 × 0.72」，左侧 28% 透明空白区承接
  /// 点击/左滑关闭手势。改面板宽度只动这里。
  /// 有卡展开时改用 expandedPanelWidthRatio（0.92），见该常量
  static const double expandedWidthRatio = 0.72;

  /// 有卡展开时的面板宽度比例：展开卡片需要比收起胶囊明显更宽（对齐闪念原型，
  /// 展开卡约占屏宽 88-90%）。窗口本是 MATCH_PARENT 全屏，面板加宽无需原生
  /// resize；收起卡内容自适应+右对齐（Align centerRight），面板变宽不改变其
  /// 渲染宽度/位置（右缘不动），视觉零影响。读取方：OverlayHome._buildPanel
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
  /// (0,0,全屏) 移到 (右缘,垂直居中,28×88)，移动期 Dart 感知不到完成时刻——
  /// 配合 curve Interval(0.625, 1.0)（见 _postResizeFadeCurve 构造处）：
  /// 前 60%（300ms）value 恒 0，把手完全透明，等窗口 frame 移动完成；
  /// 后 40%（180ms）把手从屏幕右缘滑入+渐显（平移 (1-value, 0)，value=0 时
  /// 整块在小窗右侧外被 surface 裁剪=不可见，与面板推屏滑出同机制）。
  /// 扩窗方向不走此动效（旧原点与新帧把手位置重合，直接满显）
  static const Duration postResizeFadeDuration = Duration(milliseconds: 480);

  /// 面板日记列表区域高度的估算基准（张数）：列表区域限高 ≈ N 张收起卡的
  /// 纵向高度，超出部分在区域内滚动查看全部记录。
  /// 读取方：panelListMaxHeight
  static const int maxVisibleDiaryCards = 10;

  /// 面板日记列表区域的最大高度（dp）= maxVisibleDiaryCards × (卡片高+间距)
  /// + 列表上下 padding（top 8 / bottom 48，与 _buildPanel 的 ListView padding
  /// 保持一致）。卡片按收起态估算，展开卡变高属预期、区域高度不变。
  /// 读取方：OverlayHome._buildPanel
  static const double panelListMaxHeight =
      maxVisibleDiaryCards * (cardHeight + cardSpacing) + 8 + 48;

  /// 卡片固定默认色（无标注的活跃卡片）。标注（紧急/收藏/灵感）后整卡换
  /// 标注色（色映射唯一真值在 utils/diary_tag.dart 的 DiaryTag.colors，
  /// 主 App 日记页小色点共用），已归档卡片不参与取色，固定灰色 + 删除线。
  /// 取色方：OverlayDiaryCard.build
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

  /// 录音胶囊基础宽度（dp）：录音 0s 时的起始宽度（对齐锤子闪念胶囊
  /// "2s 和 5s 胶囊长度不同"的语义——胶囊随录音时长变长）
  static const double voiceMemoBaseWidth = 80.0;

  /// 录音胶囊每秒增长宽度（dp）
  static const double voiceMemoGrowthPerSec = 40.0;

  /// 录音胶囊最大宽度（dp）：约 5.5s 后封顶不再变长
  static const double voiceMemoMaxWidth = 300.0;

  /// 录音胶囊本体高度（dp）
  static const double voiceMemoCapsuleHeight = 44.0;

  /// 录音胶囊距屏幕右缘的边距（dp）
  static const double voiceMemoEdgeMargin = 12.0;

  /// 录音态悬浮窗宽度（dp）：= voiceMemoMaxWidth(300) + voiceMemoEdgeMargin(12)。
  /// ⚠️ 语音速记冷启动隐藏窗口以此尺寸（312×64，高=voiceMemoWindowHeight）直建
  ///（Kotlin 侧硬编码副本 VOICE_MEMO_OVERLAY_WIDTH_DP / VOICE_MEMO_OVERLAY_HEIGHT_DP
  /// 在 VolumeKeyAccessibilityService.kt，改尺寸必须双侧同步）——直建胶囊尺寸 =
  /// 把手尺寸的窗口在此路径中不存在，无 resize 无把手帧，根治冷启动把手一闪而过
  static const int voiceMemoWindowWidth = 312;

  /// 录音态悬浮窗高度（dp）：胶囊在其中垂直居中。
  /// 原生 resizeOverlay 对非哨兵值高度使用 Gravity.CENTER_VERTICAL|END
  /// （见 Kotlin resizeOverlay），窗口天然贴右缘垂直居中，与把手同款停靠。
  /// ⚠️ 同上：语音速记冷启动隐藏窗口的直建高度，Kotlin 侧有硬编码副本须同步
  static const int voiceMemoWindowHeight = 64;

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

  /// ── 收起后自动隐藏 ──

  /// 收起后自动隐藏秒数默认值（未写入过 prefs 时的兜底）。
  /// 读取方：settings_tab 加载 / OverlayHome._scheduleAutoHide
  static const int autoHideDefaultSeconds = 10;

  /// 「永久」不自动隐藏的哨兵值：设置页选「永久」时把本值写进
  /// `overlay_auto_hide_seconds`（与秒数同 key 同 int 通道存储，不另立
  /// bool key）；_scheduleAutoHide 读到本值即不起 Timer。取 -1 而非 0，
  /// 避免 0 被误读成"立即隐藏"
  static const int autoHideNeverSeconds = -1;
}
