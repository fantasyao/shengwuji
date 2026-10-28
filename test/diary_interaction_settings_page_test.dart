import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/settings/diary_interaction_settings_page.dart';
import 'package:shengwuji_app/theme/app_theme.dart';
import 'package:shengwuji_app/utils/note_lock_settings.dart';

/// 「日记智能与交互」二级页回归（2026-10-22）：四个开关渲染、默认值、
/// 各开关写对应 prefs key；关闭笔记锁定同时 bump 跨 engine 变更计数。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemes.defaultTheme.toThemeData(),
        home: const DiaryInteractionSettingsPage(),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('渲染四个开关与分组标题', (tester) async {
    await pumpPage(tester);

    expect(find.text('隐私'), findsOneWidget);
    expect(find.text('智能识别与交互'), findsOneWidget);
    expect(find.text('笔记锁定'), findsOneWidget);
    expect(find.text('日记智能识别物品'), findsOneWidget);
    expect(find.text('日记智能查询物品位置'), findsOneWidget);
    expect(find.text('交换单击与双击'), findsOneWidget);
    expect(find.byType(Switch), findsNWidgets(4));
  });

  testWidgets('默认值：锁定/识别/查询开，点击交换关', (tester) async {
    await pumpPage(tester);

    final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switches[0].value, isTrue);
    expect(switches[1].value, isTrue);
    expect(switches[2].value, isTrue);
    expect(switches[3].value, isFalse);
  });

  testWidgets('切换交换单击与双击写历史 prefs key', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byType(Switch).at(3));
    await tester.pump();
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('diary_card_swap_tap_longpress'), isTrue);
  });

  testWidgets('关闭笔记锁定写 prefs 并 bump 悬浮窗同步计数', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byType(Switch).at(0));
    await tester.pump();
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(NoteLockSettings.enabledKey), isFalse);
    expect(prefs.getInt('diary_change_counter'), 1);
  });

  testWidgets('智能识别与查询开关写对应 prefs key', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byType(Switch).at(1));
    await tester.pump();
    await tester.tap(find.byType(Switch).at(2));
    await tester.pump();
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('diary_item_transfer_enabled'), isFalse);
    expect(prefs.getBool('diary_query_answer_enabled'), isFalse);
  });
}
