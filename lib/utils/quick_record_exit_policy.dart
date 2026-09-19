/// 快捷录音「退出即停」判定（纯函数，便于单测）。
///
/// 背景（努比亚滑动键用户反馈）：快捷方式拉起的日记录音在用户退出 App 后
/// 仍继续录，需要二次回 App 点停止。修复策略：快捷录音会话（lockedMode）
/// 在 App 退到后台**且屏幕仍亮着**时判定为"用户离开 App"，自动停止并照常
/// 转写保存。
///
/// 亮屏条件的存在是为了豁免"锁屏快捷录音中按电源键息屏"（场景 D）：息屏
/// 时 Flutter 同样收到 paused，但录音须继续（既有行为，锁屏之上录音的
/// 设计场景）——屏幕状态经 MethodChannel `isScreenOn`（PowerManager.
/// isInteractive）查询；查询失败返回 null 时宁可不停（保守，不截断录音）。
///
/// 调用方：DiaryTab.didChangeAppLifecycleState（延迟 800ms 后二次确认，
/// 覆盖息屏广播晚于 onPause 的竞态与"误触 Home 后立刻返回"的场景）。
library;

/// 是否应自动停止快捷录音。
///
/// - [isLockedRecording]：本会话由快捷方式/音量键拉起（startListening
///   lockedMode=true）；App 内手动点录音按钮的会话**不**自动停（后台续录
///   是既有行为，不在本次反馈范围内）
/// - [isListening]：仍在录音（延迟窗口内已手动停止则不再动）
/// - [isProcessing]：已在转写（等于已停录，无事可做）
/// - [appStillBackgrounded]：延迟复核时 App 仍处 paused/hidden（已回到
///   前台说明误触，续录）
/// - [screenOn]：屏幕交互中（true=亮屏停录；false=息屏续录；null=查询
///   失败，保守续录）
bool shouldAutoStopQuickRecording({
  required bool isLockedRecording,
  required bool isListening,
  required bool isProcessing,
  required bool appStillBackgrounded,
  required bool? screenOn,
}) {
  if (!isLockedRecording || !isListening || isProcessing) return false;
  if (!appStillBackgrounded) return false;
  return screenOn == true;
}
