import 'package:flutter/material.dart';

/// 悬浮窗（闪念胶囊）通用常量
class OverlayConstants {
  OverlayConstants._();

  /// 收起态把手宽度（dp）。⚠️ 原生侧硬编码副本 HANDLE_WIDTH_DP（拖动守卫按
  /// 「窗口宽 == 把手宽」判定）与 showOverlay 初始建窗 (28, 88) 双处同步
  static const int handleWidth = 28;

  /// 收起态把手高度（dp）。语音胶囊窗口高（voiceMemoWindowHeight 84）必须
  /// 小于本值——overlay_home build 的硬不变量按「窗口高 < 把手高」判定
  /// idle 帧渲染空白
  static const int handleHeight = 88;

  /// 把手胶囊相对窗口的视觉内缩（dp）：用户要求把手缩小一号，但窗口尺寸是
  /// 原生硬编码副本 + 语音胶囊 84<88 不变量的联动值，动窗口须双侧同步——
  /// 因此窗口保持 28×88（触控面积不变），胶囊本体向内收缩，视觉变小
  static const double handleInsetHorizontal = 2.0;
  static const double handleInsetVertical = 4.0;

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
  /// build 的硬不变量（idle 帧在胶囊窗口里渲染空白）按"窗口高 < 把手高"判定，
  /// ≥88 会让 idle 帧误渲染把手
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
}
