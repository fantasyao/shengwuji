package com.shengwuji.app

import android.content.Context
import android.media.AudioManager

/**
 * 录音期间临时静音媒体的伴生工具（2026-09-06 从 MainActivity 抽出）。
 *
 * 双 engine 共用：主 App 快捷录音（MainActivity 通道 com.shengwuji.app/app 的
 * muteMedia / restoreMedia）与悬浮窗语音速记（无障碍 Service 通道
 * com.shengwuji.app/accessibility_overlay 的同名 handler）——悬浮窗是独立
 * FlutterEngine，messenger 与主 engine 互不相通，无法调用 MainActivity 的
 * 通道处理器；Service 与 MainActivity 同进程，逻辑抽到这里双方各传自己的
 * Context 即可（同 CalendarEventHelper 先例）。
 *
 * 交互语义（快捷录音 / 悬浮窗录音一致，受同一开关 flutter.keep_muted_on_volume_down
 * 控制——标记方在 VolumeKeyAccessibilityService.adjustVolume，按音量减时若开关开启
 * 且静音现场存在则置 keep_muted=true，本类不感知开关）：
 * - mute：保存当前媒体音量到 flutter.saved_media_volume + 清 keep_muted → 音量置 0
 * - restore：keep_muted=false 时恢复保存的音量（用户录音中按过音量减则保持静音），
 *   最后清理两个标记
 * saved_media_volume 是否存在即「静音现场」标志：restore 增加了无现场直接返回的
 * 防御（原 MainActivity 实现无现场时会误把音量设为默认值 0，抽公共类的顺带修正），
 * adjustVolume 的保持静音标记同款判断，两处语义一致。
 */
object MediaMuteHelper {

    /** 临时静音：保存当前媒体音量 → 清 keep_muted 标记 → 音量置 0 */
    fun mute(context: Context) {
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val currentVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        // 保存到 SharedPreferences（与 Flutter 共享）
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putInt(PREF_SAVED_VOLUME, currentVolume)
            .putBoolean(PREF_KEEP_MUTED, false)
            .apply()
        // 静音
        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, 0, 0)
        println("🔇 [Audio] 静音媒体: 保存音量=$currentVolume, 已设为0")
    }

    /** 恢复媒体音量（用户按音量减标记了保持静音时不恢复）；无静音现场直接返回 */
    fun restore(context: Context) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (!prefs.contains(PREF_SAVED_VOLUME)) {
            println("🔇 [Audio] 无静音现场(saved_media_volume 不存在)，跳过恢复")
            return
        }
        val keepMuted = prefs.getBoolean(PREF_KEEP_MUTED, false)
        if (!keepMuted) {
            val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val savedVolume = prefs.getInt(PREF_SAVED_VOLUME, 0)
            audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, savedVolume, 0)
            println("🔇 [Audio] 恢复媒体音量: $savedVolume")
        } else {
            println("🔇 [Audio] 用户按了音量减，保持静音")
        }
        // 清理标记
        prefs.edit().remove(PREF_KEEP_MUTED).remove(PREF_SAVED_VOLUME).apply()
    }

    private const val PREFS_NAME = "FlutterSharedPreferences"
    private const val PREF_SAVED_VOLUME = "flutter.saved_media_volume"
    private const val PREF_KEEP_MUTED = "flutter.keep_muted"
}
