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
import android.content.IntentFilter
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
import kotlin.math.roundToInt
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
        // 长按阈值的默认/回落值（毫秒）：prefs 缺失或越界脏值时用。用户可在
        // 设置页「音量键快捷操作」选预设档或输入自定义值，每次按键 DOWN 实时读
        // 落盘（getLongPressDurationMs）
        private const val LONG_PRESS_DURATION_MS = 400L
        // 长按阈值 prefs key（long，毫秒；写入方：Flutter 设置页 setInt；
        // 读取方：getLongPressDurationMs）。⚠️ 必须 getLong 读：Flutter
        // shared_preferences 的 setInt 在 Android 端落盘即 Long（Dart int 64 位，
        // 插件走 putLong，同 pro_trial_deadline_ms 先例），getInt 读会
        // ClassCastException 崩服务进程（2026-09-19 真机炸过：选 1200ms 后长按即崩）
        private const val LONG_PRESS_MS_KEY = "flutter.volume_long_press_ms"
        // 长按阈值合法范围边界（毫秒，闭区间）：⚠️ 硬编码副本——唯一真值在
        // Dart 侧 lib/utils/volume_gesture_config.dart VolumeLongPressMs.minMs/maxMs，
        // 改边界必须双侧同步。2026-09-23 设置页新增「自定义」档（点 chip 弹输入框，
        // 范围内任意值写同一 key）后，校验从档位集合白名单（旧
        // LONG_PRESS_MS_CHOICES.contains）改为范围校验——预设集合 {200,300,400,700}
        // 与 2026-09-21 前的旧档位 {400,500,800,1200} 都落在范围内，老用户升级后
        // 按原值继续生效（刻意选择：尊重其当年显式选的档位，不再回落 400）
        private const val LONG_PRESS_MS_MIN = 50L
        private const val LONG_PRESS_MS_MAX = 2000L
        // 「录音中单击结束录音」开关 prefs key（bool，默认 false；写入方：Flutter 设置页；
        // 读取方：onKeyEvent / isSingleClickStopEnabled 每次按键实时读）。与
        // keep_muted_on_volume_down（按音量减保持静音）互斥二选一——互斥在 Flutter
        // 设置页保证（开一个自动关另一个），本服务不重复校验；开启后录音中单击
        // 音量键直接停录，不再走 adjustVolume（keep_muted 自然失去触发入口）
        private const val SINGLE_CLICK_STOP_KEY = "flutter.single_click_stop_recording"

        // 「单击结束录音」额外覆盖的实体键：耳机线控中键 / 蓝牙耳机播放键 / 实体相机键。
        // 无障碍服务（flagRequestFilterKeyEvents）能收到这些键，但仅在录音中+开关开启时
        // 消费用于停录，平时完全放行（线控切歌 / 相机键启动相机不受影响）；电源键、
        // Home 等系统保留键任何第三方应用都收不到 KeyEvent，无法覆盖；厂商自定义
        // 侧键（努比亚滑动键等）不广播标准 KeyEvent，接入靠快捷方式映射（见
        // ShortcutDispatchActivity 链路）
        private val STOP_RECORDING_EXTRA_KEYCODES = intArrayOf(
            KeyEvent.KEYCODE_HEADSETHOOK,
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_CAMERA
        )

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
        // 按住说话（实验分支 2026-09-21）：长按槽位专属动作——按住达阈值即开录，
        // 松开同一键立即停录转写（与 toggle 制「松手后继续录、再长按才停」的根本
        // 差异）。复用悬浮窗语音速记整条链路（隐藏窗直建 / pendingVoiceMemoStart
        // 握手 / 四级 watchdog / 3s stop 回执兜底），只在触发与收尾时机上不同；
        // 会话跟踪见 pttHold* 系列。⚠️ 与 Dart 侧 VolumeGestureAction.pttRecord
        // 严格一致（跨端硬编码副本，改值必须双侧同步）
        private const val ACTION_PTT_RECORD = "ptt_record"
        // stopVoiceMemo 回执超时（毫秒）：Dart 卡死时防 toggle 死锁的最简兜底
        // （完整四级 watchdog 见 voiceMemoWatchdog* 系列——本超时只负责 stop 消息的回执兜底）
        private const val VOICE_MEMO_STOP_TIMEOUT_MS = 3000L
        // 语音速记录音上限（毫秒）：Dart 侧上限 Timer 停录（T0），Kotlin T1 同刻补发兜底。
        // 唯一真值在 Dart 侧 overlay_constants.dart voiceMemoMaxSeconds，改值须双侧同步
        private const val VOICE_MEMO_MAX_DURATION_MS = 300000L
        // overlay engine 的独立缓存 key（唯一真值；getOrCreateOverlayEngine / destroyOverlayEngine 共用）
        private const val OVERLAY_ENGINE_CACHE_KEY = "shengwuji_accessibility_overlay"
        // 语音速记冷启动隐藏窗口的直建尺寸（dp）：312 宽 / 84 高。
        // ⚠️ 硬编码副本——唯一真值在 Dart 侧 lib/overlay/overlay_constants.dart
        // （voiceMemoMaxWidth 300 + voiceMemoEdgeMargin 12 = 312 宽 / voiceMemoWindowHeight 84 高），
        // 改胶囊尺寸必须双侧同步。84 = 胶囊 44 居中带 + 下部提示条带（「再次长按
        // 音量上键停止」提示胶囊，仅前 2 次速记展示）；须 < 把手高 88——Dart 侧
        // build 硬不变量按「窗口高 < 把手高」判定 idle 帧渲染空白，≥88 会误渲染把手
        private const val VOICE_MEMO_OVERLAY_WIDTH_DP = 312
        private const val VOICE_MEMO_OVERLAY_HEIGHT_DP = 84

        // Pro 未解锁提示胶囊的展示时长（ms）：到点由 proHintDismissRunnable 收窗
        private const val PRO_HINT_DISPLAY_MS = 3000L

        // Pro 试用截止的持久化 key（long，epoch 毫秒；0=从未开过试用）。
        // 写入方：Dart ProGate.startTrial；读取方：isProUnlocked（试用中视为已解锁）。
        // 与 Dart 侧 ProGate.kKeyTrialDeadlineMs 同名（本服务读 Flutter prefs 加 flutter. 前缀）
        private const val PRO_TRIAL_DEADLINE_KEY = "flutter.pro_trial_deadline_ms"

        // 收起态把手宽度（dp）：dragHandle / endHandleDrag 用「窗口宽 == 把手宽」
        // 判定拖动是否仍作用在把手上——录音中打断等路径的残留拖动消息不得挪动
        // 语音胶囊窗口、也不得把胶囊的居中位置覆盖进拖存档（唯一真值在 Dart 侧
        // overlay_constants.dart handleWidth = 28，改把手宽度须双侧同步）
        private const val HANDLE_WIDTH_DP = 28

        // 「贴边竖线」驻留态的宽度判定阈值（dp）：自动隐藏后 Dart 侧把窗口缩成
        // 20dp 宽（edgeLineWindowWidth = 透明触摸缓冲区，视觉线仅 edgeLineWidth
        // = 4dp 贴停靠缘，唯一真值在 overlay_constants.dart）。
        // 窗口实际宽 ≤ 本阈值即视为线态（把手 28dp / 语音胶囊 312dp 都大于它），
        // 用于音量键 toggle 分流（见 isOverlayInEdgeLineState）。2026-09-14
        // 触摸缓冲区方案把线态窗口 4→20dp（4dp 难触发的修复），阈值同步
        // 12→24——在 20（线态）与 28（把手）之间取中，双侧硬编码副本须同步
        private const val EDGE_LINE_WIDTH_THRESHOLD_DP = 24

        // 把手纵向位置偏移的持久化 key（int，dp）：用户长按把手拖动后，收起态
        // 窗口相对「停靠缘垂直居中」的纵向偏移（向下为正；左右停靠共用同一份
        // 纵向位置——切侧不丢用户拖的上下位置）。写入方：本服务
        // endHandleDrag（拖动松手落盘）；读取方：handleYOffsetPxClamped（
        // buildOverlayParams / resizeOverlay 恢复把手与贴边竖线的位置；
        // 语音胶囊窗口恒居中不读）。单位用 dp 而非 px，跨分辨率/密度切换不漂移
        private const val HANDLE_Y_OFFSET_KEY = "flutter.overlay_handle_y_offset_dp"

        // 悬浮窗停靠侧的持久化 key（bool，Flutter bool 通道落盘）：false（缺省）
        // = 停靠屏幕右缘（Gravity.END，历史行为），true = 停靠左缘（Gravity.START）。
        // 唯一真值在 Dart 侧 overlay_constants.dart overlaySideLeftPrefKey（写入方
        // settings_tab，Flutter SharedPreferences 落盘带 flutter. 前缀，与本 key
        // 同文件同键名）；读取方：horizontalEdgeGravity（buildOverlayParams /
        // resizeOverlay 每次建窗/resize 实时读）——设置切换后下一次状态转换
        // 整体换侧，与 Dart 侧 OverlayHome._refreshSide 的镜像同步
        private const val OVERLAY_SIDE_LEFT_KEY = "flutter.overlay_side_left"

        // 笔记解锁会话的持久化 key（long，epoch 毫秒；0=未解锁）。⚠️ 硬编码副本
        // ——唯一真值在 Dart 侧 lib/utils/note_unlock_session.dart NoteUnlockSession.key
        //（Flutter setInt 落盘即 Long，本服务只 putLong 清零，不 getLong 读）。
        // 写入方：Dart NoteUnlockSession.extend（认证成功）/ 本服务 SCREEN_OFF
        // 广播（锁屏即重锁：直接清零，不依赖 Dart isolate 存活——悬浮窗锁屏
        // 偷看的最大威胁兜底就在这条链路）；读取方：Dart 侧 isUnlocked（reload 后读）
        private const val NOTE_UNLOCK_UNTIL_KEY = "flutter.notes_unlock_until_ms"

        // 认证让位的透明度：指纹对话框是系统窗口（TYPE_BIOMETRIC_PROMPT），
        // 层级低于无障碍悬浮窗（TYPE_ACCESSIBILITY_OVERLAY 特权层），会整块
        // 被面板挡住——拉起认证 Activity 时把窗口整体降到近透明让位（用户
        // 2026-09-22 反馈「指纹弹窗在悬浮窗下一层」，备选方案「透明一下」定版
        // 整体降透明而非只透下半），认证结果回发时恢复 1f。留 0.15 而非 0：
        // 用户仍隐约感知面板在场，恢复时无「窗口闪现」感
        private const val OVERLAY_AUTH_DIM_ALPHA = 0.15f

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
    // DOWN 时缓存的长按槽位键码：PTT 会话归属判定用（UP 只认发起 PTT 的那一键，
    // 防止按住 A 键录音时另一键的 UP 误停）。清空方：ACTION_UP（onInterrupt 不清
    // ——服务被中断时进行中的 PTT 会话仍应能被 UP 幂等收尾）
    private var currentLongPressKeyCode = 0

    // Handler 方案：不依赖 repeatCount（三星 ROM 不发送重复事件）
    private val longPressHandler = Handler(Looper.getMainLooper())
    private val longPressRunnable = Runnable {
        if (!isLongPressTriggered) {
            isLongPressTriggered = true
            currentLongPressAction?.let { executeGestureAction(it, "长按") }
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

    // 锁屏即重锁 + 息屏隐藏：监听屏幕熄灭/点亮。
    // - SCREEN_OFF：直接清零笔记解锁会话（flutter.notes_unlock_until_ms，不依赖
    //   Dart isolate 存活）+ 通知悬浮窗 Dart 打码已展开的锁定卡片 + 把悬浮窗
    //   visibility 置 GONE（TYPE_ACCESSIBILITY_OVERLAY 在 AOD 息屏时钟上仍参与
    //   合成，把手/贴边竖线会跟着时钟杵在息屏画面上——2026-09-22 用户反馈）。
    //   ACTION_SCREEN_OFF 在息屏时刻即发出（AOD 属非交互态），无需专门的 AOD
    //   检测 API，「屏幕变黑」与「进入 AOD」两种形态都被它覆盖
    // - SCREEN_ON：恢复 VISIBLE（见 setOverlayGoneForScreen）
    // 注册在服务而不是 MainActivity：服务常驻，主 App 未启动/已被划掉时
    // MainActivity 的 receiver 不存在，而悬浮窗恰恰在锁屏上显示
    private var screenOffReceiver: android.content.BroadcastReceiver? = null

    // 悬浮窗因息屏处于 GONE 的标志：SCREEN_ON 只在本标志为 true 时恢复 VISIBLE，
    // 防未来其他机制隐藏窗口后（visibility 归它管的前提破坏）被亮屏误揭示。
    // 随 service 实例生死（onDestroy 注销 receiver + hideOverlay 移窗，无跨实例残留）
    private var overlayHiddenByScreenOff = false

    // 把手长按拖动中：beginHandleDrag 到达时缓存的窗口 y 基线（px，gravity
    // CENTER_VERTICAL 语义 = 相对屏幕垂直中心的偏移）。dragHandle 的每次更新都
    // 用「基线 + Dart 报来的自按下原点累计位移」计算目标位置，不逐帧累加
    //（无累积漂移，丢一条中间消息也不偏）；endHandleDrag 落盘后无需清理
    private var handleDragBaseY = 0

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

    // ===== 按住说话（ptt_record，实验分支 2026-09-21）=====
    // 长按阈值已开录、等待本键 UP 停录的 PTT 会话标志 + 归属键码。
    // 写入方：triggerPttVoiceMemo（开录成功时）；清零方：stopPttHold / destroyOverlayEngine
    private var pttHoldActive = false
    private var pttHoldKeyCode = 0
    // 松手已请求停录、但 Dart 尚未回执 voiceMemoStarted（start 的 await 链还在跑）。
    // 此时早发的 stopVoiceMemo 会被 Dart stop() 的非录音态守卫静默 no-op 丢弃，等
    // voiceMemoStarted 回执到达后必须补发一次 stop——toggle 时代「stop 追上 start」
    // 只在冷启动极快连按两下长按时才可能撞上，PTT 短按住让它变成常态路径
    private var pttReleasePending = false
    // 语音速记隐藏窗口标记：showOverlay(hidden=true) 时窗口直接以胶囊尺寸（312×84）addView，
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

    // ===== Pro 未解锁提示胶囊（blockOverlayIfProLocked 的替代 Toast 反馈）=====
    // 提示窗复用语音速记的隐藏窗直建机制（312×84 胶囊尺寸 + alpha=0 + 揭示），
    // Dart 渲染「暂未解锁」提示胶囊首帧后发 voiceMemoUiReady 揭示，到点 Kotlin 收窗。
    // proHintActive：提示窗在场标志。⚠️ 期间再按键不得走 triggerShowOverlay 的
    // toggle 显示分支（提示窗揭示后 overlayView 非空，会被当成"已显示浮窗"）——
    // 否则未解锁用户可借提示窗绕出完整悬浮窗。清零唯一入口：hideOverlay（所有
    // 移窗路径必经：用户 toggle 关掉 / 3s 超时收窗 / destroy），保证不残留
    private var proHintActive = false
    // Dart 未就绪时挂起的 Pro 提示渲染请求（dartReady 握手到达后补发，与 pendingAutoExpand 同机制）
    private var pendingProHint = false
    private val proHintHandler = Handler(Looper.getMainLooper())
    private val proHintDismissRunnable = Runnable {
        if (proHintActive) {
            println("🔒 [Accessibility] Pro 未解锁提示胶囊到点收窗")
            hideOverlay()
        }
    }

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

    // 通用读取：新 key 的值为 7 个合法动作之一则直接用，否则（不存在/非法值）走迁移推导
    private fun getGestureAction(prefs: SharedPreferences, newKey: String, migrate: () -> String): String {
        val action = prefs.getString(newKey, null)
        return when (action) {
            ACTION_NONE, ACTION_SHOW_OVERLAY, ACTION_OVERLAY_RECORD,
            ACTION_QUICK_RECORD, ACTION_QUICK_TEXT_NOTE, ACTION_OVERLAY_NEW_NOTE,
            ACTION_PTT_RECORD -> action!!
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

    // 长按触发阈值：读设置页写入的值（预设档 200/300/400/700 或自定义
    // [LONG_PRESS_MS_MIN, LONG_PRESS_MS_MAX] 内任意值），缺失/脏值/越界回落 400。
    // 每次按键实时读落盘 prefs（与手势槽位动作同模式：无需 MethodChannel、
    // App 未打开也生效）。
    // ⚠️ 必须 getLong：Flutter setInt 落盘即 Long，getInt 会崩（key 注释详见）
    private fun getLongPressDurationMs(): Long {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val ms = prefs.getLong(LONG_PRESS_MS_KEY, LONG_PRESS_DURATION_MS)
        return if (ms in LONG_PRESS_MS_MIN..LONG_PRESS_MS_MAX) ms else LONG_PRESS_DURATION_MS
    }

    // 检查 Flutter 层是否正在录音
    private fun isRecording(): Boolean {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getBoolean("flutter.is_recording", false)
    }

    // 「录音中单击结束录音」开关：每次按键实时读落盘（同 4 槽位 key 模式——
    // 无 MethodChannel，App 未打开/设置页改完立即生效）
    private fun isSingleClickStopEnabled(): Boolean {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getBoolean(SINGLE_CLICK_STOP_KEY, false)
    }

    // 当前是否有录音在进行：悬浮窗语音速记 toggle 态或主 APP 录音互斥桥标志
    //（两者经互斥桥不会同时为 true，先查 voiceMemoActive 只是免一次 prefs 读）
    private fun isRecordingActive(): Boolean = voiceMemoActive || isRecording()

    // 录音中存在临时静音现场时兜底恢复媒体音量（悬浮窗被原生强杀的路径：
    // T3 移窗 / T4 销毁 engine / service 销毁——这些路径 Dart 侧 restoreMedia
    // 不会执行，不兜底会让手机永久静音）。无现场 / 非录音中均为幂等 no-op
    private fun restoreMutedMediaIfRecording() {
        if (isRecording()) MediaMuteHelper.restore(this)
    }

    // 检查 Pro 是否可用（设置页/弹窗写入，与 isRecording 同款落盘读取模式）。
    // 永久解锁 = is_pro_unlocked=true **且** 存在授权码记录 pro_license_code——
    // ⚠️ 裸布尔不认：旧版（君子协定）用户点一下就写 true 但无码记录，授权码
    // 体系上线后必须两者同时成立（2026-09-19 拍板：存量免费解锁用户升级即失效，
    // 走试用/输码流程）。与 Dart 侧 ProGate 组合判定同一组 key，双侧语义必须一致
    private fun isProUnlocked(): Boolean {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val licensed = prefs.getBoolean("flutter.is_pro_unlocked", false) &&
            !prefs.getString("flutter.pro_license_code", null).isNullOrEmpty()
        if (licensed) return true
        val deadline = prefs.getLong(PRO_TRIAL_DEADLINE_KEY, 0L)
        return deadline > 0 && System.currentTimeMillis() < deadline
    }

    /**
     * 悬浮窗系动作的 Pro 门禁：不可用时震动 + 显示「暂未解锁」提示胶囊并返回 true
     * （已拦截，调用方直接 return）。
     * 提示胶囊替代旧 Toast：复用语音速记隐藏窗直建机制在原录音胶囊位置（312×84）
     * 渲染提示文案，3 秒后自动收窗；建窗失败（engine 起不来等）回退 Toast 兜底。
     * ⚠️ 只拦"从隐藏态启动悬浮窗"的入口；已显示时的 toggle 隐藏 / 录音中 toggle 停止
     * 分支在调用本函数之前已放行——未解锁用户（或降级回未解锁的用户）必须关得掉
     * 已显示的浮窗。
     */
    private fun blockOverlayIfProLocked(): Boolean {
        if (isProUnlocked()) return false
        vibrateOneShot(50, 60)
        // 提示已在场（用户提示期内再按键）：刷新收窗计时即可，不重复建窗
        if (proHintActive) {
            proHintHandler.removeCallbacks(proHintDismissRunnable)
            proHintHandler.postDelayed(proHintDismissRunnable, PRO_HINT_DISPLAY_MS)
            println("🔒 [Accessibility] Pro 提示胶囊已在场，刷新收窗计时")
            return true
        }
        if (showProLockedHint()) {
            println("🔒 [Accessibility] 悬浮窗功能未解锁 Pro，已显示未解锁提示胶囊")
        } else {
            // 建窗失败（engine 起不来 / 已有浮窗在场不宜替换，见 showProLockedHint）
            Toast.makeText(this, "暂未解锁，无法使用（悬浮窗是 Pro 功能，请在声物记设置页解锁）", Toast.LENGTH_LONG).show()
            println("🔒 [Accessibility] 提示胶囊显示失败，已回退 Toast 拦截")
        }
        return true
    }

    /**
     * 显示「暂未解锁」提示胶囊：直建 312×84 隐藏窗（复用语音速记冷启动机制），
     * 通知 Dart 渲染提示胶囊首帧，揭示后 PRO_HINT_DISPLAY_MS 到点收窗。
     * 仅在无既有浮窗时使用（overlayView 非空时返回 false 由调用方回退 Toast）——
     * 已有浮窗（授权中途过期的罕见场景）不能被强行替换成提示窗。
     */
    private fun showProLockedHint(): Boolean {
        if (overlayView != null) return false
        val shown = showOverlay(autoExpand = false, hidden = true)
        if (!shown) return false
        proHintActive = true
        proHintHandler.postDelayed(proHintDismissRunnable, PRO_HINT_DISPLAY_MS)
        notifyDartProLockedHint()
        return true
    }

    /**
     * 通知 Dart 渲染 Pro 未解锁提示胶囊。与 notifyDartStartVoiceMemo 同一握手
     * 模式：dartReady=true 直接发；否则挂起 pendingProHint，dartReady 后补发。
     */
    private fun notifyDartProLockedHint() {
        if (dartReady) {
            overlayMethodChannel?.invokeMethod("showProLockedHint", null)
        } else {
            pendingProHint = true
            println("⏳ [Accessibility] Dart 未就绪，Pro 提示渲染请求已挂起")
        }
    }

    override fun onKeyEvent(event: KeyEvent): Boolean {
        val keyCode = event.keyCode

        // ── 非音量键：仅「单击结束录音」开启且录音中时，消费耳机线控/相机键停录 ──
        // 平时这些键完全还给系统（线控切歌、相机键启动相机），不进任何状态机。
        // 整段按键（DOWN/repeat/UP）都消费——部分 ROM 在 DOWN 就有系统行为，只拦
        // UP 拦不干净；停录动作只认非 repeat 的 UP（单击语义在抬起时刻生效，
        // 按住不放的重复事件不算）
        if (keyCode != KeyEvent.KEYCODE_VOLUME_UP && keyCode != KeyEvent.KEYCODE_VOLUME_DOWN) {
            if (isSingleClickStopEnabled() && isRecordingActive() &&
                STOP_RECORDING_EXTRA_KEYCODES.contains(keyCode)
            ) {
                if (event.action == KeyEvent.ACTION_UP && event.repeatCount == 0) {
                    stopActiveRecording()
                }
                return true
            }
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

            // 长按槽有动作才启动长按计时（DOWN 时缓存动作，runnable 执行用；
            // 时长读设置页档位/自定义值，默认 400ms）
            if (longAction != ACTION_NONE) {
                currentLongPressAction = longAction
                // 键码随动作一并缓存：PTT 的 UP 只认发起会话的这一键（按住 A 键
                // 录音期间另一键的 UP 不得误停）
                currentLongPressKeyCode = event.keyCode
                longPressHandler.postDelayed(longPressRunnable, getLongPressDurationMs())
            }
            // longAction==none：不启动长按计时，按住不放无动作，UP 走调音量路径
            println("🔑 [Accessibility] 按键按下(已拦截): keyCode=${event.keyCode}, longAction=$longAction, doubleAction=$doubleAction")
            return true
        } else if (event.action == KeyEvent.ACTION_UP) {
            // 取消长按计时
            longPressHandler.removeCallbacks(longPressRunnable)
            currentLongPressAction = null
            val wasLongPress = isLongPressTriggered
            val wasPttKeyCode = currentLongPressKeyCode == keyCode
            currentLongPressKeyCode = 0
            isLongPressTriggered = false

            if (wasLongPress) {
                // 按住说话（ptt_record）：长按阈值已开录的会话在本键 UP 时停录转写
                // ——PTT 与 toggle 制的全部差异就在这一行；键码校验防按住 A 键录音
                // 时另一键的 UP 误停。非 PTT 长按维持原语义（松手不追发动作）
                if (pttHoldActive && wasPttKeyCode) {
                    stopPttHold()
                }
                println("🔑 [Accessibility] 按键抬起: 长按已处理")
                return true // 长按已处理，不进双击
            }

            val now = System.currentTimeMillis()
            val timeSinceLastClick = now - lastClickTime

            // 录音中与非录音态走同一套单击/双击状态机（2026-09-15 移除旧的
            // 「录音中不进双击检测、单击立即调音量」短路——双击 quick_record 开始的
            // 录音无法再双击停止，用户真机踩中：第二次双击被当成两次单击调音量，
            // 弹出的媒体静音条被误认为「按音量加变静音」）。现在录音中双击 = 槽位
            // 动作 toggle 停录，代价仅是录音中单击调音量延迟 300ms 等双击窗口超时；
            // keep_muted 标记在 adjustVolume 内部随超时路径照常执行，语义不变。
            // 注意双击确认走 executeGestureAction 不经过 adjustVolume，录音中双击
            // 音量减不会误标 keep_muted（旧短路版会）。录音中长按仍由 500ms
            // longPressRunnable 触发（上方 wasLongPress 短路只拦 UP 不拦 runnable），
            // quick_record / overlay_record 长按 toggle 停录语义不受影响
            if (doubleAction != ACTION_NONE) {
                if (timeSinceLastClick < DOUBLE_CLICK_THRESHOLD_MS && lastClickKeyCode == event.keyCode) {
                    // 双击确认
                    lastClickTime = 0L
                    lastClickKeyCode = 0
                    executeGestureAction(doubleAction, "双击")
                } else {
                    // 第一次点击或超时 → 延迟确认不是双击后再执行单击语义
                    lastClickTime = now
                    lastClickKeyCode = event.keyCode

                    pendingSingleClick = Runnable {
                        // 执行时实时判定（而非排定单击时）：开关/录音状态在 300ms
                        // 窗口内可能变化（说完自动停等），非录音中回落调音量——
                        // 与「每次按键实时读落盘」的惯例一致
                        if (isSingleClickStopEnabled() && isRecordingActive()) {
                            stopActiveRecording()
                        } else {
                            adjustVolume(keyCode)
                        }
                        pendingSingleClick = null
                    }
                    singleClickHandler.postDelayed(pendingSingleClick!!, DOUBLE_CLICK_THRESHOLD_MS)
                }
            } else {
                // 双击槽=无动作：无需等双击窗口，立即执行（本次重构的体验优化）——
                // 录音中+单击结束开 → 立即停录；否则立即调音量
                if (isSingleClickStopEnabled() && isRecordingActive()) {
                    stopActiveRecording()
                } else {
                    adjustVolume(event.keyCode)
                }
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
        // 交互态走原路径；非交互态（AOD/熄屏）走 adjustVolumeInDoze——实机曾出现调节请求
        // 被收下后静默丢弃（dumpsys audio 只记一行无 VOLUME_CHANGED 跟随），真凶是
        // HyperOS「媒体音量控制」权限为「仅在使用中允许」：熄屏态被判非使用中而拦截，
        // 改「始终允许」即愈（2026-09-20）；回退链保留作其他 ROM/权限受限时的兜底
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (powerManager.isInteractive) {
            audioManager.adjustVolume(direction, AudioManager.FLAG_SHOW_UI)
        } else {
            adjustVolumeInDoze(audioManager, direction)
        }
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
     * 非交互态（AOD/熄屏）下的音量调节回退链：
     * 1. adjustStreamVolume(STREAM_MUSIC)——显式流，绕开 USE_DEFAULT_STREAM_TYPE 解析；
     * 2. 仍无效 → setStreamVolume 显式写值 ±1。
     * 每步 getStreamVolume 回读判定是否生效，已生效就不再走下一级（避免连跳两级）。
     * 实机备注（2026-09-20）：权限「媒体音量控制=仅在使用中允许」时曾两路全被拦
     * （140 → 140 目标 139、调用不抛异常），改「始终允许」即愈，权限正常时第一级
     * 即生效；若两路仍未生效优先引导查该权限，勿再叠加代码兜底（曾加过第三级
     * 「点亮屏幕转交互态补调」，体验差且权限修正后无用，已移除）。
     * 整段 try/catch：任何异常只打日志，绝不能崩掉无障碍服务（服务崩溃会连带杀主进程）。
     */
    private fun adjustVolumeInDoze(audioManager: AudioManager, direction: Int) {
        try {
            val before = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
            audioManager.adjustStreamVolume(AudioManager.STREAM_MUSIC, direction, AudioManager.FLAG_SHOW_UI)
            val afterAdjust = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
            if (afterAdjust != before) {
                println("🎵 [Accessibility] DOZE 调音量: adjustStreamVolume 生效 $before → $afterAdjust")
                return
            }
            val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            val target = (before + if (direction == AudioManager.ADJUST_RAISE) 1 else -1).coerceIn(0, max)
            audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, target, AudioManager.FLAG_SHOW_UI)
            val afterSet = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
            if (afterSet != before) {
                println("🎵 [Accessibility] DOZE 调音量: setStreamVolume 回退生效 $before → $afterSet")
            } else {
                println("⚠️ [Accessibility] DOZE 调音量: 两路均未生效 (音量仍 $before)——检查系统设置里本 App 的「媒体音量控制」权限是否「始终允许」")
            }
        } catch (e: Exception) {
            println("⚠️ [Accessibility] DOZE 调音量失败: ${e.message}")
        }
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

    /**
     * 触觉反馈（Dart overlay 通道 "performHaptic" 用）：与主 App
     * MainActivity.performHaptic 同一张 type → VibrationEffect 映射表（含低版本
     * 回退时长：heavy/double 30ms，其余 15ms）。overlay engine 无 Activity 够不着
     * 主 App 通道（com.shengwuji.app/app 的 handler 在 MainActivity），服务内同参
     * 实现。首个使用方：悬浮窗语音速记停止按钮的 "heavy" 一档（对齐日记页
     * stopListening 的 _haptic('heavy')）
     */
    private fun performHaptic(type: String) {
        val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        if (!vibrator.hasVibrator()) return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // 调试日志：真机核对预定义触感档位（tick 应轻 / heavy 应重）——厂商 ROM
            // （如努比亚 MyOS）对 EFFECT_* 的波形实现可能非标，体感与标准档位不符时
            // 靠此日志区分「type 未到达」与「type 正确但设备映射非标」
            println(
                "🫧 [Accessibility] performHaptic: $type (SDK ${Build.VERSION.SDK_INT}, " +
                    "amplitudeControl=${vibrator.hasAmplitudeControl()})"
            )
            val effect = when (type) {
                "click" -> VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK)
                "heavy" -> VibrationEffect.createPredefined(VibrationEffect.EFFECT_HEAVY_CLICK)
                "double" -> VibrationEffect.createPredefined(VibrationEffect.EFFECT_DOUBLE_CLICK)
                "tick" -> VibrationEffect.createPredefined(VibrationEffect.EFFECT_TICK)
                else -> VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK)
            }
            vibrator.vibrate(effect)
        } else {
            // Android 7.x 及以下回退（与 MainActivity.performHaptic 一致）
            @Suppress("DEPRECATION")
            vibrator.vibrate(when (type) {
                "heavy" -> 30L
                "double" -> 30L
                else -> 15L
            })
        }
    }

    /**
     * 手势槽位动作分发：槽位动作的唯一执行入口。
     * 调用方：长按 runnable / 双击确认（本服务内部，source 分别传「长按」「双击」）+
     * ShortcutDispatchActivity（外部硬件快捷方式，如努比亚滑动键映射的静态快捷方式
     * overlay_record，不传 source 用默认值「外部快捷方式」）——
     * 外部入口与音量键手势走同一张分发表，Pro 门禁 / toggle 语义 / 麦克风互斥
     * 等约束只维护一份。必须在主线程调用。
     * source 只用于分发入口日志定位触发来源——trigger* 内部日志不再硬编码
     * 手势名（旧文案如「长按音量键触发快速录音」在双击触发时会误导排查）。
     */
    fun executeGestureAction(action: String, source: String = "外部快捷方式") {
        println("🎮 [Accessibility] 手势动作分发: action=$action, 来源=$source")
        when (action) {
            ACTION_QUICK_RECORD -> triggerQuickRecord()
            ACTION_QUICK_TEXT_NOTE -> triggerQuickTextNote()
            ACTION_SHOW_OVERLAY -> triggerShowOverlay()
            ACTION_OVERLAY_RECORD -> triggerVoiceMemoOverlay()
            ACTION_OVERLAY_NEW_NOTE -> triggerOverlayNewNote()
            ACTION_PTT_RECORD -> triggerPttVoiceMemo()
            else -> println("⚠️ [Accessibility] 未知手势动作: $action")
        }
    }

    /**
     * 「录音中单击结束录音」：停止当前进行中的录音，返回是否有录音被停止
     * （false = 无录音在场，调用方回落调音量路径）。
     * - 悬浮窗语音速记中 → 与 triggerVoiceMemoOverlay 的 toggle 停止分支同链路：
     *   tick 清脆震 + stopVoiceMemo + 3s 回执超时兜底（复位以 Dart 回执为准）
     * - 主 APP 录音中 → 复用 triggerQuickRecord（内部按 isRecording 分流出 tick
     *   停录震 + quick_record Intent，Flutter _handleQuickRecord 检测 isListening
     *   后 stopListening——与长按停录完全同一条链路）
     * 互斥约束：本函数只在 isSingleClickStopEnabled() 为 true 时被调用，而该开关
     * 与 keep_muted 静音标记互斥，停录路径不会误标 keep_muted
     */
    private fun stopActiveRecording(): Boolean {
        if (voiceMemoActive) {
            performHaptic("tick")
            overlayMethodChannel?.invokeMethod("stopVoiceMemo", null)
            scheduleVoiceMemoStopTimeout()
            println("✅ [Accessibility] 单击结束录音：请求停止语音速记")
            return true
        }
        if (isRecording()) {
            triggerQuickRecord()
            println("✅ [Accessibility] 单击结束录音：请求停止主 APP 录音")
            return true
        }
        return false
    }

    private fun triggerQuickRecord() {
        // 锁屏状态下先点亮屏幕（屏幕熄灭时才能在锁屏之上显示 Activity）
        wakeScreenIfLocked()

        // 震动分流（2026-09-17 用户拍板「开始嗡、停止清脆」）：本函数开始录音与
        // 「录音中双击/长按 toggle 停录」共用——按 is_recording 互斥桥分流：
        // 录音中 = 停录 → tick 清脆（悬浮窗 toggle 停止同款）；非录音中 = 开始
        // → 50,50 嗡（悬浮窗旧停止震同款 one-shot）。Dart 侧开始不再震
        // （lockedMode 分支已删），触感只此一下防重叠
        if (isRecording()) performHaptic("tick") else vibrateOneShot(50, 50)

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
        println("✅ [Accessibility] 快速录音 Intent 已发出")
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
        println("✅ [Accessibility] 文本笔记 Intent 已发出")
    }

    /**
     * 悬浮窗当前是否处于「贴边竖线」驻留态（自动隐藏后的瘦身边线）。
     *
     * 判定依据 = 窗口实际宽度（LayoutParams 真值随窗口自身走，无跨端状态
     * 需要同步——Dart 缩线时经 resizeOverlay 落到本宽度）：窗口宽 20dp
     * （overlay_constants.dart edgeLineWindowWidth，触摸缓冲区；视觉线仅
     * 4dp），把手 28dp / 语音胶囊 312dp /
     * 展开态 MATCH_PARENT 都不满足阈值。调用方：triggerShowOverlay 的
     * toggle 分流（线态长按音量键 = 重新展开而非隐藏）
     */
    private fun isOverlayInEdgeLineState(): Boolean {
        val view = overlayView ?: return false
        val params = view.layoutParams as? WindowManager.LayoutParams ?: return false
        if (params.width == WindowManager.LayoutParams.MATCH_PARENT) return false
        return params.width <= dpToPx(EDGE_LINE_WIDTH_THRESHOLD_DP)
    }

    private fun triggerShowOverlay() {
        // 锁屏状态下先点亮屏幕
        wakeScreenIfLocked()

        // toggle 判断必须在 showOverlay() 之前（showOverlay 开头会强制重建已存在的浮窗）。
        // 注意 pendingVoiceMemoReveal 条件：语音速记冷启动隐藏窗口（alpha=0 等 Dart 胶囊首帧
        // 揭示）期间 view 存在但用户不可见——此时触发"显示悬浮窗"预期是显示而非隐藏一个
        // 看不见的窗，走正常显示路径（showOverlay 开头会 hideOverlay 清掉隐藏窗再重建）
        if (overlayView != null && !pendingVoiceMemoReveal) {
            if (isOverlayInEdgeLineState()) {
                // 线态（自动隐藏后的贴边竖线驻留）→ 再长按 = 重新展开面板。
                // 竖线语义上是"隐藏后的驻留提示"，长按召唤 = 显示，而非 toggle 隐藏
                //（彻底移除入口仍在：展开态长按隐藏，或设置页关掉竖线开关）。
                // 不走 Pro 门禁：窗口已存在，本次只是把既有会话拉回前台，
                // "从无到有创建浮窗"的入口才拦（拦了会让竖线永远无法展开成死线）
                // 50,50 轻嗡（2026-09-17 用户拍板，与语音速记开始同款；原 100,70 偏重）
                vibrateOneShot(50, 50)
                notifyDartExpand()
                println("✅ [Accessibility] 贴边竖线态 → 重新展开悬浮窗")
                return
            }
            // 已显示 → 再长按 = 立即彻底隐藏（toggle 兜底，不用等自动隐藏）
            // 震动差异化：amplitude 60（显示分支 50,50——振幅差 10 体感接近，
            // 语义靠浮窗出现/消失的 UI 变化区分；避免与双击文本笔记 50-50-50 波形混淆）
            vibrateOneShot(50, 60)
            hideOverlay()
            println("✅ [Accessibility] 悬浮窗已隐藏")
            return
        }

        // Pro 门禁：只拦"从隐藏态启动"（上面的 toggle 隐藏分支已放行——未解锁用户必须关得掉已显示的浮窗）
        if (blockOverlayIfProLocked()) return

        // 震动反馈：50,50 轻嗡（2026-09-17 用户拍板，与语音速记开始同款；原
        // 100,70 强嗡偏重）。注意与下方 toggle 隐藏分支的 50,60 仅差振幅 10——
        // 体感接近，靠 UI 变化（浮窗出现 vs 消失）区分语义
        vibrateOneShot(50, 50)
        // 直连本服务的 TYPE_ACCESSIBILITY_OVERLAY 浮窗并自动展开面板。
        // （旧链路是 startActivity 拉主 App 再走 flutter_overlay_window 插件，
        //  在小米/HyperOS 上会被系统拦截，已废弃）
        val shown = showOverlay(autoExpand = true)
        println(if (shown) "✅ [Accessibility] 悬浮窗已显示(自动展开)"
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
     *   312×84 addView，alpha=0 + FLAG_NOT_TOUCHABLE，无 resize 无把手帧，等 Dart
     *   录音态首帧 voiceMemoUiReady 才揭示，把手像素物理上不可能出现）+ 通知 Dart 开始录音
     * - 录音中再长按 → 50ms 短震 + 通知 Dart 停止（转写在 Dart 侧做）
     * - 主 APP 正在录音 → 麦克风互斥，退回现有“显示浮窗”行为（不抢麦）
     */
    private fun triggerVoiceMemoOverlay() {
        if (voiceMemoActive) {
            // 录音中再长按 → toggle 停止（转写由 Dart 侧接管）
            // 震动（2026-09-17 用户拍板「开始嗡、停止清脆」）：tick 清脆（与快速
            // 录音 toggle 停录同款），替换旧 50,50 嗡（嗡挪给开始用）
            performHaptic("tick")
            // ⚠️ 不在此处置 voiceMemoActive=false：stopVoiceMemo 消息可能未被 Dart 消化
            // （handler 未注册时 invokeMethod 静默丢弃），先置 false 会让紧随其后的长按
            // 误触“开始新录音”。复位以 Dart 回执 voiceMemoStopped 为准，3s 超时强制清兜底
            overlayMethodChannel?.invokeMethod("stopVoiceMemo", null)
            scheduleVoiceMemoStopTimeout()
            println("✅ [Accessibility] 请求停止语音速记")
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
        // 震动（2026-09-17 用户拍板「开始嗡、停止清脆」）：50,50 one-shot 嗡
        // （即旧停止震那款，用户指定就用它做开始），与快速录音开始同款
        vibrateOneShot(50, 50)
        if (overlayView == null) {
            // 语音速记态：hidden=true 隐藏窗口——engine/FlutterView/channel 照常创建，
            // 窗口直接以胶囊尺寸（312×84，常量见 companion object，唯一真值在 Dart 侧
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
        println("✅ [Accessibility] 语音速记已启动（等待 Dart 开始录音）")
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
            // 把手在屏上的原地切换路径（false）维持立即发（Kotlin 侧非 pending 时收到也 no-op）。
            // ptt 负载：true = 按住说话会话，Dart 据此把停止提示切「松开音量键，停止并转写」
            //（普通语音速记恒 false——非 PTT 路径置位前 pttHoldActive 必为 false；旧版本
            // Dart 不识此 key 自动忽略）
            overlayMethodChannel?.invokeMethod(
                "startVoiceMemo",
                mapOf("hiddenReveal" to pendingVoiceMemoReveal, "ptt" to pttHoldActive)
            )
        } else {
            pendingVoiceMemoStart = true
            println("⏳ [Accessibility] Dart 未就绪，语音速记启动请求已挂起")
        }
    }

    /**
     * 按住说话（action=ptt_record，实验分支）：长按阈值到期开录，松开同一键停录。
     * 复用悬浮窗语音速记整条基础设施（隐藏窗直建 / pendingVoiceMemoStart 握手 /
     * 四级 watchdog / 3s stop 回执兜底），差异只有触发与收尾时机：
     * - 开录 = 长按阈值到期（与 overlay_record 同一时刻、同一入口 executeGestureAction），
     *   额外登记 PTT 会话（pttHoldActive/pttHoldKeyCode）
     * - 停录 = 本键 ACTION_UP → stopPttHold，而非下一次长按 toggle
     * 停录后端选悬浮窗语音速记而非主 APP 快捷录音：松手即停要求停录指令延迟低且
     * 不依赖 Activity 启动——quick_record 的 Intent 冷启动期间 is_recording 尚未落盘，
     * 快速松手的 toggle 停录会被 Flutter 侧当成「开始」反向误触
     */
    private fun triggerPttVoiceMemo() {
        if (voiceMemoActive) {
            // 会话已在场（外部快捷方式重入等边缘）：不开第二条录音，本键 UP 仍会走
            // stopPttHold 幂等收尾在场会话
            println("🎤 [Accessibility] 按住说话：语音速记已在场，忽略重复启动")
            return
        }
        // Pro 门禁：与悬浮窗语音速记同一闸（PTT 就是它的按住版，链路完全复用）
        if (blockOverlayIfProLocked()) return
        if (isRecording()) {
            // 主 APP 录音中 → 麦克风互斥不开录。与 overlay_record 的「退回显示浮窗」
            // 不同：松手即停的瞬时手势不该顺手改变浮窗可见性
            println("🎤 [Accessibility] 按住说话：主 APP 录音中，麦克风互斥不开录")
            return
        }
        // 锁屏状态下先点亮屏幕（与 triggerVoiceMemoOverlay 同款前置）
        wakeScreenIfLocked()
        vibrateOneShot(50, 50)
        if (overlayView == null) {
            // 与语音速记同款：hidden=true 隐藏窗口直建（胶囊尺寸 + alpha=0 +
            // FLAG_NOT_TOUCHABLE），Dart 录音态首帧 voiceMemoUiReady 才揭示
            val shown = showOverlay(autoExpand = false, hidden = true)
            if (!shown) {
                println("❌ [Accessibility] 按住说话：浮窗创建失败，放弃启动录音")
                return
            }
        }
        voiceMemoActive = true
        startVoiceMemoWatchdog()
        // 先登记会话再发启动消息：ptt 负载读 pttHoldActive（dartReady 握手补发
        // 场景同读此标志——用户若已松手，stopPttHold 会连挂起一起取消，不会补发）
        pttHoldActive = true
        pttHoldKeyCode = currentLongPressKeyCode
        notifyDartStartVoiceMemo()
        println("✅ [Accessibility] 按住说话已启动（keyCode=$pttHoldKeyCode，等待松手停录）")
    }

    /**
     * PTT 松手停录（本键 ACTION_UP，wasLongPress 分支内调用）。三路分流：
     * - 启动请求还挂着（冷启动 Dart 未就绪）→ 取消挂起启动并收掉未揭示的隐藏窗。
     *   不能照发 stopVoiceMemo：handler 未注册时 invokeMethod 静默丢弃，等 dartReady
     *   握手补发启动后录音会开始却没人停（挂起请求在 stopPttHold 前必须先撤）
     * - 会话已被别的路径收尾（单击停录 / voiceMemoFailed 回执 / watchdog）→ 幂等 no-op
     * - 正常路径 → tick 清脆震 + stopVoiceMemo + 3s 回执兜底；若 Dart 的 start await
     *   链还没跑完（stop 被非录音态守卫静默丢弃），voiceMemoStarted 回执到达时按
     *   pttReleasePending 补发一次
     */
    private fun stopPttHold() {
        pttHoldActive = false
        pttHoldKeyCode = 0
        if (pendingVoiceMemoStart) {
            pendingVoiceMemoStart = false
            voiceMemoActive = false
            cancelVoiceMemoWatchdog()
            hideOverlay()
            println("✅ [Accessibility] 按住说话：松手于 Dart 就绪前，已取消挂起的启动")
            return
        }
        if (!voiceMemoActive) {
            println("ℹ️ [Accessibility] 按住说话：会话已不在场，松手无需停录")
            return
        }
        pttReleasePending = true
        performHaptic("tick")
        overlayMethodChannel?.invokeMethod("stopVoiceMemo", null)
        scheduleVoiceMemoStopTimeout()
        println("✅ [Accessibility] 按住说话：松手，请求停止录音")
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
                // PTT 的待补发停录随会话一并作废（会话都不在场了，回执无从谈起）
                pttReleasePending = false
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
        // PTT 会话标志随 engine 一并清零（T4 销毁路径 / service 重建后不留陈旧会话态）
        pttHoldActive = false
        pttHoldKeyCode = 0
        pttReleasePending = false
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
     *               窗口直接以胶囊尺寸 312×84（VOICE_MEMO_OVERLAY_WIDTH_DP/HEIGHT_DP，唯一真值
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
                        // 触觉反馈（Dart → Kotlin）：悬浮窗 UI 的震动反馈走服务实现
                        // （overlay engine 无 Activity，够不着 MainActivity 的
                        // com.shengwuji.app/app 通道）。映射表见 performHaptic
                        "performHaptic" -> {
                            val type = call.argument<String>("type") ?: "heavy"
                            performHaptic(type)
                            result.success(true)
                        }
                        // 语音速记录音回执（Dart → Kotlin）：录音已真正开始 → 取消 stop 超时兜底（如有）
                        // + 设置浮窗常亮（锁屏下 wakeScreenIfLocked 只有 3s 点亮，之后 3-5s 自动
                        // 息屏会打断录音/转写；wakelock_plus 在 overlay engine 不可用，走窗口 flag）
                        "voiceMemoStarted" -> {
                            cancelVoiceMemoStopTimeout()
                            setOverlayKeepScreenOn()
                            if (pttReleasePending) {
                                // PTT 松手早于 Dart 开录完成：此前发的 stopVoiceMemo 落在
                                // start await 链中途，被 Dart stop() 的非录音态守卫静默
                                // no-op 丢弃；此刻录音已真正开始，补发停录（3s 回执超时
                                // 兜底照排——Dart 卡死时由超时强制复位）
                                pttReleasePending = false
                                overlayMethodChannel?.invokeMethod("stopVoiceMemo", null)
                                scheduleVoiceMemoStopTimeout()
                                println("✅ [Accessibility] 按住说话：开录回执晚于松手，补发停录")
                            }
                            println("✅ [Accessibility] Dart 回执：语音速记录音已开始")
                            result.success(true)
                        }
                        // 语音速记录音回执：录音已停止（进入转写）→ 复位 toggle 状态 + 撤 watchdog
                        "voiceMemoStopped" -> {
                            voiceMemoActive = false
                            pttReleasePending = false
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
                            pttReleasePending = false
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
                        // ── 把手长按拖动（收起态位置调整，2026-09-09）──
                        // 手势识别全在 Dart（OverlayHandle 长按 + 纵向位移），原生只负责
                        // 移窗与落盘。窗口跟手移动后手指始终留在 28×88 窗口内，后续
                        // move 事件不丢——这是「Dart 发位移、原生挪窗」方案成立的前提
                        // 拖动开始：缓存当前窗口 y 作基线（dragHandle 的目标位置 = 基线 + 累计位移）
                        "beginHandleDrag" -> {
                            (overlayView?.layoutParams as? WindowManager.LayoutParams)?.let {
                                handleDragBaseY = it.y
                            }
                            println("👆 [Accessibility] 把手拖动开始，基线 y=${handleDragBaseY}px")
                            result.success(true)
                        }
                        // 拖动更新：dy = 自按下原点的纵向累计位移（dp，向下为正）。换算
                        // 目标 y 并 clamp 到屏幕内再 updateViewLayout。仅把手尺寸窗口生效：
                        // 拖动中旬被打断进语音胶囊（窗口已 resize 成 312×84）时，Dart 侧
                        // 组件尚未随帧移除、在途的拖动消息不得挪动胶囊（胶囊恒居中）
                        "dragHandle" -> {
                            val view = overlayView
                            val wm = overlayWindowManager
                            if (view != null && wm != null) {
                                val params = view.layoutParams as WindowManager.LayoutParams
                                if (params.width == dpToPx(HANDLE_WIDTH_DP)) {
                                    val dyDp = call.argument<Double>("dy") ?: 0.0
                                    val maxAbsY =
                                        (resources.displayMetrics.heightPixels - params.height) / 2
                                    params.y = (handleDragBaseY + dpToPx(dyDp))
                                        .coerceIn(-maxAbsY, maxAbsY)
                                    wm.updateViewLayout(view, params)
                                }
                            }
                            result.success(true)
                        }
                        // 拖动结束：当前位置折算成 dp 落盘（round 保亚像素精度），下次
                        // 建窗恢复。同样仅把手尺寸窗口生效——打断进胶囊路径的残留收尾
                        // 不得把胶囊的居中位置（y=0）覆盖进拖存档，丢掉用户拖的位置
                        "endHandleDrag" -> {
                            val view = overlayView
                            if (view != null) {
                                val params = view.layoutParams as WindowManager.LayoutParams
                                if (params.width == dpToPx(HANDLE_WIDTH_DP)) {
                                    val offsetDp = Math.round(params.y / resources.displayMetrics.density)
                                    getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                                        .edit()
                                        .putInt(HANDLE_Y_OFFSET_KEY, offsetDp)
                                        .apply()
                                    println("👆 [Accessibility] 把手位置已保存: ${offsetDp}dp (y=${params.y}px)")
                                }
                            }
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
                        // ── 悬浮窗 header「打开随手记」按钮（OverlayHome._openDiaryPage，2026-09-13）──
                        // 拉起主 App 并路由到日记页（底部导航索引 2）。launcher intent
                        // 带 type=open_diary extra，MainActivity.extractShortcutType
                        // 路由到 Dart onShortcutLaunch 切 tab——与上方 requestCalendarPermission
                        // 的 grant_calendar 同一条跨 engine 路由链。Dart 侧调用前已收起
                        // 面板并等缩窗链路走完（防全屏窗口吞触摸挡住主 App 首屏）。
                        // getLaunchIntentForPackage 取当前 enabled 的 launcher component
                        //（图标包切换后 alias 路由，同该先例的说明）；失败 Toast + false
                        "openDiaryPage" -> {
                            val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                putExtra("type", "open_diary")
                            }
                            if (launch != null) {
                                startActivity(launch)
                                println("📖 [Accessibility] 已拉起主 App 日记页")
                            } else {
                                Toast.makeText(
                                    this@VolumeKeyAccessibilityService,
                                    "未能打开随手记，请重试",
                                    Toast.LENGTH_SHORT
                                ).show()
                                println("❌ [Accessibility] 拉起主 App 失败（getLaunchIntentForPackage null）")
                            }
                            result.success(launch != null)
                        }
                        // 悬浮窗闹钟确认后写日历：与主 App 日记页共用 CalendarEventHelper
                        // （逻辑同 MainActivity 原实现，Service 上下文直接可用）。
                        // 成功/失败反馈走原生 Toast（悬浮窗小窗口不适合 SnackBar），
                        // 文案按结果码区分（"no_calendar_account" = 手机上没有
                        // 日历账户，常见于系统日历 app 被卸载/停用，如摩托罗拉）
                        "addCalendarEvent" -> {
                            val timestamp = call.argument<Long>("timestamp") ?: 0L
                            val title = call.argument<String>("title") ?: "提醒"
                            val enableAlarm = call.argument<Boolean>("enableAlarm") ?: true
                            val code = if (!CalendarEventHelper.hasCalendarPermission(this@VolumeKeyAccessibilityService)) {
                                Toast.makeText(this@VolumeKeyAccessibilityService, "日历权限未授予，添加失败", Toast.LENGTH_LONG).show()
                                println("❌ [Accessibility] 写日历中止：日历权限未授予")
                                CalendarEventHelper.RESULT_PERMISSION_DENIED
                            } else {
                                val code = CalendarEventHelper.addCalendarEvent(
                                    this@VolumeKeyAccessibilityService, timestamp, title, enableAlarm
                                )
                                Toast.makeText(
                                    this@VolumeKeyAccessibilityService,
                                    when (code) {
                                        CalendarEventHelper.RESULT_OK ->
                                            if (enableAlarm) "已添加到系统日历，到点响铃提醒" else "已添加到系统日历（无响铃）"
                                        CalendarEventHelper.RESULT_NO_CALENDAR_ACCOUNT ->
                                            "手机上没有可用的日历，请检查系统日历应用是否被卸载或停用"
                                        CalendarEventHelper.RESULT_PERMISSION_DENIED ->
                                            "日历权限未授予，添加失败"
                                        else -> "添加日历事件失败"
                                    },
                                    Toast.LENGTH_SHORT
                                ).show()
                                code
                            }
                            result.success(code)
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
                                // hiddenReveal / ptt 负载语义同 notifyDartStartVoiceMemo
                                //（补发时 pendingVoiceMemoReveal 仍有效；PTT 会话未松手
                                // 才可能走到补发——松手路径连挂起一并取消了，ptt 负载
                                // 读 pttHoldActive 即当时真值）
                                overlayMethodChannel?.invokeMethod(
                                    "startVoiceMemo",
                                    mapOf("hiddenReveal" to pendingVoiceMemoReveal, "ptt" to pttHoldActive)
                                )
                            }
                            // 挂起的新增笔记请求同样补发（与 pendingAutoExpand 同一握手机制）
                            if (pendingNewNote) {
                                pendingNewNote = false
                                overlayMethodChannel?.invokeMethod("newNote", null)
                            }
                            // 挂起的 Pro 提示渲染请求同样补发（与 pendingAutoExpand 同一握手机制）
                            if (pendingProHint) {
                                pendingProHint = false
                                overlayMethodChannel?.invokeMethod("showProLockedHint", null)
                            }
                            result.success(true)
                        }
                        "voiceMemoUiReady" -> {
                            // Dart 首帧已构建（postFrameCallback 后发出）——此刻揭示窗口，
                            // 保证用户看到的第一个画面就是正确尺寸胶囊而非把手。
                            // 通用揭示：语音速记胶囊与 Pro 未解锁提示胶囊共用本消息
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
                                                // Pro 提示窗保持 FLAG_NOT_TOUCHABLE：纯展示无交互，
                                                // 3 秒在场期间不得挡住下层应用的这块区域
                                                if (!proHintActive) {
                                                    params.flags = params.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
                                                }
                                                overlayWindowManager?.updateViewLayout(view, params)
                                            }
                                            println(if (proHintActive) {
                                                "🔒 [Accessibility] Pro 提示窗已揭示（提示胶囊首帧就绪）"
                                            } else {
                                                "🎤 [Accessibility] 语音速记窗口已揭示（胶囊首帧就绪）"
                                            })
                                        }
                                    }
                                }
                            }
                            result.success(null)
                        }
                        // ── 笔记锁定：悬浮窗点锁定卡片发起系统认证（2026-09-22）──
                        // 由 NoteUnlockCoordinator 拉起透明认证 Activity：锁屏中走
                        // requestDismissKeyguard（系统解锁界面），未锁屏弹
                        // BiometricPrompt（指纹/面部优先、锁屏密码兜底）。
                        // 结果异步经 notifyNoteUnlockResult 回发，此处不等待。
                        // 指纹弹窗（系统窗口）层级低于本悬浮窗会被面板挡住，
                        // 拉起前先整体降透明让位（见 OVERLAY_AUTH_DIM_ALPHA）；
                        // 拉起失败立即恢复，成功则等结果回发时恢复
                        "requestUnlockAuth" -> {
                            setOverlayDimForAuth(true)
                            val ok = NoteUnlockCoordinator.launch(
                                this@VolumeKeyAccessibilityService,
                                fromOverlay = true
                            )
                            if (!ok) setOverlayDimForAuth(false)
                            result.success(ok)
                        }
                        else -> result.notImplemented()
                    }
                }
            }

            if (hidden) {
                // 隐藏窗口（语音速记冷启动路径）：照常住流程立即 addView（engine 渲染期间
                // FlutterView 必须 attach 到窗口，否则 AccessibilityBridge NPE → SIGABRT），
                // 但窗口直接以胶囊尺寸 312×84 创建 + alpha=0 + FLAG_NOT_TOUCHABLE——
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
        // Pro 提示窗收窗复位：所有移窗路径必经此处（用户 toggle 关掉提示 /
        // proHintDismissRunnable 超时收窗 / destroy），在这里清标志 + 撤收窗计时，
        // 保证 proHintActive 不残留（残留会让下一次按键误走"提示已在场"分支）
        if (proHintActive) {
            proHintActive = false
            proHintHandler.removeCallbacks(proHintDismissRunnable)
        }
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
            // 展开铺满全屏宽度：停靠侧透明空白区手势关闭由 Dart 侧绘制，
            // 面板宽度比例的唯一真值是 Dart 侧 OverlayConstants.expandedWidthRatio
            params.width = WindowManager.LayoutParams.MATCH_PARENT
        } else {
            params.width = dpToPx(width)
        }
        if (height == -1) {
            // 展开铺满全屏高度
            params.height = WindowManager.LayoutParams.MATCH_PARENT
            // 铺满全屏时只保留停靠侧水平分量（MATCH_PARENT 下位置无差，随侧
            // 一致设置保持语义统一）
            params.gravity = horizontalEdgeGravity()
            // y 一并归零：FLAG_LAYOUT_NO_LIMITS 下全屏窗口也会被残留的 y 推离
            // 屏幕（把手拖到上方后 y<0，展开的笔记面板整体上移、底部露空）——
            // 面板铺满全屏，位置恒定不随把手走；收起回把手时由 else 分支从
            // prefs 恢复拖存位置
            params.y = 0
        } else {
            params.height = dpToPx(height)
            // 收起/把手态：88dp 把手必须垂直居中，否则顶到屏幕顶端；水平分量
            // 按停靠侧设置（右缘 END / 左缘 START）
            params.gravity = Gravity.CENTER_VERTICAL or horizontalEdgeGravity()
            // 纵向位置分流（2026-09-11 用户真机反馈定夺）：语音胶囊窗口始终垂直
            // 居中（不跟随把手拖动位置）；把手/贴边竖线恢复拖存位置——从 prefs
            // 取而非沿用 params.y 现值，因为语音胶囊会话刚把 y 归零，收起回把手
            // 要从这里取回原位置
            params.y = if (width == VOICE_MEMO_OVERLAY_WIDTH_DP && height == VOICE_MEMO_OVERLAY_HEIGHT_DP) {
                0
            } else {
                handleYOffsetPxClamped(params.height)
            }
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
     * （宽高均 -1 时 gravity 只留停靠侧水平分量；否则停靠缘垂直居中——88dp 把手/64dp 语音胶囊都必须垂直居中，
     * 并恢复用户拖存的纵向偏移，见 HANDLE_Y_OFFSET_KEY）。
     * hidden=true（语音速记冷启动隐藏窗口）：直建胶囊尺寸 312×84 + alpha=0 不可见 +
     * FLAG_NOT_TOUCHABLE 不挡触摸，等 Dart 录音态首帧 voiceMemoUiReady 到达再 alpha=1 揭示
     * （清 NOT_TOUCHABLE）——无 resize 无把手帧，把手像素物理上不可能出现。
     * 使用方：showOverlay 立即 addView（非隐藏=28x88 把手起步；隐藏=直建 312x84 胶囊尺寸） */
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
        params.gravity = if (heightDp == -1) horizontalEdgeGravity()
                         else Gravity.CENTER_VERTICAL or horizontalEdgeGravity()
        // 非全屏态设置纵向位置：语音胶囊直建窗口（隐藏路径 312×84）始终垂直居中；
        // 把手窗口恢复用户拖过的位置（dp 偏移，相对垂直中心，向下为正）。
        // 未拖过/读取失败 = 0 = 垂直居中（旧行为）。全屏态 y 无语义不设
        if (heightDp != -1) {
            params.y = if (widthDp == VOICE_MEMO_OVERLAY_WIDTH_DP && heightDp == VOICE_MEMO_OVERLAY_HEIGHT_DP) {
                0
            } else {
                handleYOffsetPxClamped(dpToPx(heightDp))
            }
        }
        if (hidden) params.alpha = 0f
        return params
    }

    /**
     * 悬浮窗水平停靠侧的重力分量：右缘 END（缺省，历史行为）/ 左缘 START。
     * 读取 [OVERLAY_SIDE_LEFT_KEY]（Flutter SharedPreferences 落盘，写入方
     * settings_tab 的「停靠侧」选择器），每次建窗/resize 实时读——无缓存即
     * 无跨端状态同步，设置切换后下一次状态转换窗口即落新侧（Dart 侧镜像由
     * OverlayHome._refreshSide 同 key 刷新）
     */
    private fun horizontalEdgeGravity(): Int {
        val left = try {
            getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .getBoolean(OVERLAY_SIDE_LEFT_KEY, false)
        } catch (e: Exception) {
            println("⚠️ [Accessibility] 读取停靠侧失败，按右缘兜底: ${e.message}")
            false
        }
        return if (left) Gravity.START else Gravity.END
    }

    /**
     * 读取把手拖存的纵向偏移（dp → px）并 clamp 到「窗口完整留在屏内」。
     * 旋转等屏高变化后拖存值可能超界，凡设 y 处（buildOverlayParams /
     * resizeOverlay）统一走本函数兜底
     */
    private fun handleYOffsetPxClamped(winHeightPx: Int): Int {
        val savedDp = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getInt(HANDLE_Y_OFFSET_KEY, 0)
        val maxAbsY = (resources.displayMetrics.heightPixels - winHeightPx) / 2
        return dpToPx(savedDp).coerceIn(-maxAbsY, maxAbsY)
    }

    private fun dpToPx(dp: Int): Int {
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            dp.toFloat(),
            resources.displayMetrics
        ).toInt()
    }

    // 小数 dp 版（dragHandle 的位移是 Dart 逻辑像素 = dp，逐帧换算取整即可）
    private fun dpToPx(dp: Double): Int {
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            dp.toFloat(),
            resources.displayMetrics
        ).roundToInt()
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        // 三星等 ROM 可能忽略 XML 中的 flagRequestFilterKeyEvents，需代码中再次请求
        serviceInfo = serviceInfo.apply {
            flags = flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_REQUEST_FILTER_KEY_EVENTS
        }
        // 锁屏即重锁（笔记锁定功能）+ 息屏隐藏悬浮窗：注册在服务生命周期内
        // （onDestroy 注销），幂等防服务重建重复注册。SCREEN_OFF/SCREEN_ON 都是
        // 受保护系统广播，仅系统可发，registerReceiver 无需 export flag
        if (screenOffReceiver == null) {
            screenOffReceiver = object : android.content.BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    when (intent?.action) {
                        Intent.ACTION_SCREEN_OFF -> {
                            try {
                                getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                                    .edit()
                                    .putLong(NOTE_UNLOCK_UNTIL_KEY, 0L)
                                    .apply()
                                println("🔒 [Accessibility] 屏幕熄灭，笔记解锁会话已清零（锁屏即重锁）")
                            } catch (e: Exception) {
                                println("⚠️ [Accessibility] 清笔记解锁会话失败: ${e.message}")
                            }
                            // 通知悬浮窗 Dart 收起/打码已展开的锁定卡片（dartReady=false
                            // 时丢弃无害——engine 刚建时列表尚未渲染锁定明文）
                            if (dartReady) {
                                overlayMethodChannel?.invokeMethod("relockNotes", null)
                            }
                            // 息屏隐藏：AOD 息屏时钟上不再显示把手/贴边竖线/录音胶囊
                            setOverlayGoneForScreen(true)
                            // 息屏推进（2026-09-22 用户拍板「进 AOD 必须收、亮屏/解锁
                            // 不得复活把手/面板」）：通知 Dart 立即收起到驻留终态——
                            // 竖线开关开 → 缩成贴边竖线（亮屏后恢复的只有竖线），
                            // 关 → closeOverlay 彻底移除。必须在 GONE 之后发：黑屏
                            // 期间 Dart 跳终态/缩窗，用户看不见任何过程。
                            // Pro 提示窗不推进（3 秒自收窗，与把手/面板生命周期无关）；
                            // dartReady=false（engine 冷启动中）丢弃无害，下轮息屏再推进
                            if (dartReady && !proHintActive) {
                                overlayMethodChannel?.invokeMethod("screenAutoHide", null)
                            }
                        }
                        Intent.ACTION_SCREEN_ON -> setOverlayGoneForScreen(false)
                    }
                }
            }
            registerReceiver(screenOffReceiver, IntentFilter(Intent.ACTION_SCREEN_OFF).apply {
                addAction(Intent.ACTION_SCREEN_ON)
            })
        }
        println("✅ [Accessibility] 无障碍服务已连接，按键过滤已启用")
    }

    /**
     * 通知悬浮窗 Dart 笔记认证结果（NoteUnlockCoordinator 完成后调用）。
     * 必须先恢复认证让位的透明度再回发——Dart 收到结果后会立刻 setState
     * 展开卡片/解除锁定，窗口必须已可见。dartReady=false（engine 冷启动中）
     * 时丢弃事件——认证由用户主动发起，Dart 未就绪意味着面板都没渲染，
     * 结果无人消费
     */
    fun notifyNoteUnlockResult(success: Boolean) {
        setOverlayDimForAuth(false)
        if (dartReady) {
            overlayMethodChannel?.invokeMethod("noteUnlockResult", mapOf("success" to success))
        }
        println("🔒 [Accessibility] 笔记认证结果已通知悬浮窗: success=$success")
    }

    /**
     * 认证让位：悬浮窗窗口整体透明度切换（true=降到近透明让出指纹弹窗，
     * false=恢复不透明）。幂等；窗口已移除（overlayView 空跳过）时无需处理
     * ——下次 showOverlay 重建窗口 alpha 恒 1，不会残留降透明态
     */
    private fun setOverlayDimForAuth(dim: Boolean) {
        val view = overlayView ?: return
        val wm = overlayWindowManager ?: return
        // 防御：恢复分支撞上语音速记隐藏窗的揭示期（alpha=0 等首帧揭示）时
        // 跳过——揭示机制自己会置 1，提前恢复成 1 会让未渲染的把手帧闪现。
        // 时序上正常到不了这里（dim 只在面板态发起，录音态无卡片可点），纯兜底
        if (!dim && pendingVoiceMemoReveal) return
        try {
            val params = view.layoutParams as WindowManager.LayoutParams
            val target = if (dim) OVERLAY_AUTH_DIM_ALPHA else 1f
            if (params.alpha == target) return
            params.alpha = target
            wm.updateViewLayout(view, params)
            println(if (dim) "🔒 [Accessibility] 认证让位：悬浮窗已降透明 (${OVERLAY_AUTH_DIM_ALPHA})"
                    else "🔒 [Accessibility] 认证结束：悬浮窗透明度已恢复")
        } catch (e: Exception) {
            println("⚠️ [Accessibility] 悬浮窗透明度切换失败: ${e.message}")
        }
    }

    /**
     * 息屏隐藏 / 亮屏恢复悬浮窗（2026-09-22 用户反馈：录完音不管它，息屏后把手/
     * 贴边竖线跟着 AOD 息屏时钟一直杵在息屏画面上）。
     *
     * 用 visibility=GONE 而非 hideOverlay() 移窗：窗口 token、Dart engine、录音/
     * 转写链路、自动隐藏计时全部原样保留；hideOverlay 会发 reset 复位 Dart 并
     * 打断这套状态，代价不成比例。正常路径下 SCREEN_OFF 同时发 screenAutoHide
     * 让 Dart 收起到驻留终态（竖线/移除），故亮屏恢复 VISIBLE 看到的只是竖线
     * （或录音中的胶囊——该场景 screenAutoHide 被守卫跳过，活动会话不掐 UI），
     * 把手/面板不会复活。
     *
     * 与 alpha（隐藏窗揭示期 0 / 认证让位 0.15）是两个正交维度：恢复 VISIBLE
     * 不会泄露 alpha=0 的未揭示窗口。onReceive 在主线程（无参 registerReceiver
     * 默认主线程），直接动 view 属性无线程问题。幂等；窗口已移除（overlayView
     * 空 = 悬浮窗本就彻底隐藏）时 no-op。
     */
    private fun setOverlayGoneForScreen(gone: Boolean) {
        val view = overlayView ?: return
        if (gone) {
            view.visibility = View.GONE
            overlayHiddenByScreenOff = true
            println("🌙 [Accessibility] 屏幕熄灭，悬浮窗已隐藏（亮屏恢复）")
        } else if (overlayHiddenByScreenOff) {
            view.visibility = View.VISIBLE
            overlayHiddenByScreenOff = false
            // GONE 期间 FlutterView 的窗口可见性回调可能把 engine lifecycle 带进
            // paused（停止出帧）——同 getOrCreateOverlayEngine 复用分支的手动
            // appIsResumed 兜底，防「窗口回来了画面冻结在最后一帧」
            FlutterEngineCache.getInstance().get(OVERLAY_ENGINE_CACHE_KEY)
                ?.lifecycleChannel?.appIsResumed()
            println("☀️ [Accessibility] 屏幕点亮，悬浮窗已恢复显示")
        }
    }

    override fun onDestroy() {
        // 清理语音速记 stop 超时计时，避免 Runnable 在 service 销毁后仍持有引用 3 秒
        cancelVoiceMemoStopTimeout()
        // 同理撤四级 watchdog（最长 76s，比 stop 超时更不能泄漏到已销毁的 service 实例上）
        cancelVoiceMemoWatchdog()
        // 撤销锁屏重锁广播（与 onServiceConnected 注册配对）
        screenOffReceiver?.let {
            try {
                unregisterReceiver(it)
            } catch (e: Exception) {
                println("⚠️ [Accessibility] 注销 SCREEN_OFF receiver 失败（服务已销毁？）: ${e.message}")
            }
            screenOffReceiver = null
        }
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
