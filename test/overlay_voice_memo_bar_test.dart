import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record_platform_interface/record_platform_interface.dart';
import 'package:shengwuji_app/overlay/overlay_constants.dart';
import 'package:shengwuji_app/overlay/overlay_voice_memo.dart';
import 'package:shengwuji_app/overlay/widgets/overlay_voice_memo_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 语音速记录音胶囊（性能审查 Top8 回归）：
/// 红点闪烁（录音态）与三点跳动（转写态）两个动画控制器改为随分支挂载/销毁，
/// 任一时刻只有一个在转——不用的那个不再空转驱动逐帧；可见动画一帧不变。
///
/// 事件语义：胶囊切换依赖父层重建（生产中 OverlayHome 监听 controller 后
/// setState；测试里用重新 pumpWidget 等价模拟）。查找全部限定在胶囊子树内
/// （MaterialApp 路由过渡自带 FadeTransition/Transform，不能按类型全局找）。
/// record 插件的测试假实现。
///
/// ⚠️ 真实插件在 widget test 环境里 `AudioRecorder.stop()` **永不完成**（非抛错，
/// 是挂起——实测 pump 多轮 done 仍为 false），会把停录链路卡死在
/// `await _recorder.stop()`。假实现的 stop 立即正常返回 null，链路才能走到
/// 收尾。其余方法仅占位（本测试只触发 stop 一条路径）
class _FakeRecordPlatform extends RecordPlatform {
  @override
  Future<void> create(String recorderId) async {}

  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) async {}

  @override
  Future<Stream<Uint8List>> startStream(
    String recorderId,
    RecordConfig config,
  ) async => const Stream.empty();

  @override
  Future<String?> stop(String recorderId) async => null;

  @override
  Future<void> pause(String recorderId) async {}

  @override
  Future<void> resume(String recorderId) async {}

  @override
  Future<bool> isRecording(String recorderId) async => false;

  @override
  Future<bool> isPaused(String recorderId) async => false;

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async =>
      true;

  @override
  Future<void> dispose(String recorderId) async {}

  @override
  Future<Amplitude> getAmplitude(String recorderId) async =>
      Amplitude(current: 0, max: 0);

  @override
  Future<bool> isEncoderSupported(String recorderId, AudioEncoder encoder) =>
      Future.value(true);

  @override
  Future<List<InputDevice>> listInputDevices(String recorderId) async =>
      const [];

  @override
  Future<void> cancel(String recorderId) async {}

  @override
  Stream<RecordState> onStateChanged(String recorderId) => const Stream.empty();
}

void main() {
  final bar = find.byType(OverlayVoiceMemoBar);

  Future<void> pumpBar(
    WidgetTester tester,
    OverlayVoiceMemoController c, {
    bool dockLeft = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OverlayVoiceMemoBar(controller: c, dockLeft: dockLeft),
        ),
      ),
    );
  }

  testWidgets('录音态：红点闪烁动画在跑，无「转写中」', (tester) async {
    final c = OverlayVoiceMemoController()
      ..setStateForTest(OverlayVoiceMemoState.recording);
    await pumpBar(tester, c);
    await tester.pump();

    expect(
      find.descendant(of: bar, matching: find.text('转写中')),
      findsNothing,
      reason: '录音态不渲染转写胶囊',
    );
    final fade = find.descendant(
      of: bar,
      matching: find.byType(FadeTransition),
    );
    expect(fade, findsOneWidget, reason: '红点闪烁 = 胶囊内唯一 FadeTransition');
    final t1 = tester.widget<FadeTransition>(fade).opacity.value;
    await tester.pump(const Duration(milliseconds: 150));
    final t2 = tester.widget<FadeTransition>(fade).opacity.value;
    expect(t2, isNot(t1), reason: '录音态红点闪烁动画持续运行');
  });

  testWidgets('录音→转写：胶囊切换，红点动画随分支销毁、三点跳动接管', (tester) async {
    final c = OverlayVoiceMemoController()
      ..setStateForTest(OverlayVoiceMemoState.recording);
    await pumpBar(tester, c);
    await tester.pump();
    expect(
      find.descendant(of: bar, matching: find.byType(FadeTransition)),
      findsOneWidget,
    );

    c.setStateForTest(OverlayVoiceMemoState.transcribing);
    await pumpBar(tester, c); // 父层重建 → 分支切换
    await tester.pump();

    expect(
      find.descendant(of: bar, matching: find.text('转写中')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bar, matching: find.byType(FadeTransition)),
      findsNothing,
      reason: '录音胶囊卸载，红点闪烁控制器随分支销毁',
    );

    // 三点跳动：三个 Transform 的 y 偏移随帧变化（波浪相位推进）
    List<double> dotOffsets() => tester
        .widgetList<Transform>(
          find.descendant(of: bar, matching: find.byType(Transform)),
        )
        .map((t) => t.transform.getTranslation().y)
        .toList();
    expect(dotOffsets().length, 3, reason: '三个跳动点');
    final y1 = dotOffsets();
    await tester.pump(const Duration(milliseconds: 150));
    final y2 = dotOffsets();
    expect(y2, isNot(y1), reason: '转写态三点跳动动画持续运行');
  });

  testWidgets('转写→录音：切回红点闪烁，三点动画随分支销毁', (tester) async {
    final c = OverlayVoiceMemoController()
      ..setStateForTest(OverlayVoiceMemoState.transcribing);
    await pumpBar(tester, c);
    await tester.pump();
    expect(
      find.descendant(of: bar, matching: find.text('转写中')),
      findsOneWidget,
    );

    c.setStateForTest(OverlayVoiceMemoState.recording);
    await pumpBar(tester, c);
    await tester.pump();

    expect(find.descendant(of: bar, matching: find.text('转写中')), findsNothing);
    expect(
      find.descendant(of: bar, matching: find.byType(Transform)),
      findsNothing,
      reason: '转写胶囊卸载，三点跳动控制器随分支销毁',
    );
    expect(
      find.descendant(of: bar, matching: find.byType(FadeTransition)),
      findsOneWidget,
      reason: '切回红点闪烁',
    );
  });

  testWidgets('录音态：停止按钮钉在胶囊贴屏端，命中区 44×44', (tester) async {
    final c = OverlayVoiceMemoController()
      ..setStateForTest(OverlayVoiceMemoState.recording);
    await pumpBar(tester, c);
    await tester.pump();

    final icon = find.descendant(of: bar, matching: find.byIcon(Icons.stop));
    expect(icon, findsOneWidget, reason: '录音态渲染停止按钮');
    // 命中区 = 图标外层的 GestureDetector（bar 子树内唯一一个）
    final hit = tester.getRect(
      find.ancestor(of: icon, matching: find.byType(GestureDetector)).first,
    );
    expect(
      hit.width,
      OverlayConstants.voiceMemoStopZoneWidth,
      reason: '命中区宽度 = 停止钮区常量',
    );
    expect(
      hit.height,
      OverlayConstants.voiceMemoCapsuleHeight,
      reason: '命中区高度 = 胶囊全高（贴屏端整列）',
    );
    // 钉在贴屏端：命中区右缘与胶囊右缘重合（Stack 内 Positioned right:0）。
    // AnimatedContainer 的盒子含 12dp 右 margin，先扣掉才是胶囊本体的右缘
    final capsule = tester.getRect(
      find.descendant(of: bar, matching: find.byType(AnimatedContainer)).first,
    );
    expect(
      hit.right,
      closeTo(capsule.right - OverlayConstants.voiceMemoEdgeMargin, 0.5),
      reason: '停止钮右缘 = 胶囊右缘（屏幕端），不随胶囊变长移动',
    );
  });

  testWidgets('停靠左缘（dockLeft）：停止钮钉在胶囊左端（贴屏端镜像）', (tester) async {
    final c = OverlayVoiceMemoController()
      ..setStateForTest(OverlayVoiceMemoState.recording);
    await pumpBar(tester, c, dockLeft: true);
    await tester.pump();

    final icon = find.descendant(of: bar, matching: find.byIcon(Icons.stop));
    expect(icon, findsOneWidget, reason: '录音态渲染停止按钮');
    final hit = tester.getRect(
      find.ancestor(of: icon, matching: find.byType(GestureDetector)).first,
    );
    expect(
      hit.width,
      OverlayConstants.voiceMemoStopZoneWidth,
      reason: '命中区宽度 = 停止钮区常量',
    );
    // 钉在贴屏端（左缘）：命中区左缘 = 胶囊本体左缘（AnimatedContainer 含
    // 12dp 左 margin，先扣掉；镜像后 Positioned left:0）
    final capsule = tester.getRect(
      find.descendant(of: bar, matching: find.byType(AnimatedContainer)).first,
    );
    expect(
      hit.left,
      closeTo(capsule.left + OverlayConstants.voiceMemoEdgeMargin, 0.5),
      reason: '停止钮左缘 = 胶囊左缘（屏幕端），镜像后不随胶囊变长移动',
    );
    // 胶囊整体贴停靠侧：Align.centerLeft 使胶囊靠窗口左侧
    final barRect = tester.getRect(bar);
    expect(
      (capsule.left - OverlayConstants.voiceMemoEdgeMargin) - barRect.left,
      lessThan(1.0),
      reason: '胶囊（含距屏边距）贴窗口左缘',
    );
  });

  testWidgets('转写态：无停止按钮（仅录音阶段展示）', (tester) async {
    final c = OverlayVoiceMemoController()
      ..setStateForTest(OverlayVoiceMemoState.transcribing);
    await pumpBar(tester, c);
    await tester.pump();

    expect(
      find.descendant(of: bar, matching: find.byIcon(Icons.stop)),
      findsNothing,
      reason: '转写开始后无法中断，胶囊上无停止钮',
    );
  });

  testWidgets('点击停止按钮 → heavy 震感 + controller.stop() 走完整停录链路', (tester) async {
    // 停录收尾链路的通道 mock：performHaptic（停止按钮震感，捕获断言用）+
    // voiceMemoStopped / voiceMemoFinished 回执 + restoreMedia（都走
    // accessibility_overlay 通道）。不 mock 会以 MissingPluginException 炸测试
    // （voiceMemoStopped 未 try-catch）。本版本 mock handler 直接返回解码后的
    // 响应对象：null = 成功空响应
    final hapticCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.shengwuji.app/accessibility_overlay'),
      (call) async {
        if (call.method == 'performHaptic') hapticCalls.add(call);
        return null;
      },
    );
    // 互斥桥（is_recording 置 false）：SharedPreferences 测试内存实现
    SharedPreferences.setMockInitialValues({});
    // record 插件换假实现（真实插件 stop() 在测试环境永不完成，见类注释）
    final prevRecordPlatform = RecordPlatform.instance;
    RecordPlatform.instance = _FakeRecordPlatform();
    addTearDown(() => RecordPlatform.instance = prevRecordPlatform);

    final c = OverlayVoiceMemoController()
      ..setStateForTest(OverlayVoiceMemoState.recording);
    await pumpBar(tester, c);
    await tester.pump();

    await tester.tap(
      find.descendant(of: bar, matching: find.byIcon(Icons.stop)),
    );
    // 不 pump 直接断言：stop 入口在首个 await 前同步置 transcribing；
    // 一旦 pump，假 record 平台会让整条链路瞬时跑完直达 idle
    expect(
      c.state,
      OverlayVoiceMemoState.transcribing,
      reason: '证明按钮点击已接入 controller.stop()',
    );
    expect(hapticCalls, hasLength(1), reason: '停止按钮发一次触觉反馈');
    expect(
      hapticCalls.single.arguments['type'],
      'tick',
      reason: '「开始嗡、停止清脆」定版（2026-09-17）：停止档 tick，与 Kotlin '
          'toggle 停录的 performHaptic("tick") 同档',
    );

    // 冲完整条异步收尾（recorder.stop 异常被吞 → 清互斥桥 → 回执 → 空录音
    // 丢弃路径 _finishTranscribe 回 idle）
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(c.state, OverlayVoiceMemoState.idle, reason: '收尾完成回到 idle');

    // 冲掉 _finishTranscribe 排定的 worker idle 释放 Timer（120s），
    // 否则测试收尾报 pending timer
    await tester.pump(const Duration(minutes: 3));
  });

  test('shouldShowStopHint 纯函数：未达上限展示、达到 2 次上限后永不再展示', () {
    expect(
      OverlayVoiceMemoController.shouldShowStopHint(0),
      isTrue,
      reason: '首次速记展示提示',
    );
    expect(
      OverlayVoiceMemoController.shouldShowStopHint(1),
      isTrue,
      reason: '第二次速记仍展示',
    );
    expect(
      OverlayVoiceMemoController.shouldShowStopHint(
        OverlayConstants.voiceMemoStopHintMaxShows,
      ),
      isFalse,
      reason: '展示满 2 次后不再打扰',
    );
  });

  testWidgets('停止提示：showStopHint=true 渲染在录音胶囊正下方，贴屏端边缘对齐', (tester) async {
    final c = OverlayVoiceMemoController()
      ..setStateForTest(OverlayVoiceMemoState.recording)
      ..setShowStopHintForTest(true);
    await pumpBar(tester, c);
    await tester.pump();

    final hint = find.descendant(
      of: bar,
      matching: find.text('再次长按音量上键，停止并转写'),
    );
    expect(hint, findsOneWidget, reason: '前 2 次速记录音展示提示胶囊');
    // 胶囊盒（AnimatedContainer 的 rect 含 12dp 停靠侧 margin）与提示胶囊盒
    //（同样自带 12dp margin）都贴 Align 的停靠侧：右缘停靠时两盒右缘重合
    final capsuleRect = tester.getRect(
      find.descendant(of: bar, matching: find.byType(AnimatedContainer)).first,
    );
    final hintRect = tester.getRect(
      find.ancestor(of: hint, matching: find.byType(Container)).first,
    );
    expect(
      hintRect.top,
      greaterThanOrEqualTo(capsuleRect.bottom),
      reason: '提示在胶囊正下方（窗口下部条带），不遮挡计时/停止钮',
    );
    expect(
      hintRect.right,
      closeTo(capsuleRect.right, 0.5),
      reason: '贴屏端边缘与录音胶囊对齐，不随胶囊变长移动',
    );
  });

  testWidgets('停止提示：停靠左缘镜像——贴屏端（左）边缘与胶囊对齐', (tester) async {
    final c = OverlayVoiceMemoController()
      ..setStateForTest(OverlayVoiceMemoState.recording)
      ..setShowStopHintForTest(true);
    await pumpBar(tester, c, dockLeft: true);
    await tester.pump();

    final hint = find.descendant(
      of: bar,
      matching: find.text('再次长按音量上键，停止并转写'),
    );
    expect(hint, findsOneWidget);
    final capsuleRect = tester.getRect(
      find.descendant(of: bar, matching: find.byType(AnimatedContainer)).first,
    );
    final hintRect = tester.getRect(
      find.ancestor(of: hint, matching: find.byType(Container)).first,
    );
    expect(
      hintRect.left,
      closeTo(capsuleRect.left, 0.5),
      reason: '左缘停靠镜像后贴屏端 = 左端，提示与胶囊左缘对齐',
    );
  });

  testWidgets('停止提示:「单击键结束录音」开启 → 文案切「单击音量键」(短按已被拦截停录)', (tester) async {
    final c = OverlayVoiceMemoController()
      ..setStateForTest(OverlayVoiceMemoState.recording)
      ..setShowStopHintForTest(true)
      ..singleClickStopEnabled = true;
    await pumpBar(tester, c);
    await tester.pump();

    expect(
      find.descendant(of: bar, matching: find.text('单击音量键，停止并转写')),
      findsOneWidget,
      reason: '单击停录开启后短按音量键就是停录,提示与实际交互一致',
    );
    expect(
      find.descendant(of: bar, matching: find.text('再次长按音量上键，停止并转写')),
      findsNothing,
      reason: '「再次长按」旧文案在单击停录模式下不准确,不再展示',
    );
  });

  testWidgets('停止提示：showStopHint=false 不渲染（展示满 2 次后回归纯胶囊）', (tester) async {
    final c = OverlayVoiceMemoController()
      ..setStateForTest(OverlayVoiceMemoState.recording);
    await pumpBar(tester, c);
    await tester.pump();

    expect(
      find.descendant(of: bar, matching: find.text('再次长按音量上键，停止并转写')),
      findsNothing,
      reason: '计数达上限后录音态只有胶囊本体',
    );
  });

  testWidgets('停止提示：转写态不渲染（停止提示只在录音阶段有意义）', (tester) async {
    final c = OverlayVoiceMemoController()
      ..setStateForTest(OverlayVoiceMemoState.transcribing)
      ..setShowStopHintForTest(true);
    await pumpBar(tester, c);
    await tester.pump();

    expect(
      find.descendant(of: bar, matching: find.text('再次长按音量上键，停止并转写')),
      findsNothing,
      reason: '转写已无法中断，提示无意义不展示',
    );
  });
}
