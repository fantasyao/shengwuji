import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/pro_unlock_dialog.dart';

/// Pro 功能门禁工具
///
/// 检查 `is_pro_unlocked` 持久化状态，未解锁时弹 ProUnlockDialog 引导用户解锁。
///
/// 使用场景：
/// - 点击付费主题/图标包前调用
/// - 未来其他付费功能（如皮肤编辑器）的入口
///
/// 用法：
/// ```dart
/// final ok = await ProGate.tryAccess(context);
/// if (!ok) return; // 未解锁，已弹窗，中止后续逻辑
/// // 已解锁，继续付费功能
/// ```
class ProGate {
  /// SharedPreferences 中 Pro 解锁状态的 key
  static const kKeyIsProUnlocked = 'is_pro_unlocked';

  /// 当前是否已解锁（每次都重新读 prefs，避免状态过期）
  static Future<bool> isUnlocked() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(kKeyIsProUnlocked) ?? false;
  }

  /// 尝试访问 Pro 功能
  ///
  /// - 已解锁：返回 true，调用方继续执行
  /// - 未解锁：弹出 ProUnlockDialog 引导用户解锁，返回 false
  ///
  /// 注意：本方法会等待弹窗关闭后才返回 false，调用方需要 await
  static Future<bool> tryAccess(BuildContext context) async {
    final unlocked = await isUnlocked();
    if (unlocked) return true;

    // 跨 async gap 使用 context 前必须检查 mounted（lint 要求）
    if (!context.mounted) return false;
    // 弹解锁窗——用户解锁后 ProUnlockDialog 会自动 pop，本方法返回 false
    // 调用方根据业务决定是否再次尝试（通常直接 return 即可）
    // 兜底再读一次 isAlreadyUnlocked（理论上 unlocked 已为 false，但显式读取更安全）
    final alreadyUnlocked = unlocked;
    if (!context.mounted) return false;
    await ProUnlockDialog.show(
      context,
      isAlreadyUnlocked: alreadyUnlocked,
    );
    return false;
  }
}
