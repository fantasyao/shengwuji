package com.shengwuji.app

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.app.AlarmManager
import android.app.PendingIntent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.VibrationEffect
import android.os.Vibrator
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.provider.AlarmClock
import android.provider.CalendarContract
import android.view.WindowManager
import java.util.Calendar
import java.util.TimeZone

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.shengwuji.app/app"
    private var flutterEngine: FlutterEngine? = null
    // 锁屏隐私保护：监听屏幕熄灭，清除 sticky 锁屏 flag + 退到后台
    private var screenOffReceiver: BroadcastReceiver? = null

    companion object {
        // 常驻 Flutter 通道引用：闹钟广播接收器（AlarmReceiver 等）没有 Activity 上下文，
        // 响铃开始/停止时经此向 Flutter 推事件（onAlarmRinging / onAlarmStopped），
        // 替代 Dart 侧 2 秒轮询 SharedPreferences（性能审查 Top5）。
        // Receiver 与本 Activity 同进程（Manifest 未声明 android:process），静态可达；
        // ⚠️ invokeMethod 必须在主线程调用（Receiver.onReceive / 超时 Handler 回调均在主线程）。
        @Volatile
        var flutterChannel: MethodChannel? = null

        fun notifyFlutterAlarm(ringing: Boolean, alarmId: Int) {
            flutterChannel?.invokeMethod(
                if (ringing) "onAlarmRinging" else "onAlarmStopped",
                mapOf("alarm_id" to alarmId)
            )
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // 处理从闹钟通知点击返回的情况（停止响铃）
        if (intent?.getStringExtra("action") == "stop_alarm") {
            val alarmId = intent?.getIntExtra("alarm_id", 0) ?: 0
            AlarmReceiver.stopAlarmCompletely(this, alarmId)
            println("🔔 [MainActivity] onCreate: 停止闹钟响铃")
        }

        // 🔥 锁屏快捷录音：若是快捷方式触发的冷启动，确认锁屏之上显示能力
        // （动态设置 setShowWhenLocked + setTurnScreenOn；
        //  不再用 Manifest 静态属性——会让用户主动打开 APP 时也绕过锁屏界面，暴露隐私）
        applyLockScreenFlagsIfNeeded(intent)

        // 处理冷启动时的快捷方式 Intent
        // 延迟执行，确保 Flutter 引擎已初始化
        savedInstanceState ?: handleShortcutIntentOnColdStart(intent)

        // 处理冷启动时的系统分享文本
        savedInstanceState ?: handleShareIntentOnColdStart(intent)

        // 🔒 锁屏隐私保护：监听屏幕熄灭，清除 sticky 锁屏 flag
        // 覆盖场景 D（录音中直接按电源键锁屏），避免点亮屏幕后绕过锁屏界面
        //
        // ⚠️ 只调用 clearLockScreenFlags()，不调用 moveTaskToBack(true)：
        //   moveTaskToBack 对"用户主动打开 APP 后息屏"的场景会造成 task 状态异常，
        //   下次点图标时 APP 短暂显示又退出（需点第二次才能正常进入）。
        //   clearLockScreenFlags() 调用 setShowWhenLocked(false) 足以保护隐私——
        //   下次点亮屏幕时 Android 会正常显示锁屏界面，不会绕过。
        //   clearLockScreenFlags() 对未设置过锁屏 flag 的 APP 是 no-op（幂等）。
        screenOffReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == Intent.ACTION_SCREEN_OFF) {
                    println("🔒 [MainActivity] 屏幕熄灭，清除锁屏 flag（不 moveTaskToBack，避免 task 状态异常）")
                    clearLockScreenFlags()
                }
            }
        }
        registerReceiver(screenOffReceiver, IntentFilter(Intent.ACTION_SCREEN_OFF))
    }

    override fun onDestroy() {
        // 引擎随 Activity 销毁，置空防悬挂引用（重建时 configureFlutterEngine 重新注册）
        flutterChannel = null
        screenOffReceiver?.let {
            unregisterReceiver(it)
            screenOffReceiver = null
        }
        super.onDestroy()
    }

    /**
     * 锁屏快捷录音：当 Intent 是 quick_record / quick_text_note 时，
     * 调用 setShowWhenLocked + setTurnScreenOn，确保 MainActivity 显示在锁屏界面之上。
     * - API 27+ (O_MR1)：用 Activity.setShowWhenLocked / setTurnScreenOn（官方推荐）
     * - API 26 及以下：用 Window.FLAG_SHOW_WHEN_LOCKED / FLAG_TURN_SCREEN_ON（已 deprecated 但仍工作）
     *
     * 注意：singleTop 模式下，第二次快捷方式触发走 onNewIntent，不会重新走 onCreate。
     * 所以 onNewIntent 中也要调用本方法（MainActivity 可能首次正常启动未走快捷方式路径）。
     */
    private fun applyLockScreenFlagsIfNeeded(intent: Intent?) {
        val shortcutType = extractShortcutType(intent)
        if (shortcutType == null) return  // 非快捷方式启动，不应用锁屏 flag

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            println("🔒 [MainActivity] 已启用锁屏显示 (API 27+): $shortcutType")
        } else {
            @Suppress("DEPRECATION")
            window.setFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
            println("🔒 [MainActivity] 已启用锁屏显示 (API 26-): $shortcutType")
        }
    }

    /**
     * 锁屏隐私保护：清除锁屏显示 flag。
     * 仅由 ACTION_SCREEN_OFF 接收器调用（用户主动锁屏时），
     * 确保 setShowWhenLocked(true) 的 sticky 效果被移除，
     * 避免下次点亮屏幕时绕过锁屏界面。
     *
     * ⚠️ 注意：录音停止/编辑面板关闭时**不要**调用本方法——
     * 会让 APP 在锁屏之上录音后立即失去锁屏显示能力，用户看不到转写结果。
     * 实测教训：在 stopListening 中清 flag 会导致录音结束后 APP 被锁屏遮挡。
     */
    private fun clearLockScreenFlags() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(false)
            setTurnScreenOn(false)
            println("🔒 [MainActivity] 已清除锁屏显示 flag (API 27+)")
        } else {
            @Suppress("DEPRECATION")
            window.clearFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
            println("🔒 [MainActivity] 已清除锁屏显示 flag (API 26-)")
        }
    }

    private fun handleShortcutIntentOnColdStart(intent: Intent?) {
        val shortcutType = extractShortcutType(intent)
        if (shortcutType == "show_overlay") {
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                notifyFlutterShowOverlay()
            }, 100)
        } else if (shortcutType != null) {
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                notifyFlutterShortcut(shortcutType)
            }, 100)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        this.flutterEngine = flutterEngine

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "moveTaskToBack" -> {
                    moveTaskToBack(true)
                    result.success(true)
                }
                "openAlarmApp" -> {
                    val timestamp = call.argument<Long>("timestamp") ?: 0L
                    val message = call.argument<String>("message") ?: ""
                    val success = openAlarmApp(timestamp, message)
                    result.success(success)
                }
                "addCalendarEvent" -> {
                    val timestamp = call.argument<Long>("timestamp") ?: 0L
                    val title = call.argument<String>("title") ?: "提醒"
                    val enableAlarm = call.argument<Boolean>("enableAlarm") ?: true
                    // 日历逻辑在 CalendarEventHelper（与无障碍 Service 侧悬浮窗
                    // 闹钟共用，见该文件头注释——两个 FlutterEngine 通道不通）
                    val success = CalendarEventHelper.addCalendarEvent(this, timestamp, title, enableAlarm)
                    result.success(success)
                }
                "isAccessibilityServiceEnabled" -> {
                    val enabled = isAccessibilityServiceEnabled()
                    result.success(enabled)
                }
                "openAccessibilitySettings" -> {
                    val intent = Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(intent)
                    result.success(true)
                }
                "performHaptic" -> {
                    val type = call.argument<String>("type") ?: "click"
                    performHaptic(type)
                    result.success(true)
                }
                // 静音逻辑在 MediaMuteHelper（悬浮窗录音共用同一份，见该文件头注释）
                "muteMedia" -> {
                    MediaMuteHelper.mute(this)
                    result.success(true)
                }
                "restoreMedia" -> {
                    MediaMuteHelper.restore(this)
                    result.success(true)
                }
                "stopAlarmRingtone" -> {
                    // 供 Flutter 层调用：停止闹钟响铃
                    val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                    val alarmId = prefs.getInt("flutter.current_alarm_id", 0)
                    AlarmReceiver.stopAlarmCompletely(this, alarmId)
                    result.success(true)
                }
                "setIconPack" -> {
                    val packId = call.argument<String>("packId") ?: "default"
                    result.success(setIconPack(packId))
                }
                "getCurrentIconPack" -> {
                    result.success(getCurrentIconPack())
                }
                else -> result.notImplemented()
            }
        }
        // 注册进静态引用：供 AlarmReceiver 等无 Activity 上下文的组件推事件
        flutterChannel = channel
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)

        // 处理闹钟通知点击（singleTop 模式下 Activity 不重建，走 onNewIntent）
        if (intent.getStringExtra("action") == "stop_alarm") {
            val alarmId = intent.getIntExtra("alarm_id", 0)
            AlarmReceiver.stopAlarmCompletely(this, alarmId)
            println("🔔 [MainActivity] onNewIntent: 停止闹钟响铃")
        }

        // 🔥 锁屏快捷录音：热启动场景下确认锁屏显示能力
        // （若上次是非快捷方式启动，onCreate 未应用锁屏 flag，这里补上）
        applyLockScreenFlagsIfNeeded(intent)

        handleShortcutIntent(intent)
        handleShareIntent(intent)
    }

    private fun handleShortcutIntent(intent: Intent?) {
        val shortcutType = extractShortcutType(intent)
        when (shortcutType) {
            "show_overlay" -> notifyFlutterShowOverlay()
            null -> Unit
            else -> notifyFlutterShortcut(shortcutType)
        }
    }

    private fun extractShortcutType(intent: Intent?): String? {
        if (intent == null) return null

        // 新格式：自定义 action（shortcut intent，支持图标包切换后 alias 路由）
        when (intent.action) {
            "com.shengwuji.app.ACTION_QUICK_RECORD" -> return "quick_record"
            "com.shengwuji.app.ACTION_QUICK_TEXT_NOTE" -> return "quick_text_note"
        }

        // 老格式：无障碍服务发的 ACTION_VIEW + data（保持兼容）
        if (intent.dataString == "quick_record") {
            return "quick_record"
        }

        // 双击音量键触发的文本笔记快捷方式
        if (intent.dataString == "quick_text_note") {
            return "quick_text_note"
        }

        // 长按音量上键触发的悬浮窗快捷方式
        if (intent.dataString == "show_overlay") {
            return "show_overlay"
        }

        // 动态快捷方式（quick_actions 插件）
        val extras = intent.extras
        if (extras != null) {
            val type = extras.getString("type")
            if (type == "action_quick_record") return "quick_record"
            // 悬浮窗闹钟缺日历权限：无障碍 Service 拉起主 App 时携带
            // （VolumeKeyAccessibilityService requestCalendarPermission），
            // Dart 侧收到后自动弹系统授权框
            if (type == "grant_calendar") return "grant_calendar"

            val shortcutType = extras.getString("shortcutType")
            if (shortcutType == "action_quick_record") return "quick_record"
        }

        return null
    }

    private fun notifyFlutterShortcut(shortcutType: String) {
        flutterEngine?.let { engine ->
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                .invokeMethod("onShortcutLaunch", shortcutType)
        }
    }

    private fun notifyFlutterShowOverlay() {
        flutterEngine?.let { engine ->
            println("🪟 [MainActivity] 通知 Flutter 显示悬浮窗")
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                .invokeMethod("showOverlay", null)
        }
    }

    // ==================== 接收系统分享文本 ====================

    private fun handleShareIntentOnColdStart(intent: Intent?) {
        if (intent?.action == Intent.ACTION_SEND && intent.type == "text/plain") {
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                handleShareIntent(intent)
            }, 100)
        }
    }

    private fun handleShareIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND || intent.type != "text/plain") return

        val sharedText = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim() ?: return
        if (sharedText.isEmpty()) return

        val source = getShareSource(intent)
        println("📝 [MainActivity] 接收到分享文本: ${sharedText.take(100)}, source=$source")
        notifyFlutterSharedText(sharedText, source)

        // 防止重建时重复处理
        intent.action = Intent.ACTION_MAIN
        intent.removeExtra(Intent.EXTRA_TEXT)
    }

    private fun getShareSource(intent: Intent?): String? {
        return try {
            var packageName: String? = null

            // 1. 优先 EXTRA_PACKAGE_NAME
            packageName = intent?.getStringExtra(Intent.EXTRA_PACKAGE_NAME)
            println("📝 [MainActivity] EXTRA_PACKAGE_NAME: $packageName")

            // 2. 其次 getReferrer()
            if (packageName == null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
                packageName = getReferrer()?.authority
                println("📝 [MainActivity] getReferrer(): $packageName")
            }

            // 3. 最后 getCallingPackage()
            if (packageName == null) {
                packageName = getCallingPackage()
                println("📝 [MainActivity] getCallingPackage(): $packageName")
            }

            // 4. 包名转应用名
            if (packageName != null) {
                try {
                    val appInfo = packageManager.getApplicationInfo(packageName, 0)
                    packageManager.getApplicationLabel(appInfo).toString()
                } catch (e: PackageManager.NameNotFoundException) {
                    println("📝 [MainActivity] 包名解析失败: $packageName, ${e.message}")
                    null
                }
            } else {
                null
            }
        } catch (e: Exception) {
            println("📝 [MainActivity] 获取分享来源失败: ${e.message}")
            null
        }
    }

    private fun notifyFlutterSharedText(text: String, source: String?) {
        flutterEngine?.let { engine ->
            val args = mapOf("text" to text, "source" to source)
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
                .invokeMethod("onReceiveSharedText", args)
        }
    }

    private fun isAccessibilityServiceEnabled(): Boolean {
        // 三星系统存储格式：包名/完整类名（不是 .简写格式）
        val serviceName = "$packageName/${packageName}.VolumeKeyAccessibilityService"
        val enabledServices = android.provider.Settings.Secure.getString(
            contentResolver,
            android.provider.Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        println("🔍 [MainActivity] 已启用的无障碍服务: $enabledServices")
        println("🔍 [MainActivity] 查找服务名: $serviceName")
        return enabledServices.contains(serviceName)
    }

    private fun performHaptic(type: String) {
        val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        if (!vibrator.hasVibrator()) return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val effect = when (type) {
                "click" -> VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK)
                "heavy" -> VibrationEffect.createPredefined(VibrationEffect.EFFECT_HEAVY_CLICK)
                "double" -> VibrationEffect.createPredefined(VibrationEffect.EFFECT_DOUBLE_CLICK)
                "tick" -> VibrationEffect.createPredefined(VibrationEffect.EFFECT_TICK)
                else -> VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK)
            }
            vibrator.vibrate(effect)
        } else {
            // Android 7.x 及以下回退
            @Suppress("DEPRECATION")
            vibrator.vibrate(when (type) {
                "heavy" -> 30L
                "double" -> 30L
                else -> 15L
            })
        }
    }

    private fun openAlarmApp(timestamp: Long, message: String): Boolean {
        val calendar = Calendar.getInstance().apply {
            timeInMillis = timestamp
        }
        val hour = calendar.get(Calendar.HOUR_OF_DAY)
        val minute = calendar.get(Calendar.MINUTE)

        // 方案1：尝试使用 ACTION_SET_ALARM（三星设备可能被拒绝）
        val intent = Intent(AlarmClock.ACTION_SET_ALARM).apply {
            putExtra(AlarmClock.EXTRA_HOUR, hour)
            putExtra(AlarmClock.EXTRA_MINUTES, minute)
            putExtra(AlarmClock.EXTRA_MESSAGE, message)
            putExtra(AlarmClock.EXTRA_SKIP_UI, false)
        }

        try {
            if (intent.resolveActivity(packageManager) != null) {
                startActivity(intent)
                println("✅ 使用 ACTION_SET_ALARM 成功")
                return true
            }
        } catch (e: SecurityException) {
            println("⚠️ ACTION_SET_ALARM 被拒绝: ${e.message}")
        }

        // 方案2：降级到 ACTION_SHOW_ALARMS（显示闹钟列表）
        try {
            val showAlarmsIntent = Intent(AlarmClock.ACTION_SHOW_ALARMS)
            if (showAlarmsIntent.resolveActivity(packageManager) != null) {
                startActivity(showAlarmsIntent)
                println("✅ 降级到 ACTION_SHOW_ALARMS 成功")
                return true
            }
        } catch (e: Exception) {
            println("⚠️ ACTION_SHOW_ALARMS 失败: ${e.message}")
        }

        // 方案3：降级到启动三星时钟应用
        try {
            val launchIntent = packageManager.getLaunchIntentForPackage("com.sec.android.app.clockpackage")
            if (launchIntent != null) {
                startActivity(launchIntent)
                println("✅ 降级到启动三星时钟成功")
                return true
            }
        } catch (e: Exception) {
            println("⚠️ 启动三星时钟失败: ${e.message}")
        }

        // 方案4：降级到启动标准时钟
        try {
            val launchIntent = packageManager.getLaunchIntentForPackage("com.android.deskclock")
            if (launchIntent != null) {
                startActivity(launchIntent)
                println("✅ 降级到启动标准时钟成功")
                return true
            }
        } catch (e: Exception) {
            println("⚠️ 启动标准时钟失败: ${e.message}")
        }

        println("❌ 所有方案都失败")
        return false
    }

    // 日历写入逻辑（addCalendarEvent/scheduleAlarm/getAvailableCalendarId）已抽至
    // CalendarEventHelper——与无障碍 Service 侧悬浮窗闹钟共用；悬浮窗是独立
    // FlutterEngine，其通道调不到本 Activity 的处理器，Service 直接调同一份实现
    // ==================== Phase 4：图标包切换 ====================

    /**
     * 切换图标包：通过 setComponentEnabledSetting 启用目标组件、禁用其他。
     * ⚠️ 副作用：1-3 秒内 APP 进程会被系统杀死（Android 已知行为）。
     */
    private fun setIconPack(packId: String): Boolean {
        return try {
            val pkg = packageName
            val components = mapOf(
                "default" to ComponentName(pkg, "$pkg.MainActivity"),
                "warm"    to ComponentName(pkg, "$pkg.IconWarm"),
                "festive" to ComponentName(pkg, "$pkg.IconFestive"),
                "minimal" to ComponentName(pkg, "$pkg.IconMinimal"),
            )
            val target = components[packId] ?: run {
                println("❌ [IconPack] 未知 packId: $packId")
                return false
            }
            for ((id, comp) in components) {
                val state = if (id == packId) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                            else PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                // DONT_KILL_APP：让系统延迟杀进程，给 Flutter UI 时间显示"切换中"
                packageManager.setComponentEnabledSetting(comp, state, PackageManager.DONT_KILL_APP)
            }
            println("✅ [IconPack] 已切换到: $packId")
            true
        } catch (e: Exception) {
            println("❌ [IconPack] 切换失败: ${e.message}")
            false
        }
    }

    /**
     * 查询当前启用的图标包。
     * 检查 4 个组件的 enabled 状态。MainActivity 默认 enabled=true（DEFAULT 状态），
     * alias 默认 enabled=false（DEFAULT 状态）。
     */
    private fun getCurrentIconPack(): String {
        return try {
            val pkg = packageName
            val components = mapOf(
                "default" to ComponentName(pkg, "$pkg.MainActivity"),
                "warm"    to ComponentName(pkg, "$pkg.IconWarm"),
                "festive" to ComponentName(pkg, "$pkg.IconFestive"),
                "minimal" to ComponentName(pkg, "$pkg.IconMinimal"),
            )
            for ((id, comp) in components) {
                val state = packageManager.getComponentEnabledSetting(comp)
                val isEnabled = state == PackageManager.COMPONENT_ENABLED_STATE_ENABLED ||
                    (state == PackageManager.COMPONENT_ENABLED_STATE_DEFAULT && id == "default")
                if (isEnabled) return id
            }
            "default"
        } catch (e: Exception) {
            "default"
        }
    }
}
