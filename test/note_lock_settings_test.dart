// 笔记加锁功能总开关（NoteLockSettings）持久化语义测试。
//
// 开关是跨 engine 共享的 prefs 布尔：默认开启（历史行为），关闭后主 App /
// 悬浮窗 / 局域网服务按明文展示但保留 is_locked 落库标记。这里只验证
// 读写与缺省兜底，跨 engine 可见性由 reload 纪律保证（与 NoteUnlockSession
// 同款，不在此重复模拟）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/utils/note_lock_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('缺省无 key 时默认开启（老版本升级行为不变）', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await NoteLockSettings.isEnabled(), isTrue);
  });

  test('setEnabled(false) 落盘后读取为关闭', () async {
    SharedPreferences.setMockInitialValues({});
    await NoteLockSettings.setEnabled(false);
    expect(await NoteLockSettings.isEnabled(), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(NoteLockSettings.enabledKey), isFalse);
  });

  test('重新开启覆盖旧值', () async {
    SharedPreferences.setMockInitialValues({
      NoteLockSettings.enabledKey: false,
    });
    expect(await NoteLockSettings.isEnabled(), isFalse);
    await NoteLockSettings.setEnabled(true);
    expect(await NoteLockSettings.isEnabled(), isTrue);
  });
}
