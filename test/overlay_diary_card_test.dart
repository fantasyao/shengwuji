import 'package:flutter/gestures.dart' show HitTestResult;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/overlay/widgets/overlay_diary_card.dart';

/// 悬浮窗胶囊卡片展开态布局回归：
/// 展开应显示全部文本（多行撑高），收起回单行省略。
/// 背景教训：overflow 恒为 ellipsis 时，TextPainter 对 "ellipsis + maxLines=null"
/// 按 1 行处理，展开态曾退化成单行（"展开只见前两行"）
void main() {
  // 100 字长文本：Ahem 字体 15px/字、卡片内可用文本宽 ~188dp ≈ 12 字/行 → 展开应 8 行左右
  final longText = '这是一条用来验证展开态多行显示的测试文本' * 5;

  Widget wrap({required bool expanded, ValueChanged<bool>? onCheckChanged}) =>
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 296, // 模拟面板宽（OverlayHome._buildPanel 的 panelWidth 量级）
            child: ListView(
              children: [
                OverlayDiaryCard(
                  diary: {'id': 1, 'content': longText, 'is_archived': 0},
                  maxWidth: 268,
                  expanded: expanded,
                  onCheckChanged: onCheckChanged ?? (_) {},
                ),
              ],
            ),
          ),
        ),
      );

  // 卡片内的正文 RichText：按文本内容定位（展开态卡片还有时间行等其它 RichText，
  // 旧"卡片内唯一"的按类型查找随展开态改版失效——时间行加入后 getSize 报
  // Too many elements，改为按正文内容匹配保唯一）
  final cardRichText = find.descendant(
    of: find.byType(OverlayDiaryCard),
    matching: find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText().contains(longText),
    ),
  );

  // 卡片内的所有 FadeTransition（外层展开/收起 + 内层查看/编辑两个 AnimatedSwitcher
  // 的 transitionBuilder 各包一层；AnimatedSwitcher 静止态也恒包当前 child 一层，
  // 因此收起静止 = 1 个、展开静止 = 2 个、过渡期再加出场 child 的 1 个）
  final cardFadeTransitions = find.descendant(
    of: find.byType(OverlayDiaryCard),
    matching: find.byType(FadeTransition),
  );

  testWidgets('展开态：正文多行渲染（高度 > 3 行），不再退化单行', (tester) async {
    await tester.pumpWidget(wrap(expanded: true));
    await tester.pumpAndSettle();

    final textSize = tester.getSize(cardRichText);
    // ignore: avoid_print
    print('🧪 展开态正文尺寸: $textSize');
    // Ahem 行高 ~21dp，3 行 = 63dp；单行回归时只有 ~21dp
    expect(textSize.height, greaterThan(21.0 * 3));
  });

  testWidgets('收起态：正文单行省略（高度 ≈ 1 行）', (tester) async {
    await tester.pumpWidget(wrap(expanded: false));
    await tester.pumpAndSettle();

    final textSize = tester.getSize(cardRichText);
    // ignore: avoid_print
    print('🧪 收起态正文尺寸: $textSize');
    expect(textSize.height, lessThan(21.0 * 2));
  });

  testWidgets('展开→收起切换后卡片高度收敛回 minHeight 46', (tester) async {
    await tester.pumpWidget(wrap(expanded: true));
    await tester.pumpAndSettle();

    await tester.pumpWidget(wrap(expanded: false));
    await tester.pumpAndSettle();

    final cardSize = tester.getSize(find.byType(OverlayDiaryCard));
    // ignore: avoid_print
    print('🧪 收起后整卡尺寸(含margin): $cardSize');
    // 46 卡片高 + 10 底部 margin
    expect(cardSize.height, 56.0);
  });

  // 纵向运动学（2026-09-03 纵向真补间重构）：纵向补间源 = transitionBuilder
  // 内 Align(heightFactor: lerp(46/estH, 1, progress)) + 容器 padding 10↔0，
  // Stack 高度从 t=0 起随 progress 线性收缩。⚠️ 旧注释的"AnimatedSize 追赶式
  // 前快后慢"是误诊——RenderAnimatedSize 在 child 尺寸第二次变化时吸附透传、
  // 补间失效（实际纵向是 ~90% 一帧完成的跳变）；外层 AnimatedSize 已移除，
  // 勿重新引入（新结构下 child 逐帧变化，它会制造开场单帧顿挫），结构与动机
  // 详见 overlay_diary_card.dart 的 AnimatedContainer 大注释。
  // 更旧的两拍实现（a36800b 之前）Stack 被淡出中的多行旧内容占位到 t=200ms
  // 才跳变，纵向呈现"前半段不动、后半段果冻加速"
  // 收起态内容纵向居中（a36800b 防再犯）：外层 Switcher 的 Stack 锚点
  // topRight 只服务收起动画的旧内容顶缘连续；收起静止态裸 Row（~24dp）比
  // Stack（容器 minHeight 撑到 46）矮，会被钉在胶囊顶部、底部空 22dp——
  // ⚠️ 收起分支 Row 必须包 ConstrainedBox(minHeight: cardHeight)，由 Row
  // 自身 crossAxisAlignment.center 接管垂直居中，勿让裸 Row 靠 topRight 定位
  testWidgets('收起态内容纵向居中：不被 topRight 锚点钉在胶囊顶部', (tester) async {
    await tester.pumpWidget(wrap(expanded: false));
    await tester.pumpAndSettle();

    final cardRect = tester.getRect(find.byType(OverlayDiaryCard));
    final textRect = tester.getRect(cardRichText);
    // ignore: avoid_print
    print('🧪 收起态文本中心: ${textRect.center}, 卡片区域: $cardRect');
    // 胶囊占卡片区域顶部 46dp（margin bottom 10 在下方）：胶囊中心 = top + 23
    expect((textRect.center.dy - (cardRect.top + 23.0)).abs(), lessThan(1.0));
  });

  testWidgets('收起纵向匀速收缩：t=50ms 高度精确收缩总量的 25%', (tester) async {
    await tester.pumpWidget(wrap(expanded: true));
    await tester.pumpAndSettle();

    final expandedHeight = tester.getSize(find.byType(OverlayDiaryCard)).height;
    // ignore: avoid_print
    print('🧪 展开态整卡高(含margin): $expandedHeight');

    await tester.pumpWidget(wrap(expanded: false));
    await tester.pump(const Duration(milliseconds: 50));
    final midHeight = tester.getSize(find.byType(OverlayDiaryCard)).height;
    // ignore: avoid_print
    print(
      '🧪 收起 50ms 时整卡高(含margin): $midHeight（已收缩 ${expandedHeight - midHeight}dp）',
    );
    // animationDuration 200ms 的 t=50ms = 时间轴 25% 处。纵向真补间重构后
    // 高度链与宽度链同源同拍 linear（Align heightFactor 补间 + padding
    // 10↔0），此处应精确收缩总量（展开高→56）的 25%。容差 ±3.5dp 兜 estH
    // 过估偏置（+10dp，见 _estimateExpandedHeight）对中段速率的影响
    //（先例 overlay_card_list_follow_test 高度链）。区分度充足：纵向
    // 一拍化回归（a36800b~046fe0b 病灶，~90% 一帧完成）此处偏差 >40dp；
    // 旧两拍实现此刻仅 padding 补间收回 ~5dp（偏差 >30dp）
    expect(
      midHeight,
      closeTo(expandedHeight - (expandedHeight - 56.0) * 0.25, 3.5),
    );

    await tester.pumpAndSettle();
    final settledHeight = tester.getSize(find.byType(OverlayDiaryCard)).height;
    // ignore: avoid_print
    print('🧪 收起收敛后整卡高(含margin): $settledHeight');
    // 46 卡片高 + 10 底部 margin（对齐上面"展开→收起切换后"测试的断言值）
    expect(settledHeight, 56.0);
  });

  testWidgets('fade-through 时序：切换帧新旧 child 共存，新 child 从全透明淡入', (tester) async {
    await tester.pumpWidget(wrap(expanded: false));
    await tester.pumpAndSettle();
    // 收起静止态：仅外层 Switcher 当前 child 包一层 FadeTransition
    expect(cardFadeTransitions, findsOneWidget);

    await tester.pumpWidget(wrap(expanded: true));
    await tester.pump(); // t=0：切换后的过渡首帧（pumpWidget 已渲一帧，此处固化）
    // 过渡期新旧 child 都在树中（AnimatedSwitcher 出场 child 反向动画到
    // dismissed 才移除，200ms 全程占位）
    expect(find.byKey(const ValueKey('card-collapsed')), findsOneWidget);
    expect(find.byKey(const ValueKey('card-expanded')), findsOneWidget);
    // FadeTransition = 外层新旧 child 各 1 + 展开内容内层正文 Switcher 1 = 3
    expect(cardFadeTransitions, findsNWidgets(3));
    // 入场 child 透明度：Interval(0.5, 1.0) 在 t=0 输出 0（前半程保持全透明，
    // 给外框 AnimatedSize/AnimatedContainer 长大的时间）。
    // 定位方式（2026-09-03 纵向真补间重构后更新）：card-expanded 分支的包装
    // = FadeTransition → AnimatedBuilder（收卷窗口）→ ClipRect →
    // Align(heightFactor 纵向补间) → OverflowBox（排版冻结）→ KeyedSubtree，
    // FadeTransition 的直接 child 不再是 KeyedSubtree——改为按"child 为
    // AnimatedBuilder"判定（卡片内唯一组合：card-collapsed 分支与内层正文
    // Switcher 的 FadeTransition child 均为 KeyedSubtree，MaterialApp 路由
    // 过渡的 FadeTransition child 亦非 AnimatedBuilder；find.ancestor 仍不可
    // 用——会一路命中 MaterialApp 路由过渡固有的多个 FadeTransition）
    final expandedFade = find.byWidgetPredicate(
      (w) => w is FadeTransition && w.child is AnimatedBuilder,
    );
    expect(expandedFade, findsOneWidget);
    final fadeOpacity = tester.widget<FadeTransition>(expandedFade).opacity;
    // ignore: avoid_print
    print('🧪 切换首帧入场 child 透明度: ${fadeOpacity.value}');
    expect(fadeOpacity.value, 0.0);

    await tester.pumpAndSettle();
    // 过渡结束：旧收起 child 已移除；展开静止态 = 外层 1 + 内层 1 = 2
    expect(find.byKey(const ValueKey('card-collapsed')), findsNothing);
    expect(cardFadeTransitions, findsNWidgets(2));
  });

  testWidgets('淡出中旧收起 child 手势被屏蔽：IgnorePointer 防误触旧勾选框', (tester) async {
    var checkCount = 0;

    await tester.pumpWidget(
      wrap(expanded: false, onCheckChanged: (_) => checkCount++),
    );
    await tester.pumpAndSettle();

    // 收起态 KeyedSubtree 内唯一的 GestureDetector 即勾选框（正文 Text 无手势，
    // 卡片级 GestureDetector 是 KeyedSubtree 的祖先不算后代）
    final collapsedCheckbox = find.descendant(
      of: find.byKey(const ValueKey('card-collapsed')),
      matching: find.byType(GestureDetector),
    );
    // 前置 sanity：静止收起态点勾选框确实触发回调（证明定位的是活靶，非空断言）
    await tester.tap(collapsedCheckbox);
    await tester.pump();
    expect(checkCount, 1);

    // 切到展开 + 50ms：旧收起 Row 正在淡出（出场反向 200ms 的 25% 处中段，
    // 仍在树中；时刻随 animationDuration 400→200ms（2026-09-03 恢复 945be75
    // 节奏）从 100ms 按比例改 50ms，采样位置 25% 不变——淡出
    // Interval(0.5,1.0) 前半程已淡完、child 仍在树的窗口内）
    await tester.pumpWidget(
      wrap(expanded: true, onCheckChanged: (_) => checkCount++),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('card-collapsed')), findsOneWidget);

    // 旧勾选框中心做一次命中测试：IgnorePointer 使旧 child 子树不进 hit-test
    // 路径——不依赖叠放次序的直接证据（即使新 child 未覆盖该点，旧勾选框也拿
    // 不到事件；若 IgnorePointer 缺失，旧勾选框的 Listener 必出现在 path 中）
    final center = tester.getCenter(collapsedCheckbox);
    final HitTestResult hitResult = tester.hitTestOnBinding(center);
    final oldCheckboxRender = tester.renderObject(collapsedCheckbox);
    final inPath = hitResult.path.any((e) => e.target == oldCheckboxRender);
    // ignore: avoid_print
    print('🧪 淡出中旧勾选框中心=$center 命中路径含旧勾选框: $inPath');
    expect(inPath, isFalse);

    // 行为兜底：旧勾选框命中区内做一次 tap 也不触发旧回调（淡出期误点不归档）。
    // ⚠️ 取命中区顶缘附近而非几何中心：收起 child 包 ConstrainedBox 撑满
    // cardHeight（贴顶回归修复）后，旧勾选框中心与新展开 child 正文首行内联
    // 勾选框的命中盒纵向重叠——中心点会命中新 child 的活勾选框（属正常分流，
    // 非本测试要验证的 IgnorePointer 屏蔽），顶缘点仍落在旧命中区内且避开重叠
    final oldCheckboxRect = tester.getRect(collapsedCheckbox);
    await tester.tapAt(oldCheckboxRect.topCenter + const Offset(0, 2));
    await tester.pump();
    expect(checkCount, 1);
  });

  testWidgets('快速反向无残留：展开中途回收起，收敛后单 child 且单行排版', (tester) async {
    await tester.pumpWidget(wrap(expanded: false));
    await tester.pumpAndSettle();

    await tester.pumpWidget(wrap(expanded: true));
    // 展开进行到一半（入场 child 的淡入区间刚起步，尚在半透明途中）——
    // 200ms 的 50% 处 = 100ms（Interval(0.5,1.0) 淡入区间起点；时刻随
    // animationDuration 400→200ms（2026-09-03 恢复 945be75 节奏）从 200ms
    // 按比例改 100ms，采样位置不变）
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(wrap(expanded: false)); // 中途反向（快速连点）
    await tester.pumpAndSettle();

    // 收敛后无残留：FadeTransition 只剩外层 Switcher 当前 child 的 1 个包装
    //（展开内容及其内层正文 Switcher 已随出场动画移除），单行排版复原
    expect(cardFadeTransitions, findsOneWidget);
    expect(find.byKey(const ValueKey('card-expanded')), findsNothing);
    expect(find.byKey(const ValueKey('card-collapsed')), findsOneWidget);
    // 复用收起态断言：单行高度 < 2 行
    expect(tester.getSize(cardRichText).height, lessThan(21.0 * 2));
  });

  // ── 收起出场裁剪收卷（2026-09-03；纵向真补间重构后加几何断言）──
  // 收起方向旧展开内容不再纯淡出：FadeTransition 内包 ClipRect 收卷窗口
  //（右缘固定、与胶囊同曲线同拍收缩）+ Align(heightFactor) 纵向收卷，
  // 文字边界持续跟随胶囊 = 横纵双向收缩可见、旧文字全程画不出胶囊。
  // _CollapseWindowClipper 是卡片文件的库私有类，测试（独立 library）断言
  // 不了其字段——本测试做行为级断言：a) 收卷 ClipRect 存在且包着
  // card-expanded 子树；b) 出场动画期间（50/100ms）持续在树、settle 后
  // 随旧 child 一起移除；c) 每帧几何不变量 ClipRect 窗口 ⊆ 胶囊色块
  //（bottom/right 断言——文字出界闪烁的矩形级回归证据）+ 窗口高度
  // t=50ms 精确收卷 25%（横向宽度的逐帧数值断言由
  // overlay_card_list_follow_test 的色块宽度链覆盖，同曲线驱动）
  testWidgets('收起出场裁剪收卷：旧内容被收卷窗口约束，窗口随动画收窄', (tester) async {
    // 收卷 ClipRect 定位：card-expanded 的祖先中"带 clipper"的 ClipRect——
    // 实测此链上有 2 个 ClipRect（另一个是 MaterialApp/ListView 层无 clipper
    // 的系统裁剪），按 clipper 非空过滤后唯一（card-collapsed 分支无 ClipRect）
    final rollingClip = find.ancestor(
      of: find.byKey(const ValueKey('card-expanded')),
      matching: find.byWidgetPredicate(
        (w) => w is ClipRect && w.clipper != null,
      ),
    );
    // 胶囊色块本体：按 decoration 背景色定位主 AnimatedContainer（复选框也是
    // AnimatedContainer 但圆形白/透明底，按默认色 #6F9AF0 过滤保唯一——
    // 先例 overlay_card_list_follow_test 的 block2）
    final capsuleBlock = find.descendant(
      of: find.byType(OverlayDiaryCard),
      matching: find.byWidgetPredicate(
        (w) =>
            w is AnimatedContainer &&
            (w.decoration as BoxDecoration?)?.color == const Color(0xFF6F9AF0),
      ),
    );
    // 每帧不变量：旧内容绘制区 ⊆ ClipRect 窗口 ⊆ Stack 边界 ⊆ 胶囊内。
    // 窗口锚定 topRight、胶囊右缘对齐，只须断言 bottom/right 两侧不外溢
    //（+0.5 容差兜浮点尾差）
    void expectClipInsideCapsule(String when) {
      final clipRect = tester.getRect(rollingClip);
      final capsuleRect = tester.getRect(capsuleBlock);
      // ignore: avoid_print
      print('🧪 收卷窗口@$when: clip=$clipRect 胶囊=$capsuleRect');
      expect(clipRect.bottom, lessThanOrEqualTo(capsuleRect.bottom + 0.5));
      expect(clipRect.right, lessThanOrEqualTo(capsuleRect.right + 0.5));
    }

    await tester.pumpWidget(wrap(expanded: true));
    await tester.pumpAndSettle();
    // 展开静止态：card-expanded 是当前 child，transitionBuilder 同样生效，
    // 完成态 progress=1 → 窗口=全内容尺寸（无实际裁剪），ClipRect 恒在
    expect(rollingClip, findsOneWidget);
    final expandedClipH = tester.getSize(rollingClip).height;

    await tester.pumpWidget(wrap(expanded: false)); // 切收起，不 settle
    expect(find.byKey(const ValueKey('card-expanded')), findsOneWidget);
    expectClipInsideCapsule('t=0ms');

    await tester.pump(const Duration(milliseconds: 50));
    // 出场进行中：旧 child 与收卷窗口同在（cardResizeCurve = linear，
    // 此刻窗口开度 = 1 - 0.25 = 75%，仍在从左往右收卷中；时刻随
    // animationDuration 400→200ms 从 100ms 按比例改 50ms，采样位置 25% 不变）
    expect(find.byKey(const ValueKey('card-expanded')), findsOneWidget);
    expect(rollingClip, findsOneWidget);
    expectClipInsideCapsule('t=50ms');
    // 窗口高度线性断言：t=50ms（25% 处）应精确收卷总量（展开高→46）的 25%。
    // 容差 ±3.5dp 兜 estH 过估偏置对 heightFactor 中段速率的影响（同
    //"收起纵向匀速收缩"测试）；旧"淡出占位"实现此刻窗口仍全高（偏差 >30dp）
    final clipH50 = tester.getSize(rollingClip).height;
    expect(
      clipH50,
      closeTo(expandedClipH - (expandedClipH - 46.0) * 0.25, 3.5),
    );

    await tester.pump(const Duration(milliseconds: 50));
    // t=100ms（时间轴 50% 处）：开度 1 - 0.5 = 50%，窗口已收过半
    expect(find.byKey(const ValueKey('card-expanded')), findsOneWidget);
    expect(rollingClip, findsOneWidget);
    expectClipInsideCapsule('t=100ms');

    await tester.pumpAndSettle();
    // 出场动画 dismissed：旧 child 连同其收卷窗口一起移除
    expect(find.byKey(const ValueKey('card-expanded')), findsNothing);
    expect(rollingClip, findsNothing);
  });

  // 展开方向镜像（与收起共用同一 transitionBuilder 包装，入场 forward 分支
  // progress = cardResizeCurve.transform(value)）：heightFactor 从 minFactor
  //（46/estH）起随 progress 线性放大。入场初段贡献高略低于 46 时被 Stack 的
  // max(46,…) 钳位（膝点区，长文本卡仅 ~3ms），容差放宽到 4.0dp（收起侧 3.5）
  testWidgets('展开纵向匀速：t=50/100ms 高度精确增长总量的 25%/50%', (tester) async {
    await tester.pumpWidget(wrap(expanded: false));
    await tester.pumpAndSettle();
    final collapsedHeight = tester
        .getSize(find.byType(OverlayDiaryCard))
        .height;
    // ignore: avoid_print
    print('🧪 收起态整卡高(含margin): $collapsedHeight');

    await tester.pumpWidget(wrap(expanded: true)); // 切展开，不 settle
    await tester.pump(const Duration(milliseconds: 50));
    final h50 = tester.getSize(find.byType(OverlayDiaryCard)).height;
    await tester.pump(const Duration(milliseconds: 50));
    final h100 = tester.getSize(find.byType(OverlayDiaryCard)).height;
    // ignore: avoid_print
    print('🧪 展开 50/100ms 整卡高(含margin): $h50 / $h100');

    await tester.pumpAndSettle();
    final expandedHeight = tester.getSize(find.byType(OverlayDiaryCard)).height;
    // ignore: avoid_print
    print('🧪 展开收敛后整卡高(含margin): $expandedHeight');

    // t=50/100ms = 时间轴 25%/50% 处，linear 下应精确增长总量的 25%/50%。
    // 区分度：旧"淡出占位"实现此刻高度仍压在收起态（偏差 >30dp）
    final totalGrow = expandedHeight - collapsedHeight;
    expect(h50 - collapsedHeight, closeTo(totalGrow * 0.25, 4.0));
    expect(h100 - collapsedHeight, closeTo(totalGrow * 0.50, 4.0));
  });

  // ── 标注（标签换色）──
  // 查看态底条末尾新增标注入口（label_outline）；标注选择态底行整行替换为
  //「❗ ⭐ 💡 ✗返回」（对齐删除确认态先例）；取色：无标注=固定默认色
  // #6F9AF0，标注=整卡换标注色，归档恒灰

  Widget wrapTag({
    String? tag,
    bool isArchived = false,
    bool isTagPicking = false,
    VoidCallback? onTagEntry,
    ValueChanged<String?>? onTagToggle,
    VoidCallback? onTagPickCancel,
  }) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 296,
        child: ListView(
          children: [
            OverlayDiaryCard(
              diary: {
                'id': 1,
                'content': '标注测试',
                'is_archived': isArchived ? 1 : 0,
                'tag': tag,
              },
              maxWidth: 268,
              expanded: true,
              onCheckChanged: (_) {},
              isTagPicking: isTagPicking,
              onTagEntry: onTagEntry ?? () {},
              onTagToggle: onTagToggle ?? (_) {},
              onTagPickCancel: onTagPickCancel ?? () {},
            ),
          ],
        ),
      ),
    ),
  );

  // 卡片外框 AnimatedContainer 的背景色（按 decoration 颜色定位——复选框也是
  // AnimatedContainer，按颜色值区分保唯一）
  Color? cardBgColor(WidgetTester tester, Color target) {
    final found = find.byWidgetPredicate(
      (w) =>
          w is AnimatedContainer &&
          (w.decoration as BoxDecoration?)?.color == target,
    );
    return found.evaluate().isEmpty
        ? null
        : (tester.widget<AnimatedContainer>(found).decoration as BoxDecoration)
              .color;
  }

  testWidgets('取色：无标注=默认色 #6F9AF0，标注=标注色，归档恒灰', (tester) async {
    await tester.pumpWidget(wrapTag());
    await tester.pumpAndSettle();
    expect(cardBgColor(tester, const Color(0xFF6F9AF0)), isNotNull);

    await tester.pumpWidget(wrapTag(tag: 'star'));
    await tester.pumpAndSettle();
    expect(cardBgColor(tester, const Color(0xFFFEA545)), isNotNull);

    // 归档卡允许标注入库，但视觉仍固定灰（恢复后才显示标注色）
    await tester.pumpWidget(wrapTag(tag: 'urgent', isArchived: true));
    await tester.pumpAndSettle();
    expect(cardBgColor(tester, const Color(0xFFFF6B6B)), isNull);
  });

  testWidgets('查看态底条含标注入口，点击进入标注选择态回调', (tester) async {
    var entryCount = 0;
    await tester.pumpWidget(wrapTag(onTagEntry: () => entryCount++));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.label_outline));
    await tester.pump();
    expect(entryCount, 1);
  });

  testWidgets('标注选择态：底行整行替换，点 tag / 点已选 tag / 点 ✗ 三分支', (tester) async {
    final toggled = <String?>[];
    var cancelCount = 0;
    await tester.pumpWidget(
      wrapTag(
        isTagPicking: true,
        onTagToggle: toggled.add,
        onTagPickCancel: () => cancelCount++,
      ),
    );
    await tester.pumpAndSettle();

    // 整行替换：标注行 4 图标出现，查看态的复制/标注入口不再渲染
    expect(find.byIcon(Icons.priority_high), findsOneWidget);
    expect(find.byIcon(Icons.star_rounded), findsOneWidget);
    expect(find.byIcon(Icons.lightbulb_outline), findsOneWidget);
    expect(find.byIcon(Icons.label_outline), findsNothing);
    expect(find.byIcon(Icons.copy), findsNothing);

    // 点收藏 → 回调 'star'
    await tester.tap(find.byIcon(Icons.star_rounded));
    await tester.pump();
    expect(toggled, ['star']);

    // 已选中 star 时再点 = 取消标注（回调 null）
    await tester.pumpWidget(
      wrapTag(
        tag: 'star',
        isTagPicking: true,
        onTagToggle: toggled.add,
        onTagPickCancel: () => cancelCount++,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.star_rounded));
    await tester.pump();
    expect(toggled, ['star', null]);

    // 点 ✗ → 退出标注选择态
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(cancelCount, 1);
  });

  // 系统字体放大时展开态勾选框变大根治（2026-09-05，真机截图实测两态直径比
  // ~1.28）：WidgetSpan 子项会被框架按系统字体缩放整体放大（widget_span.dart
  // _RenderScaledInlineWidget，scale = textScaler.scale(正文字号)/字号），悬浮窗
  // 引擎又跟随系统字体缩放——勾选框画 20dp 被放大成 ~26dp，比收起态（普通
  // Row 子项，不参与文字缩放）大一圈。修法 = 展开态内部显式尺寸除以倍率，
  // 经框架放大后还原设计 dp。本测试在倍率 1.3 下验证：
  // ① 布局尺寸 = 20/1.3（补偿已生效，未补偿则布局就是 20、放大后 26）；
  // ② 布局尺寸 × 框架 paint transform 对角缩放 = 20dp 最终渲染；
  // ③ 同倍率收起态视觉圆 = 20dp，两态一致（用户诉求：展开不比收起大）
  testWidgets('系统字体放大 1.3 时展开态勾选框仍渲染 20dp（WidgetSpan 反缩放补偿）', (
    tester,
  ) async {
    Widget scaledWrap({required bool expanded}) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 296,
              child: ListView(
                children: [
                  // MediaQuery 直接包卡片：textScalerOf 精确命中本测试值，
                  // 不受 MaterialApp 自建 MediaQuery 干扰
                  MediaQuery(
                    data: const MediaQueryData(
                      textScaler: TextScaler.linear(1.3),
                    ),
                    child: OverlayDiaryCard(
                      diary: {'id': 1, 'content': longText, 'is_archived': 0},
                      maxWidth: 268,
                      expanded: expanded,
                      onCheckChanged: (_) {},
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

    // 视觉圆定位：卡片内唯一的 BoxShape.circle AnimatedContainer
    //（勾选框；播放钮/标注钮是普通 Container 且查看态不渲染）
    final circle = find.byWidgetPredicate(
      (w) =>
          w is AnimatedContainer &&
          (w.decoration as BoxDecoration?)?.shape == BoxShape.circle,
    );

    // 展开态：勾选框在正文 WidgetSpan 内
    await tester.pumpWidget(scaledWrap(expanded: true));
    await tester.pumpAndSettle();
    expect(circle, findsOneWidget);
    // ① 内部尺寸已除以倍率：布局尺寸 = 20/1.3 ≈ 15.38
    final circleLayoutWidth = tester.getSize(circle).width;
    // ignore: avoid_print
    print('🧪 字体 1.3 展开态勾选框布局宽: $circleLayoutWidth');
    expect(circleLayoutWidth, closeTo(20 / 1.3, 0.01));
    // ② 最终渲染尺寸：合成到正文 RichText 的 paint transform（_RenderScaled
    //    InlineWidget.applyPaintTransform 的对角缩放）× 布局尺寸 = 20dp
    final transform = tester
        .renderObject(circle)
        .getTransformTo(tester.renderObject(cardRichText));
    final paintedWidth = circleLayoutWidth * transform.storage[0];
    // ignore: avoid_print
    print(
      '🧪 字体 1.3 展开态勾选框最终渲染宽: $paintedWidth（缩放 ${transform.storage[0]}）',
    );
    expect(paintedWidth, closeTo(20.0, 0.01));

    // ③ 同倍率收起态：普通 Row 子项不缩放，视觉圆就是 20dp——与展开态一致
    await tester.pumpWidget(scaledWrap(expanded: false));
    await tester.pumpAndSettle();
    expect(circle, findsOneWidget);
    final collapsedCircleWidth = tester.getSize(circle).width;
    // ignore: avoid_print
    print('🧪 字体 1.3 收起态勾选框视觉圆: $collapsedCircleWidth');
    expect(collapsedCircleWidth, closeTo(20.0, 0.01));
    expect(paintedWidth, collapsedCircleWidth);
  });

  // ── Top7：收起卡文字宽度测量缓存 ──

  test('测量缓存：同 (文本, textScaler, fontFamily) 只 shaping 一次', () {
    final w1 = OverlayDiaryCard.measureCollapsedTextWidthForTest(
      '同一段收起文字', TextScaler.noScaling, null,
    );
    final c1 = OverlayDiaryCard.collapsedTextMeasureCount;
    final w2 = OverlayDiaryCard.measureCollapsedTextWidthForTest(
      '同一段收起文字', TextScaler.noScaling, null,
    );
    expect(w2, w1, reason: '命中缓存返回同一数值');
    expect(OverlayDiaryCard.collapsedTextMeasureCount, c1,
        reason: '缓存命中不再执行 TextPainter.layout');

    // 任一环境因子变化 → 新 key → 重新测量
    final w3 = OverlayDiaryCard.measureCollapsedTextWidthForTest(
      '同一段收起文字', TextScaler.linear(1.3), null,
    );
    expect(OverlayDiaryCard.collapsedTextMeasureCount, c1 + 1);
    expect(w3, greaterThan(w1), reason: '放大倍率下测量值变大');
    OverlayDiaryCard.measureCollapsedTextWidthForTest(
      '另一段文字', TextScaler.noScaling, null,
    );
    expect(OverlayDiaryCard.collapsedTextMeasureCount, c1 + 2);
  });

  testWidgets('重建命中缓存：卡片重复 build 不重复 shaping', (tester) async {
    await tester.pumpWidget(wrap(expanded: false));
    await tester.pumpAndSettle();
    final countAfterFirstBuild = OverlayDiaryCard.collapsedTextMeasureCount;
    expect(countAfterFirstBuild, greaterThan(0), reason: '首次 build 至少测量一次');

    // 模拟面板宽度补间/父层 setState 引发的重复 build——同内容输入不变
    for (var i = 0; i < 3; i++) {
      await tester.pumpWidget(wrap(expanded: false));
      await tester.pumpAndSettle();
    }
    expect(OverlayDiaryCard.collapsedTextMeasureCount, countAfterFirstBuild,
        reason: '重复 build 命中缓存，零新增 shaping');
  });
}
