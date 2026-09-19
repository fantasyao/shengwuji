import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/utils/pro_gate.dart';
import 'package:shengwuji_app/widgets/pro_unlock_dialog.dart';

/// Pro 解锁弹窗（授权码体系版）回归：
/// 三按钮 = 主实心金「扫码支付」/ 浅金描边「输入授权码解锁」（付费用户落点）/
/// 灰描边「先免费试用 7 天」（未开过试用才显示）；
/// 试用激活 → 写 pro_trial_deadline_ms 且 show() 返回 true；
/// 授权码弹层：格式预校验即时报错，channel 验证通过写 is_pro_unlocked；
/// 已解锁态：授权码/试用入口整体隐藏、主按钮变灰禁用。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.shengwuji.app/app');
  final binding = TestWidgetsFlutterBinding.instance;

  /// mock 授权 channel：getAndroidId 返回固定值；verifyLicense 默认 null
  /// （LicenseService 收到 null 返回 false），用例内可覆写
  void mockChannel({String? getAndroidId, bool? verifyLicense}) {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      switch (call.method) {
        case 'getAndroidId':
          return getAndroidId;
        case 'verifyLicense':
          return verifyLicense;
      }
      return null;
    });
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockChannel(getAndroidId: 'a1b2c3d4e5f60718');
  });

  Future<void> openDialog(WidgetTester tester) async {
    // 弹窗内容较高（流程说明 + 付款码 + 信息行 + 三按钮），默认 800×600 会溢出
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ProUnlockDialog())),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('未解锁未试用：三按钮并存 + 安卓 ID/邮箱信息行', (tester) async {
    await openDialog(tester);
    expect(find.text('扫码支付 ¥5 解锁'), findsOneWidget);
    expect(find.text('输入授权码解锁'), findsOneWidget);
    expect(find.text('先免费试用 7 天'), findsOneWidget);
    expect(find.textContaining('fantasyao@foxmail.com'), findsOneWidget);
    expect(find.textContaining('a1b2c3d4e5f60718'), findsOneWidget);
  });

  testWidgets('试用中：试用按钮消失，显示剩余天数禁用文案', (tester) async {
    SharedPreferences.setMockInitialValues({
      ProGate.kKeyTrialDeadlineMs:
          DateTime.now().add(const Duration(days: 3)).millisecondsSinceEpoch,
    });
    await openDialog(tester);
    expect(find.text('先免费试用 7 天'), findsNothing);
    expect(find.textContaining('试用中 · 剩余'), findsOneWidget);
    // 试用中仍可输码转永久解锁
    expect(find.text('输入授权码解锁'), findsOneWidget);
  });

  testWidgets('已永久解锁：主按钮变灰已解锁态，授权码/试用入口隐藏', (tester) async {
    // 永久解锁 = 解锁布尔 + 授权码记录双要素（裸布尔是旧版君子协定遗留，不算）
    SharedPreferences.setMockInitialValues({
      ProGate.kKeyIsProUnlocked: true,
      'pro_license_code': 'SXQBXPE5ILKVXU6U',
    });
    await openDialog(tester);
    expect(find.text('✓ 已解锁，感谢支持'), findsOneWidget);
    expect(find.text('输入授权码解锁'), findsNothing);
    expect(find.text('先免费试用 7 天'), findsNothing);
  });

  testWidgets('存量君子协定用户（裸布尔无码记录）：不显示已解锁态，仍见输码/试用入口', (tester) async {
    SharedPreferences.setMockInitialValues({ProGate.kKeyIsProUnlocked: true});
    await openDialog(tester);
    expect(find.text('✓ 已解锁，感谢支持'), findsNothing);
    expect(find.text('输入授权码解锁'), findsOneWidget);
    expect(find.text('先免费试用 7 天'), findsOneWidget);
  });

  testWidgets('点「先免费试用 7 天」：写入 7 天截止并 pop(true)', (tester) async {
    bool? showResult;
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async =>
                    showResult = await ProUnlockDialog.show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('先免费试用 7 天'));
    await tester.pumpAndSettle();

    expect(find.text('解锁 Pro'), findsNothing); // 弹窗已关
    expect(showResult, isTrue); // pop(true) = Pro 已可用
    // 推进时钟让浮层提示的 1.4s 自动消失 timer 跑完（避免 pending timer 报错）
    await tester.pump(const Duration(milliseconds: 1500));
    final prefs = await SharedPreferences.getInstance();
    final deadline = prefs.getInt(ProGate.kKeyTrialDeadlineMs)!;
    expect(
      deadline,
      greaterThan(
        DateTime.now().add(const Duration(days: 6)).millisecondsSinceEpoch,
      ),
    );
  });

  testWidgets('授权码弹层：格式不对即时报错，不触发 channel 验证', (tester) async {
    await openDialog(tester);
    await tester.tap(find.text('输入授权码解锁'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'ABC');
    await tester.tap(find.text('验证并解锁'));
    await tester.pump();
    expect(find.textContaining('格式不对'), findsOneWidget);
    // 弹层未关
    expect(find.text('输入授权码'), findsOneWidget);
  });

  testWidgets('授权码验证通过：写 is_pro_unlocked、两层弹窗关闭、show 返回 true', (tester) async {
    mockChannel(getAndroidId: 'a1b2c3d4e5f60718', verifyLicense: true);
    bool? showResult;
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async =>
                    showResult = await ProUnlockDialog.show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('输入授权码解锁'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'SXQB-XPE5-ILKV-XU6U');
    await tester.tap(find.text('验证并解锁'));
    await tester.pumpAndSettle();

    expect(find.text('解锁 Pro'), findsNothing); // 外层弹窗也关了
    expect(showResult, isTrue);
    // 推进时钟让浮层提示的 1.4s 自动消失 timer 跑完（避免 pending timer 报错）
    await tester.pump(const Duration(milliseconds: 1500));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(ProGate.kKeyIsProUnlocked), isTrue);
    // 永久解锁双要素：码记录必须落盘（缺它会被视为旧版君子协定遗留而失效）
    expect(prefs.getString('pro_license_code'), 'SXQBXPE5ILKVXU6U');
  });

  testWidgets('点复制按钮：rootOverlay 浮层提示可见（SnackBar 会被弹窗遮罩盖住，已弃用）', (tester) async {
    // mock 剪贴板系统通道（无 handler 时 Clipboard.setData 抛 MissingPluginException）
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => null,
    );
    await openDialog(tester);
    // 第一个复制按钮 = 安卓 ID 行
    await tester.tap(find.byIcon(Icons.copy).first);
    await tester.pump();
    expect(find.text('已复制安卓 ID（发邮件附上）'), findsOneWidget);
    // 1.4s 超时后浮层移除（同时清掉 pending timer，避免 testWidgets 报错）
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.text('已复制安卓 ID（发邮件附上）'), findsNothing);
  });

  testWidgets('授权码与设备不匹配：报错提示、is_pro_unlocked 不写入', (tester) async {
    mockChannel(getAndroidId: 'a1b2c3d4e5f60718', verifyLicense: false);
    await openDialog(tester);
    await tester.tap(find.text('输入授权码解锁'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'SXQB-XPE5-ILKV-XU6U');
    await tester.tap(find.text('验证并解锁'));
    await tester.pumpAndSettle();

    expect(find.textContaining('不匹配'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(ProGate.kKeyIsProUnlocked), isNot(true));
  });
}
