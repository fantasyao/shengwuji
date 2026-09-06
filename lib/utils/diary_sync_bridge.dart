import 'package:shared_preferences/shared_preferences.dart';

/// diary 表跨 engine 变更信号桥
///
/// 背景：主 engine 与 overlay engine 是独立 isolate，互不知晓对方写库
/// （旧 overlay_bridge MethodChannel 已废弃——两个 engine 的 messenger 互不相通）。
/// 写方每次写 diary 成功后 bump 计数器（落盘）；读方在恢复前台/展开面板时
/// prefs.reload() 比对计数，变了才刷新列表——有变更才重查，无变更零开销。
///
/// prefs key: `diary_change_counter`（int，单调递增；读写方都须 reload 后操作）
class DiarySyncBridge {
  DiarySyncBridge._();

  static const String counterKey = 'diary_change_counter';

  /// 写方：diary 表发生写入（增/改/删/归档/标注）后调用。
  /// fire-and-forget 容错：prefs 写失败不阻塞业务（下次读取方仍能靠后续 bump 同步）。
  static Future<void> bump() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload(); // 另一 engine 可能刚写过，必须 reload 再 +1 防覆盖
      final current = prefs.getInt(counterKey) ?? 0;
      await prefs.setInt(counterKey, current + 1);
    } catch (e) {
      print('⚠️ [DiarySyncBridge] bump 失败（不影响写库结果）: $e');
    }
  }

  /// 读方：返回当前计数（调用前必须已 prefs.reload()）
  static int current(SharedPreferences prefs) => prefs.getInt(counterKey) ?? 0;
}
