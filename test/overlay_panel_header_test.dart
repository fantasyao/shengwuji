import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/overlay/widgets/overlay_panel_header.dart';
import 'package:shengwuji_app/theme/app_theme.dart';

/// 悬浮窗面板 header 深色半透明工具条回归（2026-09-13 跨背景可读性改造：
/// 主题浅灰图标裸放在白色背景的应用上看不清，改黑 72% 底 + 白图标——与
/// 录音胶囊/停止提示胶囊同视觉家族）。单测只锁组件层契约：按钮渲染条件、
/// 回调接线、家族配色、停靠侧镜像；OverlayHome 集成层不单测
///（同 overlay_card_alarm_button_test 的取舍）
void main() {
  // 家族配色真值：与组件实现同表达式（黑 72% 半透明底）
  final familyColor = Colors.black.withValues(alpha: 0.72);

  Future<void> pumpBar(
    WidgetTester tester, {
    bool dockLeft = false,
    bool diariesNotEmpty = true,
    bool allExpanded = false,
    ThemeData? theme,
    VoidCallback? onNewNote,
    VoidCallback? onSaveClipboard,
    VoidCallback? onToggleExpandAll,
    VoidCallback? onOpenDiaryPage,
    VoidCallback? onStartVoiceMemo,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? AppThemes.defaultTeal.toThemeData(),
        home: Scaffold(
          body: OverlayPanelHeader(
            dockLeft: dockLeft,
            diariesNotEmpty: diariesNotEmpty,
            allExpanded: allExpanded,
            onNewNote: onNewNote ?? () {},
            onSaveClipboard: onSaveClipboard ?? () {},
            onToggleExpandAll: onToggleExpandAll ?? () {},
            onOpenDiaryPage: onOpenDiaryPage ?? () {},
            onStartVoiceMemo: onStartVoiceMemo ?? () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 工具条本体的深色底 Container（组件树里唯一带非空 color 装饰的
  /// Container——IconButton 内部的容器装饰均无此色）
  Container barContainer(WidgetTester tester) {
    return tester
        .widgetList<Container>(
          find.byWidgetPredicate(
            (w) =>
                w is Container &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).color != null,
          ),
        )
        .first;
  }

  /// 工具条的贴停靠缘 Align：深色底 Container 的最近 Align 祖先（其直接
  /// 父级）。不用 find.descendant(of: OverlayPanelHeader)——IconButton/
  /// Tooltip 内部也有 Align，会命中多个
  Align barAlign(WidgetTester tester) {
    return tester
        .element(
          find.byWidgetPredicate(
            (w) =>
                w is Container &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).color != null,
          ),
        )
        .findAncestorWidgetOfExactType<Align>()!;
  }

  testWidgets('默认（右缘停靠 + 非空列表）：5 按钮渲染，黑 72% 底 + 全白图标', (tester) async {
    await pumpBar(tester);
    expect(find.byIcon(Icons.add), findsOneWidget);
    // 2026-10-27：新增右侧的「剪贴板存为笔记」
    expect(find.byIcon(Icons.content_paste), findsOneWidget);
    expect(find.byIcon(Icons.unfold_more), findsOneWidget);
    expect(find.byIcon(Icons.book), findsOneWidget);
    // 末位 = 语音速记录音按钮（2026-10-19 起替代原收起 chevron）
    expect(find.byIcon(Icons.mic), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    // 家族配色：黑 72% 半透明底（跨背景对比度的根）+ 图标全白
    expect(barContainer(tester).decoration, isA<BoxDecoration>());
    final decoration = barContainer(tester).decoration! as BoxDecoration;
    expect(decoration.color, familyColor);
    expect(tester.widget<Icon>(find.byIcon(Icons.add)).color, Colors.white);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.content_paste)).color,
      Colors.white,
    );
    expect(tester.widget<Icon>(find.byIcon(Icons.book)).color, Colors.white);
    expect(tester.widget<Icon>(find.byIcon(Icons.mic)).color, Colors.white);
  });

  testWidgets('按钮顺序：新增 → 剪贴板 → 全部展开 → 打开随手记 → 语音速记', (tester) async {
    await pumpBar(tester);
    final addX = tester.getCenter(find.byIcon(Icons.add)).dx;
    final pasteX = tester.getCenter(find.byIcon(Icons.content_paste)).dx;
    final expandX = tester.getCenter(find.byIcon(Icons.unfold_more)).dx;
    final bookX = tester.getCenter(find.byIcon(Icons.book)).dx;
    final micX = tester.getCenter(find.byIcon(Icons.mic)).dx;
    expect(addX, lessThan(pasteX));
    expect(pasteX, lessThan(expandX));
    expect(expandX, lessThan(bookX));
    expect(bookX, lessThan(micX));
  });

  testWidgets('空列表：不渲染全部展开按钮，其余 4 个保留（历史行为）', (tester) async {
    await pumpBar(tester, diariesNotEmpty: false);
    expect(find.byIcon(Icons.unfold_more), findsNothing);
    expect(find.byIcon(Icons.unfold_less), findsNothing);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byIcon(Icons.content_paste), findsOneWidget);
    expect(find.byIcon(Icons.book), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsOneWidget);
  });

  testWidgets('点击接线：五个回调各自触发', (tester) async {
    var newNote = false;
    var saveClipboard = false;
    var toggleAll = false;
    var openDiary = false;
    var record = false;
    await pumpBar(
      tester,
      onNewNote: () => newNote = true,
      onSaveClipboard: () => saveClipboard = true,
      onToggleExpandAll: () => toggleAll = true,
      onOpenDiaryPage: () => openDiary = true,
      onStartVoiceMemo: () => record = true,
    );
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(newNote, true);
    await tester.tap(find.byIcon(Icons.content_paste));
    await tester.pumpAndSettle();
    expect(saveClipboard, true);
    await tester.tap(find.byIcon(Icons.unfold_more));
    await tester.pumpAndSettle();
    expect(toggleAll, true);
    await tester.tap(find.byIcon(Icons.book));
    await tester.pumpAndSettle();
    expect(openDiary, true);
    await tester.tap(find.byIcon(Icons.mic));
    await tester.pumpAndSettle();
    expect(record, true);
  });

  testWidgets('全部展开态：图标切 unfold_less，tooltip 切「全部收起」', (tester) async {
    await pumpBar(tester, allExpanded: true);
    expect(find.byIcon(Icons.unfold_less), findsOneWidget);
    expect(find.byIcon(Icons.unfold_more), findsNothing);
    expect(find.byTooltip('全部收起'), findsOneWidget);
  });

  testWidgets('停靠右缘：贴右对齐、阴影朝屏幕内侧（-x）', (tester) async {
    await pumpBar(tester, dockLeft: false);
    expect(barAlign(tester).alignment, Alignment.centerRight);
    final shadow =
        (barContainer(tester).decoration! as BoxDecoration).boxShadow!;
    expect(shadow.first.offset.dx, -2);
  });

  testWidgets('停靠左缘镜像：贴左对齐、阴影朝屏幕内侧（+x）', (tester) async {
    await pumpBar(tester, dockLeft: true);
    expect(barAlign(tester).alignment, Alignment.centerLeft);
    final shadow =
        (barContainer(tester).decoration! as BoxDecoration).boxShadow!;
    expect(shadow.first.offset.dx, 2);
  });
}
