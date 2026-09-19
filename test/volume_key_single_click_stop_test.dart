import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/settings/volume_key_settings_page.dart';
import 'package:shengwuji_app/theme/app_theme.dart';
import 'package:shengwuji_app/utils/volume_gesture_config.dart';
import 'package:shengwuji_app/widgets/neu_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「录音中单击结束录音」开关 + 与「按音量减保持静音」的互斥二选一（widget 测试）
///
/// 互斥的产品依据：单击停录开启后，录音中单击音量减被 Kotlin 拦截停录、不再走
/// adjustVolume，keep_muted 标记失去触发入口——两开关同开语义自相矛盾，设置页
/// 负责"开一个自动关另一个"（Kotlin 侧不重复校验）。本测试锁定：
/// - 双向互斥都生效且落盘正确（跨端读取方每次按键实时读落盘 prefs，落盘即生效）
/// - keep_muted 关闭时其联动的「静音提示」一并关闭（原有联动不得被互斥打断）
/// - Kotlin 读取端 key 常量（flutter.single_click_stop_recording）的 Dart 真值
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 无障碍服务状态检测通道：返回 true 让「录音静音」开关区渲染（false/失败
    // 时整个分区 if 隐藏，无法测互斥）。setUp 无 tester 参数，走 binding 单例
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.shengwuji.app/app'),
      (call) async =>
          call.method == 'isAccessibilityServiceEnabled' ? true : null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.shengwuji.app/app'),
      null,
    );
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppThemes.neumorphism.toThemeData(),
        home: const VolumeKeySettingsPage(),
      ),
    );
    // 等 SharedPreferences 异步读取（_load* 系列）完成后 settle
    await tester.pumpAndSettle();
  }

  /// 把「录音静音」区的开关滚进可视区：页面 ListView 懒加载，前面的 4 行手势
  /// 槽位 + 长按阈值选择器占满测试首屏，屏幕外的「录音静音」卡片尚未构建
  Future<void> scrollToSwitch(WidgetTester tester, String title) async {
    await tester.scrollUntilVisible(
      find.text(title),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  /// 某标题开关行里的开关（NeuSwitchTile → NeuSwitch）
  NeuSwitch switchOf(WidgetTester tester, String title) =>
      tester.widget<NeuSwitch>(
        find.descendant(
          of: find.ancestor(
              of: find.text(title), matching: find.byType(NeuSwitchTile)),
          matching: find.byType(NeuSwitch),
        ),
      );

  Future<void> tapSwitch(WidgetTester tester, String title) async {
    await tester.tap(
      find.descendant(
        of: find.ancestor(
            of: find.text(title), matching: find.byType(NeuSwitchTile)),
        matching: find.byType(NeuSwitch),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('默认态：保持静音开、单击停录关（出厂默认互斥侧 = 保持静音）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpPage(tester);
    await scrollToSwitch(tester, '单击键结束录音');

    expect(switchOf(tester, '按音量减保持静音').value, isTrue, reason: '保持静音默认开启');
    expect(switchOf(tester, '单击键结束录音').value, isFalse, reason: '单击停录默认关闭');
  });

  testWidgets('开启「单击键结束录音」→ 自动关闭保持静音（含联动的静音提示），双方落盘', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpPage(tester);
    await scrollToSwitch(tester, '单击键结束录音');

    await tapSwitch(tester, '单击键结束录音');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kSingleClickStopRecordingKey), isTrue,
        reason: '本开关自身落盘（Kotlin 每次按键实时读）');
    expect(prefs.getBool('keep_muted_on_volume_down'), isFalse,
        reason: '互斥：保持静音被自动关闭并落盘');
    expect(prefs.getBool('mute_hint_enabled'), isFalse,
        reason: '保持静音关闭时联动关闭静音提示（原有联动不得被互斥打断）');
    expect(switchOf(tester, '按音量减保持静音').value, isFalse, reason: 'UI 同步反映互斥结果');
  });

  testWidgets('反向互斥：单击停录已开时开启「保持静音」→ 单击停录被自动关闭', (tester) async {
    SharedPreferences.setMockInitialValues({
      kSingleClickStopRecordingKey: true,
      'keep_muted_on_volume_down': false,
    });
    await pumpPage(tester);
    await scrollToSwitch(tester, '按音量减保持静音');
    expect(switchOf(tester, '单击键结束录音').value, isTrue);

    await tapSwitch(tester, '按音量减保持静音');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('keep_muted_on_volume_down'), isTrue, reason: '保持静音正常开启');
    expect(prefs.getBool(kSingleClickStopRecordingKey), isFalse,
        reason: '互斥：单击停录被自动关闭并落盘');
    expect(switchOf(tester, '单击键结束录音').value, isFalse, reason: 'UI 同步反映互斥结果');
  });

  test('Dart key 真值与 Kotlin 读取端（flutter. 前缀拼接）跨端一致', () {
    // Kotlin 侧常量为 "flutter.single_click_stop_recording"（VolumeKeyAccessibilityService
    // SINGLE_CLICK_STOP_KEY）；改 Dart 真值不同步 Kotlin 会导致开关静默失灵
    expect(kSingleClickStopRecordingKey, 'single_click_stop_recording');
  });
}
