// 笔记解锁会话（NoteUnlockSession）纯逻辑测试。
//
// 会话 = prefs 里的有效期时间戳（notes_unlock_until_ms），主 App / 悬浮窗
// 两个 engine 共享、原生 SCREEN_OFF 广播直接清零。这里用 mock prefs 验证
// extend/isUnlocked/revoke 的语义边界（不含跨 engine 与原生链路——那部分
// 依赖 MethodChannel 与广播，由真机验证）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shengwuji_app/utils/note_unlock_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('默认未解锁：无 key / 已过期时间戳 / 零值都判未解锁', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await NoteUnlockSession.isUnlocked(), isFalse);

    SharedPreferences.setMockInitialValues({
      'notes_unlock_until_ms': 0, // 原生 SCREEN_OFF 清零后的形态
    });
    expect(await NoteUnlockSession.isUnlocked(), isFalse);

    SharedPreferences.setMockInitialValues({
      'notes_unlock_until_ms':
          DateTime.now().millisecondsSinceEpoch - 1, // 刚过期
    });
    expect(await NoteUnlockSession.isUnlocked(), isFalse);
  });

  test('extend 后会话内生效，且有效期 ≈ now + 5 分钟', () async {
    final before = DateTime.now().millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({});
    await NoteUnlockSession.extend();
    final prefs = await SharedPreferences.getInstance();
    final until = prefs.getInt('notes_unlock_until_ms')!;
    expect(await NoteUnlockSession.isUnlocked(), isTrue);
    expect(
      until,
      inInclusiveRange(
        before + NoteUnlockSession.sessionDuration.inMilliseconds - 50,
        before + NoteUnlockSession.sessionDuration.inMilliseconds + 5000,
      ),
    );
  });

  test('extend 滑动续期：再次调用重置计时（不从首次认证起算）', () async {
    SharedPreferences.setMockInitialValues({
      'notes_unlock_until_ms': DateTime.now().millisecondsSinceEpoch + 1000,
    });
    await NoteUnlockSession.extend();
    final prefs = await SharedPreferences.getInstance();
    // 续期后必须明显晚于旧过期点（旧只剩 1s，新至少 5min）
    expect(
      prefs.getInt('notes_unlock_until_ms')!,
      greaterThan(DateTime.now().millisecondsSinceEpoch + 1000),
    );
  });

  test('revoke 立即失效（悬浮窗 relockNotes 事件路径）', () async {
    SharedPreferences.setMockInitialValues({});
    await NoteUnlockSession.extend();
    expect(await NoteUnlockSession.isUnlocked(), isTrue);
    await NoteUnlockSession.revoke();
    expect(await NoteUnlockSession.isUnlocked(), isFalse);
  });

  test('打码占位文本固定字数（防长度泄露的约定锁死）', () {
    expect(kLockedMaskText, '＊＊＊＊＊＊');
    expect(kLockedMaskText.length, 6);
  });
}
