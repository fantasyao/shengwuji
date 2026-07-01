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
import android.media.AudioManager
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
        if (shortcutType != null) {
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                notifyFlutterShortcut(shortcutType)
            }, 100)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        this.flutterEngine = flutterEngine

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
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
                    val success = addCalendarEvent(timestamp, title, enableAlarm)
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
                "muteMedia" -> {
                    val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val currentVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
                    // 保存到 SharedPreferences（与 Flutter 共享）
                    getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                        .edit()
                        .putInt("flutter.saved_media_volume", currentVolume)
                        .putBoolean("flutter.keep_muted", false)
                        .apply()
                    // 静音
                    audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, 0, 0)
                    println("🔇 [Audio] 静音媒体: 保存音量=$currentVolume, 已设为0")
                    result.success(true)
                }
                "restoreMedia" -> {
                    val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                    val keepMuted = prefs.getBoolean("flutter.keep_muted", false)
                    if (!keepMuted) {
                        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val savedVolume = prefs.getInt("flutter.saved_media_volume", 0)
                        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, savedVolume, 0)
                        println("🔇 [Audio] 恢复媒体音量: $savedVolume")
                    } else {
                        println("🔇 [Audio] 用户按了音量减，保持静音")
                    }
                    // 清理标记
                    prefs.edit().remove("flutter.keep_muted").remove("flutter.saved_media_volume").apply()
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
    }

    private fun handleShortcutIntent(intent: Intent?) {
        val shortcutType = extractShortcutType(intent)
        if (shortcutType != null) {
            notifyFlutterShortcut(shortcutType)
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

        // 动态快捷方式（quick_actions 插件）
        val extras = intent.extras
        if (extras != null) {
            val type = extras.getString("type")
            if (type == "action_quick_record") return "quick_record"

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

    /**
     * 通过 Calendar Provider 静默写入日历事件 + 提醒
     * 替代 ACTION_SET_ALARM，绕过三星等设备的闹钟权限限制
     *
     * 注意事项：
     * 1. 必须获取有效的 CALENDAR_ID（不能硬编码 1）
     * 2. EVENT_TIMEZONE 是必填字段
     * 3. 提醒必须单独插入 Reminders 表
     */
    private fun addCalendarEvent(timestamp: Long, title: String, enableAlarm: Boolean): Boolean {
        if (timestamp <= 0L) {
            println("❌ [Calendar] 无效的时间戳: $timestamp")
            return false
        }

        try {
            // 1. 查询系统可用的日历账户
            val calendarId = getAvailableCalendarId()
            if (calendarId == null) {
                println("❌ [Calendar] 未找到可用的日历账户")
                return false
            }
            println("📅 [Calendar] 使用日历账户 ID: $calendarId")

            // 2. 插入日历事件
            val timeZone = TimeZone.getDefault().id
            val endTime = timestamp + 30 * 60 * 1000L // 默认 30 分钟时长

            val values = android.content.ContentValues().apply {
                put(CalendarContract.Events.DTSTART, timestamp)
                put(CalendarContract.Events.DTEND, endTime)
                put(CalendarContract.Events.TITLE, title)
                put(CalendarContract.Events.CALENDAR_ID, calendarId)
                put(CalendarContract.Events.EVENT_TIMEZONE, timeZone)
                // 全天事件为 0，非全天为 1（默认）
                put(CalendarContract.Events.ALL_DAY, 0)
                // 闹钟提醒相关的字段设为默认值
                put(CalendarContract.Events.HAS_ALARM, if (enableAlarm) 1 else 0)
            }

            val eventUri = contentResolver.insert(CalendarContract.Events.CONTENT_URI, values)
            if (eventUri == null) {
                println("❌ [Calendar] 插入日历事件失败（返回 null）")
                return false
            }

            // 3. 从返回的 URI 中提取事件 ID
            val eventId = eventUri.lastPathSegment?.toLongOrNull()
            if (eventId == null) {
                println("⚠️ [Calendar] 无法解析事件 ID，事件已创建但无法添加提醒")
                return true // 事件已创建，只是无法添加提醒
            }
            println("📅 [Calendar] 事件创建成功, ID: $eventId")

            // 不插入 Reminders 表——响铃由 AlarmReceiver 控制，避免日历 App 弹自己的通知导致用户混淆

            println("✅ [Calendar] 日历事件写入成功: $title @ $timestamp")

            // 5. 同时用 AlarmManager 设置精确闹钟（持续响铃，不依赖日历通知）
            if (enableAlarm) {
                scheduleAlarm(timestamp, title, eventId?.toInt() ?: 0)
            } else {
                println("📅 [Calendar] 响铃闹钟已跳过 (enableAlarm=false)")
            }

            return true

        } catch (e: SecurityException) {
            println("❌ [Calendar] 权限不足: ${e.message}")
            return false
        } catch (e: Exception) {
            println("❌ [Calendar] 写入失败: ${e.message}")
            return false
        }
    }

    /**
     * 使用 AlarmManager 设置精确闹钟
     * 到时间后触发 AlarmReceiver，播放循环闹钟响铃
     */
    private fun scheduleAlarm(timestamp: Long, message: String, alarmId: Int) {
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(this, AlarmReceiver::class.java).apply {
            putExtra("message", message)
            putExtra("alarm_id", alarmId)
        }

        val pendingIntent = PendingIntent.getBroadcast(
            this,
            alarmId,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // Android 12+：检查是否有精确闹钟权限
                if (alarmManager.canScheduleExactAlarms()) {
                    alarmManager.setExactAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP,
                        timestamp,
                        pendingIntent
                    )
                    println("🔔 [Alarm] 精确闹钟已设置 (Android 12+): $message @ $timestamp")
                } else {
                    // 没有精确闹钟权限，降级为非精确闹钟
                    alarmManager.setAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP,
                        timestamp,
                        pendingIntent
                    )
                    println("🔔 [Alarm] 非精确闹钟已设置（无精确权限）: $message @ $timestamp")
                }
            } else {
                // Android 11 及以下：直接设置精确闹钟
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP,
                    timestamp,
                    pendingIntent
                )
                println("🔔 [Alarm] 精确闹钟已设置: $message @ $timestamp")
            }
        } catch (e: SecurityException) {
            println("⚠️ [Alarm] 设置闹钟失败（权限不足）: ${e.message}")
            // 降级：不设闹钟，仅依赖日历提醒
        } catch (e: Exception) {
            println("⚠️ [Alarm] 设置闹钟失败: ${e.message}")
        }
    }

    /**
     * 查询系统中第一个可写入的日历账户 ID
     * 优先选择同步账户（Google/Samsung），其次选择本地账户
     */
    private fun getAvailableCalendarId(): Long? {
        // 优先查询同步账户
        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.ACCOUNT_NAME,
            CalendarContract.Calendars.ACCOUNT_TYPE,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
        )

        // 先尝试查询同步的日历（Google、Samsung 账户等）
        try {
            var cursor = contentResolver.query(
                CalendarContract.Calendars.CONTENT_URI,
                projection,
                "${CalendarContract.Calendars.SYNC_EVENTS} = 1",
                null,
                "${CalendarContract.Calendars._ID} ASC"
            )

            if (cursor != null && cursor.moveToFirst()) {
                val id = cursor.getLong(cursor.getColumnIndexOrThrow(CalendarContract.Calendars._ID))
                val name = cursor.getString(cursor.getColumnIndexOrThrow(CalendarContract.Calendars.ACCOUNT_NAME))
                val type = cursor.getString(cursor.getColumnIndexOrThrow(CalendarContract.Calendars.ACCOUNT_TYPE))
                println("📅 [Calendar] 找到同步日历: id=$id, account=$name, type=$type")
                cursor.close()
                return id
            }
            cursor?.close()

            // 没有同步日历，查询任何可用的日历
            cursor = contentResolver.query(
                CalendarContract.Calendars.CONTENT_URI,
                projection,
                null,
                null,
                "${CalendarContract.Calendars._ID} ASC"
            )

            if (cursor != null && cursor.moveToFirst()) {
                val id = cursor.getLong(cursor.getColumnIndexOrThrow(CalendarContract.Calendars._ID))
                val name = cursor.getString(cursor.getColumnIndexOrThrow(CalendarContract.Calendars.ACCOUNT_NAME))
                val type = cursor.getString(cursor.getColumnIndexOrThrow(CalendarContract.Calendars.ACCOUNT_TYPE))
                println("📅 [Calendar] 找到本地日历: id=$id, account=$name, type=$type")
                cursor.close()
                return id
            }
            cursor?.close()
        } catch (e: Exception) {
            println("❌ [Calendar] 查询日历账户失败: ${e.message}")
        }

        return null
    }

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
