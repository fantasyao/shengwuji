import 'package:shared_preferences/shared_preferences.dart';

/// 锁定笔记的打码占位文本（主 App 列表 / 悬浮窗卡片 / 局域网服务 JSON 共用）。
/// 固定字数而非等长星号：等长会泄露笔记长度
const String kLockedMaskText = '＊＊＊＊＊＊';

/// 笔记解锁「会话」的跨 engine 共享状态。
///
/// 与 diary.is_locked（锁定标志，落库）是两回事：认证通过后本会话开始，
/// 有效期内所有锁定笔记免认证查看；会话过期/锁屏后卡片重新打码，但
/// is_locked 标志不动（无需重复逐条解锁）。
///
/// 主 engine 与悬浮窗 engine 是独立 isolate、共用同一 SharedPreferences
/// 文件，读写纪律与 DiarySyncBridge 一致：**任何读写前必须 prefs.reload()**
/// （另一 engine 可能刚写过，本地缓存会覆盖）。锁屏即失效由原生侧执行：
/// VolumeKeyAccessibilityService 的 ACTION_SCREEN_OFF 广播直接写
/// `flutter.notes_unlock_until_ms = 0`（不依赖 Dart isolate 存活），本类
/// 读取时 reload 天然感知。
///
/// prefs key: `notes_unlock_until_ms`（int，epoch 毫秒；0=未解锁）。
/// ⚠️ Kotlin 侧写同一 key 须用 putLong（Flutter setInt 落盘即 Long，
/// Kotlin getInt 读会 ClassCastException，同 volume_long_press_ms 教训）。
class NoteUnlockSession {
  NoteUnlockSession._();

  static const String key = 'notes_unlock_until_ms';

  /// 解锁有效期：认证成功后 N 分钟内免重复认证（对齐 OneNote 默认
  /// 「离开后约 10 分钟重锁」的宽松下限取半，速记场景交互要短平快）。
  /// 悬浮窗场景的最大威胁（锁屏被旁人看到）由「锁屏即失效」兜住，
  /// 不依赖本时效
  static const Duration sessionDuration = Duration(minutes: 5);

  /// 当前是否处于解锁会话内（写方：[extend] / 原生 SCREEN_OFF 清零；
  /// 读方：主 App DiaryTab / 悬浮窗 OverlayHome 渲染打码分支前）。
  /// 读取失败按「未解锁」兜底（最严处理）
  static Future<bool> isUnlocked() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload(); // 另一 engine / 原生可能刚写过，必须 reload
      final until = prefs.getInt(key) ?? 0;
      return until > DateTime.now().millisecondsSinceEpoch;
    } catch (e) {
      print('⚠️ [NoteUnlockSession] 读会话失败（按未解锁兜底）: $e');
      return false;
    }
  }

  /// 认证成功后调用：把有效期延长到 now + [sessionDuration]。
  /// 多次调用滑动续期（每次认证都重置计时）
  static Future<void> extend() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload(); // 写前 reload 防覆盖另一 engine 的写入
      await prefs.setInt(
        key,
        DateTime.now().millisecondsSinceEpoch +
            sessionDuration.inMilliseconds,
      );
    } catch (e) {
      print('⚠️ [NoteUnlockSession] 写会话失败（下次认证重新生效）: $e');
    }
  }

  /// 立即重锁（悬浮窗收到原生 relockNotes 事件时调用；原生 SCREEN_OFF
  /// 路径自己清零不经过本方法）
  static Future<void> revoke() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      await prefs.setInt(key, 0);
    } catch (e) {
      print('⚠️ [NoteUnlockSession] 重锁失败: $e');
    }
  }
}
