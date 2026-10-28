import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/main.dart';
import 'package:shengwuji_app/settings/appearance_settings_page.dart';
import 'package:shengwuji_app/settings/tag_style_settings_page.dart';
import 'package:shengwuji_app/theme/app_font.dart';
import 'package:shengwuji_app/theme/app_theme.dart';

/// 「外观」二级页回归（2026-10-22）：主题/深色模式/图标/字号/字体五行走 chips
/// 与 prefs 写入，「标签外观」入口可进原二级页。
/// AppRoot 的 notifier 是全局静态值，每个用例前后显式复位，避免串场。
void main() {
  const channel = MethodChannel('com.shengwuji.app/app');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getCurrentIconPack':
          return 'default';
        case 'setIconPack':
          return true;
      }
      return null;
    });
    AppRoot.themeNotifier.value = AppThemes.defaultTheme;
    AppRoot.themeModeNotifier.value = ThemeMode.system;
    AppRoot.fontScaleNotifier.value = 1.0;
    AppRoot.fontChoiceNotifier.value = kDefaultAppFontChoice;
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    AppRoot.themeNotifier.value = AppThemes.defaultTheme;
    AppRoot.themeModeNotifier.value = ThemeMode.system;
    AppRoot.fontScaleNotifier.value = 1.0;
    AppRoot.fontChoiceNotifier.value = kDefaultAppFontChoice;
  });

  Future<void> pumpPage(WidgetTester tester) async {
    // 页面底部「标签外观」在默认 600 高测试视口外，拉高让整页进树
    tester.view.physicalSize = const Size(1080, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemes.defaultTheme.toThemeData(),
        home: const AppearanceSettingsPage(),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('渲染外观五项与标签外观入口', (tester) async {
    await pumpPage(tester);

    expect(find.text('主题'), findsOneWidget);
    expect(find.text('默认青'), findsOneWidget);
    expect(find.text('深色模式'), findsOneWidget);
    expect(find.text('图标'), findsOneWidget);
    expect(find.text('字号'), findsOneWidget);
    expect(find.text('字体'), findsOneWidget);
    expect(find.text('标签外观'), findsOneWidget);
  });

  testWidgets('深色模式点选写 prefs 并更新全局 notifier', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('深色'));
    await tester.pump();
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kThemeModePrefKey), 'dark');
    expect(AppRoot.themeModeNotifier.value, ThemeMode.dark);
  });

  testWidgets('字号点选写 prefs 并更新全局 notifier', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('大'));
    await tester.pump();
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('font_size_scale'), 1.15);
    expect(AppRoot.fontScaleNotifier.value, 1.15);
  });

  testWidgets('字体点选系统默认写 prefs 并更新全局 notifier', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('系统默认'));
    await tester.pump();
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kAppFontPrefKey), 'system');
    expect(AppRoot.fontChoiceNotifier.value, AppFontChoice.system);
  });

  testWidgets('主题选择弹层可点选预设主题并写 prefs', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('主题'));
    await tester.pumpAndSettle();
    expect(find.text('选择主题'), findsOneWidget);

    await tester.tap(find.text('暖橙'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('selected_theme'), 'warm_orange');
    expect(AppRoot.themeNotifier.value.id, 'warm_orange');
  });

  testWidgets('标签外观入口进入原有二级页', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('标签外观'));
    await tester.pumpAndSettle();

    expect(find.byType(TagStyleSettingsPage), findsOneWidget);
  });
}
