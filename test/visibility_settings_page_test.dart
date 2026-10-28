import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/settings/visibility_settings_page.dart';
import 'package:shengwuji_app/theme/app_theme.dart';
import 'package:shengwuji_app/utils/tab_visibility.dart';

/// 「眼不见为净」二级页回归（2026-10-22）：三个开关渲染、初始值来自 prefs、
/// 两个 Tab 隐藏开关写 key 并提示重启、后台隐藏写 key 并调原生通道。
void main() {
  const channel = MethodChannel('com.shengwuji.app/app');
  late List<String> channelCalls;

  setUp(() {
    channelCalls = [];
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      channelCalls.add(call.method);
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemes.defaultTheme.toThemeData(),
        home: const VisibilitySettingsPage(),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('渲染三个开关与分组标题', (tester) async {
    await pumpPage(tester);

    expect(find.text('主界面页面'), findsOneWidget);
    expect(find.text('后台'), findsOneWidget);
    expect(find.text('隐藏存物品页'), findsOneWidget);
    expect(find.text('隐藏查物品页'), findsOneWidget);
    expect(find.text('后台隐藏'), findsOneWidget);
    expect(find.byType(Switch), findsNWidgets(3));
  });

  testWidgets('初始开关状态读取 prefs', (tester) async {
    SharedPreferences.setMockInitialValues({
      prefKeyRecordTabHidden: true,
      prefKeyListTabHidden: false,
      'exclude_from_recents': true,
    });
    await pumpPage(tester);

    final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switches[0].value, isTrue);
    expect(switches[1].value, isFalse);
    expect(switches[2].value, isTrue);
  });

  testWidgets('切换隐藏存物品页写 prefs 并提示重启生效', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byType(Switch).at(0));
    await tester.pump();
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(prefKeyRecordTabHidden), isTrue);
    expect(prefs.getBool(prefKeyListTabHidden), isFalse);
    expect(find.text('已保存，重启 App 后生效'), findsOneWidget);
  });

  testWidgets('切换后台隐藏写 prefs 并调用原生通道', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byType(Switch).at(2));
    await tester.pump();
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('exclude_from_recents'), isTrue);
    expect(channelCalls, contains('setExcludeFromRecents'));
  });
}
