package com.shengwuji.app

import android.content.Context
import android.content.Intent

/**
 * 笔记解锁认证的发起协调器（单例）。
 *
 * 两个 Flutter engine（主 App / 悬浮窗）都通过各自 MethodChannel 发
 * requestUnlockAuth 到这里；认证本身由 [NoteUnlockActivity] 承接
 * （悬浮窗 engine 无 Activity，主 App 也统一走同一条链路——认证 UI 一份实现）。
 * 完成后经 [complete] 把结果回发给发起方的 engine：
 * - source=app → MainActivity.flutterChannel 推 noteUnlockResult（main.dart
 *   转发给 DiaryTabState）
 * - source=overlay → 无障碍服务的悬浮窗通道推 noteUnlockResult（OverlayHome）
 *
 * 会话写入（notes_unlock_until_ms）不在这里做——统一由 Dart 侧
 * NoteUnlockSession.extend 完成（prefs 读写纪律在 Dart 一处收口）。
 */
object NoteUnlockCoordinator {

    /** 发起方标记（extra key；与本文件 launch 的两个取值严格一致） */
    private const val EXTRA_SOURCE = "source"
    private const val SOURCE_APP = "app"
    private const val SOURCE_OVERLAY = "overlay"

    /** 同一时刻只允许一个认证流程（BP 对话框/锁屏解锁界面不叠两个） */
    @Volatile
    private var inFlight = false

    /**
     * 拉起认证 Activity。返回 false = 已有认证在进行（调用方直接忽略本次）。
     * Service 上下文必须 NEW_TASK（同 openDiaryPage 先例）；Activity 上下文
     * 由系统忽略该 flag，无副作用
     */
    fun launch(context: Context, fromOverlay: Boolean): Boolean {
        if (inFlight) {
            println("🔒 [NoteUnlock] 已有认证在进行，忽略重复请求")
            return false
        }
        return try {
            val intent = Intent(context, NoteUnlockActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(EXTRA_SOURCE, if (fromOverlay) SOURCE_OVERLAY else SOURCE_APP)
            context.startActivity(intent)
            inFlight = true
            println("🔒 [NoteUnlock] 认证 Activity 已拉起 (from=${if (fromOverlay) "overlay" else "app"})")
            true
        } catch (e: Exception) {
            inFlight = false
            println("❌ [NoteUnlock] 拉起认证 Activity 失败: ${e.message}")
            false
        }
    }

    /** 认证完成回发（NoteUnlockActivity finish 前调用；幂等清 inFlight） */
    fun complete(context: Context, source: String?, success: Boolean, reason: String?) {
        inFlight = false
        if (source == SOURCE_OVERLAY) {
            VolumeKeyAccessibilityService.instance?.notifyNoteUnlockResult(success)
        } else {
            // 主 engine：flutterChannel 静态可达（AlarmReceiver 推事件同款）。
            // engine 未启动时为 null，invokeMethod 静默丢弃——悬浮窗场景无主
            // engine 属正常，Dart 侧无 handler 收不到即可
            MainActivity.flutterChannel?.invokeMethod(
                "noteUnlockResult",
                mapOf("success" to success, "reason" to (reason ?: ""))
            )
        }
    }
}
