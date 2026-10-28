import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/theme/app_theme.dart';
import 'package:shengwuji_app/widgets/checklist_widget.dart';

/// ChecklistWidget 长清单折叠（maxItems）：折叠态只渲染前 N 条，
/// 折叠判定（itemCount）与渲染同源。日记卡片超过 5 条默认折叠。
void main() {
  const content6 = '- [ ] 牛奶\n- [ ] 面包\n- [x] 鸡蛋\n- [ ] 苹果\n- [ ] 香蕉\n- [ ] 橙子';

  Future<void> pumpChecklist(
    WidgetTester tester, {
    required String content,
    int? maxItems,
    void Function(int)? onToggle,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        // AppThemeExtension.of 经 Theme.extension 解析，必须挂应用主题
        theme: AppThemes.defaultTheme.toThemeData(),
        home: Scaffold(
          body: ChecklistWidget(
            content: content,
            onToggle: onToggle ?? (_) {},
            maxItems: maxItems,
          ),
        ),
      ),
    );
  }

  testWidgets('itemCount 只统计清单行', (tester) async {
    expect(ChecklistWidget.itemCount(content6), 6);
    expect(ChecklistWidget.itemCount('- [ ] 牛奶\n普通文本行\n- [x] 鸡蛋'), 2);
    expect(ChecklistWidget.itemCount('没有清单'), 0);
  });

  testWidgets('不传 maxItems 渲染全部条目', (tester) async {
    await pumpChecklist(tester, content: content6);
    expect(find.text('橙子'), findsOneWidget);
    expect(find.text('牛奶'), findsOneWidget);
  });

  testWidgets('maxItems=5 只渲染前 5 条（第 6 条不进树）', (tester) async {
    await pumpChecklist(tester, content: content6, maxItems: 5);
    expect(find.text('香蕉'), findsOneWidget); // 第 5 条仍在
    expect(find.text('橙子'), findsNothing); // 第 6 条被折叠
  });

  testWidgets('折叠态勾选回调仍带原始行索引', (tester) async {
    int? toggled;
    await pumpChecklist(
      tester,
      content: content6,
      maxItems: 5,
      onToggle: (i) => toggled = i,
    );
    await tester.tap(find.text('面包')); // 第 2 条，原始行索引 1
    expect(toggled, 1);
  });
}
