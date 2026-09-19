import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../app_logger.dart';
import '../widgets/pro_unlock_dialog.dart';

/// Pro 功能门禁工具
///
/// 两层可用状态（满足其一即 Pro 可用）：
/// - 永久解锁：`is_pro_unlocked=true` **且** 存在授权码记录 `pro_license_code`。
///   ⚠️ 必须两者同时成立——旧版（君子协定）用户点一下就有 is_pro_unlocked=true
///   但无码记录，授权码体系上线后不得再认裸布尔（2026-09-19 用户拍板：存量
///   免费解锁用户升级即失效，走试用/输码流程；确有付费的找开发者补码）
/// - 试用中：`pro_trial_deadline_ms` 毫秒时间戳未到（点「先试用 7 天」写入，一次性不可重试）
///
/// 试用到期后各门禁点即时拦截；Pro 主题的启动回退在 main.dart 恢复处（下次启动生效）。
/// 悬浮窗的按键拦截在 Kotlin 侧（VolumeKeyAccessibilityService.isProUnlocked 同判这三 key）。
///
/// 用法：
/// ```dart
/// final ok = await ProGate.tryAccess(context);
/// if (!ok) return; // 不可用，已弹窗，中止后续逻辑
/// // 可用，继续 Pro 功能
/// ```
class ProGate {
  /// SharedPreferences 中 Pro 永久解锁状态的 key（Kotlin 侧同名读 flutter. 前缀）。
  /// ⚠️ 单看此 key 不构成解锁（旧版君子协定遗留），必须搭配 [kKeyLicenseCode]
  static const kKeyIsProUnlocked = 'is_pro_unlocked';

  /// 授权码记录（normalize 后的 16 位码，输码验证通过时写入）。
  /// 与 [kKeyIsProUnlocked] 同时存在才算永久解锁——存量旧版用户无此记录
  static const kKeyLicenseCode = 'pro_license_code';

  /// 试用截止时间（epoch 毫秒）；0/缺失 = 从未开过试用
  static const kKeyTrialDeadlineMs = 'pro_trial_deadline_ms';

  /// 试用时长
  static const trialDuration = Duration(days: 7);

  /// 当前是否永久解锁（授权码体系：解锁布尔 + 授权码记录必须同时存在；
  /// 每次都重新读 prefs，避免状态过期）
  static Future<bool> isUnlocked() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getBool(kKeyIsProUnlocked) ?? false) &&
        (prefs.getString(kKeyLicenseCode)?.isNotEmpty ?? false);
  }

  /// 纯函数：给定 prefs 与当前时刻判断 Pro 是否可用（试用窗口判定可注入时钟单测）
  static bool isProActiveWithPrefs(SharedPreferences prefs, {int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    // 永久解锁 = 解锁布尔 + 授权码记录同时成立（裸布尔是旧版君子协定遗留，不认）
    final unlocked = (prefs.getBool(kKeyIsProUnlocked) ?? false) &&
        (prefs.getString(kKeyLicenseCode)?.isNotEmpty ?? false);
    if (unlocked) return true;
    final deadline = prefs.getInt(kKeyTrialDeadlineMs) ?? 0;
    return deadline > 0 && now < deadline;
  }

  /// 当前 Pro 是否可用（永久解锁 或 试用中）
  static Future<bool> isProActive() async {
    final prefs = await SharedPreferences.getInstance();
    return isProActiveWithPrefs(prefs);
  }

  /// 试用剩余整警告天数（向上取整；未开试用/已过期返回 0）
  static int remainingTrialDaysWithPrefs(SharedPreferences prefs, {int? nowMs}) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final deadline = prefs.getInt(kKeyTrialDeadlineMs) ?? 0;
    if (deadline <= now) return 0;
    return ((deadline - now) / Duration.millisecondsPerDay).ceil();
  }

  /// 开启 7 天试用。一次性：已开过（含已过期）返回 false 不重置。
  static Future<bool> startTrial() async {
    final prefs = await SharedPreferences.getInstance();
    if ((prefs.getInt(kKeyTrialDeadlineMs) ?? 0) != 0) return false;
    final deadline =
        DateTime.now().add(trialDuration).millisecondsSinceEpoch;
    await prefs.setInt(kKeyTrialDeadlineMs, deadline);
    log('✓ Pro 试用已开启，截止 $deadline（7 天）');
    return true;
  }

  /// 尝试访问 Pro 功能
  ///
  /// - 可用（永久解锁或试用中）：返回 true，调用方继续执行
  /// - 不可用：弹出 ProUnlockDialog 引导付费/试用/输码；用户在弹窗内试用激活或
  ///   授权码验证成功时弹窗 pop(true)，本方法返回 true——调用方可继续原操作
  ///   （如应用刚点击的主题卡片）
  ///
  /// 注意：本方法会等待弹窗关闭后才返回，调用方需要 await
  static Future<bool> tryAccess(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    if (isProActiveWithPrefs(prefs)) return true;

    // 跨 async gap 使用 context 前必须检查 mounted（lint 要求）
    if (!context.mounted) return false;
    return ProUnlockDialog.show(context);
  }
}
