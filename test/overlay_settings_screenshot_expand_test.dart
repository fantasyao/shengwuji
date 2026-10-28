// 悬浮窗设置页「截图附件」开关回归（2026-10-21）：
// - 「截图后展开笔记卡片」默认关（历史行为：截图成功只 Toast、保持收起）
// - 点开写 prefs overlay_screenshot_expand_card（overlay engine 收尾现场 reload 读）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/overlay/overlay_constants.dart';
import 'package:shengwuji_app/settings/overlay_settings_page.dart';
import 'package:shengwuji_app/theme/app_theme.dart';
import 'package:shengwuji_app/utils/pro_gate.dart';

void main() {
  setUp(() {
    // 页面 initState 读 prefs，且开关点击走 Pro 门禁：永久解锁 = 布尔 + 授权码
    SharedPreferences.setMockInitialValues({
      ProGate.kKeyIsProUnlocked: true,
      ProGate.kKeyLicenseCode: 'TESTCODE12345678',
    });
  });

  testWidgets('截图后展开笔记卡片：默认关，点开写 prefs 并即时切换', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemes.defaultTheme.toThemeData(),
        home: const OverlaySettingsPage(),
      ),
    );
    await tester.pump();
    await tester.pump();

    final title = find.text('截图后展开笔记卡片');
    await tester.scrollUntilVisible(
      title,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    final tile = find.ancestor(
      of: title,
      matching: find.byType(SwitchListTile),
    );
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);

    await tester.tap(title);
    await tester.pump();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(OverlayConstants.screenshotExpandCardPrefKey), isTrue);
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);

    // 再点回去：写 false，恢复历史行为
    await tester.tap(title);
    await tester.pump();
    expect(prefs.getBool(OverlayConstants.screenshotExpandCardPrefKey), isFalse);
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
  });
}
