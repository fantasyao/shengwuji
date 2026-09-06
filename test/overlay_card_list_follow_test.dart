import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/overlay/widgets/overlay_diary_card.dart';

/// 诊断性测试（2026-09-02 建；2026-09-03 恢复 945be75 补间结构后重写基线；
/// 同日纵向真补间重构后再重写）：悬浮窗日记卡片收起动画期间，ListView 里
/// 后续卡片（下方位卡）的位置是**逐帧实时跟随**（每收一点、后面实时贴一
/// 点），还是**等动画结束才动**（用户真机观感："等收起完才紧赶慢赶往上赶"）。
///
/// 方法：3 张卡放在 ListView，第 2 张从展开切收起，不 settle 逐帧采样
/// 第 3 张卡的 top + 第 2 张卡的胶囊宽/整卡高。
///
/// 纵向真补间重构后，宽/高/top 是**同源同拍的单链**（200ms linear，结构与
/// 动机见 overlay_diary_card 的 AnimatedContainer 大注释）：
/// - 横向补间源 = 色块本体（AnimatedContainer）的 constraints.maxWidth 布局
///   渐变（maxWidth prop ↔ _estimateCollapsedWidth）
/// - 纵向补间源 = transitionBuilder 内 Align(heightFactor: lerp(46/estH, 1,
///   progress)) + padding.vertical 10↔0——Stack 高度随 progress 线性变化，
///   下方卡片经 ListView 每帧 relayout 逐帧贴上
/// → t=50/100/150ms 宽/高/top 均应精确收缩总量的 25%/50%/75%
///
/// ⚠️ 历史误诊警示：本文件旧版（046fe0b）按"宽度链 linear / 高度链
/// AnimatedSize 追赶式前快后慢"两链不同拍建模——"追赶式"是对
/// RenderAnimatedSize 的误诊（child 尺寸第二次变化即吸附透传，补间失效），
/// 实际纵向是"90% 变化一帧完成"的跳变。外层 AnimatedSize 已随重构移除，
/// 采样点只剩色块本体（print 对照列同步改用色块值）。
///
/// ⚠️ 宽度采样点 = 胶囊色块本体：按 decoration 背景色定位主 AnimatedContainer
///（卡片内 _buildCheckbox/_buildPlayButton 处还有别的 AnimatedContainer，
/// 复选框的是圆形白/透明底，按默认色 #6F9AF0 过滤保唯一）。卡片根 widget
///（OverlayDiaryCard）在 ListView 里被列表约束拉满 296dp 恒定——量整卡宽
/// 永远 296 量不到收缩。
///
/// 诊断价值（无论哪边）：
/// - "实时跟"成立 → 布局层没问题，真机滞后另有原因（面板层/掉帧等）
/// - 滞后成立 → 找到根因，后续修法完全不同
///
/// 本文件只新增测试、不改 lib；数据本身就是结论，断言失败如实保留。
void main() {
  // 第 2 卡（动画主角）用短文本：长文本卡两态都顶满 maxWidth（展开内容撑满 /
  // 收起态单行省略想要的宽 > 上限），本测试无面板层（真机长文本的横向收缩
  // 来自面板宽 0.92W→0.72W 约束补间，在 overlay_home 层），宽度差恒 0 测不到；
  // 短文本收起胶囊随内容收窄——实测胶囊（含 margin）296 → 161.75（settle
  // 终值 = 实际内容宽；补间终点 = _estimateCollapsedWidth 估算 132+4dp 度量
  // 余量 + margin 28 ≈ 165.75，尾部 ~3.25dp 落差由容差吸收，总收缩 134.25dp
  // ≥ 40dp 稳健线），断言稳。纵向大收缩量
  //（222→56）的时序断言由 overlay_diary_card_test 的"收起纵向匀速收缩"覆盖
  //（那边单卡长文本 t=50ms 采样），本测试短文本高度差变小（132→56，总收缩
  // 76dp）但比例断言不受影响
  const shortText = '钥匙放在玄关柜';

  Widget wrap({required bool expandCard2}) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 296, // 模拟面板宽（对齐 overlay_diary_card_test 的 wrap 模式）
        child: ListView(
          // 排除默认 padding 干扰（本测试只看相对位移）
          padding: EdgeInsets.zero,
          children: [
            OverlayDiaryCard(
              key: const ValueKey('card-1'),
              diary: {'id': 1, 'content': '第一条', 'is_archived': 0},
              maxWidth: 268,
              expanded: false,
              onCheckChanged: (_) {},
            ),
            OverlayDiaryCard(
              key: const ValueKey('card-2'),
              diary: {'id': 2, 'content': shortText, 'is_archived': 0},
              maxWidth: 268,
              expanded: expandCard2,
              onCheckChanged: (_) {},
            ),
            OverlayDiaryCard(
              key: const ValueKey('card-3'),
              diary: {'id': 3, 'content': '第三条短文本', 'is_archived': 0},
              maxWidth: 268,
              expanded: false,
              onCheckChanged: (_) {},
            ),
          ],
        ),
      ),
    ),
  );

  testWidgets('收起动画期间后续卡片 top 逐帧实时跟随（诊断）', (tester) async {
    final card2 = find.byKey(const ValueKey('card-2'));
    final card3 = find.byKey(const ValueKey('card-3'));
    // 色块本体采样点（宽度链断言对象；高度链的胶囊高 = 色块高 + margin，
    // 与整卡高差恒定的 margin，断言用整卡高）：按 decoration 背景色定位主
    // AnimatedContainer——本测试卡片未标注未归档，恒默认色 #6F9AF0；
    // 复选框/播放钮处的 AnimatedContainer 无此背景色，过滤后保唯一
    //（先例：overlay_diary_card_test 的 cardBgColor 按色定位）。
    // 外层 AnimatedSize 已随纵向真补间重构移除（旧"胶囊宽"对照采样点
    // 失效），print 对照列改用色块宽
    final block2 = find.descendant(
      of: card2,
      matching: find.byWidgetPredicate(
        (w) =>
            w is AnimatedContainer &&
            (w.decoration as BoxDecoration?)?.color == const Color(0xFF6F9AF0),
      ),
    );

    await tester.pumpWidget(wrap(expandCard2: true));
    await tester.pumpAndSettle();

    final expandedBlockW = tester.getSize(block2).width;
    final expandedW = tester.getSize(block2).width;
    final expandedH = tester.getSize(card2).height;
    final top3Before = tester.getTopLeft(card3).dy;
    // ignore: avoid_print
    print(
      '🧪 [诊断] 展开稳态  : 第2卡色块宽=$expandedBlockW 胶囊宽=$expandedW 整卡高=$expandedH, 第3卡top=$top3Before',
    );

    await tester.pumpWidget(wrap(expandCard2: false)); // 切收起，不 settle
    final bw0 = tester.getSize(block2).width;
    final w0 = tester.getSize(block2).width;
    final h0 = tester.getSize(card2).height;
    final top3At0 = tester.getTopLeft(card3).dy;
    // ignore: avoid_print
    print('🧪 [诊断] t=0ms(切换帧): 第2卡色块宽=$bw0 胶囊宽=$w0 整卡高=$h0, 第3卡top=$top3At0');

    await tester.pump(const Duration(milliseconds: 50));
    final bw50 = tester.getSize(block2).width;
    final w50 = tester.getSize(block2).width;
    final h50 = tester.getSize(card2).height;
    final top3At50 = tester.getTopLeft(card3).dy;
    // ignore: avoid_print
    print('🧪 [诊断] t=50ms: 第2卡色块宽=$bw50 胶囊宽=$w50 整卡高=$h50, 第3卡top=$top3At50');

    await tester.pump(const Duration(milliseconds: 50));
    final bw100 = tester.getSize(block2).width;
    final w100 = tester.getSize(block2).width;
    final h100 = tester.getSize(card2).height;
    final top3At100 = tester.getTopLeft(card3).dy;
    // ignore: avoid_print
    print(
      '🧪 [诊断] t=100ms: 第2卡色块宽=$bw100 胶囊宽=$w100 整卡高=$h100, 第3卡top=$top3At100',
    );

    await tester.pump(const Duration(milliseconds: 50));
    final bw150 = tester.getSize(block2).width;
    final w150 = tester.getSize(block2).width;
    final h150 = tester.getSize(card2).height;
    final top3At150 = tester.getTopLeft(card3).dy;
    // ignore: avoid_print
    print(
      '🧪 [诊断] t=150ms: 第2卡色块宽=$bw150 胶囊宽=$w150 整卡高=$h150, 第3卡top=$top3At150',
    );

    await tester.pumpAndSettle();
    final settledBlockW = tester.getSize(block2).width;
    final settledW = tester.getSize(block2).width;
    final settledH = tester.getSize(card2).height;
    final top3Settled = tester.getTopLeft(card3).dy;
    // ignore: avoid_print
    print(
      '🧪 [诊断] settle  : 第2卡色块宽=$settledBlockW 胶囊宽=$settledW 整卡高=$settledH, 第3卡top=$top3Settled',
    );

    final totalShrink = expandedH - settledH;
    final totalWidthShrink = expandedBlockW - settledBlockW;
    final totalRise = top3Before - top3Settled;
    final shrink50 = expandedH - h50;
    final shrink100 = expandedH - h100;
    final shrink150 = expandedH - h150;
    final widthShrink50 = expandedBlockW - bw50;
    final widthShrink100 = expandedBlockW - bw100;
    final widthShrink150 = expandedBlockW - bw150;
    final rise50 = top3Before - top3At50;
    final rise100 = top3Before - top3At100;
    final rise150 = top3Before - top3At150;
    double pct(double v) => totalRise == 0 ? 0.0 : v / totalRise * 100;
    double wpct(double v) =>
        totalWidthShrink == 0 ? 0.0 : v / totalWidthShrink * 100;
    // ignore: avoid_print
    print(
      '🧪 [诊断] 汇总: 第2卡总收缩 高=$totalShrink 色块宽=$totalWidthShrink'
      '（50ms 色块宽${wpct(widthShrink50).toStringAsFixed(1)}%、100ms ${wpct(widthShrink100).toStringAsFixed(1)}%、150ms ${wpct(widthShrink150).toStringAsFixed(1)}%，'
      '高50ms ${(shrink50 / totalShrink * 100).toStringAsFixed(1)}%）；'
      '第3卡总上移=$totalRise（50ms=${pct(rise50).toStringAsFixed(1)}%）',
    );

    // ── 宽度链主断言（色块本体 = constraints.maxWidth 的 linear 补间）──
    // t=50/100/150ms 应精确收缩总量的 25%/50%/75%（cardResizeCurve 恢复
    // linear，animationDuration 恢复 200ms——匀速逐帧收缩"非跳变"固化进
    // 基线）。容差 3.5dp：兜两点——①帧对齐浮点尾差；②补间终点（估算宽+4dp
    // 度量余量，见 _estimateCollapsedWidth）与 settle 终值（实际内容宽）之间
    // ~3.25dp 尾部落差按进度混入各采样点（50% 处 ≈1.6dp、75% 处 ≈2.4dp）。
    // 区分度无损：easeOut 回归 50ms 处偏差 >40dp、即时结构回归（色块一步
    // 跳窄，9432813~a513ca1 病灶）t=50ms 收缩已 100%——均远超容差
    expect(widthShrink50, closeTo(totalWidthShrink * 0.25, 3.5));
    expect(widthShrink100, closeTo(totalWidthShrink * 0.50, 3.5));
    expect(widthShrink150, closeTo(totalWidthShrink * 0.75, 3.5));

    // ── 高度/top 链断言（纵向真补间重构后：与宽度链同源同拍 linear）──
    // 纵向补间源 = transitionBuilder 的 Align(heightFactor: lerp(46/estH, 1,
    // progress)) + padding 10↔0 → t=50/100/150ms 高度收缩、第 3 卡 top 上移
    // 应同样精确占总量的 25%/50%/75%。容差放宽到 4.5dp（宽于宽度链）：
    // 兜 estH 估算过估偏置（+10dp，见 _estimateExpandedHeight）对中段速率
    // 的系统性影响——贡献高终点略低于 46 被 max(46,…) 提前钳位，中段实测
    // 略快于理想线性（短文本实测 150ms 处偏差 ~3.1dp）。区分度无损：
    // 纵向一拍化回归（a36800b~046fe0b 病灶，90% 变化一帧完成）t=50ms 收缩
    // 已 ~87%（偏差 >40dp）、跳变结构下 100ms 处偏差 >20dp——均远超容差
    expect(shrink50, closeTo(totalShrink * 0.25, 4.5));
    expect(shrink100, closeTo(totalShrink * 0.50, 4.5));
    expect(shrink150, closeTo(totalShrink * 0.75, 4.5));
    expect(rise50, closeTo(totalRise * 0.25, 4.5));
    expect(rise100, closeTo(totalRise * 0.50, 4.5));
    expect(rise150, closeTo(totalRise * 0.75, 4.5));
  });
}
