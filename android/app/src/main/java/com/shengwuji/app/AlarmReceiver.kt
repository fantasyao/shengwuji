package com.shengwuji.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import androidx.core.app.NotificationCompat
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Handler
import android.os.Looper

class AlarmReceiver : BroadcastReceiver() {

    companion object {
        // 静态 MediaPlayer，确保响铃持续播放直到用户点击通知
        private var mediaPlayer: MediaPlayer? = null
        private var timeoutHandler: Handler? = null
        private var timeoutRunnable: Runnable? = null
        private const val ALARM_TIMEOUT_MS = 3 * 60 * 1000L  // 3 分钟自动停止

        fun stopRingtone() {
            mediaPlayer?.let {
                if (it.isPlaying) {
                    it.stop()
                }
                it.release()
            }
            mediaPlayer = null
            // 取消超时定时器
            timeoutRunnable?.let { timeoutHandler?.removeCallbacks(it) }
            timeoutHandler = null
            timeoutRunnable = null
        }

        /**
         * 完整停止闹钟：停止响铃 + 取消通知 + 取消超时定时器 + 清除 SharedPreferences 状态
         */
        fun stopAlarmCompletely(context: Context, alarmId: Int) {
            stopRingtone()
            // 取消通知
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(alarmId)
            // 清除 SharedPreferences 响铃状态
            context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .edit()
                .putBoolean("flutter.is_alarm_ringing", false)
                .remove("flutter.current_alarm_id")
                .apply()
            println("🔔 [AlarmReceiver] 闹钟已完全停止（alarmId=$alarmId）")
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        val message = intent.getStringExtra("message") ?: "提醒时间到了"
        val alarmId = intent.getIntExtra("alarm_id", 0)
        showNotification(context, alarmId, message)
        playAlarmRingtone(context, alarmId)
    }

    private fun showNotification(context: Context, alarmId: Int, message: String) {
        val channelId = "alarm_channel"
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "闹钟提醒",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "日记闹钟提醒"
                enableVibration(true)
                // 不在 channel 设置铃声，避免和 MediaPlayer 重复
                setSound(null, null)
            }
            notificationManager.createNotificationChannel(channel)
        }

        // 点击通知体 → 打开 MainActivity 停止响铃
        val stopIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("action", "stop_alarm")
            putExtra("alarm_id", alarmId)
        }
        val pendingIntent = android.app.PendingIntent.getActivity(
            context,
            alarmId,
            stopIntent,
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
        )

        // 停止按钮 → AlarmStopReceiver
        val stopActionIntent = Intent(context, AlarmStopReceiver::class.java).apply {
            action = "ACTION_STOP_ALARM"
            putExtra("alarm_id", alarmId)
        }
        val stopActionPendingIntent = android.app.PendingIntent.getBroadcast(
            context,
            alarmId + 10000,
            stopActionIntent,
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.mipmap.launcher_icon)
            .setContentTitle("日记提醒")
            .setContentText(message)
            .setStyle(NotificationCompat.BigTextStyle().bigText(message))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setOngoing(true)
            .setAutoCancel(false)
            .setVibrate(longArrayOf(0, 500, 200, 500))
            .setFullScreenIntent(pendingIntent, true)
            .setContentIntent(pendingIntent)
            // 通知被系统消除时（如三星UI的"停止"按钮）也触发停止响铃
            .setDeleteIntent(stopActionPendingIntent)
            .addAction(
                android.R.drawable.ic_media_pause,
                "停止响铃",
                stopActionPendingIntent
            )

        notificationManager.notify(alarmId, builder.build())
    }

    /**
     * 使用 MediaPlayer 循环播放闹钟铃声
     * 与 Ringtone.play() 不同，MediaPlayer 可以循环播放，直到用户手动关闭
     */
    private fun playAlarmRingtone(context: Context, alarmId: Int) {
        try {
            // 先停止之前的响铃
            stopRingtone()

            val alarmUri: Uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)

            mediaPlayer = MediaPlayer().apply {
                setDataSource(context, alarmUri)
                setAudioStreamType(AudioManager.STREAM_ALARM)
                isLooping = true  // 循环播放
                prepare()
                start()
            }

            // 写入 SharedPreferences 响铃状态（供 Flutter 层读取）
            context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .edit()
                .putBoolean("flutter.is_alarm_ringing", true)
                .putInt("flutter.current_alarm_id", alarmId)
                .apply()

            // 设置 3 分钟自动停止
            timeoutHandler = Handler(Looper.getMainLooper())
            timeoutRunnable = Runnable {
                println("🔔 [AlarmReceiver] 闹钟超时，自动停止（3分钟）")
                stopAlarmCompletely(context, alarmId)
            }
            timeoutHandler?.postDelayed(timeoutRunnable!!, ALARM_TIMEOUT_MS)

            println("🔔 [AlarmReceiver] 闹钟响铃已开始（循环播放，3分钟后自动停止）")
        } catch (e: Exception) {
            println("⚠️ [AlarmReceiver] MediaPlayer 播放失败，降级到 Ringtone: ${e.message}")
            // 降级方案：用 Ringtone 播放一次
            try {
                val alarmUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                val ringtone = RingtoneManager.getRingtone(context, alarmUri)
                ringtone.play()
            } catch (e2: Exception) {
                println("❌ [AlarmReceiver] Ringtone 也失败了: ${e2.message}")
            }
        }
    }
}
