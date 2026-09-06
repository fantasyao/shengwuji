package com.shengwuji.app

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.CalendarContract
import java.util.TimeZone

/**
 * 写系统日历 + AlarmManager 精确响铃的伴生工具（2026-09-06 从 MainActivity 抽出）。
 *
 * 双 engine 共用：主 App 日记页（MainActivity 通道 com.shengwuji.app/app 的
 * addCalendarEvent）与悬浮窗闹钟（无障碍 Service 通道 com.shengwuji.app/
 * accessibility_overlay 的 addCalendarEvent）——悬浮窗是独立 FlutterEngine，
 * messenger 与主 engine 互不相通，无法调用 MainActivity 的通道处理器；
 * Service 与 MainActivity 同进程，逻辑抽到这里双方各传自己的 Context 即可。
 *
 * 逻辑与原 MainActivity 实现逐行等价（仅 this → context 参数化）：
 * - 必须查询有效 CALENDAR_ID（优先同步账户，其次本地账户）
 * - EVENT_TIMEZONE 必填；事件默认 30 分钟时长、非全天
 * - 不插 Reminders 表——响铃由 AlarmReceiver 控制，避免日历 App 弹自己的通知
 */
object CalendarEventHelper {

    /** 日历写权限是否已授予（读+写都需 granted；悬浮窗/主 App 通用检查） */
    fun hasCalendarPermission(context: Context): Boolean {
        return context.checkSelfPermission(android.Manifest.permission.READ_CALENDAR) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED &&
            context.checkSelfPermission(android.Manifest.permission.WRITE_CALENDAR) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
    }

    /** 通知权限是否已授予（API 33+ 响铃通知需要 POST_NOTIFICATIONS，以下版本恒 true） */
    fun hasNotificationPermission(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
    }

    /**
     * 写入系统日历事件，enableAlarm 时同时用 AlarmManager 设置精确闹钟
     * （持续响铃，不依赖日历通知）
     *
     * 注意事项：
     * 1. 必须获取有效的 CALENDAR_ID（不能硬编码 1）
     * 2. EVENT_TIMEZONE 是必填字段
     * 3. 提醒必须单独插入 Reminders 表（本项目不插，响铃走 AlarmReceiver）
     */
    fun addCalendarEvent(
        context: Context,
        timestamp: Long,
        title: String,
        enableAlarm: Boolean
    ): Boolean {
        if (timestamp <= 0L) {
            println("❌ [Calendar] 无效的时间戳: $timestamp")
            return false
        }

        try {
            // 1. 查询系统可用的日历账户
            val calendarId = getAvailableCalendarId(context)
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

            val eventUri = context.contentResolver.insert(CalendarContract.Events.CONTENT_URI, values)
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

            println("✅ [Calendar] 日历事件写入成功: $title @ $timestamp")

            // 5. 同时用 AlarmManager 设置精确闹钟（持续响铃，不依赖日历通知）
            if (enableAlarm) {
                scheduleAlarm(context, timestamp, title, eventId.toInt())
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
    private fun scheduleAlarm(context: Context, timestamp: Long, message: String, alarmId: Int) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(context, AlarmReceiver::class.java).apply {
            putExtra("message", message)
            putExtra("alarm_id", alarmId)
        }

        val pendingIntent = PendingIntent.getBroadcast(
            context,
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
    private fun getAvailableCalendarId(context: Context): Long? {
        // 优先查询同步账户
        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.ACCOUNT_NAME,
            CalendarContract.Calendars.ACCOUNT_TYPE,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
        )

        // 先尝试查询同步的日历（Google、Samsung 账户等）
        try {
            var cursor = context.contentResolver.query(
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
            cursor = context.contentResolver.query(
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
}
