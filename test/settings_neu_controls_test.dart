import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/db_helper.dart';
import 'package:shengwuji_app/main.dart';
import 'package:shengwuji_app/overlay/overlay_constants.dart';
import 'package:shengwuji_app/settings/appearance_settings_page.dart';
import 'package:shengwuji_app/settings/cloud_sync_page.dart';
import 'package:shengwuji_app/settings/overlay_settings_page.dart';
import 'package:shengwuji_app/settings/search_settings_page.dart';
import 'package:shengwuji_app/settings/settings_widgets.dart';
import 'package:shengwuji_app/settings/volume_key_settings_page.dart';
import 'package:shengwuji_app/text_processor.dart';
import 'package:shengwuji_app/theme/app_font.dart';
import 'package:shengwuji_app/theme/app_theme.dart';
import 'package:shengwuji_app/utils/big_bang_search.dart';
import 'package:shengwuji_app/utils/pro_gate.dart';
import 'package:shengwuji_app/utils/volume_gesture_config.dart';
import 'package:shengwuji_app/widgets/neu_widgets.dart';

/// 新拟物主题设置页覆盖回归（2026-10-28）
///
/// 用户实测反馈的漏网页面：WebDAV 保存/测试/同步按钮与录音开关、识别页
/// 保存热词按钮、大爆炸搜索引擎、音量键手势 chip、悬浮窗 8 组档位 chip、
/// 外观字体 chip。本测试锁两层：
/// 1. 共享分流函数 —— 拟物主题走 NeuChoiceChip / NeuPressable，其余主题
///    仍走 M3 ChoiceChip / ElevatedButton（默认主题渲染路径零变化）
/// 2. 页面级 —— 上述页面在拟物主题下确实渲染拟物控件且交互落盘
void main() {
  const channel = MethodChannel('com.shengwuji.app/app');

  setUp(() {
    SharedPreferences.setMockInitialValues({
      ProGate.kKeyIsProUnlocked: true,
      ProGate.kKeyLicenseCode: 'TESTCODE12345678',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'isAccessibilityServiceEnabled':
              return true;
            case 'getCurrentIconPack':
              return 'default';
            case 'getInstalledBrowsers':
              return const [
                {'appName': 'Chrome', 'packageName': 'com.android.chrome'},
              ];
            case 'getAppIcon':
              return null;
          }
          return null;
        });
    AppRoot.themeNotifier.value = AppThemes.neumorphism;
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

  Widget wrap(Widget home, {AppThemeDefinition? theme}) => MaterialApp(
    theme: (theme ?? AppThemes.neumorphism).toThemeData(),
    home: home,
  );

  group('共享分流函数', () {
    testWidgets('拟物主题：ChoiceChip → NeuChoiceChip（选中凹陷），点击回调', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        wrap(
          Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => buildSettingsChoiceChip(
                  context,
                  icon: Icons.search,
                  label: const Text('选项'),
                  selected: true,
                  onTap: () => tapped = true,
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(NeuChoiceChip), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.byType(NeuInset), findsOneWidget, reason: '选中态 = 凹陷胶囊');

      await tester.tap(find.text('选项'));
      expect(tapped, isTrue);
    });

    testWidgets('其余主题：仍走 M3 ChoiceChip，不出现拟物组件', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        wrap(
          Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => buildSettingsChoiceChip(
                  context,
                  icon: Icons.search,
                  label: const Text('选项'),
                  selected: true,
                  onTap: () => tapped = true,
                ),
              ),
            ),
          ),
          theme: AppThemes.defaultTheme,
        ),
      );

      expect(find.byType(ChoiceChip), findsOneWidget);
      expect(find.byType(NeuChoiceChip), findsNothing);
      expect(find.byType(NeuInset), findsNothing);

      await tester.tap(find.byType(ChoiceChip));
      expect(tapped, isTrue);
    });

    testWidgets('主按钮分流：拟物 = 同色凸起 NeuPressable + 品牌青字', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        wrap(
          Scaffold(
            body: Builder(
              builder: (context) => buildSettingsPrimaryButton(
                context,
                icon: Icons.save_rounded,
                label: '保存',
                onPressed: () => tapped = true,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(NeuPressable), findsOneWidget);
      expect(find.byType(ElevatedButton), findsNothing);
      final text = tester.widget<Text>(find.text('保存'));
      final ext = AppThemes.neumorphism.extension;
      expect(text.style?.color, ext.primaryDark);

      await tester.tap(find.text('保存'));
      expect(tapped, isTrue);
    });

    testWidgets('主按钮分流：其余主题保持 ElevatedButton', (tester) async {
      await tester.pumpWidget(
        wrap(
          Scaffold(
            body: Builder(
              builder: (context) => buildSettingsPrimaryButton(
                context,
                icon: Icons.save_rounded,
                label: '保存',
                onPressed: () {},
              ),
            ),
          ),
          theme: AppThemes.defaultTheme,
        ),
      );

      expect(find.byType(ElevatedButton), findsOneWidget);
      expect(find.byType(NeuPressable), findsNothing);
    });

    testWidgets('输入框外壳：拟物 = NeuInset；其余主题原样返回', (tester) async {
      const field = TextField();
      await tester.pumpWidget(
        wrap(
          Scaffold(
            body: Builder(
              builder: (context) =>
                  buildSettingsFieldShell(context, field: field),
            ),
          ),
        ),
      );
      expect(find.byType(NeuInset), findsOneWidget);

      await tester.pumpWidget(
        wrap(
          Scaffold(
            body: Builder(
              builder: (context) =>
                  buildSettingsFieldShell(context, field: field),
            ),
          ),
          theme: AppThemes.defaultTheme,
        ),
      );
      // MaterialApp 切主题走 AnimatedTheme：等插值结束才是真正的默认主题
      await tester.pumpAndSettle();
      expect(find.byType(NeuInset), findsNothing);
    });

    // 2026-10-28 用户真机反馈：WebDAV 输入框浮动标签压在上边框线上、被内
    // 阴影切掉半截（「文字一半在边框里」）。拟物改为标签画在凹陷外上方。
    testWidgets('输入框外壳：拟物标签画在凹陷外，不压凹陷上沿', (tester) async {
      await tester.pumpWidget(
        wrap(
          Scaffold(
            body: Center(
              child: Builder(
                builder: (context) => buildSettingsFieldShell(
                  context,
                  label: '服务器地址',
                  field: const TextField(),
                ),
              ),
            ),
          ),
        ),
      );

      final label = find.text('服务器地址');
      expect(label, findsOneWidget);
      expect(find.byType(NeuInset), findsOneWidget);
      final labelRect = tester.getRect(label);
      final insetRect = tester.getRect(find.byType(NeuInset));
      expect(
        labelRect.bottom,
        lessThanOrEqualTo(insetRect.top),
        reason: '标签整体落在凹陷上沿之外，否则会被内阴影切掉下半截',
      );
    });

    testWidgets('输入框外壳：其余主题不额外画标签（仍走 labelText 浮动）', (tester) async {
      await tester.pumpWidget(
        wrap(
          Scaffold(
            body: Builder(
              builder: (context) => buildSettingsFieldShell(
                context,
                label: '服务器地址',
                field: const TextField(
                  decoration: InputDecoration(labelText: '服务器地址'),
                ),
              ),
            ),
          ),
          theme: AppThemes.defaultTheme,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(NeuInset), findsNothing);
      // 唯一一份标签来自 M3 浮动标签，外壳没有重复渲染
      expect(find.text('服务器地址'), findsOneWidget);
    });
  });

  group('页面级覆盖（新拟物主题）', () {
    testWidgets('云端同步：4 个输入框标签在凹陷外、无浮动标签', (tester) async {
      // CloudSyncConfig.load 读密码走 flutter_secure_storage，测试里给空值
      const storageChannel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(storageChannel, (call) async => null);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(storageChannel, null),
      );
      tester.view.physicalSize = const Size(1080, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        wrap(CloudSyncPage(processor: TextProcessor(), dbHelper: DbHelper())),
      );
      await tester.pumpAndSettle();

      expect(find.byType(NeuInset), findsNWidgets(4));
      for (final field in tester.widgetList<TextField>(
        find.byType(TextField),
      )) {
        expect(
          field.decoration?.labelText,
          isNull,
          reason: '拟物改用凹陷外标题，浮动标签会压在框线上',
        );
      }
      const labels = ['服务器地址', '账号', '应用密码', '远端目录（网盘上的存放位置）'];
      for (final label in labels) {
        expect(find.text(label), findsOneWidget);
      }
      final labelRect = tester.getRect(find.text('服务器地址'));
      final insetRect = tester.getRect(find.byType(NeuInset).first);
      expect(labelRect.bottom, lessThanOrEqualTo(insetRect.top));
    });

    testWidgets('大爆炸搜索：三个引擎 chip 全部拟物化，点选写 prefs', (tester) async {
      await tester.pumpWidget(wrap(const SearchSettingsPage()));
      await tester.pumpAndSettle();

      expect(find.byType(NeuChoiceChip), findsNWidgets(3));
      expect(find.byType(ChoiceChip), findsNothing);

      await tester.tap(find.text('必应'));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kSearchEngineKey), 'bing');
    });

    testWidgets('外观：字体两档 chip 拟物化，点选写 prefs', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(wrap(const AppearanceSettingsPage()));
      await tester.pumpAndSettle();

      expect(
        find.ancestor(
          of: find.text('系统默认'),
          matching: find.byType(NeuChoiceChip),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('系统默认'));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kAppFontPrefKey), 'system');
      expect(AppRoot.fontChoiceNotifier.value, AppFontChoice.system);
    });

    testWidgets('悬浮窗设置：把手大小档位拟物化，点选落盘', (tester) async {
      await tester.pumpWidget(wrap(const OverlaySettingsPage()));
      await tester.pumpAndSettle();

      final mini = find.text('迷你');
      await tester.scrollUntilVisible(
        mini,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.ancestor(of: mini, matching: find.byType(NeuChoiceChip)),
        findsOneWidget,
      );
      expect(find.byType(ChoiceChip), findsNothing);

      await tester.tap(mini);
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(OverlayConstants.handleSizePrefKey), 50);
    });

    testWidgets('音量键快捷操作：手势动作 chip 拟物化，点选落盘', (tester) async {
      await tester.pumpWidget(wrap(const VolumeKeySettingsPage()));
      await tester.pumpAndSettle();

      final showOverlay = find.widgetWithText(NeuChoiceChip, '显示悬浮窗');
      expect(showOverlay, findsNWidgets(4), reason: '4 个手势槽位都有该动作');
      expect(find.byType(ChoiceChip), findsNothing);

      await tester.tap(showOverlay.first);
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(VolumeGestureSlot.longPressUp),
        VolumeGestureAction.showOverlay,
      );
    });
  });
}
