# 音量键快捷操作

> 2026-08-29 重构：从"监听哪些音量键"的两开关模型改为 **4 手势槽位 × 6 动作** 的统一矩阵（提交 `4c64d57` 契约+单测 / `a7a6b6e` Kotlin 重构 / `0d0a8cb` 设置页 UI；第 6 动作 `overlay_new_note` 后补）。本文档以新架构为准。
>
> **⚠️ 实验分支（2026-09-21）**：本分支新增第 7 动作 `ptt_record`「按住说话」（长按槽位专属，松手停录），见下方「按住说话（ptt_record）」小节。合回主干前本文档按实验状态描述。

## 概述

通过 Android 无障碍服务（AccessibilityService）拦截音量键事件。每个音量键的长按、双击各是一个独立"手势槽位"，共 4 个槽位，每个槽位可绑定 6 种动作之一。

### 手势槽位 × 动作矩阵

**4 个槽位**（SharedPreferences key，Dart 侧常量 `VolumeGestureSlot.*`；Kotlin 读取时加 `flutter.` 前缀）：

| 槽位 | prefs key | 出厂默认 |
| --- | --- | --- |
| 长按音量上键（阈值可调，默认 400ms） | `volume_gesture_long_press_up` | `none` |
| 长按音量下键（阈值可调，默认 400ms） | `volume_gesture_long_press_down` | `quick_record` |
| 双击音量上键（300ms 窗口） | `volume_gesture_double_click_up` | `none` |
| 双击音量下键（300ms 窗口） | `volume_gesture_double_click_down` | `quick_text_note` |

> 长按触发阈值见下方「长按触发阈值（预设档 + 自定义）」；双击窗口仍为固定 300ms 硬编码。

**6 种动作**（字符串常量，Dart `VolumeGestureAction.*` 与 Kotlin `ACTION_*` 严格一致）：

| 动作值 | 含义 |
| --- | --- |
| `none` | 无动作（槽位关闭，该手势不拦截） |
| `show_overlay` | 显示悬浮窗（toggle：显示中再触发则立即隐藏）**〔Pro〕** |
| `overlay_record` | 悬浮窗语音速记（toggle 状态机，详见 @floating-window.md）**〔Pro〕** |
| `overlay_new_note` | 悬浮窗新增笔记（浮窗未显示则先建，通知 Dart 新增空白笔记进编辑态；不做 toggle 隐藏，重复触发 = 再新增一条）**〔Pro〕** |
| `quick_record` | 快速进入 APP 录音（Flutter 侧 toggle：录音中再触发则停录） |
| `quick_text_note` | 快速进入 APP 新建文本笔记 |
| `ptt_record` | 按住说话（长按槽位专属，实验分支：按住达阈值开录、松开同一键停录转写，见下方专节）**〔Pro〕** |

> **Pro 门禁（2026-09-03；2026-09-19 反馈升级）**：悬浮窗系动作（`show_overlay` / `overlay_record` / `overlay_new_note`）为 Pro 付费功能。不可用（未解锁且试用过期）时：① 设置页手势选择器的对应 chip 标 Pro 徽章且点击弹付费弹窗（不写 prefs）；② Kotlin 侧执行动作前读落盘 `flutter.is_pro_unlocked` / `flutter.pro_trial_deadline_ms` 拦截——在原录音胶囊位置弹「暂未解锁，无法使用」提示胶囊 3 秒（旧 Toast 已替换），但**放行 toggle 分支**——已显示的浮窗/进行中的录音，未解锁用户必须关得掉、停得掉。详见 @floating-window.md 的"Pro 门禁"小节与 @pro-license.md。

出厂默认对齐重构前旧版的默认行为（音量减键长按录音 + 双击笔记、音量加键不监听）。

### 长按触发阈值（预设档 + 自定义，2026-09-19；2026-09-21 档位下调；2026-09-23 自定义档）

两个「长按」槽位共用一个触发阈值，设置页「音量键快捷操作」ChoiceChip 选预设档（很快 200 / 快 300 / 标准 400 / 慢 700ms，默认 400ms）或「自定义」档——点自定义 chip 弹输入对话框，输入 [50, 2000]ms 内任意整数，确认按钮在输入合法前禁用（「选中自定义就必须有值」由构造保证，不存在「选中了但没值」的落盘中间态），取消/清空不改任何状态；再点已选中的自定义 chip 重新打开对话框微调（预填当前值），输入值恰为某预设时 UI 归位到该预设 chip。2026-09-21 按用户实测反馈整体下调（原快 400 / 标准 500 / 慢 800 / 很慢 1200、默认 500=1.1.0~1.2.0 的历史硬编码值——旧最短档 400 体感仍偏钝，重度使用者宁愿改用双击）；2026-09-23 应「最短 200 仍太长」的用户反馈加自定义档。

- **prefs key**：`volume_long_press_ms`（⚠️ 落盘类型 **Long**——Flutter `setInt` 在 Android 端即走 `putLong`（Dart int 64 位），Kotlin 必须 `getLong` 读，`getInt` 会 ClassCastException 崩服务进程，2026-09-19 真机炸过；同 `pro_trial_deadline_ms` 先例；读取加 `flutter.` 前缀）。Dart 写入方为二级页 `volume_key_settings_page.dart` 的 `_saveLongPressMs`（唯一写入方，自定义值走同一 key），Kotlin `getLongPressDurationMs()` 每次 `ACTION_DOWN` 实时读落盘——与手势槽位动作同模式，无 MethodChannel、App 未打开也生效
- **校验双侧同规则（2026-09-23 起范围取代集合）**：[50, 2000] 闭区间内的值（含预设档与自定义档）原样生效，缺失/脏值/越界回落 400。此前校验是「预设集合白名单，不在集合内回落 400」（旧默认 500 就近迁移）；放开自定义后范围成为合法域，旧档位 500/800/1200 都落在范围内，老用户升级后按原值继续生效（设置页显示为「自定义」档——刻意选择：尊重其当年显式选的档位，不再二次改写）。范围边界是跨端硬编码副本（Dart `VolumeLongPressMs.minMs/maxMs` ↔ Kotlin `LONG_PRESS_MS_MIN/MAX`），改边界必须双侧同步；预设集合（`VolumeLongPressMs.choices`）只剩 Dart 侧 chip 展示用途，Kotlin 已不引用
- **超短阈值的代价（值 < ~100ms 时选择器下显警示文案）**：刻意单击的按压时长约 100~300ms，阈值低于它后不再只是「可能误判偏重单击」（200 档的权衡，副文案保留），而是每次按下都先到长按阈值、UP 被 `wasLongPress` 短路——该键上的**单击调音量、同键双击手势、按音量减保持静音（`keep_muted` 只在 `adjustVolume` 内标记）以及「单击键结束录音」的单击路径全部失效**；按住说话（ptt_record）反而是受益者（按住即录，松手即停不受影响）。这些失效都是「手势被挤掉」而非「误触发危险动作」，无需自动关任何开关，文案说清即可
- **与单击/双击的结构关系**：三者时钟互相独立（长按计 DOWN 持续时长、双击计两次 UP 间隔、单击是双击窗口超时兜底），`wasLongPress` 短路保证长按后的 UP 不进双击序列——状态机本身任何档位下均无冲突；但阈值低于单击时长时该键实际上只剩长按一个手势可达（见上条）

### 录音中单击结束录音（与保持静音互斥，2026-09-19）

设置页「录音静音」卡片的开关（`single_click_stop_recording`，默认关）：开启后**录音中**（主 APP 录音或悬浮窗语音速记）单击音量键立即停录并转写，无需再长按 toggle。

- **prefs key**：`single_click_stop_recording`（Bool；Dart 常量 `kSingleClickStopRecordingKey`，Kotlin 读取加 `flutter.` 前缀）。写入方为二级页 `_saveSingleClickStop`（唯一），Kotlin `isSingleClickStopEnabled()` 每次按键实时读落盘（同 4 槽位 key 模式）
- **与「按音量减保持静音」互斥二选一**（用户拍板）：单击停录开启后录音中单击音量减被拦截停录、不再走 `adjustVolume`，`keep_muted` 标记失去触发入口，两开关同开语义自相矛盾。互斥由设置页保证——**开一个自动关另一个**（`_saveSingleClickStop` / `_saveKeepMutedOnVolumeDown` 双向联动，关闭保持静音时连同其联动的静音提示一起关），Kotlin 侧不重复校验。停录路径 `stopActiveRecording()` 复用既有 toggle 链路（悬浮窗语音速记走 `stopVoiceMemo` + 3s 回执超时兜底；主 APP 录音复用 `triggerQuickRecord`，内部按 `is_recording` 分流出 tick 停录震 + quick_record Intent）
- **与双击/长按槽位的兼容**：单击停录挂在单击路径上（双击槽有动作的键等 300ms 窗口超时后执行、双击槽 none 的键立即执行），双击确认仍执行槽位动作、长按 toggle 停录仍由 `wasLongPress` 短路保护，三者互不干扰；单击执行时**实时重读**开关与录音状态（排定 300ms 窗口期间录音可能已由说完自动停结束，此时回落调音量）
- **额外覆盖的实体键**（`STOP_RECORDING_EXTRA_KEYCODES`）：耳机线控中键 `KEYCODE_HEADSETHOOK` / 蓝牙耳机播放键 `KEYCODE_MEDIA_PLAY_PAUSE` / 实体相机键 `KEYCODE_CAMERA`——仅录音中 + 开关开启时消费（DOWN/repeat/UP 全拦，停录只认非 repeat 的 UP），**平时完全放行**（线控切歌、相机键启动相机不受影响）
- **覆盖边界（Android 平台限制，无法突破）**：电源键、Home 等系统保留键任何第三方应用（含无障碍服务）都收不到 KeyEvent；厂商自定义侧键（努比亚滑动键、小米 AI 键等）不广播标准 KeyEvent——后者接入靠系统「应用快捷方式」映射（见下方「外部硬件快捷方式」，映射动作的 toggle 语义天然支持"再触发=停"）。部分 ROM 对媒体键的派发路径有魔改，耳机键实际可达性以真机为准
- **悬浮窗停止提示随开关切换**：语音速记 controller `start()` 开录时读同一 key 存快照 `singleClickStopEnabled`，`_StopHintPill` 据此选文案（开 →「单击音量键，停止并转写」；关 →「再次长按音量上键，停止并转写」）——文案必须与实际交互一致，措辞不准会让用户照做后只看到音量条、录音没停

### 按住说话（ptt_record，实验分支 2026-09-21）

**松手即停**的录音手势：绑定在长按槽位上，按住达阈值（复用 `volume_long_press_ms` 档位）即开录，**松开同一键**立即停录转写——与 `quick_record` / `overlay_record` 的 toggle 制（松手后继续录、再长按才停）根本不同。后端复用悬浮窗语音速记整条链路（隐藏窗直建 / pendingVoiceMemoStart 握手 / 四级 watchdog / 3s stop 回执兜底 / Pro 门禁），只改触发与收尾时机。

- **动作值 `ptt_record`**：Dart `VolumeGestureAction.pttRecord` ↔ Kotlin `ACTION_PTT_RECORD` 严格一致（跨端硬编码副本）；合法值集合双侧同步扩为 7 个；迁移推导永不产出它（只由设置页写入）
- **仅长按两槽位提供**（设置页 chip 只在长按行渲染）：松手停录依附「按住中态」，双击槽位触发即抬手、无按住中态
- **与既有手势的冲突面（刻意收敛到最小）**：短按不受影响——阈值未到即松手 = 长按计时取消，回落双击检测/调音量路径，**无需把其他槽位设成 none 即可共存**；`wasLongPress` 短路保证 PTT 松手不进双击；单击停录/watchdog 等路径提前收尾会话时，PTT 松手走幂等 no-op
- **Kotlin 会话跟踪**（`pttHoldActive` / `pttHoldKeyCode` / `pttReleasePending`）：UP 只认发起会话的那一键（键码 DOWN 时随 `currentLongPressAction` 一并缓存），按住 A 键录音时另一键的 UP 不会误停；`executeGestureAction` 分发入口不变，键码经 `currentLongPressKeyCode` 传入 trigger
- **竞态兜底（PTT 短按住让两条旧竞态变成常态，Kotlin 侧必须兜）**：
  1. 松手早于 Dart 就绪（`pendingVoiceMemoStart` 仍挂着）→ 取消挂起启动 + `hideOverlay()` 收掉未揭示隐藏窗——照发 stop 会被未注册的 handler 静默丢弃，等 dartReady 补发启动后录音开始却没人停
  2. 松手早于 Dart 开录完成（start 的 await 链在跑，`stop()` 非录音态守卫会 no-op 丢弃早发的 stop）→ 置 `pttReleasePending`，`voiceMemoStarted` 回执到达时补发一次 stopVoiceMemo（3s 回执超时兜底照排）
- **麦克风互斥的让位差异**：主 APP 录音中触发 PTT 直接不开录（与 `overlay_record` 的「退回显示浮窗」不同——松手即停的瞬时手势不该顺手改变浮窗可见性）
- **停止提示文案**：`startVoiceMemo` 负载新增 `ptt` key，Dart `OverlayVoiceMemoController.isPttSession` 快照，`_StopHintPill` 切「松开音量键，停止并转写」（优先级高于单击停录文案）；旧版本 Kotlin 不带此 key 按 false 兼容
- **不做主 APP 快捷录音版 PTT 的原因**：quick_record 靠 Intent 冷启动 Activity，启动期间 `is_recording` 未落盘，快速松手的 toggle 停录会被 Flutter 侧当成「开始」反向误触——松手即停要求停录指令低延迟且不依赖 Activity

### 配置迁移（旧 key → 槽位推导）

旧版 4 个 key（`volume_key_mode` / `overlay_volume_up_long_press` / `overlay_volume_up_action` / `double_click_text_note`）重构后**不再被写入**，落盘保留仅作迁移 fallback 输入源。

**推导规则**（新 key 不存在/非法时生效，Dart 与 Kotlin 双侧内置同一套）：

| 槽位 | 推导规则（优先级从上到下） |
| --- | --- |
| 长按上 | `overlay_volume_up_long_press`=true →（`overlay_volume_up_action`=='record' ? `overlay_record` : `show_overlay`）；否则 mode ∈ {up, both} → `quick_record`；否则 `none` |
| 长按下 | mode ∈ {down, both} → `quick_record`；否则 `none` |
| 双击上 | mode ∈ {up, both} 且 `double_click_text_note`≠false → `quick_text_note`；否则 `none` |
| 双击下 | mode ∈ {down, both} 且 `double_click_text_note`≠false → `quick_text_note`；否则 `none` |

双侧分工：

- **Kotlin fallback 是核心**：无障碍服务常驻后台，App 未打开时也要正确分流。每次按键 `getGestureAction()` 直接读落盘 prefs——新 key 合法直接用，缺失/非法走内置迁移推导（`migrateLongPressUp` 等 4 个函数），无任何 MethodChannel 通信
- **Dart 侧仅设置页显示层推导**：`loadVolumeGestureActions()` 发现槽位缺失/非法时用 `migrateVolumeGestures()` 纯函数补齐显示，**不写回 prefs**；用户在设置页改动槽位时才写入新 key（`_saveGestureAction` 是新 key 的唯一写入方）
- 全新安装（旧 key 也不存在）按旧版默认值（mode='down' + 双击开）推出上文出厂默认

## 架构

### 原生层（Android）

- **VolumeKeyAccessibilityService.kt** - 无障碍服务，统一手势状态机（`onKeyEvent`）
  - **入口**：读该键的长按+双击两个槽位动作，都为 `none` → `return false`（音量键完全还给系统，等价旧 mode=off）
  - **ACTION_DOWN**：取消 pendingSingleClick；长按槽有动作才缓存 `currentLongPressAction` + 启动长按计时（`longPressHandler.postDelayed`，时长读 prefs 档位，默认 400ms）。长按槽=none 时不启动计时——按住不放无动作，抬起走调音量路径
  - **ACTION_UP**：移除长按计时 → `wasLongPress` 短路（长按已处理，不再进双击）→ 双击槽有动作走 300ms 同键双击检测（第二次抬起时执行 `executeGestureAction`；录音中与非录音态同一套，2026-09-15 前录音中会短路直接调音量、导致双击停录失效）；双击槽无动作则**立即调音量**（不配双击的键单击没有 300ms 延迟，本次重构的体验优化）
  - **`executeGestureAction(action, source)`**：4 槽位动作的唯一分发入口（`when` → `triggerQuickRecord` / `triggerQuickTextNote` / `triggerShowOverlay` / `triggerVoiceMemoOverlay`）；`source`（「长按」/「双击」/「外部快捷方式」默认值）只进分发入口日志定位触发来源，trigger* 内部日志不再硬编码手势名
  - **`getGestureAction(prefs, newKey, migrate)`**：新 key 合法直接用，否则 Kotlin 侧内置迁移 fallback
  - 录音状态感知：SharedPreferences 的 `is_recording` 标志
  - `onInterrupt` 补齐了长按 Handler 清理（原 DOWN/UP 清理不对称）
  - 本次重构删除：`getVolumeKeyMode` / `isKeyMonitored` / `shouldInterceptVolumeUp` / `getOverlayVolumeUpAction`（旧开关读取）、`isOverlayLongPressTriggered` / `lastKeyCode`（死字段）、`overlayLongPressHandler` / `overlayLongPressRunnable`（两套长按 Handler 合一）、`triggerQuickTextNote` 内 `double_click_text_note` 开关检查（改由双击槽位=none 表达关闭）
  - 不动：`extractShortcutType` 的 `quick_record` / `quick_text_note` intent 识别（槽位动作仍走此链路）、`show_overlay` 死分支（保留待后续清理）、锁屏 flags
- **MainActivity.kt** - Flutter-Native 桥接
  - MethodChannel 处理：`moveTaskToBack`、`openAlarmApp`、`isAccessibilityServiceEnabled`、`muteMedia`、`restoreMedia`（本次重构删除 `showAccessibilityOverlay` / `hideAccessibilityOverlay` / `openOverlaySettings` 三个方法及 MIUI 跳转私有函数）
  - Intent 路由：解析快捷方式 Action，传递给 Flutter 层
  - 冷启动处理：`handleShortcutIntentOnColdStart()`

### Flutter 层

- **main.dart** - 接收快捷方式 Intent，触发对应操作（`quick_record` / `quick_text_note` 动作仍走此链路）
- **settings_tab.dart** - "音量键快捷操作"分区：服务状态行 + 4 行手势选择器（每行 = 手势标题 + Wrap ChoiceChip 6 选项：无动作 / 显示悬浮窗〔Pro〕/ 悬浮窗录音〔Pro〕/ 悬浮窗笔记〔Pro〕/ APP内录音 / APP内笔记）+ 前往系统设置按钮 + 静音提示开关
- **lib/utils/volume_gesture_config.dart** - 槽位/动作常量 + 迁移推导纯函数（`VolumeGestureAction` / `VolumeGestureSlot` / `migrateVolumeGestures` / `loadVolumeGestureActions`，含 11 个单元测试）

## 事件流程

### 长按（阈值可调，默认 400ms）

```
音量键按下(DOWN) → onKeyEvent() 读长按槽动作（=none 则不启动计时）
                → 阈值计时到期（longPressRunnable，时长读 volume_long_press_ms 档位）
                → executeGestureAction(长按槽动作)
                ├─ quick_record    → 震动(100ms, 70) + quick_record Intent → Flutter 录音开始/停止(toggle)
                ├─ quick_text_note → 震动(50+50+50ms, 80) + quick_text_note Intent
                ├─ show_overlay    → 显示/隐藏悬浮窗（详见 @floating-window.md）
                └─ overlay_record  → 悬浮窗语音速记 toggle（详见 @floating-window.md）
音量键抬起(UP)   → 移除长按计时 → wasLongPress=true 短路返回（不进双击检测）
```

### 双击（300ms 同键窗口）

```
第一次单击抬起(UP) → 记录 lastClickTime/keyCode + 排定 300ms 延迟调音量(pendingSingleClick)
                    （录音中与非录音态同一套，见「录音期间的音量键行为」）
300ms 内同键第二次按下(DOWN) → 取消延迟调音量
第二次抬起(UP)    → 双击确认 → executeGestureAction(双击槽动作)
300ms 超时未二击  → pendingSingleClick 执行调音量（单击 = 正常调音量，只是晚 300ms）
```

## Flutter-Native 通信

### Intent

- `quick_record` - 快速录音（`quick_record` 动作触发）
- `quick_text_note` - 新建文本笔记（`quick_text_note` 动作触发）

### SharedPreferences 桥接

- `volume_gesture_long_press_up` / `volume_gesture_long_press_down` / `volume_gesture_double_click_up` / `volume_gesture_double_click_down` (String) - Flutter 写入（设置页 `_saveGestureAction`），原生每次按键直接读落盘 prefs（无需 channel 通知）
- `volume_long_press_ms` (Long) - 长按触发阈值毫秒（Flutter `setInt` 写入 `_saveLongPressMs` 但落盘即 Long，原生必须 `getLong` 读否则崩，见上文；缺失/脏值/越界（[50,2000] 范围外）回落 400）
- `single_click_stop_recording` (bool) - 录音中单击结束录音开关（Flutter 写入 `_saveSingleClickStop`，原生 `isSingleClickStopEnabled()` 每次按键实时读；与 `keep_muted_on_volume_down` 互斥由设置页保证；默认关）
- `is_recording` (bool) - Flutter 写入，原生读取，录音状态感知
- `keep_muted` (bool) - 原生写入，用户按音量减时标记保持静音
- 旧 key（`volume_key_mode` / `overlay_volume_up_long_press` / `overlay_volume_up_action` / `double_click_text_note`）：仅作迁移 fallback 输入源，不再写入

### MethodChannel

- `isAccessibilityServiceEnabled` - 检查无障碍服务是否已启用
- `muteMedia` - 保存当前音量并设为 0
- `restoreMedia` - 恢复原始音量（除非 `keep_muted` 为 true）

## 录音期间的音量键行为

2 条刻意保留的行为 + 1 条 2026-09-15 的行为变更 + 1 条 2026-09-19 的可选变更：

1. **录音中长按仍触发**——`longPressRunnable`（阈值档位时长，默认 400ms）不被 `is_recording` 拦截，`quick_record` / `overlay_record` 的 toggle 停录语义依赖于此（长按一下开始、再长按一下停止）
2. **录音中与非录音态同一套单击/双击状态机**（2026-09-15 变更）——旧版录音中不进双击检测、单击立即调音量，导致「双击 quick_record 开始的录音无法再双击停止」（真机踩中：第二次双击被当成两次单击调音量，录音开始时临时静音的媒体音量条被弹出，误认为「按音量加变静音」）。现在录音中双击 = 槽位动作 toggle 停录，代价仅是录音中单击调音量延迟 300ms 等双击窗口超时（与非录音态单击体验一致）。附带差异：双击确认走 `executeGestureAction` 不经过 `adjustVolume`，录音中双击音量减**不会**再误标 `keep_muted`（旧短路版会把两次误判的单击都标记）；保持静音仅在录音中**单击**音量减（300ms 超时路径）时标记
3. **长按后的 UP 不进双击**——`wasLongPress` 短路，避免"长按 600ms 松手"被误判为双击序列的一部分
4. **录音中单击改停录**（2026-09-19，`single_click_stop_recording` 开启时）——两处单击路径（双击槽超时兜底 / 双击槽 none 立即路径）在执行时实时判定：`isSingleClickStopEnabled() && isRecordingActive()` → `stopActiveRecording()`，否则维持原 `adjustVolume` 调音量。此时 keep_muted 永不会被标记（互斥开关保证 `keep_muted_on_volume_down` 已关，且停录路径不经过 `adjustVolume`）；耳机线控/相机键同样生效（见「录音中单击结束录音」小节）

其余照旧（仅在**未开启**单击停录时成立）：

- 录音中单击音量减（300ms 超时后）→ `adjustVolume` 设置 `keep_muted` 标志
- 录音结束后恢复音量时检查 `keep_muted`：
  - `keep_muted = false` → 恢复原始音量
  - `keep_muted = true` → 保持静音

## 媒体静音机制

快捷录音时自动静音其他媒体（如音乐、视频）：

```
开始录音 → muteMedia()
         → 保存当前音量到 _savedVolume
         → 设置媒体音量为 0

停止录音 → restoreMedia()
         → 检查 keep_muted 标志
         → keep_muted=false → 恢复 _savedVolume
         → keep_muted=true → 保持静音（用户主动选择）
```

## 震动反馈模式

| 操作             | 时长       | 振幅 | 说明             |
| ---------------- | ---------- | ---- | ---------------- |
| 长按触发录音     | 100ms      | 70   | 单次震动         |
| 双击触发笔记     | 50+50+50ms | 80   | 波形震动（两段） |
| 录音开始（快捷） | 100ms      | 70   | 确认录音已开始   |
| 录音停止（快捷） | 100ms      | 70   | 确认录音已停止   |
| 显示悬浮窗       | 100ms      | 70   | 召唤确认         |
| 悬浮窗显示中 toggle 隐藏 | 50ms | 60  | 短震             |
| 悬浮窗语音速记开始 | 100ms    | 70   | 确认录音已开始   |
| 悬浮窗语音速记停止（toggle） | 50ms | 50 | 短震           |

## 关键文件

| 文件                                                                              | 说明                          |
| --------------------------------------------------------------------------------- | ----------------------------- |
| `android/app/src/main/java/com/shengwuji/app/VolumeKeyAccessibilityService.kt`   | 无障碍服务（手势状态机）      |
| `android/app/src/main/java/com/shengwuji/app/MainActivity.kt`                    | 原生桥接                      |
| `lib/utils/volume_gesture_config.dart`                                            | 槽位/动作常量 + 迁移推导 + 长按阈值档位（VolumeLongPressMs） |
| `lib/main.dart`                                                                   | 快捷方式 Intent 处理          |
| `lib/settings/volume_key_settings_page.dart`                                      | 「音量键快捷操作」二级页：4 槽位手势选择器 UI + 长按阈值档位选择器（settings_tab.dart 保留入口行） |

## 外部硬件快捷方式（努比亚滑动键等，2026-09-12 起）

努比亚 Z60S Pro 等机型的侧边滑动键（及灵动键类硬件）在系统设置里只能映射到**应用快捷方式**，拿不到按键事件——此类硬件接入靠静态快捷方式 + 透明分发层，而非扩展手势槽位：

```
滑动键（系统映射快捷方式）
  → 静态快捷方式 overlay_record（shortcuts.xml，label「悬浮窗语音速记（再触发停止）」）
  → ACTION_OVERLAY_RECORD Intent
  → ShortcutDispatchActivity（透明无 UI，空 taskAffinity 独立 task，不拉主 App 前台）
  → VolumeKeyAccessibilityService.executeGestureAction("overlay_record")（同进程静态 instance 引用）
  → triggerVoiceMemoOverlay()——与音量键手势同一链路，toggle / Pro 门禁 / 麦克风互斥 / watchdog 全部复用
```

- **服务不可达重试**：分发层以 350ms × 6 重试等服务绑定（进程刚重启的竞态窗口），仍不可达 Toast 引导开启无障碍服务——悬浮窗动作本就以服务启用为前置（与音量键手势同款要求）
- **quick_record 不走此链路**：主 App 录音需要 Activity（锁屏显示/页面切换），静态快捷方式仍直落 MainActivity（现状不变）
- 反馈来源：滑动键上滑呼出快捷录音正常，下滑（系统"退出应用"动作）后录音不停——由此同时落地了**快捷录音「退出即停」**：lockedMode 会话退后台 + 亮屏 → 自动停录转写（息屏续录/手动会话不受影响，详见 @speech-recognition.md「快捷方式（系统）」小节）

## 前置条件

- 用户需手动启用无障碍服务（设置 → 无障碍）
- 应用无法自动启用无障碍服务（Android 限制）
- 设置页面提供引导入口

## 相关文档

- @speech-recognition.md - 语音识别整体流程
- @state-management.md - 状态管理架构
- @floating-window.md - 悬浮窗（`show_overlay` / `overlay_record` 动作的实现细节）

## Changelog

- 2026-09-23（实验分支）：长按触发阈值新增「自定义」档——预设 200/300/400/700 之外可输入 [50,2000]ms 任意值（用户反馈「最短 200 仍太长」）；点自定义 chip 弹输入对话框，确认按钮在输入合法前禁用（「选中自定义就必须有值」由构造保证，取消/清空不落盘），再点已选中的自定义 chip 可重新编辑预填当前值，输入值恰为某预设时 UI 归位到该预设 chip；合法域从预设集合白名单放开为范围闭区间，Kotlin `getLongPressDurationMs` 同步改范围校验（`LONG_PRESS_MS_CHOICES` 集合删除，`LONG_PRESS_MS_MIN/MAX` 边界为新的跨端硬编码副本对，预设集合只剩 Dart 侧 chip 展示用途），旧档位 500/800/1200 落在范围内改为按原值继续生效（不再就近回落 400，尊重老用户当年显式选择）；行标题秒数显示非整百值改两位小数（如 0.15 秒，一位小数会误显 0.1）；值 <100ms（刻意单击的最短按压）时选择器下显警示文案：该键单击调音量/同键双击/按音量减保持静音/单击停录路径失效、每次按下直接触发长按动作（按住说话反而是受益者），均为「手势被挤掉」而非误触发，无需自动关任何开关；flutter analyze 0 error + flutter test 全过（normalize 组重写：自定义边界/旧档位存续/越界回落 + isCustom 5 例）
- 2026-09-21（实验分支）：新增第 7 动作 `ptt_record`「按住说话」（长按槽位专属，Pro 门禁同语音速记）——按住达阈值开录、松开同一键停录转写；后端复用悬浮窗语音速记全链路，Kotlin 新增 PTT 会话跟踪（pttHoldActive/pttHoldKeyCode/pttReleasePending：UP 只认发起键 + 松手两条竞态兜底：冷启动取消挂起启动 / 开录回执到达补发停录），startVoiceMemo 负载新增 ptt key（Dart isPttSession 快照切停止提示「松开音量键」）；短按不受影响（阈值未到回落双击/调音量），与其他槽位动作天然共存；设置页 chip 仅长按两行提供
- 2026-09-21：长按触发档位按用户实测反馈整体下调（400/500/800/1200 → **200/300/400/700ms**，默认 500 → 400）——旧最短档 400ms 体感仍偏钝（比 1.1.0~1.2.0 硬编码 500ms 时代的体感无实质差异），重度使用者宁愿改用双击；下限 200ms 用误触风险换响应速度（用户要求，刻意单击约 100~300ms 会误判，设置页副文案保留提示）；旧默认 500 不在新集合内，缺失/脏值/旧值统一就近回落 400（Dart normalize 与 Kotlin getLongPressDurationMs 同规则，老用户升级自动迁移无需显式迁移代码）；设置页 chips 改「很快0.2/快0.3/标准0.4/慢0.7」
- 2026-09-19：新增「录音中单击结束录音」（prefs key `single_click_stop_recording`，默认关）——录音中单击音量键/耳机线控键/相机键立即停录，无需再长按 toggle；与「按音量减保持静音」互斥二选一（设置页开一个自动关另一个，Kotlin 不重复校验）；Kotlin `stopActiveRecording()` 复用两条既有 toggle 停录链路（`stopVoiceMemo` / `triggerQuickRecord`），单击路径执行时实时重读开关与录音状态；悬浮窗停止提示文案随开关切换「单击音量键，停止并转写」；电源键/Home（系统保留）与厂商自定义侧键（不走标准 KeyEvent）无法覆盖
- 2026-09-19：长按触发阈值改为可调档位（400/500/800/1200ms，默认 500）——设置页「音量键快捷操作」新增档位选择器，prefs key `volume_long_press_ms`（Dart 写 / Kotlin 每次 DOWN 读，档位集合跨端硬编码副本须双侧同步），Kotlin `LONG_PRESS_DURATION_MS` 降级为回落默认值；下限 400ms 防刻意单击误判长按；槽位行标题「约0.5秒」随档位动态显示；双击窗口维持固定 300ms 不变
- 2026-09-15：录音中按键改走与非录音态统一的单击/双击状态机（移除「录音中单击立即调音量」短路）——修复双击 `quick_record` 开始的录音无法再双击停止；附带消除录音中双击音量减对 `keep_muted` 的误标；`executeGestureAction` 增加 `source` 来源参数（长按/双击/外部快捷方式）进分发日志，trigger* 内部日志去掉误导性手势名前缀
- 2026-08-29：重构为 4 手势槽位 × 6 动作统一矩阵（见文首引言）
