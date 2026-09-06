package com.shengwuji.app

import android.app.Application

/// 进程入口兜底：进程启动时清 is_recording 录音互斥标志。
/// 该标志由本进程内 Flutter（主 App 或 overlay engine）写入、无障碍服务读取；
/// 进程死亡（崩溃/被杀）时 true 会永久残留，导致下次语音速记被误判
/// “主 APP 录音中”让位（2026-08-29 SIGABRT 崩溃后真实发生）。
/// 进程刚启动时本进程绝无录音在进行，清零无竞态。
class ShengwujiApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
            .edit()
            .putBoolean("flutter.is_recording", false)
            .apply()
    }
}
