import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/settings/volume_key_settings_page.dart';
import 'package:shengwuji_app/theme/app_theme.dart';
import 'package:shengwuji_app/utils/pro_gate.dart';
import 'package:shengwuji_app/utils/volume_gesture_config.dart';
import 'package:shengwuji_app/widgets/neu_widgets.dart';
import 'package:shengwuji_app/widgets/pro_unlock_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 音量键「剪贴板笔记」动作（overlay_clipboard_note，2026-10-28）的设置页契约：
///
/// 用户需求：给某个手势槽位绑上后，按一下就把系统剪贴板最近一条文本直接存成
/// 随手记，不展开悬浮窗、不切前台。设置页必须做到：
/// - 4 个槽位行都提供该选项（含双击槽位——它不依赖"按住中态"，与按住说话不同）；
/// - 选中即写对应槽位 key（原生每次按键实时读落盘 prefs，写错 key 等于没绑）；
/// - 归入悬浮窗系动作 → 未解锁 Pro 时展示徽章、点击走解锁弹窗且不写 prefs
///  （Kotlin blockOverlayIfProLocked 是第二道门，设置页是第一道）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 无障碍服务状态检测通道：返回 true 让 4 行手势槽位渲染（未开启时整块隐藏）
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
    // 等 _load*（prefs / 无障碍状态 / Pro 状态）异步完成后 settle
    await tester.pumpAndSettle();
  }

  /// 把 4 行手势槽位滚进可视区：页面 ListView 懒加载，首屏放不下整张卡片
  Future<void> scrollToGestures(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.textContaining('双击音量减'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  Finder chipContaining(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(NeuChoiceChip));

  testWidgets('Pro 已解锁：4 个手势槽位都提供「剪贴板笔记」选项', (tester) async {
    SharedPreferences.setMockInitialValues({
      ProGate.kKeyIsProUnlocked: true,
      ProGate.kKeyLicenseCode: 'TESTCODE12345678',
    });
    await pumpPage(tester);
    await scrollToGestures(tester);

    expect(
      find.text('剪贴板笔记'),
      findsNWidgets(4),
      reason: '长按加/长按减/双击加/双击减 4 行各一个（双击也支持，本动作不需要按住中态）',
    );
  });

  testWidgets('点长按音量加行的「剪贴板笔记」→ 写 volume_gesture_long_press_up 并选中', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      ProGate.kKeyIsProUnlocked: true,
      ProGate.kKeyLicenseCode: 'TESTCODE12345678',
    });
    await pumpPage(tester);
    await scrollToGestures(tester);

    // 第一个命中 = 长按音量加行
    await tester.ensureVisible(find.text('剪贴板笔记').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('剪贴板笔记').first);
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(VolumeGestureSlot.longPressUp),
      VolumeGestureAction.overlayClipboardNote,
      reason: '原生按键时直接读落盘 prefs（flutter.volume_gesture_long_press_up）',
    );
    expect(
      tester.widget<NeuChoiceChip>(chipContaining('剪贴板笔记').first).selected,
      isTrue,
      reason: 'UI 同步反映选中态',
    );
  });

  testWidgets('Pro 未解锁：点「剪贴板笔记」弹解锁弹窗且不写 prefs', (tester) async {
    // 弹窗内容高（流程说明 + 付款码 + 三按钮），默认 800×600 会溢出
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    await pumpPage(tester);
    await scrollToGestures(tester);

    await tester.ensureVisible(find.text('剪贴板笔记').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('剪贴板笔记').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(ProUnlockDialog), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(VolumeGestureSlot.longPressUp),
      isNull,
      reason: '门禁拦截时不得落盘（否则未付费用户也绑上悬浮窗系动作）',
    );
  });
}
