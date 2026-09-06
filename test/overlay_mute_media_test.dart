import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/overlay/accessibility_overlay.dart';
import 'package:shengwuji_app/overlay/overlay_voice_memo.dart';

/// 语音速记临时静音（悬浮窗录音接入「按音量减保持静音」，2026-09-06）：
///
/// 1. 通道契约——AccessibilityOverlay.muteMedia / restoreMedia 必须把方法名
///    发到无障碍 Service 通道（原生 MediaMuteHelper 只在该通道 handler 执行；
///    overlay engine 调不到主 App 的 MainActivity 通道），方法名/通道名漂移
///    会让静音静默失效；
/// 2. 失败路径兜底——录音流出错的 fail() 也必须恢复媒体音量（restore 对无
///    静音现场幂等，由原生按 saved_media_volume 判断），否则强杀/异常路径
///    会把手机永久留在静音态。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.shengwuji.app/accessibility_overlay');
  // record 插件通道：fail() 收尾会 await _recorder.stop()，testWidgets 环境
  // 下未 mock 的平台通道永不返回（挂死测试），mock 空实现让 stop 正常完成
  const recordChannel = MethodChannel('com.llfbandit.record/messages');
  final invoked = <MethodCall>[];

  setUp(() {
    invoked.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      invoked.add(call);
      return true;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recordChannel, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recordChannel, null);
  });

  test('muteMedia：发送 muteMedia 到无障碍 Service 通道', () async {
    await AccessibilityOverlay.muteMedia();
    expect(invoked, hasLength(1));
    expect(invoked.single.method, 'muteMedia');
  });

  test('restoreMedia：发送 restoreMedia 到无障碍 Service 通道', () async {
    await AccessibilityOverlay.restoreMedia();
    expect(invoked, hasLength(1));
    expect(invoked.single.method, 'restoreMedia');
  });

  testWidgets('fail()：录音态失败路径恢复媒体音量，且先于 voiceMemoFailed 回执',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final c = OverlayVoiceMemoController()
      ..setStateForTest(OverlayVoiceMemoState.recording);

    await c.fail('录音流出错: 测试');

    expect(
      invoked.map((call) => call.method),
      containsAllInOrder(<String>['restoreMedia', 'voiceMemoFailed']),
      reason: '失败路径先恢复媒体音量再回执 Kotlin（回执会触发原生隐藏浮窗）',
    );
    expect(c.state, OverlayVoiceMemoState.idle);
  });
}
