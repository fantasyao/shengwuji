package com.shengwuji.app

import android.accessibilityservice.AccessibilityService
import android.content.ClipData
import android.content.ClipboardManager
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
import android.content.SharedPreferences
import android.graphics.Color
import android.graphics.PixelFormat
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewTreeObserver
import android.view.WindowManager
import android.widget.Toast
import java.util.concurrent.atomic.AtomicBoolean
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterTextureView
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

class VolumeKeyAccessibilityService : AccessibilityService() {

    companion object {
        // 长按阈值（毫秒）
        private const val LONG_PRESS_DURATION_MS = 500L
        // 双击判定窗口（毫秒）
        private const val DOUBLE_CLICK_THRESHOLD_MS = 300L
        // SharedPreferences 相关
        private const val PREFS_NAME = "FlutterSharedPreferences"

        // 4 个手势槽位的新配置 key（写入方：Flutter 设置页；读取方：本服务 getLongPressAction / getDoubleClickAction）
        private const val GESTURE_KEY_LONG_UP = "flutter.volume_gesture_long_press_up"
        private const val GESTURE_KEY_LONG_DOWN = "flutter.volume_gesture_long_press_down"
        private const val GESTURE_KEY_DOUBLE_CLICK_UP = "flutter.volume_gesture_double_click_up"
        private const val GESTURE_KEY_DOUBLE_CLICK_DOWN = "flutter.volume_gesture_double_click_down"

        // 旧配置 key（写入方：Flutter 设置页旧版本；读取方：migrate* 迁移函数——
        // 新 key 不存在/非法时从这些旧 key 推导，无障碍服务常驻、App 未打开也要能正确推导）
        private const val LEGACY_KEY_MODE = "flutter.volume_key_mode"
        private const val LEGACY_KEY_OVERLAY_LONG_PRESS = "flutter.overlay_volume_up_long_press"
        private const val LEGACY_KEY_OVERLAY_ACTION = "flutter.overlay_volume_up_action"
        private const val LEGACY_KEY_DOUBLE_CLICK = "flutter.double_click_text_note"

        // 6 个手势槽位动作常量（与 Dart 侧严格一致；写入方：Flutter 设置页；读取方：onKeyEvent 状态机 / executeGestureAction）
        private const val ACTION_NONE = "none"
        private const val ACTION_SHOW_OVERLAY = "show_overlay"
        private const val ACTION_OVERLAY_RECORD = "overlay_record"
        private const val ACTION_QUICK_RECORD = "quick_record"
        private const val ACTION_QUICK_TEXT_NOTE = "quick_text_note"
        // 悬浮窗新增笔记：显示浮窗（若未显示）并自动展开面板 + 新增一条空白笔记进入编辑态
        //（Kotlin 只发 newNote 消息，expand + 新增由 Dart 侧 handler 完成；已显示时不 toggle 隐藏，直接再发一次）
        private const val ACTION_OVERLAY_NEW_NOTE = "overlay_new_note"
        // stopVoiceMemo 回执超时（毫秒）：Dart 卡死时防 toggle 死锁的最简兜底
        // （完整四级 watchdog 见 voiceMemoWatchdog* 系列——本超时只负责 stop 消息的回执兜底）
        private const val VOICE_MEMO_STOP_TIMEOUT_MS = 3000L
        // 语音速记录音上限（毫秒）：Dart 侧上限 Timer 停录（T0），Kotlin T1 同刻补发兜底。
        // 唯一真值在 Dart 侧 overlay_constants.dart voiceMemoMaxSeconds，改值须双侧同步
        private const val VOICE_MEMO_MAX_DURATION_MS = 300000L
        // overlay engine 的独立缓存 key（唯一真值；getOrCreateOverlayEngine / destroyOverlayEngine 共用）
        private const val OVERLAY_ENGINE_CACHE_KEY = "shengwuji_accessibility_overlay"
        // 语音速记冷启动隐藏窗口的直建尺寸（dp）：312 宽 / 64 高。
        // ⚠️ 硬编码副本——唯一真值在 Dart 侧 lib/overlay/overlay_constants.dart
        // （voiceMemoMaxWidth 300 + voiceMemoEdgeMargin 12 = 312 宽 / voiceMemoWindowHeight 64 高），
        // 改胶囊尺寸必须双侧同步
        private const val VOICE_MEMO_OVERLAY_WIDTH_DP = 312
        private const val VOICE_MEMO_OVERLAY_HEIGHT_DP = 64

        // 供主 Activity / Flutter 调用，控制无障碍浮窗
        var instance: VolumeKeyAccessibilityService? = null
            private set
    }

    // 标记是否已触发长按（避免持续触发）
    private var isLongPressTriggered = false
    // DOWN 时缓存的长按槽位动作，longPressRunnable 执行时直接用。
    // 写入方：onKeyEvent ACTION_DOWN（缓存）；清空方：ACTION_UP + onInterrupt。
    // 为什么缓存：runnable 执行时若二次读 prefs，期间配置被改写会与 DOWN 时的判定不一致
    private var currentLongPressAction: String? = null

    // Handler 方案：不依赖 repeatCount（三星 ROM 不发送重复事件）
    private val longPressHandler = Handler(Looper.getMainLooper())
    private val longPressRunnable = Runnable {
        if (!isLongPressTriggered) {
            isLongPressTriggered = true
            currentLongPressAction?.let { executeGestureAction(it) }
        }
    }

    // 双击检测相关
    private var lastClickTime = 0L
    private var lastClickKeyCode = 0
    private var pendingSingleClick: Runnable? = null
    private val singleClickHandler = Handler(Looper.getMainLooper())

    // 无障碍浮窗（TYPE_ACCESSIBILITY_OVERLAY）
    private var overlayWindowManager: WindowManager? = null
    private var overlayView: FlutterView? = null
    private var overlayMethodChannel: MethodChannel? = null

    // Dart 侧 handler 是否已注册（= engine 为复用；随 engine 存活而非 service 实例）。
    // 写入方：getOrCreateOverlayEngine 复用分支(置 true) / 新建分支(置 false) / dartReady 握手(置 true)；
    // 读取方：notifyDartExpand 决定直接发 expand 还是挂起 pendingAutoExpand
    private var dartReady = false
    // Dart 未就绪时挂起的自动展开请求（dartReady 握手到达后补发）
    private var pendingAutoExpand = false
    // Dart 未就绪时挂起的新增笔记请求（dartReady 握手到达后补发，与 pendingAutoExpand 同机制；
    // 生命周期清理严格镜像 pendingAutoExpand：仅 destroyOverlayEngine 清零 + 握手分支补发后复位）
    private var pendingNewNote = false

    // 语音速记（音量上键长按直接录音，action=record）的 toggle 状态。
    // 写入方：triggerVoiceMemoOverlay(启动置 true) / voiceMemoStopped·voiceMemoFailed 回执
    //         与 stop 超时兜底(置 false)；读取方：triggerVoiceMemoOverlay 的 toggle 分流
    private var voiceMemoActive = false
    // Dart 未就绪时挂起的语音速记启动请求（dartReady 握手到达后补发，与 pendingAutoExpand 同机制）
    private var pendingVoiceMemoStart = false
    // 语音速记隐藏窗口标记：showOverlay(hidden=true) 时窗口直接以胶囊尺寸（312×64）addView，
    // 但 alpha=0 + FLAG_NOT_TOUCHABLE（FlutterView 在 engine 渲染期间必须 attach 到窗口——
    // 未 attach 时 Dart 推 semantics 更新，AccessibilityBridge.sendAccessibilityEvent 调
    // view.parent.requestSendAccessibilityEvent 必 NPE → JNI fatal → SIGABRT，
    // 2026-08-29 deferred-addView 方案因此崩溃废弃）。
    // 直建胶囊尺寸 = 把手尺寸的窗口在此路径中不存在，无 resize、无把手帧，把手像素
    // 物理上不可能出现（根治"冷启动把手一闪而过"，替代旧的"28×88 隐藏窗口等 resize"方案）；
    // Dart 录音态首帧渲染完发 voiceMemoUiReady 才 alpha=1 揭示——首帧即正确尺寸胶囊。
    // 写入方：showOverlay(hidden=true)；清空方：voiceMemoUiReady 揭示 / hideOverlay / destroyOverlayEngine
    private var pendingVoiceMemoReveal = false
    // stopVoiceMemo 发出后等待 Dart 回执 voiceMemoStopped 的超时兜底计时（对齐 longPressHandler 的 Handler 模式）
    private val voiceMemoStopTimeoutHandler = Handler(Looper.getMainLooper())
    private var voiceMemoStopTimeoutRunnable: Runnable? = null

    // 四级 watchdog 救生链（相对录音启动时刻，单 Handler + 四个 Runnable，cancel 时全部移除）：
    //   T1 +60s：voiceMemoActive 仍 true → 补发 stopVoiceMemo（Dart 的 60s Timer(T0) 可能没收到/没执行）
    //   T2 +63s：仍 true → 再补发一次
    //   T3 +66s：仍 true → 判定 Dart isolate 卡死 → hideOverlay()（纯 Kotlin 移窗，桌面立即可用）
    //   T4 +76s：is_recording（落盘 prefs 为准，不信任回执）仍 true → destroyOverlayEngine()（最后手段释放 mic）
    private val voiceMemoWatchdogHandler = Handler(Looper.getMainLooper())
    private val voiceMemoWatchdogT1 = Runnable {
        if (!voiceMemoActive) return@Runnable
        println("⚠️ [Accessibility] watchdog T1(+60s)：语音速记未自行结束，补发 stopVoiceMemo")
        overlayMethodChannel?.invokeMethod("stopVoiceMemo", null)
    }
    private val voiceMemoWatchdogT2 = Runnable {
        if (!voiceMemoActive) return@Runnable
        println("⚠️ [Accessibility] watchdog T2(+63s)：仍 active，再补发一次 stopVoiceMemo")
        overlayMethodChannel?.invokeMethod("stopVoiceMemo", null)
    }
    private val voiceMemoWatchdogT3 = Runnable {
        if (!voiceMemoActive) return@Runnable
        println("🚨 [Accessibility] watchdog T3(+66s)：Dart 无响应，强制移除悬浮窗")
        hideOverlay()
    }
    private val voiceMemoWatchdogT4 = Runnable {
        // T4 不信任回执：直接读落盘的 flutter.is_recording prefs 判定麦克风是否仍被占用
        if (!isRecording()) return@Runnable
        println("🚨 [Accessibility] watchdog T4(+76s)：is_recording 仍为 true，销毁 overlay engine 释放麦克风")
        destroyOverlayEngine()
    }

    // ==================== 手势槽位配置读取（4 槽位 × 6 动作）====================

    // 读取长按槽位动作（keyCode 区分音量加/减）
    private fun getLongPressAction(keyCode: Int): String {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
            getGestureAction(prefs, GESTURE_KEY_LONG_UP) { migrateLongPressUp(prefs) }
        } else {
            getGestureAction(prefs, GESTURE_KEY_LONG_DOWN) { migrateLongPressDown(prefs) }
        }
    }

    // 读取双击槽位动作（keyCode 区分音量加/减）
    private fun getDoubleClickAction(keyCode: Int): String {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
            getGestureAction(prefs, GESTURE_KEY_DOUBLE_CLICK_UP) { migrateDoubleClickUp(prefs) }
        } else {
            getGestureAction(prefs, GESTURE_KEY_DOUBLE_CLICK_DOWN) { migrateDoubleClickDown(prefs) }
        }
    }

    // 通用读取：新 key 的值为 6 个合法动作之一则直接用，否则（不存在/非法值）走迁移推导
    private fun getGestureAction(prefs: SharedPreferences, newKey: String, migrate: () -> String): String {
        val action = prefs.getString(newKey, null)
        return when (action) {
            ACTION_NONE, ACTION_SHOW_OVERLAY, ACTION_OVERLAY_RECORD,
            ACTION_QUICK_RECORD, ACTION_QUICK_TEXT_NOTE, ACTION_OVERLAY_NEW_NOTE -> action!!
            else -> migrate()
        }
    }

    // 旧监听模式（off/up/down/both），不存在时默认 "down"——恰好推出出厂默认：
    // 长按减=quick_record、双击减=quick_text_note、加键两槽=none
    private fun legacyMode(prefs: SharedPreferences): String {
        return prefs.getString(LEGACY_KEY_MODE, "down") ?: "down"
    }

    // 迁移：长按音量加。旧悬浮窗开关开启时优先（当年优先级高于 mode），
    // record=语音速记 / 其他=显示浮窗；否则 mode 含 up → 快速录音；否则无动作
    private fun migrateLongPressUp(prefs: SharedPreferences): String {
        if (prefs.getBoolean(LEGACY_KEY_OVERLAY_LONG_PRESS, false)) {
            return if (prefs.getString(LEGACY_KEY_OVERLAY_ACTION, null) == "record") {
                ACTION_OVERLAY_RECORD
            } else {
                ACTION_SHOW_OVERLAY
            }
        }
        val mode = legacyMode(prefs)
        return if (mode == "up" || mode == "both") ACTION_QUICK_RECORD else ACTION_NONE
    }

    // 迁移：长按音量减。mode 含 down → 快速录音；否则无动作
    private fun migrateLongPressDown(prefs: SharedPreferences): String {
        val mode = legacyMode(prefs)
        return if (mode == "down" || mode == "both") ACTION_QUICK_RECORD else ACTION_NONE
    }

    // 迁移：双击音量加。mode 含 up 且双击笔记开关未关闭（默认开）→ 文本笔记；否则无动作
    private fun migrateDoubleClickUp(prefs: SharedPreferences): String {
        val mode = legacyMode(prefs)
        return if ((mode == "up" || mode == "both") && prefs.getBoolean(LEGACY_KEY_DOUBLE_CLICK, true)) {
            ACTION_QUICK_TEXT_NOTE
        } else {
            ACTION_NONE
        }
    }

    // 迁移：双击音量减。mode 含 down 且双击笔记开关未关闭（默认开）→ 文本笔记；否则无动作
    private fun migrateDoubleClickDown(prefs: SharedPreferences): String {
        val mode = legacyMode(prefs)
        return if ((mode == "down" || mode == "both") && prefs.getBoolean(LEGACY_KEY_DOUBLE_CLICK, true)) {
            ACTION_QUICK_TEXT_NOTE
        } else {
            ACTION_NONE
        }
    }

    // 检查 Flutter 层是否正在录音
    private fun isRecording(): Boolean {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getBoolean("flutter.is_recording", false)
    }

    // 录音中存在临时静音现场时兜底恢复媒体音量（悬浮窗被原生强杀的路径：
    // T3 移窗 / T4 销毁 engine / service 销毁——这些路径 Dart 侧 restoreMedia
    // 不会执行，不兜底会让手机永久静音）。无现场 / 非录音中均为幂等 no-op
    private fun restoreMutedMediaIfRecording() {
        if (isRecording()) MediaMuteHelper.restore(this)
    }

    // 检查 Pro 是否已解锁（设置页/弹窗写入 flutter.is_pro_unlocked，与 isRecording 同款落盘读取模式）
    private fun isProUnlocked(): Boolean {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getBoolean("flutter.is_pro_unlocked", false)
    }

    /**
     * 悬浮窗系动作的 Pro 门禁：未解锁时震动 + Toast 提示并返回 true（已拦截，调用方直接 return）。
     * ⚠️ 只拦"从隐藏态启动悬浮窗"的入口；已显示时的 toggle 隐藏 / 录音中 toggle 停止分支
     * 在调用本函数之前已放行——未解锁用户（或降级回未解锁的用户）必须关得掉已显示的浮窗。
     */
    private fun blockOverlayIfProLocked(): Boolean {
        if (isProUnlocked()) return false
        vibrateOneShot(50, 60)
        Toast.makeText(this, "悬浮窗是 Pro 功能，请在声物记设置页解锁", Toast.LENGTH_LONG).show()
        println("🔒 [Accessibility] 悬浮窗功能未解锁 Pro，已拦截")
        return true
    }

    override fun onKeyEvent(event: KeyEvent): Boolean {
        // 只处理音量键
        if (event.keyCode != KeyEvent.KEYCODE_VOLUME_UP && event.keyCode != KeyEvent.KEYCODE_VOLUME_DOWN) {
            return false
        }

        // 统一手势槽位：每个键读长按/双击两个槽位动作
        val longAction = getLongPressAction(event.keyCode)
        val doubleAction = getDoubleClickAction(event.keyCode)

        // 两槽都无动作 → 键完全还给系统（等价旧 mode=off）
        if (longAction == ACTION_NONE && doubleAction == ACTION_NONE) {
            return false
        }

        if (event.action == KeyEvent.ACTION_DOWN) {
            // 消费 ACTION_DOWN，阻止系统音量变化

            // 如果有等待中的单击，取消它（用户又按下了，可能是双击）
            pendingSingleClick?.let { singleClickHandler.removeCallbacks(it) }
            pendingSingleClick = null

            // 长按槽有动作才启动长按计时（DOWN 时缓存动作，runnable 执行用）
            if (longAction != ACTION_NONE) {
                currentLongPressAction = longAction
                longPressHandler.postDelayed(longPressRunnable, LONG_PRESS_DURATION_MS)
            }
            // longAction==none：不启动长按计时，按住不放无动作，UP 走调音量路径
            println("🔑 [Accessibility] 按键按下(已拦截): keyCode=${event.keyCode}, longAction=$longAction, doubleAction=$doubleAction")
            return true
        } else if (event.action == KeyEvent.ACTION_UP) {
            // 取消长按计时
            longPressHandler.removeCallbacks(longPressRunnable)
            currentLongPressAction = null
            val wasLongPress = isLongPressTriggered
            isLongPressTriggered = false

            if (wasLongPress) {
                println("🔑 [Accessibility] 按键抬起: 长按已处理")
                return true // 长按已处理，不进双击
            }

            val now = System.currentTimeMillis()
            val timeSinceLastClick = now - lastClickTime

            // 录音中不做双击检测，单击立即调音量（现状行为）。
            // 注意：录音中长按仍会在 500ms 由 longPressRunnable 触发——
            // quick_record / overlay_record 的 toggle 停录语义依赖于此，此处不拦 runnable
            if (isRecording()) {
                adjustVolume(event.keyCode)
                println("🔑 [Accessibility] 录音中，直接调音量: keyCode=${event.keyCode}")
                return true
            }

            if (doubleAction != ACTION_NONE) {
                if (timeSinceLastClick < DOUBLE_CLICK_THRESHOLD_MS && lastClickKeyCode == event.keyCode) {
                    // 双击确认
                    lastClickTime = 0L
                    lastClickKeyCode = 0
                    executeGestureAction(doubleAction)
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
            } else {
                // 双击槽=无动作：无需等双击窗口，立即调音量（本次重构的体验优化）
                adjustVolume(event.keyCode)
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

    /**
     * 单次震动反馈（SDK_INT < O 降级为无振幅的旧 API）。
     * triggerQuickRecord / triggerShowOverlay 共用，避免重复样板代码
     */
    private fun vibrateOneShot(ms: Long, amplitude: Int) {
        val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createOneShot(ms, amplitude))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(ms)
        }
    }

    /**
     * tick 轻触震动反馈（SDK_INT < O 降级为 30ms 旧 API）。
     * 与主 App 日记页卡片复制反馈（MainActivity performHaptic "tick"）逐参数一致：
     * SDK >= O 用 EFFECT_TICK，低版本回退 30ms
     */
    private fun vibrateTick() {
        val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_TICK))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(30)
        }
    }

    /** 手势槽位动作分发：4 个槽位动作的唯一执行入口（长按 runnable / 双击确认两处调用） */
    private fun executeGestureAction(action: String) {
        when (action) {
            ACTION_QUICK_RECORD -> triggerQuickRecord()
            ACTION_QUICK_TEXT_NOTE -> triggerQuickTextNote()
            ACTION_SHOW_OVERLAY -> triggerShowOverlay()
            ACTION_OVERLAY_RECORD -> triggerVoiceMemoOverlay()
            ACTION_OVERLAY_NEW_NOTE -> triggerOverlayNewNote()
            else -> println("⚠️ [Accessibility] 未知手势动作: $action")
        }
    }

    private fun triggerQuickRecord() {
        // 锁屏状态下先点亮屏幕（屏幕熄灭时才能在锁屏之上显示 Activity）
        wakeScreenIfLocked()

        // 震动反馈（让用户知道触发了）
        vibrateOneShot(100, 70)

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

    private fun triggerShowOverlay() {
        // 锁屏状态下先点亮屏幕
        wakeScreenIfLocked()

        // toggle 判断必须在 showOverlay() 之前（showOverlay 开头会强制重建已存在的浮窗）。
        // 注意 pendingVoiceMemoReveal 条件：语音速记冷启动隐藏窗口（alpha=0 等 Dart 胶囊首帧
        // 揭示）期间 view 存在但用户不可见——此时触发"显示悬浮窗"预期是显示而非隐藏一个
        // 看不见的窗，走正常显示路径（showOverlay 开头会 hideOverlay 清掉隐藏窗再重建）
        if (overlayView != null && !pendingVoiceMemoReveal) {
            // 已显示 → 再长按 = 立即彻底隐藏（toggle 兜底，不用等自动隐藏）
            // 震动差异化：短震 50ms（区别于显示时的 100ms），避免与双击文本笔记的 50-50-50 波形混淆
            vibrateOneShot(50, 60)
            hideOverlay()
            println("✅ [Accessibility] 长按音量上键：悬浮窗已隐藏")
            return
        }

        // Pro 门禁：只拦"从隐藏态启动"（上面的 toggle 隐藏分支已放行——未解锁用户必须关得掉已显示的浮窗）
        if (blockOverlayIfProLocked()) return

        // 震动反馈：与快速录音相同，100ms 单次震动
        vibrateOneShot(100, 70)
        // 直连本服务的 TYPE_ACCESSIBILITY_OVERLAY 浮窗并自动展开面板。
        // （旧链路是 startActivity 拉主 App 再走 flutter_overlay_window 插件，
        //  在小米/HyperOS 上会被系统拦截，已废弃）
        val shown = showOverlay(autoExpand = true)
        println(if (shown) "✅ [Accessibility] 长按音量上键：悬浮窗已显示(自动展开)"
                else "❌ [Accessibility] 悬浮窗显示失败")
    }

    /**
     * 悬浮窗新增笔记（action=overlay_new_note）：显示浮窗（若未显示）并通知 Dart 新增一条
     * 空白笔记进入编辑态。与 triggerShowOverlay 的关键差异：**不做 toggle 隐藏**——
     * 浮窗已显示时重复触发 = 再新增一条（产品已定语义）；展开 + 新增由 Dart 侧
     * newNote handler 内部完成，Kotlin 只负责发消息。
     */
    private fun triggerOverlayNewNote() {
        // 锁屏状态下先点亮屏幕（对齐 triggerShowOverlay）
        wakeScreenIfLocked()

        // Pro 门禁：本动作无 toggle 隐藏语义（重复触发 = 再新增一条），直接在入口拦截
        if (blockOverlayIfProLocked()) return

        // 震动反馈：与显示浮窗相同，100ms 单次震动
        vibrateOneShot(100, 70)

        // 未显示时先建浮窗（28×88 把手态窗口）；不在这里 autoExpand——
        // Dart 收到 newNote 后自己 _expand()，避免与 Dart 的展开动画编排打架
        if (overlayView == null) {
            val shown = showOverlay(autoExpand = false)
            if (!shown) {
                println("❌ [Accessibility] 悬浮窗新增笔记：浮窗创建失败，newNote 不再发送")
                return
            }
        }
        notifyDartNewNote()
        println("✅ [Accessibility] 悬浮窗新增笔记已触发")
    }

    /**
     * 音量上键长按“直接录音”（语音速记模式，action=record）的 toggle 状态机。
     *
     * - 隐藏态长按 → 唤醒屏幕 + 100ms 震 + 创建浮窗（hidden 隐藏窗口：直接以胶囊尺寸
     *   312×64 addView，alpha=0 + FLAG_NOT_TOUCHABLE，无 resize 无把手帧，等 Dart
     *   录音态首帧 voiceMemoUiReady 才揭示，把手像素物理上不可能出现）+ 通知 Dart 开始录音
     * - 录音中再长按 → 50ms 短震 + 通知 Dart 停止（转写在 Dart 侧做）
     * - 主 APP 正在录音 → 麦克风互斥，退回现有“显示浮窗”行为（不抢麦）
     */
    private fun triggerVoiceMemoOverlay() {
        if (voiceMemoActive) {
            // 录音中再长按 → toggle 停止（转写由 Dart 侧接管）
            // 震动差异化：短震 50ms（区别于开始录音的 100ms）
            vibrateOneShot(50, 50)
            // ⚠️ 不在此处置 voiceMemoActive=false：stopVoiceMemo 消息可能未被 Dart 消化
            // （handler 未注册时 invokeMethod 静默丢弃），先置 false 会让紧随其后的长按
            // 误触“开始新录音”。复位以 Dart 回执 voiceMemoStopped 为准，3s 超时强制清兜底
            overlayMethodChannel?.invokeMethod("stopVoiceMemo", null)
            scheduleVoiceMemoStopTimeout()
            println("✅ [Accessibility] 长按音量上键：请求停止语音速记")
            return
        }
        // Pro 门禁：只拦"从隐藏态启动录音"（上面的录音中 toggle 停止分支已放行——未解锁用户必须停得掉进行中的录音）
        if (blockOverlayIfProLocked()) return
        if (isRecording()) {
            // 主 APP 正在录音 → 麦克风互斥，退回显示浮窗行为（不抢麦）
            println("🎤 [Accessibility] 主 APP 录音中，语音速记让位：退回显示浮窗")
            triggerShowOverlay()
            return
        }
        // 锁屏状态下先点亮屏幕（与 triggerShowOverlay 同款前置）
        wakeScreenIfLocked()
        // 震动反馈：与快速录音同款震感（100ms, amplitude 70），告知“开始录音了”
        vibrateOneShot(100, 70)
        if (overlayView == null) {
            // 语音速记态：hidden=true 隐藏窗口——engine/FlutterView/channel 照常创建，
            // 窗口直接以胶囊尺寸（312×64，常量见 companion object，唯一真值在 Dart 侧
            // overlay_constants.dart）立即 addView（FlutterView 在 engine 渲染期间必须
            // attach，否则 AccessibilityBridge NPE → SIGABRT），alpha=0 + FLAG_NOT_TOUCHABLE
            // 不可见不挡触摸；无 resize 无把手帧——把手尺寸窗口在此路径中不存在。
            // Dart 冷启动期间窗口保持隐藏，录音态首帧渲染完发 voiceMemoUiReady 才
            // alpha=1 揭示，窗口首次可见即正确尺寸胶囊，根治冷启动把手一闪而过
            val shown = showOverlay(autoExpand = false, hidden = true)
            if (!shown) {
                println("❌ [Accessibility] 语音速记：浮窗显示失败，放弃启动录音")
                return
            }
        }
        voiceMemoActive = true
        // 四级 watchdog：录音上限救生兜底（voiceMemoStarted 回执不取消——T1 计时必须跑满，
        // 用户可能按满上限时长才由 Dart Timer 正常停录）
        startVoiceMemoWatchdog()
        notifyDartStartVoiceMemo()
        println("✅ [Accessibility] 长按音量上键：语音速记已启动（等待 Dart 开始录音）")
    }

    /**
     * 通知 Dart 侧开始语音速记录音。
     * 与 notifyDartExpand 同一握手模式：dartReady=true（engine 复用、Dart handler 已注册）
     * 直接发；否则挂起 pendingVoiceMemoStart，等 Dart initState 发来 dartReady 握手后补发
     * （invokeMethod 在 Dart 无 handler 时静默丢弃、不 crash，挂起是为避免丢消息）。
     */
    private fun notifyDartStartVoiceMemo() {
        if (dartReady) {
            // hiddenReveal 负载告知 Dart 当前是否为隐藏窗口（alpha=0 等揭示）——Dart 据此
            // 决定 voiceMemoUiReady 的发送时机：隐藏模式在 handler 顶部挂揭示门，等录音态
            // 首帧构建完才发（窗口从创建起就是胶囊尺寸，首帧即正确尺寸，根治揭示竞态）；
            // 把手在屏上的原地切换路径（false）维持立即发（Kotlin 侧非 pending 时收到也 no-op）
            overlayMethodChannel?.invokeMethod("startVoiceMemo", mapOf("hiddenReveal" to pendingVoiceMemoReveal))
        } else {
            pendingVoiceMemoStart = true
            println("⏳ [Accessibility] Dart 未就绪，语音速记启动请求已挂起")
        }
    }

    /**
     * 排定 stopVoiceMemo 的 3s 回执超时兜底。
     * Dart 卡死时 voiceMemoStopped 永远不来 → toggle 死锁（再长按永远走 stop 分支），
     * 到时强制复位 voiceMemoActive。（四级 watchdog 见 voiceMemoWatchdog* 系列，此处只管 stop 回执）
     */
    private fun scheduleVoiceMemoStopTimeout() {
        cancelVoiceMemoStopTimeout()
        val runnable = Runnable {
            voiceMemoStopTimeoutRunnable = null
            if (voiceMemoActive) {
                voiceMemoActive = false
                // 强制复位时一并撤 watchdog：toggle 状态已解锁，救生链无需再 escalate
                cancelVoiceMemoWatchdog()
                // Dart 卡死判定路径：常亮 flag 也要兜底清掉（否则浮窗 LayoutParams 上残留）
                clearOverlayKeepScreenOn()
                println("⚠️ [Accessibility] 语音速记停止回执超时(${VOICE_MEMO_STOP_TIMEOUT_MS}ms)，强制复位 voiceMemoActive")
            }
        }
        voiceMemoStopTimeoutRunnable = runnable
        voiceMemoStopTimeoutHandler.postDelayed(runnable, VOICE_MEMO_STOP_TIMEOUT_MS)
    }

    // 取消 stop 回执超时计时（voiceMemoStarted / voiceMemoStopped / voiceMemoFailed 回执到达时调用）
    private fun cancelVoiceMemoStopTimeout() {
        voiceMemoStopTimeoutRunnable?.let { voiceMemoStopTimeoutHandler.removeCallbacks(it) }
        voiceMemoStopTimeoutRunnable = null
    }

    /**
     * 启动四级 watchdog（T1=上限时刻补发停录 / T2=+3s 再补发 / T3=+6s 强制移窗 / T4=+16s 销毁 engine，
     * 基准 VOICE_MEMO_MAX_DURATION_MS）。
     * 挂钩：triggerVoiceMemoOverlay 置 voiceMemoActive=true 后启动；
     * voiceMemoStarted 回执【不取消】——T1 上限计时必须跑满（用户可能按满上限时长才由 Dart Timer 停录）；
     * voiceMemoStopped / voiceMemoFailed 回执、stop 分支 3s 超时强制清时 cancel。
     */
    private fun startVoiceMemoWatchdog() {
        cancelVoiceMemoWatchdog()
        voiceMemoWatchdogHandler.postDelayed(voiceMemoWatchdogT1, VOICE_MEMO_MAX_DURATION_MS)
        voiceMemoWatchdogHandler.postDelayed(voiceMemoWatchdogT2, VOICE_MEMO_MAX_DURATION_MS + 3000L)
        voiceMemoWatchdogHandler.postDelayed(voiceMemoWatchdogT3, VOICE_MEMO_MAX_DURATION_MS + 6000L)
        voiceMemoWatchdogHandler.postDelayed(voiceMemoWatchdogT4, VOICE_MEMO_MAX_DURATION_MS + 16000L)
        println("🐕 [Accessibility] 语音速记四级 watchdog 已启动 (T1=+${VOICE_MEMO_MAX_DURATION_MS / 1000}s/T2=+${VOICE_MEMO_MAX_DURATION_MS / 1000 + 3}s/T3=+${VOICE_MEMO_MAX_DURATION_MS / 1000 + 6}s/T4=+${VOICE_MEMO_MAX_DURATION_MS / 1000 + 16}s)")
    }

    // 取消四级 watchdog（正常停止/失败/强制复位时调用，removeCallbacks 全部四个 Runnable）
    private fun cancelVoiceMemoWatchdog() {
        voiceMemoWatchdogHandler.removeCallbacks(voiceMemoWatchdogT1)
        voiceMemoWatchdogHandler.removeCallbacks(voiceMemoWatchdogT2)
        voiceMemoWatchdogHandler.removeCallbacks(voiceMemoWatchdogT3)
        voiceMemoWatchdogHandler.removeCallbacks(voiceMemoWatchdogT4)
    }

    // 最后手段：销毁 overlay engine 释放 mic（record 插件随 engine destroy detach）。
    // 代价：下次 showOverlay 走 cache miss 重建（几百 ms 冷启动），overlay Dart 状态全丢——救生场景可接受
    private fun destroyOverlayEngine() {
        // 语音速记临时静音兜底：走到这里 = Dart isolate 卡死（T4），Dart 侧的
        // restoreMedia 不会执行，原生按 is_recording 兜底恢复（已按音量减标记
        // keep_muted 时 restore 内部保持静音，语义不变）
        restoreMutedMediaIfRecording()
        try {
            FlutterEngineCache.getInstance().get(OVERLAY_ENGINE_CACHE_KEY)?.let { engine ->
                FlutterEngineCache.getInstance().remove(OVERLAY_ENGINE_CACHE_KEY)
                engine.destroy()
            }
        } catch (e: Exception) {
            println("⚠️ [Accessibility] 销毁 overlay engine 异常: ${e.message}")
        }
        overlayView = null
        overlayWindowManager = null
        overlayMethodChannel = null
        dartReady = false
        voiceMemoActive = false
        pendingAutoExpand = false
        pendingNewNote = false
        pendingVoiceMemoStart = false
        pendingVoiceMemoReveal = false
    }

    /**
     * 显示无障碍浮窗（TYPE_ACCESSIBILITY_OVERLAY），渲染 Flutter overlay_main。
     *
     * @param autoExpand true = 显示后自动展开面板（长按音量上键召唤场景）；
     *                   默认 false 只显示把手（设置页测试按钮 / MainActivity 无参调用）
     * @param hidden true = 隐藏窗口（语音速记冷启动路径）：engine/FlutterView/channel 照常创建，
     *               窗口直接以胶囊尺寸 312×64（VOICE_MEMO_OVERLAY_WIDTH_DP/HEIGHT_DP，唯一真值
     *               在 Dart 侧 overlay_constants.dart）立即 addView——FlutterView 在 engine 渲染
     *               期间必须 attach 到窗口，否则 Dart 推 semantics 更新触发 AccessibilityBridge
     *               NPE → JNI fatal → SIGABRT（2026-08-29 延迟 addView 方案崩溃废弃的教训）。
     *               窗口 alpha=0 + FLAG_NOT_TOUCHABLE（不可见、不挡触摸），置 pendingVoiceMemoReveal；
     *               直建胶囊尺寸 = 无 resize、无把手帧，把手像素物理上不可能出现；
     *               Dart 录音态首帧渲染完发 voiceMemoUiReady 才 alpha=1 揭示——首帧即正确尺寸胶囊
     */
    fun showOverlay(autoExpand: Boolean = false, hidden: Boolean = false): Boolean {
        // 如果已有浮窗，先强制重建，避免旧 View 处于僵尸状态导致看不见
        if (overlayView != null) {
            println("🔄 [Accessibility] 浮窗已存在，先关闭再重建")
            hideOverlay()
        }
        try {
            val engine = getOrCreateOverlayEngine() ?: return false
            val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
            overlayWindowManager = wm

            val flutterView = FlutterView(this, FlutterTextureView(this)).apply {
                // 背景设为透明（原为半透明黄色调试背景 #80FFD700，窗口显示已验证通过）
                setBackgroundColor(Color.TRANSPARENT)
                setFitsSystemWindows(true)
                setFocusable(true)
                setFocusableInTouchMode(true)
                attachToFlutterEngine(engine)
                postDelayed({
                    println("🔍 [Accessibility] 浮窗尺寸: ${width}x${height}, attached=${isAttachedToWindow}")
                }, 1000)
            }
            // attach 后再 resume 一次生命周期，确保 Flutter 开始绘制
            engine.lifecycleChannel.appIsResumed()
            overlayView = flutterView

            // 注册 Dart 层调用通道（resize / updateFlag / close）
            overlayMethodChannel = MethodChannel(
                engine.dartExecutor.binaryMessenger,
                "com.shengwuji.app/accessibility_overlay"
            ).apply {
                setMethodCallHandler { call, result ->
                    when (call.method) {
                        "resizeOverlay" -> {
                            val width = call.argument<Int>("width") ?: 28
                            val height = call.argument<Int>("height") ?: 88
                            val enableDrag = call.argument<Boolean>("enableDrag") ?: false
                            resizeOverlay(width, height, enableDrag)
                            result.success(true)
                        }
                        "updateFlag" -> {
                            val flag = call.argument<String>("flag") ?: "defaultFlag"
                            updateOverlayFlag(flag, result)
                        }
                        "closeOverlay" -> {
                            hideOverlay()
                            result.success(true)
                        }
                        // 语音速记录音回执（Dart → Kotlin）：录音已真正开始 → 取消 stop 超时兜底（如有）
                        // + 设置浮窗常亮（锁屏下 wakeScreenIfLocked 只有 3s 点亮，之后 3-5s 自动
                        // 息屏会打断录音/转写；wakelock_plus 在 overlay engine 不可用，走窗口 flag）
                        "voiceMemoStarted" -> {
                            cancelVoiceMemoStopTimeout()
                            setOverlayKeepScreenOn()
                            println("✅ [Accessibility] Dart 回执：语音速记录音已开始")
                            result.success(true)
                        }
                        // 语音速记录音回执：录音已停止（进入转写）→ 复位 toggle 状态 + 撤 watchdog
                        "voiceMemoStopped" -> {
                            voiceMemoActive = false
                            cancelVoiceMemoStopTimeout()
                            cancelVoiceMemoWatchdog()
                            println("✅ [Accessibility] Dart 回执：语音速记已停止")
                            result.success(true)
                        }
                        // 语音速记转写完成回执（成功/失败/丢弃统一收尾）：录音+转写全程结束 → 清除浮窗常亮。
                        // 注意不能在 voiceMemoStopped 清——那时刚进入转写，仍需常亮
                        "voiceMemoFinished" -> {
                            clearOverlayKeepScreenOn()
                            println("✅ [Accessibility] Dart 回执：语音速记转写完成，浮窗常亮已清除")
                            result.success(true)
                        }
                        // 语音速记录音回执：Dart 自报失败（权限未授予/麦克风被占等）→ 复位 + 隐藏浮窗 + 撤 watchdog
                        "voiceMemoFailed" -> {
                            voiceMemoActive = false
                            cancelVoiceMemoStopTimeout()
                            cancelVoiceMemoWatchdog()
                            // 失败路径也清常亮（hideOverlay 移窗后 flag 天然消失，
                            // 此行是窗口还在时的防御性清理 + 日志语义闭环）
                            clearOverlayKeepScreenOn()
                            hideOverlay()
                            println("⚠️ [Accessibility] Dart 回执：语音速记失败，浮窗已隐藏")
                            result.success(true)
                        }
                        // 展开卡片底部复制按钮：原生写剪贴板（Dart 侧 flutter/platform
                        // 通道在 overlay engine + 后台状态下不可靠，MIUI 对后台剪贴板
                        // 写入有限制），震动反馈用 EFFECT_TICK 与主 App 日记页卡片复制
                        //（MainActivity performHaptic "tick"）逐参数一致
                        "copyText" -> {
                            val text = call.argument<String>("text") ?: ""
                            try {
                                val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                                cm.setPrimaryClip(ClipData.newPlainText("声物记笔记", text))
                                // tick 震动（对齐日记页复制反馈）
                                vibrateTick()
                                println("📋 [Accessibility] 已写入剪贴板 (len=${text.length})")
                                result.success(true)
                            } catch (e: Exception) {
                                println("❌ [Accessibility] 写剪贴板失败: $e")
                                result.success(false)
                            }
                        }
                        // 悬浮窗删除按钮二次确认震动：EFFECT_TICK，与复制按钮反馈一致
                        "vibrateTick" -> {
                            vibrateTick()
                            result.success(true)
                        }
                        // ── 语音速记临时静音（悬浮窗录音，2026-09-06）──
                        // 与主 App 快捷录音共用 MediaMuteHelper + 同一开关
                        // （flutter.keep_muted_on_volume_down，标记方在 adjustVolume）：
                        // Dart 侧 OverlayVoiceMemoController start 开录后 mute、
                        // stop/fail 收尾 restore，交互与快捷录音完全一致
                        "muteMedia" -> {
                            MediaMuteHelper.mute(this@VolumeKeyAccessibilityService)
                            result.success(true)
                        }
                        "restoreMedia" -> {
                            MediaMuteHelper.restore(this@VolumeKeyAccessibilityService)
                            result.success(true)
                        }
                        // ── 悬浮窗闹钟（OverlayHome._onCardAlarm，2026-09-06）──
                        // 日历写权限预检：悬浮窗 engine 没有 Activity，无法像主 App
                        // 日记页那样走 permission_handler request()，改由原生
                        // checkSelfPermission 返回状态（Dart 侧弹确认 sheet 前调用）。
                        // ⚠️ handler 在 MethodChannel.apply 的 lambda 内，this 不指向
                        // Service，须用限定 this（同下方 launchApp 的先例）
                        "checkAlarmPermissions" -> {
                            result.success(
                                mapOf(
                                    "calendar" to CalendarEventHelper.hasCalendarPermission(
                                        this@VolumeKeyAccessibilityService
                                    ),
                                    "notification" to CalendarEventHelper.hasNotificationPermission(
                                        this@VolumeKeyAccessibilityService
                                    )
                                )
                            )
                        }
                        // 缺日历权限的补救路径：Toast 提示 + 拉起主 App（launcher intent
                        // 带 type=grant_calendar extra，MainActivity.extractShortcutType
                        // 路由到 Dart onShortcutLaunch，主 App 前台后自动弹系统授权框）
                        "requestCalendarPermission" -> {
                            Toast.makeText(
                                this@VolumeKeyAccessibilityService,
                                "请授予日历权限，即可添加日历提醒",
                                Toast.LENGTH_LONG
                            ).show()
                            val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                putExtra("type", "grant_calendar")
                            }
                            if (launch != null) {
                                startActivity(launch)
                                println("⏰ [Accessibility] 已拉起主 App 请求日历权限")
                            } else {
                                println("❌ [Accessibility] 拉起主 App 失败（getLaunchIntentForPackage null）")
                            }
                            result.success(launch != null)
                        }
                        // 悬浮窗闹钟确认后写日历：与主 App 日记页共用 CalendarEventHelper
                        // （逻辑同 MainActivity 原实现，Service 上下文直接可用）。
                        // 成功/失败反馈走原生 Toast（悬浮窗小窗口不适合 SnackBar）
                        "addCalendarEvent" -> {
                            val timestamp = call.argument<Long>("timestamp") ?: 0L
                            val title = call.argument<String>("title") ?: "提醒"
                            val enableAlarm = call.argument<Boolean>("enableAlarm") ?: true
                            val ok = if (!CalendarEventHelper.hasCalendarPermission(this@VolumeKeyAccessibilityService)) {
                                Toast.makeText(this@VolumeKeyAccessibilityService, "日历权限未授予，添加失败", Toast.LENGTH_LONG).show()
                                println("❌ [Accessibility] 写日历中止：日历权限未授予")
                                false
                            } else {
                                val success = CalendarEventHelper.addCalendarEvent(
                                    this@VolumeKeyAccessibilityService, timestamp, title, enableAlarm
                                )
                                Toast.makeText(
                                    this@VolumeKeyAccessibilityService,
                                    when {
                                        success && enableAlarm -> "已添加到系统日历，到点响铃提醒"
                                        success -> "已添加到系统日历（无响铃）"
                                        else -> "添加日历事件失败，请检查日历账户"
                                    },
                                    Toast.LENGTH_SHORT
                                ).show()
                                success
                            }
                            result.success(ok)
                        }
                        // 展开卡片底部分享按钮：系统分享面板。Service 无 Activity
                        // 上下文，ACTION_SEND 和 Chooser 都必须加 FLAG_ACTIVITY_NEW_TASK。
                        // （2026-09-05 起卡片分享入口已由 AI 对话按钮替换，见 launchApp；
                        // 本 handler 暂留作通道 API 备用——todo 里 flomo 风格分享卡片
                        // 等未来分享入口可复用）
                        "shareText" -> {
                            val text = call.argument<String>("text") ?: ""
                            try {
                                val sendIntent = Intent(Intent.ACTION_SEND).apply {
                                    type = "text/plain"
                                    putExtra(Intent.EXTRA_TEXT, text)
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                val chooser = Intent.createChooser(sendIntent, "分享笔记").apply {
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                startActivity(chooser)
                                println("📤 [Accessibility] 系统分享面板已拉起 (len=${text.length})")
                            } catch (e: Exception) {
                                println("❌ [Accessibility] 分享失败: $e")
                            }
                            result.success(true)
                        }
                        // 展开卡片底部 AI 对话按钮：复制成功后拉起用户在设置页选择的
                        // AI 应用（对齐主 App 日记页 _shareToAI）。Service 无 Activity
                        // 上下文，startActivity 统一加 FLAG_ACTIVITY_NEW_TASK。启动顺序
                        // 包名 → scheme → web url 三级兜底；微信等偏好 scheme 的应用由
                        // Dart 侧传空 packageName 跳过包名步骤。API 30+ 包可见性由
                        // AndroidManifest <queries> 已声明的各 AI 应用包名覆盖。
                        // 全部失败 → Toast 提示（Service 可弹）+ result(false)
                        "launchApp" -> {
                            val name = call.argument<String>("name") ?: "AI 应用"
                            val packageName = call.argument<String>("packageName") ?: ""
                            val scheme = call.argument<String>("scheme") ?: ""
                            val url = call.argument<String>("url") ?: ""
                            var launched = false
                            if (packageName.isNotEmpty()) {
                                try {
                                    val launchIntent =
                                        packageManager.getLaunchIntentForPackage(packageName)
                                    if (launchIntent != null) {
                                        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                        startActivity(launchIntent)
                                        launched = true
                                        println("✅ [Accessibility] 已启动 $name (package): $packageName")
                                    } else {
                                        println("⚠️ [Accessibility] 包名未安装或不可见: $packageName，转 scheme/url 兜底")
                                    }
                                } catch (e: Exception) {
                                    println("⚠️ [Accessibility] 包名启动失败: $e")
                                }
                            }
                            if (!launched && scheme.isNotEmpty()) {
                                try {
                                    startActivity(
                                        Intent(Intent.ACTION_VIEW, Uri.parse(scheme)).apply {
                                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                        }
                                    )
                                    launched = true
                                    println("✅ [Accessibility] 已启动 $name (scheme): $scheme")
                                } catch (e: Exception) {
                                    println("⚠️ [Accessibility] scheme 启动失败: $e")
                                }
                            }
                            if (!launched && url.isNotEmpty()) {
                                try {
                                    startActivity(
                                        Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                        }
                                    )
                                    launched = true
                                    println("✅ [Accessibility] 已启动 $name (web): $url")
                                } catch (e: Exception) {
                                    println("⚠️ [Accessibility] web 启动失败: $e")
                                }
                            }
                            if (!launched) {
                                // handler 在 lambda 内，this 不指向 Service，须用限定 this
                                Toast.makeText(
                                    this@VolumeKeyAccessibilityService,
                                    "未能打开 $name，请检查是否已安装",
                                    Toast.LENGTH_SHORT
                                ).show()
                                println("❌ [Accessibility] AI 应用启动全部失败: $name")
                            }
                            result.success(launched)
                        }
                        // Dart 侧握手：handler 已注册（overlay_home initState 发出）。
                        // 若此前有挂起的自动展开请求，立即补发 expand
                        "dartReady" -> {
                            dartReady = true
                            if (pendingAutoExpand) {
                                pendingAutoExpand = false
                                overlayMethodChannel?.invokeMethod("expand", null)
                            }
                            // 挂起的语音速记启动请求同样补发（与 pendingAutoExpand 同一握手机制）
                            if (pendingVoiceMemoStart) {
                                pendingVoiceMemoStart = false
                                // hiddenReveal 负载语义同 notifyDartStartVoiceMemo（补发时
                                // pendingVoiceMemoReveal 仍有效，Dart 据此决定揭示信号时机）
                                overlayMethodChannel?.invokeMethod("startVoiceMemo", mapOf("hiddenReveal" to pendingVoiceMemoReveal))
                            }
                            // 挂起的新增笔记请求同样补发（与 pendingAutoExpand 同一握手机制）
                            if (pendingNewNote) {
                                pendingNewNote = false
                                overlayMethodChannel?.invokeMethod("newNote", null)
                            }
                            result.success(true)
                        }
                        "voiceMemoUiReady" -> {
                            // Dart 录音态首帧已构建（postFrameCallback 后发出）——此刻揭示窗口，
                            // 保证用户看到的第一个画面就是正确尺寸胶囊而非把手
                            if (pendingVoiceMemoReveal) {
                                // 延迟 2 帧揭示：Dart 的 postFrameCallback 只保证胶囊帧构建完
                                // ≠ 已呈现——光栅化 + SurfaceFlinger 合成可能晚 1~2 个 vsync；
                                // 多等一帧是便宜保险，消除"揭示比呈现快"的残余竞态
                                //（2026-08-29 实测同代码同日志两次运行一次闪把手一次干净 = 呈现层竞态）
                                android.view.Choreographer.getInstance().postFrameCallback {
                                    android.view.Choreographer.getInstance().postFrameCallback {
                                        // 二次检查：这两帧内可能已被 hideOverlay / destroyOverlayEngine 清掉
                                        if (pendingVoiceMemoReveal) {
                                            pendingVoiceMemoReveal = false
                                            overlayView?.let { view ->
                                                val params = view.layoutParams as WindowManager.LayoutParams
                                                params.alpha = 1f
                                                params.flags = params.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
                                                overlayWindowManager?.updateViewLayout(view, params)
                                            }
                                            println("🎤 [Accessibility] 语音速记窗口已揭示（胶囊首帧就绪）")
                                        }
                                    }
                                }
                            }
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                }
            }

            if (hidden) {
                // 隐藏窗口（语音速记冷启动路径）：照常住流程立即 addView（engine 渲染期间
                // FlutterView 必须 attach 到窗口，否则 AccessibilityBridge NPE → SIGABRT），
                // 但窗口直接以胶囊尺寸 312×64 创建 + alpha=0 + FLAG_NOT_TOUCHABLE——
                // 不可见也不挡用户触摸，且把手尺寸的窗口在此路径中不存在（无 resize、
                // 无把手帧）；揭示时机：Dart 录音态首帧构建完发 voiceMemoUiReady（见 channel 分支）
                pendingVoiceMemoReveal = true
                wm.addView(flutterView, buildOverlayParams(VOICE_MEMO_OVERLAY_WIDTH_DP, VOICE_MEMO_OVERLAY_HEIGHT_DP, hidden = true))
                println("⏳ [Accessibility] 浮窗已创建（隐藏模式，胶囊尺寸直建，等 Dart 录音首帧揭示）")
            } else {
                wm.addView(flutterView, buildOverlayParams(28, 88))
                println("✅ [Accessibility] 无障碍浮窗已显示 (TYPE_ACCESSIBILITY_OVERLAY + Flutter)")
            }
            // 自动展开：Dart 未就绪时挂起，等 dartReady 握手后补发（见 notifyDartExpand）
            if (autoExpand) notifyDartExpand()
            return true
        } catch (e: Exception) {
            println("❌ [Accessibility] 显示无障碍浮窗失败: ${e.message}")
            overlayView = null
            overlayWindowManager = null
            overlayMethodChannel = null
            return false
        }
    }

    /**
     * 通知 Dart 侧展开面板。
     * dartReady=true（engine 复用、Dart handler 已注册）直接发；
     * 否则挂起 pendingAutoExpand，等 Dart initState 发来 dartReady 握手后补发
     * （invokeMethod 在 Dart 无 handler 时静默丢弃、不 crash，挂起是为避免丢消息）。
     */
    private fun notifyDartExpand() {
        if (dartReady) {
            overlayMethodChannel?.invokeMethod("expand", null)
        } else {
            pendingAutoExpand = true
            println("⏳ [Accessibility] Dart 未就绪，自动展开请求已挂起")
        }
    }

    /**
     * 通知 Dart 侧新增一条空白笔记（进入编辑态）。
     * 与 notifyDartExpand 同一握手机制：dartReady=true 直接发 newNote；
     * 否则挂起 pendingNewNote，等 Dart initState 发来 dartReady 握手后补发。
     * 覆盖场景：overlayView != null 但 dartReady == false（service 被系统重建、
     * 字段清零，engine 复用前）——showOverlay 复用分支会重新置 dartReady=true
     * 并触发补发链路，不丢消息。
     */
    private fun notifyDartNewNote() {
        if (dartReady) {
            overlayMethodChannel?.invokeMethod("newNote", null)
        } else {
            pendingNewNote = true
            println("⏳ [Accessibility] Dart 未就绪，新增笔记请求已挂起")
        }
    }

    /**
     * 隐藏无障碍浮窗。
     */
    fun hideOverlay() {
        // 语音速记临时静音兜底：录音中浮窗被原生强制移除（T3 Dart 无响应 /
        // service onDestroy）时 Dart 侧 restoreMedia 不会执行，同 destroyOverlayEngine
        // 的兜底；正常收起路径 is_recording=false 直接跳过（幂等，Dart 已恢复过也无妨）
        restoreMutedMediaIfRecording()
        overlayView?.let { view ->
            try {
                // 防御性判断：view 未 attach 时 removeView 会抛 IllegalArgumentException——
                // 显式判断更干净（原 try-catch 也能兜住不 crash）。当前 view 恒 attach
                // （隐藏窗口方案 showOverlay 里立即 addView），此判断保留防未来改动回归
                if (view.isAttachedToWindow) {
                    overlayWindowManager?.removeView(view)
                }
                view.detachFromFlutterEngine()
            } catch (e: Exception) {
                println("⚠️ [Accessibility] 移除无障碍浮窗失败: ${e.message}")
            }
            pendingVoiceMemoReveal = false
            overlayView = null
            overlayWindowManager = null
            // engine 保活，通知 Dart 复位为收起态并取消自动隐藏计时，
            // 否则下次 showOverlay 首帧状态残留（expanded + 幂等不触发 resize → 卡把手尺寸）。
            // 统一覆盖 toggle 隐藏 / closeOverlay / onDestroy 三条路径
            overlayMethodChannel?.invokeMethod("reset", null)
            overlayMethodChannel?.setMethodCallHandler(null)
            overlayMethodChannel = null
            println("✅ [Accessibility] 无障碍浮窗已隐藏")
        }
    }

    /**
     * 获取或创建 overlay FlutterEngine。
     * 使用独立缓存 key（shengwuji_accessibility_overlay），热启动时复用自己创建的引擎；
     * 不复用 flutter_overlay_window 插件的 "myCachedEngine"（插件引擎的 Dart 入口从未执行，是空壳）。
     */
    private fun getOrCreateOverlayEngine(): FlutterEngine? {
        // 独立缓存 key：不复用 flutter_overlay_window 插件的 "myCachedEngine"。
        // 插件在主 Activity attach 时（onAttachedToActivity）就抢先创建并缓存了同名 engine，
        // 但其 Dart 入口 overlayMain 从未成功执行（logcat 无 "[overlayMain] 悬浮窗引擎已启动"），
        // attach 这种空壳 engine 后没有任何帧输出——之前只能看到 View 背景色（黄色调试块）就是这个原因。
        val cacheKey = OVERLAY_ENGINE_CACHE_KEY
        var engine = FlutterEngineCache.getInstance().get(cacheKey)
        if (engine != null) {
            println("ℹ️ [Accessibility] 复用已缓存的 overlay engine")
            // 复用 = Dart isolate 一直在跑（initState 早已执行过 setupNativeChannel），
            // handler 必然已注册。service 实例可能被系统销毁重建（字段清零），
            // 这里必须重新置位，否则新 service 实例永远等不到 dartReady 握手
            dartReady = true
            engine.lifecycleChannel.appIsResumed()
            return engine
        }
        return try {
            val engineGroup = FlutterEngineGroup(this)
            val entryPoint = DartExecutor.DartEntrypoint(
                FlutterInjector.instance().flutterLoader().findAppBundlePath(),
                "overlayMain"
            )
            engine = engineGroup.createAndRunEngine(this, entryPoint)
            FlutterEngineCache.getInstance().put(cacheKey, engine)
            engine.lifecycleChannel.appIsResumed()
            // 新建 engine：Dart 入口刚起步、handler 尚未注册，等 Dart 发 dartReady
            // 握手后再置 true（见 channel "dartReady" 分支）
            dartReady = false
            println("✅ [Accessibility] 已创建 overlay engine")
            engine
        } catch (e: Exception) {
            println("❌ [Accessibility] 创建 overlay engine 失败: ${e.message}")
            null
        }
    }

    /**
     * 调整悬浮窗尺寸。
     *
     * 哨兵值 -1（由 Dart 侧 OverlayStateController.panelSize 展开态传入）：
     * - width == -1 → 展开宽度 = MATCH_PARENT 铺满全屏。窗口全屏后，"面板占屏宽
     *   72%"由 Dart 侧 _buildPanel 用 OverlayConstants.expandedWidthRatio 绘制控制
     *   （右侧 72% 画面板，左侧 28% 透明空白区承接点击/左滑关闭手势——空白区事件
     *   必须由 Flutter 收到，所以窗口本身要铺满全屏）。比例真值唯一来源在 Dart，
     *   Kotlin 侧不再持有
     * - height == -1 → MATCH_PARENT 铺满全屏高度
     */
    private fun resizeOverlay(width: Int, height: Int, enableDrag: Boolean) {
        val view = overlayView ?: return
        val wm = overlayWindowManager ?: return
        // 读 view.layoutParams 改字段再 updateViewLayout 的写法天然保留 alpha 和 flags，
        // 隐藏窗口 pending 期间的 resize 不会误揭示，无需特判
        //（冷路径窗口直建胶囊尺寸后，Dart 暖路径的 resize(312,64) 是同尺寸 updateViewLayout，幂等无害）
        val params = view.layoutParams as WindowManager.LayoutParams
        if (pendingVoiceMemoReveal && width == -1) {
            // 防御：隐藏 pending 期间收到展开尺寸（width == -1，说明语音速记已转写完成切面板）
            // → 顺带揭示，防 voiceMemoUiReady 消息漏收后面板永远不可见
            pendingVoiceMemoReveal = false
            params.alpha = 1f
            params.flags = params.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
            println("🎤 [Accessibility] 语音速记窗口随展开尺寸揭示（voiceMemoUiReady 漏收兜底）")
        }
        if (width == -1) {
            // 展开铺满全屏宽度：左侧透明空白区手势关闭由 Dart 侧绘制，
            // 面板宽度比例的唯一真值是 Dart 侧 OverlayConstants.expandedWidthRatio
            params.width = WindowManager.LayoutParams.MATCH_PARENT
        } else {
            params.width = dpToPx(width)
        }
        if (height == -1) {
            // 展开铺满全屏高度
            params.height = WindowManager.LayoutParams.MATCH_PARENT
            // 铺满全屏时只保留 END（右对齐）
            params.gravity = Gravity.END
        } else {
            params.height = dpToPx(height)
            // 收起/把手态：88dp 把手必须垂直居中，否则顶到屏幕顶端
            params.gravity = Gravity.CENTER_VERTICAL or Gravity.END
        }
        wm.updateViewLayout(view, params)
        println("📐 [Accessibility] resizeOverlay 完成: ${params.width}x${params.height}px (gravity=${params.gravity})")
    }

    // 语音速记录音/转写期间保持屏幕常亮：叠加 FLAG_KEEP_SCREEN_ON（or 语义不动其他 flag）。
    // 锁屏下 wakeScreenIfLocked 只有 3s 点亮，之后系统自动息屏会打断录音/转写；
    // wakelock_plus 在 overlay engine（无 Activity）不可用，直接操作 overlay 窗口 LayoutParams。
    private fun setOverlayKeepScreenOn() {
        try {
            val view = overlayView ?: return
            val wm = overlayWindowManager ?: return
            paramsFlagsKeepScreenOn(view, wm, true)
            println("💡 [Accessibility] 语音速记开始：浮窗已设置常亮")
        } catch (e: Exception) {
            println("⚠️ [Accessibility] 设置浮窗常亮失败: ${e.message}")
        }
    }

    private fun clearOverlayKeepScreenOn() {
        try {
            val view = overlayView ?: return
            val wm = overlayWindowManager ?: return
            val params = view.layoutParams as WindowManager.LayoutParams
            if (params.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON == 0) return // 未设置过直接返回
            paramsFlagsKeepScreenOn(view, wm, false)
            println("🌙 [Accessibility] 语音速记结束：浮窗常亮已清除")
        } catch (e: Exception) {
            println("⚠️ [Accessibility] 清除浮窗常亮失败: ${e.message}")
        }
    }

    // 提取的公共实现：on=true 叠加 FLAG_KEEP_SCREEN_ON，false 清除
    private fun paramsFlagsKeepScreenOn(view: FlutterView, wm: WindowManager, on: Boolean) {
        val params = view.layoutParams as WindowManager.LayoutParams
        params.flags = if (on) {
            params.flags or WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        } else {
            params.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON.inv()
        }
        wm.updateViewLayout(view, params)
    }

    private fun updateOverlayFlag(flag: String, result: MethodChannel.Result? = null) {
        val view = overlayView ?: run { result?.success(true); return }
        val wm = overlayWindowManager ?: run { result?.success(true); return }
        val params = view.layoutParams as WindowManager.LayoutParams
        // 语音速记录音/转写期间可能叠加了 FLAG_KEEP_SCREEN_ON，本方法整体替换
        // params.flags 会把它冲掉——替换前先保存，替换后或回
        val keepScreenOn = params.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        params.flags = when (flag.lowercase()) {
            "focuspointer", "flagnottouchmodal" -> {
                // 卡片正文编辑态：可聚焦窗口系统才会弹软键盘；展开面板是全屏窗口
                //（FLAG_LAYOUT_NO_LIMITS），不配 ADJUST_RESIZE 键盘会盖住卡片，
                // resize 让窗口高度随键盘收缩。default 分支不动：NOT_FOCUSABLE
                // 窗口永不弹 IME，残留 softInputMode 无副作用
                params.softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                        WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                        WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED or
                        keepScreenOn
            }
            else -> {
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                        WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                        WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED or
                        keepScreenOn
            }
        }
        wm.updateViewLayout(view, params)
        if (result == null) return
        when (flag.lowercase()) {
            "focuspointer", "flagnottouchmodal" -> {
                // ⚠️ updateViewLayout 异步生效：WMS 重算焦点窗口、本窗收到
                // onWindowFocusChanged(true) 还要 1~2 帧。立即回执会让 Dart
                // 下一帧的 requestFocus → showSoftInput 打在 windowFocus=false
                // 的窗口上被 IMM 静默拒绝（症状=有光标无键盘）——等窗口真正
                // 拿到 focus 再回执。已聚焦（卡 A 编辑中切卡 B）直接回执
                if (view.hasWindowFocus()) {
                    result.success(true)
                } else {
                    awaitWindowFocusThenReply(view, result)
                }
            }
            // 回 NOT_FOCUSABLE 等不弹键盘的 flag：无焦点等待需求，立即回执
            else -> result.success(true)
        }
    }

    // updateFlag('focuspointer') 回执的 window focus 等待：onWindowFocusChanged(true)
    // 到达才 result.success；500ms 超时兜底回执（Dart 侧容错：键盘没弹用户再点
    // 正文重试）。latch 防"超时"与"focus 到位"双回执；view 被移除后 observer
    // 不再存活，监听自然失效，仅超时 Runnable 兜底
    private val overlayFlagReplyHandler = Handler(Looper.getMainLooper())

    private fun awaitWindowFocusThenReply(view: FlutterView, result: MethodChannel.Result) {
        val observer = view.viewTreeObserver
        if (!observer.isAlive) {
            result.success(true)
            return
        }
        val replied = AtomicBoolean(false)
        lateinit var listener: ViewTreeObserver.OnWindowFocusChangeListener
        val timeout = Runnable {
            if (replied.compareAndSet(false, true)) {
                if (observer.isAlive) observer.removeOnWindowFocusChangeListener(listener)
                result.success(true)
            }
        }
        listener = ViewTreeObserver.OnWindowFocusChangeListener { hasFocus ->
            if (hasFocus && replied.compareAndSet(false, true)) {
                overlayFlagReplyHandler.removeCallbacks(timeout)
                if (observer.isAlive) observer.removeOnWindowFocusChangeListener(listener)
                result.success(true)
            }
        }
        observer.addOnWindowFocusChangeListener(listener)
        overlayFlagReplyHandler.postDelayed(timeout, 500)
    }

    /** 构造悬浮窗 LayoutParams。width/height 传 dp；哨兵值 -1 = MATCH_PARENT 铺满全屏
     * （宽高均 -1 时 gravity=END 贴右；否则右缘垂直居中——88dp 把手/64dp 语音胶囊都必须垂直居中）。
     * hidden=true（语音速记冷启动隐藏窗口）：直建胶囊尺寸 312×64 + alpha=0 不可见 +
     * FLAG_NOT_TOUCHABLE 不挡触摸，等 Dart 录音态首帧 voiceMemoUiReady 到达再 alpha=1 揭示
     * （清 NOT_TOUCHABLE）——无 resize 无把手帧，把手像素物理上不可能出现。
     * 使用方：showOverlay 立即 addView（非隐藏=28x88 把手起步；隐藏=直建 312x64 胶囊尺寸） */
    private fun buildOverlayParams(widthDp: Int, heightDp: Int, hidden: Boolean = false): WindowManager.LayoutParams {
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        val params = WindowManager.LayoutParams(
            if (widthDp == -1) WindowManager.LayoutParams.MATCH_PARENT else dpToPx(widthDp),
            if (heightDp == -1) WindowManager.LayoutParams.MATCH_PARENT else dpToPx(heightDp),
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                    WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED or
                    // 隐藏窗口期间追加 NOT_TOUCHABLE：不可见的窗口不该拦截用户触摸，揭示时清除
                    (if (hidden) WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE else 0),
            PixelFormat.TRANSLUCENT
        )
        params.gravity = if (heightDp == -1) Gravity.END
                         else Gravity.CENTER_VERTICAL or Gravity.END
        if (hidden) params.alpha = 0f
        return params
    }

    private fun dpToPx(dp: Int): Int {
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            dp.toFloat(),
            resources.displayMetrics
        ).toInt()
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        // 三星等 ROM 可能忽略 XML 中的 flagRequestFilterKeyEvents，需代码中再次请求
        serviceInfo = serviceInfo.apply {
            flags = flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_REQUEST_FILTER_KEY_EVENTS
        }
        println("✅ [Accessibility] 无障碍服务已连接，按键过滤已启用")
    }

    override fun onDestroy() {
        // 清理语音速记 stop 超时计时，避免 Runnable 在 service 销毁后仍持有引用 3 秒
        cancelVoiceMemoStopTimeout()
        // 同理撤四级 watchdog（最长 76s，比 stop 超时更不能泄漏到已销毁的 service 实例上）
        cancelVoiceMemoWatchdog()
        hideOverlay()
        instance = null
        super.onDestroy()
    }

    override fun onInterrupt() {
        singleClickHandler.removeCallbacksAndMessages(null)
        // 补上长按计时的对称清理（此前只清单击，长按 runnable 可能残留触发）
        longPressHandler.removeCallbacksAndMessages(null)
        currentLongPressAction = null
        isLongPressTriggered = false
        println("⚠️ [Accessibility] 无障碍服务被中断")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // 不需要处理无障碍事件，仅用于按键监听
    }
}
