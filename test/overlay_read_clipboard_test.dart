import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/overlay/accessibility_overlay.dart';

/// 悬浮窗 header「剪贴板存为笔记」的通道契约（2026-10-27）：
///
/// 1. 方法名必须是 `readClipboard`——原生 handler 同名（Kotlin
///    readClipboardWithFocus），漂移会让按钮静默失效；
/// 2. 只把 String 当文本：原生返回 null（剪贴板为空/图片等非文本/系统拒绝
///    读取）→ Dart 侧必须落成 null，交给调用方 Toast 不落库；非 String 的
///    异常负载同样按 null 兜底；
/// 3. 通道异常（服务被系统回收等）不能把异常抛给 UI，返回 null 由调用方提示。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.shengwuji.app/accessibility_overlay');
  final invoked = <MethodCall>[];
  Object? nextResult;
  Object? nextError;

  setUp(() {
    invoked.clear();
    nextResult = null;
    nextError = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          invoked.add(call);
          if (nextError != null) throw nextError!;
          return nextResult;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('readClipboard：发到无障碍 Service 通道，文本原样返回', () async {
    nextResult = '来自剪贴板的一段文字';
    final text = await AccessibilityOverlay.readClipboard();
    expect(invoked, hasLength(1));
    expect(invoked.single.method, 'readClipboard');
    expect(text, '来自剪贴板的一段文字');
  });

  test('readClipboard：原生 null / 非字符串统一落成 null', () async {
    nextResult = null;
    expect(await AccessibilityOverlay.readClipboard(), isNull);

    nextResult = 42;
    expect(await AccessibilityOverlay.readClipboard(), isNull);
  });

  test('readClipboard：通道异常不外抛，按读不到兜底', () async {
    nextError = PlatformException(code: 'service_gone');
    expect(await AccessibilityOverlay.readClipboard(), isNull);
  });

  // ── 音量键「剪贴板笔记」动作（2026-10-28）的原生 → Dart 下发契约 ──
  // Kotlin triggerOverlayClipboardNote 在浮窗不存在时直建一个不可见的临时隐藏窗
  // 只为拿焦点读剪贴板，落库（或失败）后靠 Dart 回执 clipboardNoteDone 收窗；
  // 这两个方法名/负载一旦漂移，手势会在临时窗上静默卡死（10s 超时才收）。

  Future<void> deliver(String method, Object? args) async {
    final data = const StandardMethodCodec().encodeMethodCall(
      MethodCall(method, args),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(channel.name, data, (_) {});
  }

  void registerClipboardHandler(List<bool> seen) {
    AccessibilityOverlay.setupNativeChannel(
      onExpand: () {},
      onReset: () {},
      onStartVoiceMemo: (_, _) {},
      onStopVoiceMemo: () {},
      onSaveClipboardNote: seen.add,
    );
  }

  test('saveClipboardNote：{ephemeral: true} → 回调收到 true（需回执收临时窗）', () async {
    final seen = <bool>[];
    registerClipboardHandler(seen);
    await deliver('saveClipboardNote', {'ephemeral': true});
    expect(seen, [true]);
  });

  test('saveClipboardNote：null / 缺 ephemeral → 按 false 兜底', () async {
    final seen = <bool>[];
    registerClipboardHandler(seen);
    await deliver('saveClipboardNote', null);
    // 旧版本 Kotlin 不带 payload：不得把用户已显示的浮窗当临时窗收掉
    await deliver('saveClipboardNote', <String, Object?>{});
    await deliver('saveClipboardNote', {'ephemeral': 'true'});
    expect(seen, [false, false, false]);
  });

  test('clipboardNoteDone：出站方法名与 Kotlin 通道 handler 一致', () async {
    await AccessibilityOverlay.clipboardNoteDone();
    expect(invoked.single.method, 'clipboardNoteDone');
  });
}
