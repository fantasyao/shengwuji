import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shengwuji_app/utils/overlay_launcher.dart';

/// OverlayLauncher.showOverlay 的通道封装语义：原生返回什么透传什么；
/// 通道异常/返回 null 按 false 兜底（调用方按「启动失败」提示，不抛给 UI）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.shengwuji.app/app');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('原生返回 true → showOverlay 返回 true', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'showOverlay');
      return true;
    });
    expect(await OverlayLauncher.showOverlay(), isTrue);
  });

  test('原生返回 false（服务未运行 / Pro 未解锁）→ 返回 false', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => false);
    expect(await OverlayLauncher.showOverlay(), isFalse);
  });

  test('原生抛 PlatformException → 返回 false（不抛给调用方）', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'unavailable', message: 'service dead');
    });
    expect(await OverlayLauncher.showOverlay(), isFalse);
  });

  test('原生返回 null → 返回 false', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    expect(await OverlayLauncher.showOverlay(), isFalse);
  });
}
