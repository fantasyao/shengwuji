package com.shengwuji.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 处理通知栏"停止响铃"按钮点击
 * 通知中的 Action 按钮点击后触发此 Receiver
 */
class AlarmStopReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == "ACTION_STOP_ALARM") {
            val alarmId = intent.getIntExtra("alarm_id", 0)
            println("🔔 [AlarmStopReceiver] 用户点击通知栏停止按钮")
            AlarmReceiver.stopAlarmCompletely(context, alarmId)
        }
    }
}
