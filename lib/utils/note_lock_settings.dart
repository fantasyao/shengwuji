import 'package:shared_preferences/shared_preferences.dart';

/// 笔记加锁功能总开关（设置页「笔记锁定」，免费功能无 Pro 门禁）。
///
/// 关闭后主 App 随手记、悬浮窗卡片、局域网电脑访问统一把加锁视为未启用：
/// 不渲染锁按钮、不发起认证、锁定笔记按明文展示。**落库的 diary.is_locked
/// 标记保留**（非破坏性）——重新开启后原有锁定立即恢复保护，不丢用户已做的
/// 逐条锁定选择。
///
/// 主 App 写，悬浮窗 / Web 服务（另一 engine 或本 isolate 的读取方）读；
/// 跨 engine 共享 prefs 文件，读取前必须 reload（同 NoteUnlockSession /
/// DiarySyncBridge 纪律）。
class NoteLockSettings {
  NoteLockSettings._();

  static const String enabledKey = 'note_lock_enabled';

  /// 当前是否启用加锁功能。缺省 true = 历史行为；读取失败也按开启兜底
  ///（安全侧，宁严不松）
  static Future<bool> isEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload(); // 主 engine 可能刚写过，必须 reload
      return prefs.getBool(enabledKey) ?? true;
    } catch (e) {
      print('⚠️ [NoteLockSettings] 读取开关失败（按开启兜底）: $e');
      return true;
    }
  }

  /// 保存开关（设置页写入口）
  static Future<void> setEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload(); // 写前 reload 防覆盖另一 engine 的写入
      await prefs.setBool(enabledKey, enabled);
    } catch (e) {
      print('⚠️ [NoteLockSettings] 写开关失败（下次启动仍按旧值）: $e');
    }
  }
}
