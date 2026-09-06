# 音量键快捷操作

> 2026-08-29 重构：从"监听哪些音量键"的两开关模型改为 **4 手势槽位 × 6 动作** 的统一矩阵（提交 `4c64d57` 契约+单测 / `a7a6b6e` Kotlin 重构 / `0d0a8cb` 设置页 UI；第 6 动作 `overlay_new_note` 后补）。本文档以新架构为准。

## 概述

通过 Android 无障碍服务（AccessibilityService）拦截音量键事件。每个音量键的长按、双击各是一个独立"手势槽位"，共 4 个槽位，每个槽位可绑定 6 种动作之一。

### 手势槽位 × 动作矩阵

**4 个槽位**（SharedPreferences key，Dart 侧常量 `VolumeGestureSlot.*`；Kotlin 读取时加 `flutter.` 前缀）：

| 槽位 | prefs key | 出厂默认 |
| --- | --- | --- |
| 长按音量上键（500ms） | `volume_gesture_long_press_up` | `none` |
| 长按音量下键（500ms） | `volume_gesture_long_press_down` | `quick_record` |
| 双击音量上键（300ms 窗口） | `volume_gesture_double_click_up` | `none` |
| 双击音量下键（300ms 窗口） | `volume_gesture_double_click_down` | `quick_text_note` |

**6 种动作**（字符串常量，Dart `VolumeGestureAction.*` 与 Kotlin `ACTION_*` 严格一致）：

| 动作值 | 含义 |
| --- | --- |
| `none` | 无动作（槽位关闭，该手势不拦截） |
| `show_overlay` | 显示悬浮窗（toggle：显示中再触发则立即隐藏）**〔Pro〕** |
| `overlay_record` | 悬浮窗语音速记（toggle 状态机，详见 @floating-window.md）**〔Pro〕** |
| `overlay_new_note` | 悬浮窗新增笔记（浮窗未显示则先建，通知 Dart 新增空白笔记进编辑态；不做 toggle 隐藏，重复触发 = 再新增一条）**〔Pro〕** |
| `quick_record` | 快速进入 APP 录音（Flutter 侧 toggle：录音中再触发则停录） |
| `quick_text_note` | 快速进入 APP 新建文本笔记 |

> **Pro 门禁（2026-09-03）**：悬浮窗系动作（`show_overlay` / `overlay_record` / `overlay_new_note`）为 Pro 付费功能。未解锁时：① 设置页手势选择器的对应 chip 标 Pro 徽章且点击弹付费弹窗（不写 prefs）；② Kotlin 侧执行动作前读落盘 `flutter.is_pro_unlocked` 拦截（Toast 提示），但**放行 toggle 分支**——已显示的浮窗/进行中的录音，未解锁用户必须关得掉、停得掉。详见 @floating-window.md 的"Pro 门禁"小节。

出厂默认对齐重构前旧版的默认行为（音量减键长按录音 + 双击笔记、音量加键不监听）。

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
  - **ACTION_DOWN**：取消 pendingSingleClick；长按槽有动作才缓存 `currentLongPressAction` + 启动 500ms 长按计时（`longPressHandler.postDelayed`）。长按槽=none 时不启动计时——按住不放无动作，抬起走调音量路径
  - **ACTION_UP**：移除长按计时 → `wasLongPress` 短路（长按已处理，不再进双击）→ 录音中单击立即调音量 → 双击槽有动作走 300ms 同键双击检测（第二次抬起时执行 `executeGestureAction`）；双击槽无动作则**立即调音量**（不配双击的键单击没有 300ms 延迟，本次重构的体验优化）
  - **`executeGestureAction(action)`**：4 槽位动作的唯一分发入口（`when` → `triggerQuickRecord` / `triggerQuickTextNote` / `triggerShowOverlay` / `triggerVoiceMemoOverlay`）
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

### 长按（500ms）

```
音量键按下(DOWN) → onKeyEvent() 读长按槽动作（=none 则不启动计时）
                → 500ms 计时到期（longPressRunnable）
                → executeGestureAction(长按槽动作)
                ├─ quick_record    → 震动(100ms, 70) + quick_record Intent → Flutter 录音开始/停止(toggle)
                ├─ quick_text_note → 震动(50+50+50ms, 80) + quick_text_note Intent
                ├─ show_overlay    → 显示/隐藏悬浮窗（详见 @floating-window.md）
                └─ overlay_record  → 悬浮窗语音速记 toggle（详见 @floating-window.md）
音量键抬起(UP)   → 移除长按计时 → wasLongPress=true 短路返回（不进双击检测）
```

### 双击（300ms 同键窗口）

```
第一次单击抬起(UP) → 录音中？立即调音量
                   → 否则记录 lastClickTime/keyCode + 排定 300ms 延迟调音量(pendingSingleClick)
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
- `is_recording` (bool) - Flutter 写入，原生读取，录音状态感知
- `keep_muted` (bool) - 原生写入，用户按音量减时标记保持静音
- 旧 key（`volume_key_mode` / `overlay_volume_up_long_press` / `overlay_volume_up_action` / `double_click_text_note`）：仅作迁移 fallback 输入源，不再写入

### MethodChannel

- `isAccessibilityServiceEnabled` - 检查无障碍服务是否已启用
- `muteMedia` - 保存当前音量并设为 0
- `restoreMedia` - 恢复原始音量（除非 `keep_muted` 为 true）

## 录音期间的音量键行为

3 条重构时**刻意保留的现状行为**：

1. **录音中长按仍触发**——500ms `longPressRunnable` 不被 `is_recording` 拦截，`quick_record` / `overlay_record` 的 toggle 停录语义依赖于此（长按一下开始、再长按一下停止）
2. **录音中单击立即调音量**——不进双击检测，`adjustVolume` 直接执行（方便录音中静音媒体）
3. **长按后的 UP 不进双击**——`wasLongPress` 短路，避免"长按 600ms 松手"被误判为双击序列的一部分

其余照旧：

- 录音中按音量减 → `adjustVolume` 设置 `keep_muted` 标志
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
| `lib/utils/volume_gesture_config.dart`                                            | 槽位/动作常量 + 迁移推导      |
| `lib/main.dart`                                                                   | 快捷方式 Intent 处理          |
| `lib/settings_tab.dart`                                                           | 4 槽位手势选择器 UI           |

## 前置条件

- 用户需手动启用无障碍服务（设置 → 无障碍）
- 应用无法自动启用无障碍服务（Android 限制）
- 设置页面提供引导入口

## 相关文档

- @speech-recognition.md - 语音识别整体流程
- @state-management.md - 状态管理架构
- @floating-window.md - 悬浮窗（`show_overlay` / `overlay_record` 动作的实现细节）
