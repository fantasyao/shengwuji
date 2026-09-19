import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/theme/app_theme.dart';
import 'package:shengwuji_app/web_server/diary_server_controller.dart';
import 'package:shengwuji_app/web_server/diary_web_server.dart';
import 'package:shengwuji_app/web_server/web_server_settings_card.dart';

/// 设置页「电脑访问」卡片回归（2026-09 新增）。锁组件层契约：
/// 开关状态随 controller 状态渲染（idle 关 / running 开 / error 显错误文案）、
/// 开关回调接线到 controller.start/stop、前台保活服务 MethodChannel 调用、
/// 启动失败回滚（停前台服务）、running 态展示局域网地址。
/// HTTP 服务本体契约在 diary_web_server_test.dart（真实 socket 集成）。
void main() {
  const channel = MethodChannel('com.shengwuji.app/app');
  final List<String> channelCalls = [];

  setUp(() {
    // controller.start/stop 会写 prefs 开关；widget 测试必须 mock，
    // 否则 SharedPreferences.getInstance() 挂起导致状态停在 starting
    SharedPreferences.setMockInitialValues({});
    channelCalls.clear();
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

  Future<void> pumpCard(
    WidgetTester tester, {
    required DiaryServerController controller,
    List<String> addresses = const ['192.168.1.23'],
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        // AppThemeExtension.of 经 Theme.extension 解析，必须挂应用主题
        // （同 diary_floating_button_test 的做法）
        theme: AppThemes.defaultTheme.toThemeData(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: WebServerSettingsCard(
              controller: controller,
              lanAddressesLoader: () async => addresses,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('idle 态：开关关、无地址列表', (tester) async {
    final controller = DiaryServerController(
      server: FakeDiaryWebServer(started: false),
    );
    await pumpCard(tester, controller: controller);

    expect(find.text('电脑访问服务'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(find.text('http://192.168.1.23:$kDiaryServerPort'), findsNothing);
  });

  testWidgets('开关打开 → controller.start + 前台保活服务拉起 → running 态显示地址',
      (tester) async {
    final fakeServer = FakeDiaryWebServer(started: true);
    final controller = DiaryServerController(server: fakeServer);
    await pumpCard(tester, controller: controller);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(fakeServer.startCount, 1);
    expect(channelCalls, contains('startDiaryServerService'));
    expect(controller.status.value.phase, DiaryServerPhase.running);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(
      find.text('http://192.168.1.23:$kDiaryServerPort'),
      findsOneWidget,
    );
  });

  testWidgets('启动失败（端口被其他应用占用）→ 显示错误文案 + 回滚停前台服务',
      (tester) async {
    final fakeServer = FakeDiaryWebServer(
      started: false,
      startResult: const DiaryServerStartResult(
        DiaryServerStartStatus.portBusyByOther,
      ),
    );
    final controller = DiaryServerController(server: fakeServer);
    await pumpCard(tester, controller: controller);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(controller.status.value.phase, DiaryServerPhase.error);
    expect(
      controller.status.value.message,
      contains('被其他应用占用'),
    );
    expect(find.textContaining('被其他应用占用'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(channelCalls, contains('startDiaryServerService'));
    expect(channelCalls, contains('stopDiaryServerService'),
        reason: 'HTTP 起失败应回滚前台服务');
  });

  testWidgets('running 态再关开关 → controller.stop + 前台保活服务停止',
      (tester) async {
    final fakeServer = FakeDiaryWebServer(started: true);
    final controller = DiaryServerController(server: fakeServer);
    await pumpCard(tester, controller: controller);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.status.value.phase, DiaryServerPhase.running);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(fakeServer.stopCount, 1);
    expect(channelCalls, contains('stopDiaryServerService'));
    expect(controller.status.value.phase, DiaryServerPhase.idle);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(find.text('http://192.168.1.23:$kDiaryServerPort'), findsNothing);
  });

  testWidgets('地址列表为空（Wi-Fi 未连）→ 显示提示而不是崩', (tester) async {
    final fakeServer = FakeDiaryWebServer(started: true);
    final controller = DiaryServerController(server: fakeServer);
    await pumpCard(tester, controller: controller, addresses: []);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('未获取到局域网地址'), findsOneWidget);
  });

  testWidgets('复制按钮 → 剪贴板写入完整地址 + SnackBar 提示', (tester) async {
    // Clipboard.getData 在 widget 测试的 FakeAsync zone 无平台处理器会永久
    // 挂起（实测 10 分钟超时），必须 mock 系统平台通道的剪贴板读
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        return {'text': 'http://192.168.1.23:$kDiaryServerPort'};
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    final fakeServer = FakeDiaryWebServer(started: true);
    final controller = DiaryServerController(server: fakeServer);
    await pumpCard(tester, controller: controller);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byTooltip('复制地址'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    expect(clipboard?.text, 'http://192.168.1.23:$kDiaryServerPort');
    expect(find.text('地址已复制，粘贴到电脑浏览器打开即可'), findsOneWidget);
  });
}

/// 假 HTTP 服务：只计数 start/stop 并按预设返回结果（不绑真 socket）
class FakeDiaryWebServer extends DiaryWebServer {
  FakeDiaryWebServer({
    required bool started,
    DiaryServerStartResult? startResult,
  }) : _running = started,
       _startResult =
           startResult ??
           const DiaryServerStartResult(DiaryServerStartStatus.started);

  bool _running;
  final DiaryServerStartResult _startResult;
  int startCount = 0;
  int stopCount = 0;

  @override
  bool get isRunning => _running;

  @override
  Future<DiaryServerStartResult> start({
    int port = kDiaryServerPort,
    InternetAddress? address,
    DiaryNoteRepository? repository,
    Directory? audioDir,
    Duration changePollInterval = const Duration(seconds: 1),
    Duration identityProbeTimeout = const Duration(milliseconds: 800),
  }) async {
    startCount++;
    _running = _startResult.isSuccess;
    return _startResult;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    _running = false;
  }
}
