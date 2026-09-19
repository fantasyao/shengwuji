package com.shengwuji.app

import android.app.Activity
import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Toast

/**
 * 外部快捷动作的透明分发层（无 UI、无 Flutter 引擎，冷启动极轻）。
 *
 * 背景：努比亚 Z60S Pro 等机型的侧边滑动键（以及灵动键类硬件）只能映射到
 * 「应用快捷方式」。悬浮窗语音速记此前只有音量键手势一个入口，无法被这类
 * 硬件触发。本 Activity 作为静态快捷方式「悬浮窗语音速记」（shortcuts.xml
 * 的 overlay_record）的落地组件，把动作直接转交给无障碍服务——与音量键
 * 手势完全同一执行链路（executeGestureAction → triggerVoiceMemoOverlay：
 * toggle 语义 / Pro 门禁 / 麦克风互斥让位 / 震动反馈 / 四级 watchdog 全部
 * 复用），全程不把主 App 拉到前台。
 *
 * 为什么不落在 MainActivity 上：快捷方式 Intent 启动 Activity 必然前台化，
 * 主 App 会整个弹出来盖住当前场景，违背"快捷呼出"的初衷；透明分发层
 * （translucent + 空 taskAffinity 独立 task + excludeFromRecents）用户侧
 * 感知只有悬浮窗胶囊本身。
 *
 * 前置条件：无障碍服务已启用（悬浮窗本就寄生于该服务，音量键手势同款
 * 要求）。服务未运行时短暂重试（服务可能正在随进程重启绑定中），仍不可
 * 达则 Toast 引导。
 */
class ShortcutDispatchActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val gestureAction = when (intent?.action) {
            // 与 VolumeKeyAccessibilityService.ACTION_OVERLAY_RECORD 字符串严格一致
            //（服务侧常量为 private，沿用仓库「双侧常量 + 注释钉同步」惯例）
            ACTION_OVERLAY_RECORD -> "overlay_record"
            else -> null
        }

        if (gestureAction != null) {
            println("🪟 [ShortcutDispatch] 收到外部快捷动作: ${intent.action} → $gestureAction")
            dispatchToService(applicationContext, gestureAction, RETRY_TIMES)
        } else {
            println("⚠️ [ShortcutDispatch] 未识别的 action: ${intent?.action}，忽略")
        }

        // 立即退场：重试走主线程 Handler + application context，不持有本 Activity
        finish()
    }

    companion object {
        // 与 AndroidManifest 的 intent-filter / shortcuts.xml 的 intent action 严格一致
        private const val ACTION_OVERLAY_RECORD = "com.shengwuji.app.ACTION_OVERLAY_RECORD"

        // 服务实例不可达时的重试次数（间隔 RETRY_INTERVAL_MS，总计约 2s）：
        // 覆盖"进程刚被拉起、已启用的无障碍服务尚在绑定中"的竞态窗口
        private const val RETRY_TIMES = 6
        private const val RETRY_INTERVAL_MS = 350L

        private val handler = Handler(Looper.getMainLooper())

        /**
         * 把手势动作转交给无障碍服务（同进程静态引用，无 IPC）。
         * 必须在主线程调用（onCreate 与主线程 Handler 均满足；
         * executeGestureAction 内部的震动/浮窗操作要求主线程）。
         */
        private fun dispatchToService(context: Context, gestureAction: String, retriesLeft: Int) {
            val service = VolumeKeyAccessibilityService.instance
            if (service != null) {
                println("✅ [ShortcutDispatch] 分发外部快捷动作: $gestureAction")
                service.executeGestureAction(gestureAction)
                return
            }
            if (retriesLeft <= 0) {
                println("❌ [ShortcutDispatch] 无障碍服务不可达，无法执行: $gestureAction")
                Toast.makeText(
                    context,
                    "悬浮窗录音需要先在系统设置中开启声物记的无障碍服务",
                    Toast.LENGTH_LONG
                ).show()
                return
            }
            handler.postDelayed({
                dispatchToService(context, gestureAction, retriesLeft - 1)
            }, RETRY_INTERVAL_MS)
        }
    }
}
