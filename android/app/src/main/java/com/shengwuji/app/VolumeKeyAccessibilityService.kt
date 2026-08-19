package com.shengwuji.app

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.PowerManager
import android.content.Context

class VolumeKeyAccessibilityService : AccessibilityService() {

    companion object {
        // 长按阈值（毫秒）
        private const val LONG_PRESS_DURATION_MS = 500L
        // 双击判定窗口（毫秒）
        private const val DOUBLE_CLICK_THRESHOLD_MS = 300L
        // SharedPreferences 相关
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val PREF_KEY = "flutter.volume_key_mode"
        // 默认值：只监听音量减
        private const val DEFAULT_MODE = "down"
    }

    // 标记是否已触发长按（避免持续触发）
    private var isLongPressTriggered = false
    // 记录最后按下的 keyCode，用于短按时手动调音量
    private var lastKeyCode = 0

    // Handler 方案：不依赖 repeatCount（三星 ROM 不发送重复事件）
    private val longPressHandler = Handler(Looper.getMainLooper())
    private val longPressRunnable = Runnable {
        if (!isLongPressTriggered) {
            isLongPressTriggered = true
            triggerQuickRecord()
        }
    }

    // 双击检测相关
    private var lastClickTime = 0L
    private var lastClickKeyCode = 0
    private var pendingSingleClick: Runnable? = null
    private val singleClickHandler = Handler(Looper.getMainLooper())

    // 读取用户设置的监听模式：off / up / down / both
    private fun getVolumeKeyMode(): String {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getString(PREF_KEY, DEFAULT_MODE) ?: DEFAULT_MODE
    }

    // 检查 Flutter 层是否正在录音
    private fun isRecording(): Boolean {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getBoolean("flutter.is_recording", false)
    }

    // 判断当前按键是否在监听范围内
    private fun isKeyMonitored(keyCode: Int): Boolean {
        val mode = getVolumeKeyMode()
        return when (mode) {
            "off" -> false
            "up" -> keyCode == KeyEvent.KEYCODE_VOLUME_UP
            "down" -> keyCode == KeyEvent.KEYCODE_VOLUME_DOWN
            "both" -> keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN
            else -> false
        }
    }

    override fun onKeyEvent(event: KeyEvent): Boolean {
        // 只处理音量键
        if (event.keyCode != KeyEvent.KEYCODE_VOLUME_UP && event.keyCode != KeyEvent.KEYCODE_VOLUME_DOWN) {
            return false
        }

        // 不在监听范围内的按键，交给系统正常处理
        if (!isKeyMonitored(event.keyCode)) {
            return false
        }

        if (event.action == KeyEvent.ACTION_DOWN) {
            // 消费 ACTION_DOWN，阻止系统音量变化
            lastKeyCode = event.keyCode

            // 如果有等待中的单击，取消它（用户又按下了，可能是双击）
            pendingSingleClick?.let { singleClickHandler.removeCallbacks(it) }
            pendingSingleClick = null

            // 启动长按计时器
            longPressHandler.postDelayed(longPressRunnable, LONG_PRESS_DURATION_MS)
            println("🔑 [Accessibility] 按键按下(已拦截): keyCode=${event.keyCode}")
            return true
        } else if (event.action == KeyEvent.ACTION_UP) {
            // 取消长按计时
            longPressHandler.removeCallbacks(longPressRunnable)
            val wasLongPress = isLongPressTriggered
            isLongPressTriggered = false

            if (wasLongPress) {
                println("🔑 [Accessibility] 按键抬起: 长按已处理")
                return true // 长按已处理，不再做其他操作
            }

            val now = System.currentTimeMillis()
            val timeSinceLastClick = now - lastClickTime

            // 录音中不做双击检测，直接调音量
            if (isRecording()) {
                adjustVolume(event.keyCode)
                println("🔑 [Accessibility] 录音中，直接调音量: keyCode=${event.keyCode}")
                return true
            }

            if (timeSinceLastClick < DOUBLE_CLICK_THRESHOLD_MS && lastClickKeyCode == event.keyCode) {
                // 双击确认
                lastClickTime = 0L
                lastClickKeyCode = 0
                triggerQuickTextNote()
            } else {
                // 第一次点击或超时 → 延迟确认不是双击后再调音量
                lastClickTime = now
                lastClickKeyCode = event.keyCode

                val keyCode = event.keyCode
                pendingSingleClick = Runnable {
                    adjustVolume(keyCode)
                    pendingSingleClick = null
                }
                singleClickHandler.postDelayed(pendingSingleClick!!, DOUBLE_CLICK_THRESHOLD_MS)
            }
            println("🔑 [Accessibility] 按键抬起: wasLongPress=$wasLongPress, timeSinceLastClick=$timeSinceLastClick")
            return true // 消费所有事件，防止系统二次处理
        }

        return false
    }

    // 短按时手动调整音量
    private fun adjustVolume(keyCode: Int) {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val direction = when (keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> AudioManager.ADJUST_RAISE
            KeyEvent.KEYCODE_VOLUME_DOWN -> AudioManager.ADJUST_LOWER
            else -> return
        }
        audioManager.adjustVolume(direction, AudioManager.FLAG_SHOW_UI)
        // 如果正在录音静音中，用户按了音量减，标记为保持静音
        if (direction == AudioManager.ADJUST_LOWER) {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val keepMutedEnabled = prefs.getBoolean("flutter.keep_muted_on_volume_down", true)
            if (keepMutedEnabled && prefs.contains("flutter.saved_media_volume")) {
                prefs.edit().putBoolean("flutter.keep_muted", true).apply()
                println("🔇 [Accessibility] 用户按音量减，标记保持静音")
            } else if (!keepMutedEnabled) {
                println("🔇 [Accessibility] 按音量减保持静音已关闭，不标记 keep_muted")
            }
        }
        println("🔑 [Accessibility] 短按手动调音量: keyCode=$keyCode")
    }

    /**
     * 锁屏状态下临时点亮屏幕。
     * 屏幕熄灭时 acquire 一个 3 秒超时的 WakeLock（自动释放，避免耗电）。
     * 这是 Android 推荐做法（PARTIAL_WAKE_LOCK 无法点亮屏幕，必须用 SCREEN_*_WAKE_LOCK + ACQUIRE_CAUSES_WAKEUP）。
     */
    private fun wakeScreenIfLocked() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (!powerManager.isInteractive) {
                @Suppress("DEPRECATION")
                val wakeLock = powerManager.newWakeLock(
                    PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                    PowerManager.ACQUIRE_CAUSES_WAKEUP or
                    PowerManager.ON_AFTER_RELEASE,
                    "shengwuji:volume_key_wake"
                )
                wakeLock.acquire(3000L)  // 3 秒超时自动释放
                println("💡 [Accessibility] 屏幕熄灭，已点亮 (3秒超时)")
            }
        } catch (e: Exception) {
            println("⚠️ [Accessibility] 唤醒屏幕失败: ${e.message}")
        }
    }

    private fun triggerQuickRecord() {
        // 锁屏状态下先点亮屏幕（屏幕熄灭时才能在锁屏之上显示 Activity）
        wakeScreenIfLocked()

        // 震动反馈（让用户知道触发了）
        val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createOneShot(100, 70))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(100)
        }

        // 构建与快捷方式相同的 Intent，复用现有链路
        // 注意：必须用 getLaunchIntentForPackage 获取当前 enabled 的 launcher component，
        // 否则用户切换图标包后 MainActivity 被禁用，显式 Intent(this, MainActivity::class.java) 会启动失败
        val intent = packageManager.getLaunchIntentForPackage(packageName) ?: run {
            println("❌ [Accessibility] 快速录音：无法获取 launch intent (packageName=$packageName)")
            return
        }
        intent.apply {
            action = Intent.ACTION_VIEW
            data = Uri.parse("quick_record")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            // 锁屏显示由 AndroidManifest 的 showWhenLocked/turnScreenOn 属性
            // + MainActivity.onCreate 中的 setShowWhenLocked/setTurnScreenOn 负责
            // （Intent.FLAG_SHOW_WHEN_LOCKED 在新 SDK 已从 Intent 类移除）
        }
        startActivity(intent)
        println("✅ [Accessibility] 长按音量键触发快速录音")
    }

    private fun triggerQuickTextNote() {
        // 锁屏状态下先点亮屏幕
        wakeScreenIfLocked()

        // 检查双击文本笔记开关
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val doubleClickEnabled = prefs.getBoolean("flutter.double_click_text_note", true)
        if (!doubleClickEnabled) {
            println("ℹ️ [Accessibility] 双击文本笔记已关闭，跳过")
            return
        }

        // 震动反馈：双击用两段短震（区别于长按的单段 100ms）
        val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // 双击模式：50ms 震动 + 50ms 停顿 + 50ms 震动
            vibrator.vibrate(VibrationEffect.createWaveform(
                longArrayOf(0, 50, 50, 50), intArrayOf(0, 80, 0, 80), -1))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(longArrayOf(0, 50, 50, 50), -1)
        }

        // 用 getLaunchIntentForPackage 获取当前 enabled 的 launcher component，
        // 否则用户切换图标包后 MainActivity 被禁用，显式 Intent 启动会失败
        val intent = packageManager.getLaunchIntentForPackage(packageName) ?: run {
            println("❌ [Accessibility] 文本笔记：无法获取 launch intent (packageName=$packageName)")
            return
        }
        intent.apply {
            action = Intent.ACTION_VIEW
            data = Uri.parse("quick_text_note")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        startActivity(intent)
        println("✅ [Accessibility] 双击音量键触发新建文本笔记")
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        // 三星等 ROM 可能忽略 XML 中的 flagRequestFilterKeyEvents，需代码中再次请求
        serviceInfo = serviceInfo.apply {
            flags = flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_REQUEST_FILTER_KEY_EVENTS
        }
        println("✅ [Accessibility] 无障碍服务已连接，按键过滤已启用")
    }

    override fun onInterrupt() {
        singleClickHandler.removeCallbacksAndMessages(null)
        println("⚠️ [Accessibility] 无障碍服务被中断")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // 不需要处理无障碍事件，仅用于按键监听
    }
}
