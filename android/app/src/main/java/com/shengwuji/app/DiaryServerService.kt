package com.shengwuji.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * 电脑访问服务的前台保活服务（2026-09 新增）。
 *
 * 背景：日记内容的局域网 HTTP 服务跑在主 engine 的 Dart isolate 里
 * （web_server/diary_web_server.dart）。App 退后台后进程会被系统冻结
 * （Android 12+ cached app freezer），HTTP 服务随之断掉——电脑端打不开。
 * 本前台服务唯一的职责是把进程优先级拉到前台级，让 Dart isolate 持续运行。
 *
 * 设计要点：
 * - 类型用 specialUse（与悬浮窗 OverlayService 同款）：dataSync 类型在
 *   Android 15+ 有 6 小时/24 小时运行时限，长挂会被系统掐；specialUse 无时限
 * - HTTP 生命周期完全在 Dart 侧（DiaryServerController），本服务只管保活，
 *   不持有任何业务状态——进程被杀后下次打开 App 由 autoStartIfEnabled 恢复
 * - START_NOT_STICKY：服务被单独重启没有意义（Dart 侧 HTTP 不会随之复活），
 *   不粘
 */
class DiaryServerService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundWithNotification()
        println("💻 [DiaryServerService] 前台保活服务已启动")
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        println("💻 [DiaryServerService] 前台保活服务已停止")
        super.onDestroy()
    }

    private fun startForegroundWithNotification() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "电脑访问服务",
                NotificationManager.IMPORTANCE_LOW // 低优先级：常驻但不响不弹
            ).apply {
                description = "日记电脑访问服务运行中"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }

        val builder: Notification.Builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }
        val notification = builder
            .setContentTitle("声物记 · 电脑访问服务")
            .setContentText("运行中：可在电脑浏览器打开 http://<手机IP>:9527 查看日记")
            .setSmallIcon(R.mipmap.launcher_icon)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // API 34+ 必须显式传类型，且与 Manifest 声明一致（specialUse）
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    companion object {
        private const val CHANNEL_ID = "diary_server"
        private const val NOTIFICATION_ID = 9527 // 与服务端口同号，便于排查

        /** 拉起保活服务（App 前台时调用，无 startForegroundService 时序问题） */
        fun start(context: Context) {
            val intent = Intent(context, DiaryServerService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** 停止保活服务（幂等：未在跑时 stopService 是 no-op） */
        fun stop(context: Context) {
            context.stopService(Intent(context, DiaryServerService::class.java))
        }
    }
}
