// ⚠️ intl 导出自家 TextDirection（LTR/RTL/UNKNOWN 常量类），会遮蔽 Flutter 的
// TextDirection 枚举（TextPainter 换算点击字符偏移用的 TextDirection.ltr 会
// 解析成 intl 版直接编译错误）——必须 hide 掉
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:intl/intl.dart' hide TextDirection;
import '../../utils/diary_tag.dart';
import '../overlay_constants.dart';

/// 展开态正文行首内联勾选框的占位尺寸（WidgetSpan 子树包围盒）：
/// 宽 = 命中区边长（_buildCheckbox hitSize）+ 右间距；高 = 命中区边长。
/// _buildViewingBody 渲染和 _charOffsetAt 点击换算共用同一组值——换算
/// TextPainter 必须以同尺寸 WidgetSpan 占位布局，首行缩进才与真实渲染一致
const double _kExpandedCheckboxHitSize = 28;
const double _kExpandedCheckboxRightGap = 8;

/// 收起态文字宽度测量缓存（性能审查 Top7）：key = 文本+textScaler+fontFamily，
/// 值 = TextPainter 单行 intrinsic 宽。同一张卡在面板宽度补间/归档删除等任意
/// setState 重测期间输入不变——直接命中缓存跳过全文 shaping，而逐帧 clamp
/// （cardMinWidth~maxWidth）照做，补间逐帧像素与不缓存时完全一致。
/// 上限 512 条：超出整体清空（悬浮窗会话内卡片数有限，正常到不了；只防
/// 极端长会话下反复编辑产生无界增长）。
final Map<String, double> _kCollapsedTextWidthCache = <String, double>{};

/// 实际执行 TextPainter.layout 的次数（测试探针：验证缓存命中）
int _collapsedTextWidthMeasureCount = 0;

/// 收起态文字单行 intrinsic 宽测量（带缓存）。度量环境必须与实际渲染
/// 严格一致——textScaler / fontFamily 由调用方从 MediaQuery/DefaultTextStyle
/// 取实际值传入（046fe0b 起估算值兼任收起态稳态宽度上限，估算偏窄会把
/// 短文字顶出省略号），因此二者必须参与缓存 key。
double _measureCollapsedTextWidth(
  String text,
  TextScaler textScaler,
  String? fontFamily,
) {
  final String key = '$text\u0000$textScaler\u0000${fontFamily ?? ''}';
  final double? cached = _kCollapsedTextWidthCache[key];
  if (cached != null) return cached;
  double textWidth = 0.0;
  try {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: OverlayConstants.cardCollapsedFontSize,
          fontFamily: fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    );
    painter.layout();
    textWidth = painter.width;
    painter.dispose();
  } catch (_) {
    textWidth = 0.0; // 度量异常兜底：窗口目标退化由 clamp 下限接管，仍被淡出掩盖
  }
  if (_kCollapsedTextWidthCache.length > 512) _kCollapsedTextWidthCache.clear();
  _kCollapsedTextWidthCache[key] = textWidth;
  _collapsedTextWidthMeasureCount++;
  return textWidth;
}

/// 悬浮窗内使用的彩色胶囊日记卡片
///
/// - 横向长纵向短的彩色胶囊：固定高度 [OverlayConstants.cardHeight]，全圆角
/// - 宽度随内容自适应：短内容短胶囊（下限 [OverlayConstants.cardMinWidth]），
///   超长在 [maxWidth]（面板宽 - 左右 margin）处截断省略号
/// - 取色（固定默认色 + 标注换色）：已归档固定灰色半透明 + 白字删除线；
///   活跃卡按 diary['tag'] 命中 [DiaryTag.colors] 取标注色（紧急/收藏/
///   灵感），未标注用 [OverlayConstants.defaultCardColor]
/// - 展开态（[expanded] 为 true）：多行全文 + 撑满 maxWidth + 固定小圆角
///   [OverlayConstants.cardExpandedRadius]，收起态回单行省略全圆角胶囊
///   （圆角/maxWidth/padding 由 AnimatedContainer 补间；纵向收放由
///   transitionBuilder 内的收卷 heightFactor 补间——外层 AnimatedSize
///   已移除，原因见 build 内 AnimatedContainer 上方注释）
/// - 复选框（[onCheckChanged] 非空时渲染在卡片最前）：toggle 语义——
///   勾上=归档划线、取消勾=恢复，点击不冒泡触发展开（内层手势竞技场胜出）
/// - 播放按钮（语音笔记末尾渲染）：diary['audio_path'] 非空且未归档才显示，
///   白底圆 + 深色图标（复选框勾选态同款语言），点击播放/暂停（语义在父层
///   OverlayHome._toggleAudioPlay），不冒泡触发展开
/// - 展开态多行布局（对齐闪念原型，见 _buildExpandedContent）：
///   时间行（含右上角收起 chevron）→ 正文（勾选框 WidgetSpan 内联首行，
///   后续行顶格）→ 重放录音独立行 → 底部按钮条（删除/闹钟/复制/AI 对话/
///   标注入口，删除二次确认态整行替换为「确认删除？✓ ✗」，标注选择态整行
///   替换为「❗ ⭐ 💡 ✗」）。展开态面板整体加宽到
///   OverlayConstants.expandedPanelWidthRatio（0.92，由父层 OverlayHome 切换）
class OverlayDiaryCard extends StatelessWidget {
  final Map<String, dynamic> diary;

  /// 胶囊宽度上限（dp）= 面板宽 - 左右 margin，超出内容单行省略号截断
  final double maxWidth;

  /// 展开态（显示多行全文）。真值在父层 OverlayHome._expandedIds 按 diary id 管理
  final bool expanded;

  /// 复选框点击回调，参数 = 目标归档态（true=归档 / false=恢复）；
  /// null 不渲染复选框
  final ValueChanged<bool>? onCheckChanged;

  /// 本卡是否正在播放录音（真值在父层 OverlayHome._playingDiaryId/_isPlaying，
  /// 用于切换 play/pause 图标）
  final bool isPlayingAudio;

  /// 播放按钮点击回调（播放/暂停/切卡语义由父层 OverlayHome._toggleAudioPlay
  /// 处理）；卡片内部按 diary['audio_path'] 非空且未归档决定是否渲染
  final VoidCallback? onPlayToggle;

  /// 删除确认态（真值在父层 OverlayHome._deleteConfirmIds 按 diary id 管理）：
  /// true 时底部按钮条整体替换为「确认删除？✓ ✗」
  final bool isDeleteConfirming;

  /// 底部按钮条回调：删除（含二次确认流转）/ 复制 / AI 对话 / 右上角收起
  /// chevron。null 不渲染对应按钮（onCollapse 为 null 时收起 chevron 也不
  /// 渲染；AI 对话按钮另有空 content/已归档不渲染守卫，见 _buildActionRow）
  final VoidCallback? onDelete;
  final VoidCallback? onCopy;

  /// 闹钟按钮（Icons.alarm）：解析卡片时间预填转轮弹确认 sheet，写系统日历
  /// （语义在父层 OverlayHome._onCardAlarm；识别不到时间则预填默认时刻）。
  /// 2026-09-06 前为恒禁用占位（null 回调），现已实现
  final VoidCallback? onAlarm;

  /// AI 对话按钮（对齐主 App 日记页同款按钮）：点击后复制到剪贴板并跳转
  /// 设置页选择的 AI 应用（语义在父层 OverlayHome._onCardShareToAI）
  final VoidCallback? onAiChat;
  final VoidCallback? onCollapse;

  /// 删除确认态 ✗ 取消回调（退出确认态，底行还原）
  final VoidCallback? onDeleteCancel;

  /// 正文编辑态（真值在父层 OverlayHome._editingDiaryId 按 diary id 管理）：
  /// true 时正文换多行 TextField、底部按钮条整行替换为「✗取消 / ✓保存」
  ///（优先级高于删除确认态），勾选框/播放按钮降级为禁用态（半透明+屏蔽手势）
  final bool editing;

  /// 编辑态 TextField 的控制器/焦点节点（父层 OverlayHome 持有：
  /// controller 以 content + 点击偏移光标创建，focusNode 负责弹/收软键盘）；
  /// editing=false 时为 null
  final TextEditingController? editController;
  final FocusNode? editFocusNode;

  /// 查看态正文点击回调，参数 = 点击位置换算出的字符偏移（TextPainter
  /// 近似换算，越界/异常兜底落文末）；null 时正文不可点击进入编辑
  ///（content 为空的转写占位行等场景）
  final ValueChanged<int>? onTextTap;

  /// 编辑态底部按钮条回调：✓保存 / ✗取消
  final VoidCallback? onEditSave;
  final VoidCallback? onEditCancel;

  /// 标注选择态（真值在父层 OverlayHome._tagPickingIds 按 diary id 管理）：
  /// true 时底部按钮条整行替换为「❗ ⭐ 💡 ✗返回」（优先级低于编辑态与
  /// 删除确认态——这两种态下标注入口不可见，结构互斥）
  final bool isTagPicking;

  /// 底部按钮条标注入口按钮（Icons.label_outline）点击回调：父层据此把
  /// 本卡 id 加入标注选择态；null 不渲染该按钮
  final VoidCallback? onTagEntry;

  /// 标注行 tag 按钮点击回调，参数 = 目标 tag（'urgent'/'star'/'idea'）；
  /// 点击当前已选中的 tag = 取消标注，传 null（toggle 回默认色）。
  /// 写库与退出选择态由父层 OverlayHome._setDiaryTag 处理
  final ValueChanged<String?>? onTagToggle;

  /// 标注行 ✗ 返回回调（退出标注选择态，底行还原为查看态按钮条）
  final VoidCallback? onTagPickCancel;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const OverlayDiaryCard({
    super.key,
    required this.diary,
    required this.maxWidth,
    this.expanded = false,
    this.onCheckChanged,
    this.isPlayingAudio = false,
    this.onPlayToggle,
    this.isDeleteConfirming = false,
    this.onDelete,
    this.onCopy,
    this.onAlarm,
    this.onAiChat,
    this.onCollapse,
    this.onDeleteCancel,
    this.editing = false,
    this.editController,
    this.editFocusNode,
    this.onTextTap,
    this.onEditSave,
    this.onEditCancel,
    this.isTagPicking = false,
    this.onTagEntry,
    this.onTagToggle,
    this.onTagPickCancel,
    this.onTap,
    this.onLongPress,
  });

  /// 测试探针：收起态文字宽度实际执行 TextPainter.layout 的次数（Top7 缓存验证）
  @visibleForTesting
  static int get collapsedTextMeasureCount => _collapsedTextWidthMeasureCount;

  /// 测试入口：直接调用带缓存的收起态文字测量
  @visibleForTesting
  static double measureCollapsedTextWidthForTest(
    String text,
    TextScaler textScaler,
    String? fontFamily,
  ) =>
      _measureCollapsedTextWidth(text, textScaler, fontFamily);

  @override
  Widget build(BuildContext context) {
    final content = (diary['content'] as String?) ?? '';
    final isArchived = (diary['is_archived'] as int?) == 1;
    final audioPath = (diary['audio_path'] as String?) ?? '';
    // 播放按钮渲染条件（对齐主 App 播放条惯例 audio_path!=null && !isArchived）：
    // 有回调 + 有录音 + 未归档。归档卡不显示播放控件（恢复后可正常播）。
    // 不做 existsSync 预检——避免每次 build 同步 IO，play 失败由父层 catch 归零
    final bool showPlayButton =
        onPlayToggle != null && audioPath.isNotEmpty && !isArchived;

    // 收起态单行展示文本：多行内容（文本笔记/手动编辑可能含换行）压成单行——
    // maxLines:1 下换行点会顶出省略号（"前4字\n后2字"只显示"前4字+…"）。
    // 宽度估算必须用同一字符串（见 _estimateCollapsedWidth）
    final collapsedText = content.replaceAll('\n', ' ');
    // 文字度量环境必须与实际渲染严格一致（046fe0b 起估算值兼任收起态
    // maxWidth 补间终点 = 稳态宽度上限，估算偏窄会把短文字顶出省略号）：
    // textScaler 取 MediaQuery 实际值——overlay 引擎跟随系统字体缩放（如
    // 系统字体大号 ≈1.1+），并非恒 1.0；fontFamily 取 DefaultTextStyle
    //（主题字体），裸 TextPainter 的默认字体度量与主题字体渲染存在微差
    final textScaler = MediaQuery.textScalerOf(context);
    final textFontFamily = DefaultTextStyle.of(context).style.fontFamily;
    // 归档固定灰色半透明（允许标注入库，但视觉仍固定灰，恢复后才显示标注色）；
    // 活跃卡：diary['tag'] 命中标注映射取标注色，否则固定默认色
    final Color bgColor = isArchived
        ? Colors.blueGrey.shade300.withValues(alpha: 0.5)
        : (DiaryTag.colorOf(diary['tag'] as String?) ??
              OverlayConstants.defaultCardColor);

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Align(
        // 胶囊贴屏幕边缘对齐：悬浮窗当前停靠右侧 → 右对齐贴面板右缘（=屏幕右缘-margin），
        // 长度随内容伸缩（短内容不再撑满全宽）。
        // 未来支持左右侧切换时：停靠左侧改为 centerLeft，并同步镜像 Kotlin 窗口 gravity、
        // 面板 Stack 的 Alignment.topRight、本对齐，共三处
        alignment: Alignment.centerRight,
        // ⚠️ 本层禁止再包 LayoutBuilder：收起最后一张展开卡时，父层面板宽
        // AnimatedContainer 补间（0.92W→0.72W，见 overlay_home._buildPanel）
        // 会让 ListView 给每个卡片 item 的约束逐帧变，LayoutBuilder 把约束
        // 变化放大成 builder 每帧重跑 = 整卡子树每帧 rebuild 的 build 风暴
        // = 收起动画掉帧（71bc632）。约束变化应停留在廉价的 render relayout
        //
        // ── 运动学结构（横向/纵向各有独立真补间源，同拍 200ms linear）──
        // 横向补间源 = 本 AnimatedContainer 的 constraints.maxWidth 布局渐变
        //（展开面板内容宽 ↔ 收起实际胶囊宽）+ padding.vertical（10↔0），
        // 色块宽度逐帧真收缩 = 横向匀速可见（945be75 锚点行为，046fe0b 恢复）。
        // 纵向补间源 = transitionBuilder 内展开 child 的
        // Align(heightFactor: lerp(46/estH, 1, progress))（见该处注释）——
        // Stack 高度 = max(收起 child 高, 旧内容贡献高) 随 progress 线性
        // 变化，色块高度逐帧真收缩，下方卡片逐帧贴上（ListView 每帧
        // relayout 天然跟随）。
        // ⚠️ 勿在本层重新引入 AnimatedSize 外层补间：旧注释（945be75 起）
        // 描述的"每帧重置追赶式前快后慢"是对 RenderAnimatedSize 的误诊——
        // child 尺寸第二次变化即 _sizeTween.begin=end=child.size 吸附透传
        //（SDK animated_size.dart _layoutChanged/_layoutUnstable），补间
        // 失效；本结构下 child 尺寸全程逐帧变，外层 AnimatedSize 只会在开场
        // 第 2 帧制造单帧跳变顿挫。稳态一次性高度变化（编辑加行/删除确认
        // 与标注行替换等）的平滑由展开内容根部的局部 AnimatedSize 接管
        //（见 _buildExpandedContent）
        child: AnimatedContainer(
          duration: OverlayConstants.animationDuration,
          margin: const EdgeInsets.only(
            left: 14,
            right: 14,
            bottom: OverlayConstants.cardSpacing,
          ),
          // 布局属性补间（运动学见上方注释）
          constraints: BoxConstraints(
            // 最小宽度：短内容（如单字）不至于胶囊过小
            minWidth: OverlayConstants.cardMinWidth,
            // 最大宽度补间：展开态撑满 prop 上限（面板内容宽，超出省略号）；
            // 收起态直达本卡实际胶囊宽（_estimateCollapsedWidth 已 clamp 到
            // cardMinWidth~maxWidth，兼任收卷窗口 targetWidth 的双重身份，见
            // 该函数注释）——消除"补到 maxWidth 上限后旧内容移除、再跳一次
            // 到内容宽"的尾部咯噔跳变，短文本卡一路匀速收到底
            maxWidth: expanded
                ? maxWidth
                : _estimateCollapsedWidth(
                    collapsedText,
                    showPlayButton,
                    textScaler,
                    textFontFamily,
                  ),
            // 收起态最小高度（原固定高 46）；展开态由多行文本撑高
            minHeight: OverlayConstants.cardHeight,
          ),
          padding: EdgeInsets.symmetric(
            horizontal: OverlayConstants.cardHPadding,
            // 展开态多行文本上下留白（10↔0 补间——纵向运动学的组成：
            // 胶囊高 = Stack 高 + 2×pad，两者同拍线性）
            vertical: expanded ? 10 : 0,
          ),
          // 不能用 Container.alignment：内部 Align 在有限宽度约束下会撑满
          // （Align 族仅 widthFactor!=null 或无界约束才收缩），
          // 曾导致胶囊宽度永远是 maxWidth
          decoration: BoxDecoration(
            color: bgColor,
            // 全圆角胶囊：半径 = 高度一半；展开态多行卡片改固定小圆角
            borderRadius: BorderRadius.circular(
              expanded
                  ? OverlayConstants.cardExpandedRadius
                  : OverlayConstants.cardHeight / 2,
            ),
            // 细白描边（对齐闪念原型，两态/归档灰卡通用）。Border.all 计入
            // Container 有效内边距——估算/排版补偿见 cardBorderWidth 常量注释
            border: Border.all(
              color: Colors.white,
              width: OverlayConstants.cardBorderWidth,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          // 展开态多行卡片布局（时间行/内联勾选正文/重放行/底部按钮条，
          // 对齐闪念原型）；收起态保持单行胶囊 Row 不动
          // 展开态多行排版与收起态单行胶囊互为不兼容排版（字号 12↔13、单行
          // 省略↔多行内联勾选框、可用宽度跳变），无法逐帧补间，按 Material
          // fade-through 模式整块切换：旧内容前半程淡出、新内容后半程淡入；
          // 外框尺寸/圆角/padding 照常由本 AnimatedContainer 补间 +
          // transitionBuilder 收卷 heightFactor 纵向补间，卡片本体全程
          // 可见不闪烁
          child: AnimatedSwitcher(
            duration: OverlayConstants.animationDuration,
            // 过渡期两 child 叠放顶右锚（右缘对齐 + 顶部对齐；卡片外层
            // Align centerRight，右锚一致，右缘全程固定只有左缘在动）。
            // topRight 的顶锚服务收起动画旧内容顶缘连续（收起时卡片向上
            // 收的是底部，内容区顶部不动）。⚠️ 收起静止态的 currentChild
            //（单行 Row ~24dp）比 Stack（容器 minHeight 撑到 cardHeight）
            // 矮，topRight 会让它贴顶——故收起分支自己包 ConstrainedBox
            //（minHeight: cardHeight）撑满高度居中（ae69cff 贴顶回归
            // 修复）；展开态 currentChild 填满 Stack，不受影响。
            // Stack 默认 clipBehavior: hardEdge = 纵向裁剪兜底（旧内容
            // 绘制区被裁在 Stack 边界内，与 transitionBuilder 的收卷窗口
            // 构成"文字画不出胶囊"的双层保险）。
            // previousChildren 显式包 IgnorePointer：AnimatedSwitcher 不会
            // 自动屏蔽淡出中旧 child 的手势，旧勾选框/播放钮在淡出的
            // ~100ms 内仍可命中会误触。
            // ⚠️ 旧 child 的高度贡献不再在本层压 0（a36800b 引入、
            // 9432813~046fe0b 沿用的 Align(heightFactor:0) 纵向一拍化已
            // 随纵向真补间重构移除——那是"90% 高度变化一帧完成"的纵向
            // 跳变根因）；纵向补间源在 transitionBuilder 的
            // Align(heightFactor)，本层只负责叠放锚定 + 手势屏蔽。
            // 旧 child 的宽度贡献保持：previousChildren 是 transitionBuilder
            // 包装后的子树，内部 Align(heightFactor) 的 widthFactor 缺省
            // null → 撑满补间中的约束宽 → Stack/色块宽度跟随 maxWidth
            // 补间逐帧真收缩（横向收缩可见的结构来源，945be75 行为）
            layoutBuilder: (currentChild, previousChildren) => Stack(
              alignment: Alignment.topRight,
              children: [
                for (final child in previousChildren)
                  IgnorePointer(child: child),
                // null-aware 元素：currentChild 为 null（AnimatedSwitcher 无
                // child）时不进列表，等价于 if (currentChild != null)
                ?currentChild,
              ],
            ),
            // fade-through 时序（curve/reverseCurve 双 Interval）：入场 child
            // 前半程透明（外框在长大），后半程淡入，与外框补间（均
            // animationDuration）同帧完成；出场 child 前半程淡完。
            // 按 child key 分支：
            // - card-expanded（展开态内容）：FadeTransition 之内再包
            //   「裁剪收卷」窗口（ClipRect + _CollapseWindowClipper）+
            //   Align(heightFactor 补间) + OverflowBox 冻结排版——
            //   出场（收起方向）旧内容排版冻结不动，被右缘固定、与
            //   AnimatedContainer maxWidth/padding 补间同拍的窗口从左上
            //   往右缘收卷（文字边界持续跟随胶囊收缩），且 heightFactor
            //   逐帧压矮旧 child 的高度贡献 = 纵向真补间源（Stack 高随
            //   progress 线性 展开高→46，替代已移除的 AnimatedSize 外层）；
            //   窗口恒在胶囊区域内 + Stack hardEdge 兜底，文字不可能
            //   绘制到胶囊外（无闪烁）；入场（展开方向）同一包装反向
            //   舒展（factor 从 46/estH 线性长到 1，无"先静止后猛长"）
            // - card-collapsed（收起态胶囊）：保持纯 FadeTransition 原样
            //   （入场淡入分支不得加收卷窗口）
            transitionBuilder: (child, animation) {
              if (child is KeyedSubtree &&
                  child.key == const ValueKey('card-expanded')) {
                // 收卷目标只算一次：transitionBuilder 对每个 child 只调用
                // 一次（之后逐帧靠下方 AnimatedBuilder 监听驱动），估算
                // 误差由收起前半程的淡出掩盖（见 _estimateCollapsedWidth /
                // _estimateExpandedHeight）
                final double collapsedWidth = _estimateCollapsedWidth(
                  collapsedText,
                  showPlayButton,
                  textScaler,
                  textFontFamily,
                );
                final double expandedHeight = _estimateExpandedHeight(
                  content,
                  showPlayButton,
                  textScaler,
                  textFontFamily,
                );
                // 冻结排版宽：旧内容 200ms 内恒按此宽排版（必须用
                // OverflowBox deferToChild——SizedBox 的 tight 约束会被
                // 父约束 clamp 回去，收卷中约束收窄时仍会重排），每帧不
                // 重换行 → 贡献高恒定、补间曲线干净，且旧文字子树
                // 200ms 零 relayout
                final double frozenWidth =
                    maxWidth -
                    2 * OverlayConstants.cardHPadding -
                    2 * OverlayConstants.cardBorderWidth;
                // heightFactor 下限 46/estH：旧 child 贡献高 = 真实高 ×
                // lerp(min, 1, progress)，两端精确（progress=1 收敛真实
                // 高；progress=0 ≈ 46）。⚠️ 直接拿 progress 当 factor 会
                // 在贡献高触底 46 后被 Stack 的 max(46,…) 钳位出"前快后停"
                // 膝点（纵向匀速不可接受）；estH 必须过估不可低估
                //（_estimateExpandedHeight 末尾 +10dp 偏置），否则旧 child
                // 移除瞬胶囊高度回跳
                final double minHeightFactor =
                    (OverlayConstants.cardHeight / expandedHeight).clamp(
                      0.0,
                      1.0,
                    );
                return FadeTransition(
                  opacity: CurvedAnimation(
                    parent: animation,
                    curve: OverlayConstants.cardFadeInInterval,
                    reverseCurve: OverlayConstants.cardFadeOutInterval,
                  ),
                  // 窗口/纵向 progress 与 AnimatedContainer 的 maxWidth/
                  // padding 补间逐帧同拍（同为 200ms linear）：窗口开度须
                  // = 1 - curve.transform(s)（s = 该链正向进度 0→1，收起
                  // 方向）。本 child 的 animation：入场正向 value=s（展开，
                  // 窗口随 s 舒展）；出场反向 value=1-s（收起，窗口随 s
                  // 收拢）。⚠️ 不能对出场 value 直接套
                  // CurvedAnimation(cardResizeCurve) 读值：linear 下
                  // curve(1-value) == 1-curve(value) 恰好无差，easeOut 等
                  // 非线性曲线下两条公式错拍（出场前段窗口几乎不收、文字
                  // 画出胶囊外），故按 status 分开算
                  child: AnimatedBuilder(
                    animation: animation,
                    // child 缓存：旧展开内容整棵子树不随窗口 tick 每帧
                    // rebuild（与 FadeTransition 缓存 child 同模式），
                    // builder 每帧只新建廉价的 ClipRect+Align+OverflowBox
                    child: child,
                    builder: (context, cachedChild) {
                      final double progress =
                          animation.status == AnimationStatus.reverse
                          ? 1.0 -
                                OverlayConstants.cardResizeCurve.transform(
                                  1.0 - animation.value,
                                )
                          : OverlayConstants.cardResizeCurve.transform(
                              animation.value,
                            );
                      return ClipRect(
                        clipper: _CollapseWindowClipper(
                          progress: progress,
                          targetWidth: collapsedWidth,
                          targetHeight: OverlayConstants.cardHeight,
                        ),
                        child: Align(
                          alignment: Alignment.topRight,
                          heightFactor:
                              minHeightFactor +
                              (1.0 - minHeightFactor) * progress,
                          child: OverflowBox(
                            alignment: Alignment.topRight,
                            fit: OverflowBoxFit.deferToChild,
                            minWidth: frozenWidth,
                            maxWidth: frozenWidth,
                            child: cachedChild,
                          ),
                        ),
                      );
                    },
                  ),
                );
              }
              return FadeTransition(
                opacity: CurvedAnimation(
                  parent: animation,
                  curve: OverlayConstants.cardFadeInInterval,
                  reverseCurve: OverlayConstants.cardFadeOutInterval,
                ),
                child: child,
              );
            },
            // key 只按 expanded 分流：编辑态/删除确认态是展开内容内部的子树
            // 变化，不换 key 不触发本层淡化（编辑切换走正文处的内层独立
            // Switcher）
            child: expanded
                ? KeyedSubtree(
                    key: const ValueKey('card-expanded'),
                    child: _buildExpandedContent(
                      content,
                      isArchived,
                      showPlayButton,
                      textScaler,
                    ),
                  )
                : KeyedSubtree(
                    key: const ValueKey('card-collapsed'),
                    // 纵向撑满胶囊高度：外层 Switcher 的 Stack 锚点是
                    // topRight（收起动画旧内容顶缘连续所需），裸 Row
                    //（~24dp）比 Stack（容器 minHeight 撑到 cardHeight）
                    // 矮会被钉在胶囊顶部、底部空一截（ae69cff 修复的贴顶
                    // 回归）。Row 撑满 cardHeight 后自身
                    // crossAxisAlignment.center（默认值）接管垂直居中；
                    // 只约束高度，宽度保持松散不影响胶囊内容自适应宽度。
                    // ⚠️ minHeight 减 2×cardBorderWidth 补偿：白描边计入
                    // Container 有效内边距，不减会把胶囊总高顶到 48、破坏
                    // 圆角半径 = cardHeight/2 的半高不变量（含收卷窗口
                    // targetHeight=cardHeight 的对齐）
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight:
                            OverlayConstants.cardHeight -
                            2 * OverlayConstants.cardBorderWidth,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 复选框在最前：勾上=归档划线、取消勾=恢复（onCheckChanged
                          // 由父层 OverlayHome._toggleArchive 接收，null 不渲染）
                          if (onCheckChanged != null) ...[
                            _buildCheckbox(
                              isArchived,
                              () => onCheckChanged!(!isArchived),
                              // 收起态命中区 40→24：视觉圆 20dp 居中于命中区，
                              // 圆左移 8dp、宽度省 16dp，给中间文字腾空间
                              hitSize: 24,
                            ),
                            const SizedBox(width: 4),
                          ],
                          Flexible(
                            child: Text(
                              collapsedText,
                              // 收起态单行省略（展开态已分流到 _buildExpandedContent，
                              // 不会走到这里）。⚠️ overflow 不能恒为 ellipsis：
                              // TextPainter 对 "ellipsis + maxLines=null" 按 1 行
                              // 处理（省略号需要有限行数定位）
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                // 收起态专用小字号（比展开态小 2），保证胶囊达
                                // 最大宽度时能显示约 9 个汉字 + 省略号
                                fontSize:
                                    OverlayConstants.cardCollapsedFontSize,
                                color: Colors.white,
                                decoration: isArchived
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                          ),
                          // 播放按钮在最后：语音笔记听录音入口（含转写失败/进行中的
                          // 占位行——content 为空时胶囊收缩为只有按钮，minWidth 保底）。
                          // onPlayToggle 由父层 OverlayHome._toggleAudioPlay 接收，
                          // 点按钮不冒泡触发卡片展开（内层手势竞技场胜出，同复选框）
                          if (showPlayButton) ...[
                            // 间距 10 加大文字与播放钮命中区的距离（防误触）
                            const SizedBox(width: 10),
                            // 收起态命中区 40→24：视觉圆 30dp > 命中区 24dp，
                            // 居中后圆两侧各溢出命中区 3dp，圆右缘溢出到卡片右
                            // padding 里（视觉上更贴右缘，正是要的效果）
                            _buildPlayButton(isPlayingAudio, hitSize: 24),
                          ],
                        ],
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  /// 展开态多行内容（对齐闪念原型）：
  /// 1. 时间行：created_at 格式化小字 + 右上角收起 chevron（展开态唯一收起
  ///    入口——整卡 onTap 在展开态被父层置空，防与按钮区误触）
  /// 2. 正文：勾选框 WidgetSpan 内联首行文字前，后续行自然顶格
  /// 3. 重放行（有录音才显示）：白底圆播放钮 + 「重放录音」标签，独立一行
  ///    不挤正文
  /// 4. 底部按钮条：删除 / 闹钟 / 复制 / AI 对话 / 标注入口；
  ///    删除确认态整行替换为「确认删除？✓ ✗」，标注选择态整行替换为
  ///   「❗ ⭐ 💡 ✗返回」
  /// [textScaler] 由 build 传入（StatelessWidget 方法取不到 context）：
  /// 查看态勾选框的 WidgetSpan 反缩放倍率换算用，见 _buildViewingBody
  Widget _buildExpandedContent(
    String content,
    bool isArchived,
    bool showPlayButton,
    TextScaler textScaler,
  ) {
    final createdAt = DateTime.tryParse((diary['created_at'] as String?) ?? '');
    final timeText = createdAt == null
        ? ''
        : DateFormat('yyyy年M月d日 HH:mm').format(createdAt);
    // 局部 AnimatedSize：稳态一次性高度变化（编辑打字加行 / 查看↔编辑切换 /
    // 删除确认与标注行替换）的 200ms 平滑（替代已移除的卡片外层
    // AnimatedSize）。⚠️ 勿移回卡片外层——外层在收起动画期间 child 尺寸
    // 逐帧变，RenderAnimatedSize 第二次尺寸变化即吸附透传（补间失效，详见
    // build 内 AnimatedContainer 上方注释）；本层在收起路径上被
    // transitionBuilder 的 OverflowBox 冻结排版（尺寸恒定）全程惰性，
    // 与收卷 heightFactor 补间互不干扰
    return AnimatedSize(
      duration: OverlayConstants.animationDuration,
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. 时间行 + 右上角收起 chevron
          Row(
            children: [
              Expanded(
                child: Text(
                  timeText,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.75),
                  ),
                ),
              ),
              if (onCollapse != null)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onCollapse,
                  child: const SizedBox(
                    width: 40,
                    height: 32,
                    child: Center(
                      child: Icon(
                        Icons.expand_less,
                        size: 22,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          // 2. 正文：编辑态换多行 TextField（勾选框拆出为禁用态前导）；
          // 查看态保持勾选框 WidgetSpan 内联首行，且 onTextTap 非空时外包
          // GestureDetector(onTapDown) —— 点击正文换算字符偏移进入编辑态。
          // 查看↔编辑正文切换的独立 fade-through：只包正文区域（时间行/重放行/
          // 按钮条不参与——复用外层 card Switcher 会整卡重淡）；120ms 短淡化配合
          // 软键盘弹出。layoutBuilder 左对齐（正文在卡内左起排版）+ IgnorePointer
          //（淡出中的旧正文 GestureDetector/TextField 不可点，防半透明期误触/误聚焦）
          AnimatedSwitcher(
            duration: OverlayConstants.cardEditFadeDuration,
            layoutBuilder: (currentChild, previousChildren) => Stack(
              alignment: Alignment.centerLeft,
              children: [
                for (final child in previousChildren)
                  IgnorePointer(child: child),
                // 同外层：null-aware 元素，null 时不进列表
                ?currentChild,
              ],
            ),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: CurvedAnimation(
                parent: animation,
                curve: OverlayConstants.cardFadeInInterval,
                reverseCurve: OverlayConstants.cardFadeOutInterval,
              ),
              child: child,
            ),
            child: editing
                ? KeyedSubtree(
                    key: const ValueKey('card-body-editing'),
                    child: _buildEditingBody(isArchived),
                  )
                : KeyedSubtree(
                    key: const ValueKey('card-body-viewing'),
                    child: _buildViewingBody(content, isArchived, textScaler),
                  ),
          ),
          // 3. 重放录音独立行（有录音且未归档才显示，条件与收起态一致）。
          // 编辑态禁用播放（防编辑中误触发回放）：视觉保留半透明、手势屏蔽
          if (showPlayButton) ...[
            const SizedBox(height: 8),
            IgnorePointer(
              ignoring: editing,
              child: Opacity(
                opacity: editing ? 0.4 : 1,
                child: Row(
                  // 居中排列（用户要求，旧版偏左）：去掉 mainAxisSize.min 让 Row
                  // 撑满卡片宽（展开态卡片约束宽 = maxWidth），再整体居中
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildPlayButton(isPlayingAudio),
                    const SizedBox(width: 6),
                    Text(
                      '重放录音',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          // 4. 底部按钮条：编辑态整行替换为「✗取消 / ✓保存」（优先级最高，
          // 对齐删除确认行「确认删除？✓✗」的整行替换先例）；删除确认态整行替换
          // 为「确认删除？✓✗」；标注选择态整行替换为「❗ ⭐ 💡 ✗返回」；
          // 查看态为 删除/闹钟/复制/AI 对话/标注入口
          const SizedBox(height: 8),
          Divider(color: Colors.white.withValues(alpha: 0.3), height: 1),
          const SizedBox(height: 4),
          editing
              ? _buildEditActionRow()
              : isDeleteConfirming
              ? _buildDeleteConfirmRow()
              : isTagPicking
              ? _buildTagPickRow()
              : _buildActionRow(),
        ],
      ),
    );
  }

  /// 查看态正文：勾选框 WidgetSpan 内联首行（归档划线样式与收起态一致）。
  /// [onTextTap] 非空时外包 GestureDetector(onTapDown)：把点击位置用
  /// TextPainter 换算成字符偏移回调给父层（进入编辑态、光标定位到点击处；
  /// -1 哨兵 = 点击落在勾选框占位区，父层跳过进编辑——点勾选框走归档回调）。
  /// GestureDetector 只包正文本身（localPosition 天然相对正文左上角）；
  /// 换算精度见 _charOffsetAt——占位尺寸与下方勾选框同源（_kExpandedCheckbox*
  /// 常量），首行缩进与真实渲染逐像素一致
  Widget _buildViewingBody(
    String content,
    bool isArchived,
    TextScaler textScaler,
  ) {
    // 勾选框反缩放倍率：WidgetSpan 子项会被框架按系统字体缩放整体放大
    //（widget_span.dart _RenderScaledInlineWidget，scale = textScaler.scale(正文字号)/
    // 字号），悬浮窗引擎又跟随系统字体缩放——勾选框画 20dp 会被放大成
    // 20×1.3 ≈ 26dp，比收起态（普通 Row 子项，不参与文字缩放）明显大一圈。
    // 内部所有显式尺寸除以该倍率，经框架放大后恰好还原为设计 dp；倍率 1.0
    // 时除数即 1，渲染零变化。_charOffsetAt/_estimateExpandedHeight 的占位
    // 常量保持逻辑尺寸（28/8）不变——补偿后占位盒放大回来正是 36×28，与
    // 换算 TextPainter 声明一致
    final double fontScale =
        textScaler.scale(OverlayConstants.cardFontSize) /
        OverlayConstants.cardFontSize;
    final body = Text.rich(
      TextSpan(
        children: [
          if (onCheckChanged != null)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: EdgeInsets.only(
                  right: _kExpandedCheckboxRightGap / fontScale,
                ),
                child: _buildCheckbox(
                  isArchived,
                  () => onCheckChanged!(!isArchived),
                  hitSize: _kExpandedCheckboxHitSize,
                  scale: fontScale,
                ),
              ),
            ),
          TextSpan(text: content),
        ],
      ),
      style: TextStyle(
        fontSize: OverlayConstants.cardFontSize,
        color: Colors.white,
        height: 1.4,
        decoration: isArchived ? TextDecoration.lineThrough : null,
        decorationColor: Colors.white,
      ),
    );
    if (onTextTap == null) return body;
    return LayoutBuilder(
      builder: (context, bodyConstraints) {
        // 换算环境与实际渲染一致（见 _charOffsetAt）：从本层 context 取
        // MediaQuery 实际 textScaler 与 DefaultTextStyle 的主题字体
        final textScaler = MediaQuery.textScalerOf(context);
        final fontFamily = DefaultTextStyle.of(context).style.fontFamily;
        return GestureDetector(
          // opaque：行尾空白处点击也进入编辑（段落命中区 = 整段包围盒）
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) => onTextTap!(
            _charOffsetAt(
              content,
              details.localPosition,
              bodyConstraints.maxWidth,
              textScaler,
              fontFamily,
            ),
          ),
          child: body,
        );
      },
    );
  }

  /// 点击位置 → 字符偏移：换算 TextPainter 的布局必须与真实渲染完全一致——
  /// 含勾选框 WidgetSpan 占位（setPlaceholderDimensions 声明同尺寸占位盒，
  /// 首行缩进逐像素对齐；漏掉占位会让首行点击偏移系统性偏大一个占位宽度
  /// ≈ 36dp ≈ 2~5 个字符，9403517 确诊）。占位符在 text 坐标系占 1 字符
  ///（object replacement char，偏移 0~1），返回值需 -1 平移回正文坐标系；
  /// 越界/异常兜底落文末。[textScaler] / [fontFamily] 同 _estimateCollapsedWidth：
  /// 换算 painter 的度量环境必须与实际渲染一致，系统字体放大时裸 painter
  ///（1.0 缩放）算出的字符偏移会系统性偏小
  int _charOffsetAt(
    String content,
    Offset localPosition,
    double maxWidth,
    TextScaler textScaler,
    String? fontFamily,
  ) {
    try {
      final hasCheckbox = onCheckChanged != null;
      final painter = TextPainter(
        text: TextSpan(
          children: [
            if (hasCheckbox)
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: SizedBox(
                  width: _kExpandedCheckboxHitSize + _kExpandedCheckboxRightGap,
                  height: _kExpandedCheckboxHitSize,
                ),
              ),
            TextSpan(text: content),
          ],
          style: TextStyle(
            fontSize: OverlayConstants.cardFontSize,
            height: 1.4,
            fontFamily: fontFamily,
          ),
        ),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
      );
      if (hasCheckbox) {
        painter.setPlaceholderDimensions([
          PlaceholderDimensions(
            size: Size(
              _kExpandedCheckboxHitSize + _kExpandedCheckboxRightGap,
              _kExpandedCheckboxHitSize,
            ),
            alignment: PlaceholderAlignment.middle,
          ),
        ]);
      }
      painter.layout(maxWidth: maxWidth);
      if (localPosition.dy < 0 || localPosition.dy > painter.height) {
        return content.length;
      }
      final rawOffset = painter.getPositionForOffset(localPosition).offset;
      // 有勾选框占位时 text 坐标系含 1 字符占位符（占偏移 0~1），-1 平移回正文
      final offset = hasCheckbox ? rawOffset - 1 : rawOffset;
      // ⚠️ 点击落在勾选框占位区时换算结果是 0——但点勾选框本不该进编辑：
      // 内层 onTap（归档）要等竞技场闭合才回调，外层 onTapDown 落下即触发，
      // 不过滤会"归档 + 误进编辑"双触发。返回 -1 哨兵让父层跳过进编辑；
      // 边界损失仅是"点第 0 字符左侧缘"不再进编辑（无害极端值）
      if (offset <= 0 && hasCheckbox) return -1;
      return offset.clamp(0, content.length);
    } catch (_) {
      return content.length; // 兜底落文末
    }
  }

  /// 估算收起态胶囊宽度（dp）。双重身份：
  /// ① 收卷窗口的 targetWidth（transitionBuilder 的 card-expanded 分支调用，
  /// 每个 child 一次）；② 收起态 AnimatedContainer maxWidth 的补间终点
  ///（build 直取本值——直达本卡实际胶囊宽，消除"补到 maxWidth 上限后再跳
  /// 一次到内容宽"的尾部咯噔跳变）。公式与收起分支 build 的实际排版同源：
  /// 胶囊框宽 = Row 内容宽（复选框 24 命中区 + 4 间距 / 单行文字 / 播放钮
  /// 10 间距 + 24 命中区，字面量与收起分支一致）+ 2×cardHPadding +
  /// 2×cardBorderWidth（白描边计入 Container 有效内边距），再过
  /// clamp(cardMinWidth, maxWidth)。文字用 TextPainter 按收起态排版度量
  ///（cardCollapsedFontSize、单行，先例见 _charOffsetAt；layout 不传
  /// maxWidth = 单行不换行，width 即单行 intrinsic 宽）。
  /// ⚠️ 度量环境必须与实际渲染严格一致（[textScaler] / [fontFamily] 由
  /// build 从 MediaQuery/DefaultTextStyle 取实际值传入）——裸 painter 按
  /// textScaler 1.0 + 默认字体度量，而 overlay 引擎跟随系统字体缩放、主题
  /// 字体渲染，系统字体放大（如 1.1×）时估算偏窄 → 本值兼任稳态宽度上限
  /// 会把短文字顶出省略号（6 字只显示 4 字+…）。传入文本须与收起分支
  /// 展示的同一字符串（build 的 collapsedText，换行已压成单行）
  double _estimateCollapsedWidth(
    String content,
    bool showPlayButton,
    TextScaler textScaler,
    String? fontFamily,
  ) {
    // 文字宽度走缓存（Top7）：输入不变直接命中，shaping 只发生一次
    final textWidth =
        _measureCollapsedTextWidth(content, textScaler, fontFamily);
    final double raw =
        2 * OverlayConstants.cardHPadding +
        2 * OverlayConstants.cardBorderWidth +
        (onCheckChanged != null ? 24 + 4 : 0) +
        textWidth +
        (showPlayButton ? 10 + 24 : 0);
    // +4dp 度量余量：兜 layout 舍入/字距等亚 dp 微差（textScaler 与字体环境
    // 已显式对齐，不再是余量的承担对象）。本值兼任收起态 maxWidth 补间终点
    //——若低于实际排版需求，稳态胶囊被压窄会把收起文字顶出省略号；余量
    // 换来的 3~4dp 尾部落差（补间终点 ~165 → 旧内容移除后稳态 ~162）肉眼
    // 不可辨，长文本卡 clamp 回 maxWidth 不受影响
    return (raw + 4).clamp(OverlayConstants.cardMinWidth, maxWidth).toDouble();
  }

  /// 估算展开态内容高度（dp，Stack child 高，不含容器 padding 10×2）。
  /// 用途：transitionBuilder 收卷的 heightFactor 下限分母（46/estH）——
  /// 估算误差只影响中段速率（±几 dp），两端精确（progress=1 时 factor=1
  /// 收敛到真实高）。⚠️ 必须过估不可低估（末尾 +10dp 偏置）：过估时末端
  /// 贡献 <46 被 Stack 的 max(46,…) 提前钳位（无害小膝点）；低估时末端
  /// 贡献 >46，旧 child 移除瞬胶囊会回跳几 dp。
  /// 公式与 _buildExpandedContent 的实际排版同源：时间行高（chevron 命中
  /// 盒 32 主导，无收起回调时只剩 12pt 小字 ≈17）+ 4 间距 + 正文
  /// TextPainter 实测高（含勾选框 WidgetSpan 占位，先例见 _charOffsetAt）
  /// + 重放行（8 间距 + 40 命中区）+ 按钮行（8+1+4+40）。
  /// [textScaler] / [fontFamily] 同 _estimateCollapsedWidth：度量环境与
  /// 实际渲染一致，系统字体放大时正文实测高同步放大，estH 不会系统性低估
  double _estimateExpandedHeight(
    String content,
    bool showPlayButton,
    TextScaler textScaler,
    String? fontFamily,
  ) {
    double bodyH = 0;
    try {
      final hasCheckbox = onCheckChanged != null;
      final painter = TextPainter(
        text: TextSpan(
          children: [
            if (hasCheckbox)
              const WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: SizedBox(
                  width: _kExpandedCheckboxHitSize + _kExpandedCheckboxRightGap,
                  height: _kExpandedCheckboxHitSize,
                ),
              ),
            TextSpan(text: content),
          ],
          style: TextStyle(
            fontSize: OverlayConstants.cardFontSize,
            height: 1.4,
            fontFamily: fontFamily,
          ),
        ),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
      );
      if (hasCheckbox) {
        painter.setPlaceholderDimensions([
          const PlaceholderDimensions(
            size: Size(
              _kExpandedCheckboxHitSize + _kExpandedCheckboxRightGap,
              _kExpandedCheckboxHitSize,
            ),
            alignment: PlaceholderAlignment.middle,
          ),
        ]);
      }
      painter.layout(
        maxWidth:
            maxWidth -
            2 * OverlayConstants.cardHPadding -
            2 * OverlayConstants.cardBorderWidth,
      );
      bodyH = painter.height;
      painter.dispose();
    } catch (_) {
      bodyH = 0; // 度量异常兜底：偏置与 clamp 接管，仍被淡出掩盖
    }
    final double timeRowH = onCollapse != null ? 32 : 17;
    final double audioRowH = showPlayButton ? 8 + 40 : 0;
    const double actionRowH = 8 + 1 + 4 + 40;
    return timeRowH + 4 + bodyH + audioRowH + actionRowH + 10; // +10 过估偏置
  }

  /// 编辑态正文：勾选框禁用态（半透明 + IgnorePointer，防编辑中误归档）
  /// 前导 + 多行 TextField（样式对齐查看态正文：白字同字号同行高、无边框、
  /// 白色光标；归档卡允许编辑，编辑中不画删除线）
  Widget _buildEditingBody(bool isArchived) {
    final textField = TextField(
      controller: editController,
      focusNode: editFocusNode,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      cursorColor: Colors.white,
      style: TextStyle(
        fontSize: OverlayConstants.cardFontSize,
        color: Colors.white,
        height: 1.4,
      ),
      decoration: const InputDecoration.collapsed(hintText: null),
    );
    if (onCheckChanged == null) return textField;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IgnorePointer(
          child: Opacity(
            opacity: 0.4,
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _buildCheckbox(isArchived, () {}, hitSize: 28),
            ),
          ),
        ),
        Expanded(child: textField),
      ],
    );
  }

  /// 底部按钮条：删除 / 闹钟 / 复制 / AI 对话 / 标注入口。
  /// 白色图标 + 40×40 opaque 命中区（内层手势竞技场胜出，不冒泡），
  /// 与复选框/播放钮同款命中模式
  Widget _buildActionRow() {
    // AI 对话按钮守卫：占位（空 content）与已归档卡不渲染——对齐日记页
    // AI 按钮的渲染条件（避免把空文本/归档旧文送进 AI 对话）
    final content = (diary['content'] as String?) ?? '';
    final isArchived = (diary['is_archived'] as int?) == 1;
    final showAiChat = onAiChat != null && content.isNotEmpty && !isArchived;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        if (onDelete != null)
          _buildActionButton(Icons.delete_outline, onDelete),
        // 闹钟：识别卡片时间预填转轮确认 sheet → 写系统日历（父层 _onCardAlarm）。
        // 空文案卡也可用（识别不到预填默认时刻，转轮手动调）
        _buildActionButton(Icons.alarm, onAlarm),
        if (onCopy != null) _buildActionButton(Icons.copy, onCopy),
        // AI 对话：图标对齐日记页卡片同款按钮（chat_bubble_outline），
        // 点击复制 + 跳转 AI 应用（语义在父层 _onCardShareToAI）
        if (showAiChat) _buildActionButton(Icons.chat_bubble_outline, onAiChat),
        // 标注入口：点击进入标注选择态（整行替换，见 _buildTagPickRow）
        if (onTagEntry != null)
          _buildActionButton(Icons.label_outline, onTagEntry),
      ],
    );
  }

  /// 编辑态底部按钮条：「✗取消 / ✓保存」（复用 _buildActionButton 视觉语言，
  /// 对齐删除确认行「确认删除？✓✗」的整行替换先例）
  Widget _buildEditActionRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _buildActionButton(Icons.close, onEditCancel),
        _buildActionButton(Icons.check, onEditSave),
      ],
    );
  }

  /// 删除二次确认行：「确认删除？✓ ✗」（✓ → onDelete 真删；✗ → onDeleteCancel）。
  /// onDelete 复用底部按钮条同一回调：父层按确认态分流（第一次点进确认态、
  /// 确认态点 ✓ 真删）
  Widget _buildDeleteConfirmRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        Text(
          '确认删除？',
          style: TextStyle(
            fontSize: 13,
            color: Colors.white.withValues(alpha: 0.9),
          ),
        ),
        _buildActionButton(Icons.check, onDelete),
        _buildActionButton(Icons.close, onDeleteCancel),
      ],
    );
  }

  /// 标注选择行：「❗紧急 ⭐收藏 💡灵感 ✗返回」（整行替换查看态按钮条，
  /// 对齐删除确认行的整行替换先例）。
  /// 点击 tag → onTagToggle(tag)；点击当前已选中的 tag = 取消标注
  ///（onTagToggle(null)，toggle 回默认色）；✗ → onTagPickCancel 退出还原。
  /// 已选中的 tag 按钮加视觉强调：白底圆 + 图标换标注色（对齐 _buildCheckbox
  /// 勾选态「白底圆+深色图标」的视觉语言）
  Widget _buildTagPickRow() {
    final currentTag = diary['tag'] as String?;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _buildTagButton(
          Icons.priority_high,
          DiaryTag.urgent,
          currentTag == DiaryTag.urgent,
        ),
        _buildTagButton(
          Icons.star_rounded,
          DiaryTag.star,
          currentTag == DiaryTag.star,
        ),
        _buildTagButton(
          Icons.lightbulb_outline,
          DiaryTag.idea,
          currentTag == DiaryTag.idea,
        ),
        _buildActionButton(Icons.close, onTagPickCancel),
      ],
    );
  }

  /// 标注行单个 tag 按钮：未选中 = 白色图标（同 _buildActionButton）；
  /// 选中 = 白底圆 + 标注色图标（对齐 _buildCheckbox 勾选态视觉语言）。
  /// 40×40 opaque 命中区（点按钮不冒泡，同其他底条按钮）
  Widget _buildTagButton(IconData icon, String tag, bool selected) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 点击已选中的 tag = 取消标注（传 null，toggle 回默认色）
      onTap: () => onTagToggle?.call(selected ? null : tag),
      child: SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: selected
              ? Container(
                  width: 28,
                  height: 28,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                  ),
                  child: Icon(icon, size: 18, color: DiaryTag.colors[tag]),
                )
              : Icon(icon, size: 20, color: Colors.white),
        ),
      ),
    );
  }

  /// 底部按钮条单个图标按钮：onTap 为 null 时 white38 禁用态（无手势），
  /// 否则白色图标 + GestureDetector opaque 40×40 命中区（点按钮不冒泡，
  /// 同 _buildCheckbox / _buildPlayButton 模式）
  Widget _buildActionButton(IconData icon, VoidCallback? onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: Icon(
            icon,
            size: 20,
            color: onTap == null ? Colors.white38 : Colors.white,
          ),
        ),
      ),
    );
  }

  /// 圆形勾选框（归档 toggle 入口）
  ///
  /// - GestureDetector 显式 opaque：40×40 命中区大于 20×20 视觉圆，小圆也易点
  /// - 嵌套 onTap 手势竞技场内层胜出：点复选框不冒泡触发卡片展开（Flutter 标准行为）
  /// - 视觉：未勾选 = 透明底 + 1.8dp 白圈（white70）；勾选（已归档）= 白底圆 +
  ///   灰对勾（blueGrey.shade700，与归档卡片底色语言一致）
  /// - [hitSize]：命中区边长，默认 40（收起态行内）；展开态正文 WidgetSpan
  ///   内联传 28（视觉圆仍 20 居中——40 命中区会撑高文字行）
  /// - [scale]：反缩放倍率，仅展开态 WidgetSpan 内联传（框架会把子项按系统
  ///   字体缩放放大，见 _buildViewingBody 注释）——内部全部显式尺寸（命中区/
  ///   视觉圆/描边/对勾图标）除以它，放大后还原设计 dp；默认 1 = 尺寸原样，
  ///   收起态/编辑态（普通 Row 子项，无框架缩放）不传
  Widget _buildCheckbox(
    bool isArchived,
    VoidCallback onTap, {
    double hitSize = 40,
    double scale = 1,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: hitSize / scale,
        height: hitSize / scale,
        child: Center(
          child: AnimatedContainer(
            duration: OverlayConstants.animationDuration,
            width: 20 / scale,
            height: 20 / scale,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isArchived ? Colors.white : Colors.transparent,
              border: Border.all(
                color: isArchived ? Colors.white : Colors.white70,
                width: 1.8 / scale,
              ),
            ),
            child: isArchived
                ? Icon(
                    Icons.check,
                    size: 14 / scale,
                    color: Colors.blueGrey.shade700,
                  )
                : null,
          ),
        ),
      ),
    );
  }

  /// 圆形播放/暂停按钮（语音笔记回放入口）
  ///
  /// - GestureDetector 显式 opaque + 40×40 命中区：照抄 _buildCheckbox 模式，
  ///   视觉圆 30dp 大于复选框 20dp（播放是语音卡的主操作，不能太小），
  ///   点按钮不冒泡触发卡片展开
  /// - [hitSize]：命中区边长，默认 [OverlayConstants.cardPlayButtonHitSize]（40，
  ///   展开态重放行）；收起态行内传 24——视觉圆 30dp 大于命中区，居中后圆两侧
  ///   各溢出命中区 3dp，右缘溢出到卡片右 padding 里（视觉上更贴右缘）
  /// - 视觉：白底圆 + blueGrey.shade700 图标（复选框勾选态同款语言），
  ///   图标按播放态切 play_arrow_rounded / pause_rounded（同主 App 播放条，
  ///   跨界面语义统一）。两态差异只靠图标切换，圆底恒白，不做动画
  Widget _buildPlayButton(
    bool isPlaying, {
    double hitSize = OverlayConstants.cardPlayButtonHitSize,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPlayToggle,
      child: SizedBox(
        width: hitSize,
        height: hitSize,
        child: Center(
          child: Container(
            width: OverlayConstants.cardPlayButtonSize,
            height: OverlayConstants.cardPlayButtonSize,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
            ),
            child: Icon(
              isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: OverlayConstants.cardPlayIconSize,
              color: Colors.blueGrey.shade700,
            ),
          ),
        ),
      ),
    );
  }
}

/// 收起出场的「裁剪收卷」窗口（OverlayDiaryCard 的 transitionBuilder
/// card-expanded 分支使用）：右缘固定（topRight 锚定，与胶囊的收缩锚点
/// 一致）、左缘随 progress 收拢，高度同步从旧内容高收到胶囊高。
/// progress=1 全窗（出场起点/展开完成态），0=收到胶囊目标尺寸。
/// 旧内容排版由 OverflowBox 真正冻结（恒宽、200ms 零重排），只被窗口
/// 裁剪 → 文字边界持续跟随胶囊收缩（视觉锚点）；窗口恒 ⊆ 胶囊区域
///（横向二次收缩恒窄于色块、纵向恒矮于 heightFactor 贡献高），文字
/// 不可能绘制到胶囊外（无闪烁）。progress 的取值公式见 transitionBuilder
/// 内注释（须与 AnimatedContainer 的 maxWidth/padding 补间逐帧同拍）
class _CollapseWindowClipper extends CustomClipper<Rect> {
  /// 窗口开度：1=全窗（progress 起点），0=收到 (targetWidth, targetHeight)
  final double progress;

  /// 收卷终点宽（_estimateCollapsedWidth 估算的收起态胶囊宽）
  final double targetWidth;

  /// 收卷终点高（OverlayConstants.cardHeight，收起态胶囊高）
  final double targetHeight;

  const _CollapseWindowClipper({
    required this.progress,
    required this.targetWidth,
    required this.targetHeight,
  });

  @override
  Rect getClip(Size size) {
    // 数学式插值（不引 dart:ui 的 lerpDouble）：
    // w = targetWidth + (size.width - targetWidth) * progress，h 同理
    final double w = targetWidth + (size.width - targetWidth) * progress;
    final double h = targetHeight + (size.height - targetHeight) * progress;
    // topRight 锚定：右缘固定贴胶囊右缘，左缘随收缩右移。
    // targetWidth 超过旧内容宽（长文本两态都顶满 maxWidth）时 progress→0
    // 会得到负 left 的宽窗——Rect 允许负 left，等于无实裁（长文本卡的横向
    // 收缩本就发生在父层面板宽层，本窗口只管纵向收卷）
    return Rect.fromLTWH(size.width - w, 0.0, w, h);
  }

  @override
  bool shouldReclip(_CollapseWindowClipper oldClipper) =>
      progress != oldClipper.progress ||
      targetWidth != oldClipper.targetWidth ||
      targetHeight != oldClipper.targetHeight;
}
