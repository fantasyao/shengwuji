import 'package:flutter/services.dart';

/// 笔记解锁认证的发起封装（主 App 侧）。
///
/// 认证由原生 NoteUnlockCoordinator 统一承接（锁屏中 requestDismissKeyguard
/// 弹系统解锁界面 / 未锁屏弹 androidx.biometric 对话框），invokeMethod 只等
/// 「是否成功拉起」；认证结果异步经 MainActivity → flutterChannel 的
/// noteUnlockResult 事件回发，由 main.dart 转发给 DiaryTabState.onNoteUnlockResult。
/// 悬浮窗侧同款发起走 AccessibilityOverlay.requestUnlockAuth（通道不同）。
class NoteLockAuth {
  NoteLockAuth._();

  /// 主 App 发起系统认证（MainActivity 通道）。返回 false = 已有认证在进行
  /// （Kotlin 层 coordinator 防重），可安全重复调用
  static Future<bool> requestFromApp() async {
    try {
      return await MethodChannel(
        'com.shengwuji.app/app',
      ).invokeMethod('requestUnlockAuth') == true;
    } catch (e) {
      print('❌ [NoteLockAuth] 发起认证失败: $e');
      return false;
    }
  }
}
