# 音量键快捷操作

## 概述

通过 Android 无障碍服务（AccessibilityService）拦截音量键事件，实现快捷录音和文本笔记功能。

### 两种触发方式
- **长按音量键（500ms）** → 触发快速录音
- **双击音量键（300ms 窗口）** → 新建文本笔记

### 配置项
用户可在设置页面选择监听的音量键：
- `volume_key_mode`: off / up / down / both
- 默认：仅音量减键

## 架构

### 原生层（Android）
- **VolumeKeyAccessibilityService.kt** - 无障碍服务，监听音量键
  - 长按检测：Handler + Runnable，500ms 延迟触发
  - 双击检测：300ms 窗口内同一按键连续两次按下
  - 录音状态感知：通过 SharedPreferences 的 `is_recording` 标志
- **MainActivity.kt** - Flutter-Native 桥接
  - MethodChannel 处理：`moveTaskToBack`、`openAlarmApp`、`isAccessibilityServiceEnabled`、`muteMedia`、`restoreMedia`
  - Intent 路由：解析快捷方式 Action，传递给 Flutter 层
  - 冷启动处理：`handleShortcutIntentOnColdStart()`

### Flutter 层
- **main.dart** - 接收快捷方式 Intent，触发对应操作
- **settings_tab.dart** - 无障碍服务开关和音量键配置 UI

## 事件流程

### 快速录音（长按）
```
音量键按下 → AccessibilityService.onKeyEvent()
           → 500ms 长按判定
           → 震动反馈（100ms, amplitude 70）
           → 发送 quick_record Intent
           → MainActivity 路由到 Flutter
           → Flutter 触发录音开始
```

### 文本笔记（双击）
```
音量键按下 → AccessibilityService.onKeyEvent()
           → 300ms 窗口内第二次按下
           → 震动反馈（50+50+50ms, amplitude 80）
           → 发送 quick_text_note Intent
           → MainActivity 路由到 Flutter
           → DiaryTab.startNewTextNote()
```

## Flutter-Native 通信

### Intent
- `quick_record` - 快速录音
- `quick_text_note` - 新建文本笔记

### SharedPreferences 桥接
- `is_recording` (bool) - Flutter 写入，原生读取，录音状态感知
- `keep_muted` (bool) - 原生写入，用户按音量减时标记保持静音
- `volume_key_mode` (String) - Flutter 写入，原生读取，监听按键配置

### MethodChannel
- `isAccessibilityServiceEnabled` - 检查无障碍服务是否已启用
- `muteMedia` - 保存当前音量并设为 0
- `restoreMedia` - 恢复原始音量（除非 `keep_muted` 为 true）

## 录音期间的音量键行为

录音期间音量键**正常调节音量**，不被拦截：
- 原生服务检测 `is_recording` 标志
- 录音中按音量减 → 设置 `keep_muted` 标志
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

| 操作 | 时长 | 振幅 | 说明 |
|------|------|------|------|
| 长按触发录音 | 100ms | 70 | 单次震动 |
| 双击触发笔记 | 50+50+50ms | 80 | 波形震动（两段） |
| 录音开始（快捷） | 100ms | 70 | 确认录音已开始 |
| 录音停止（快捷） | 100ms | 70 | 确认录音已停止 |

## 关键文件

| 文件 | 说明 |
|------|------|
| `android/app/src/main/java/com/example/my_first_app/VolumeKeyAccessibilityService.kt` | 无障碍服务 |
| `android/app/src/main/java/com/example/my_first_app/MainActivity.kt` | 原生桥接 |
| `lib/main.dart` | 快捷方式处理 |
| `lib/settings_tab.dart` | 配置 UI |

## 前置条件

- 用户需手动启用无障碍服务（设置 → 无障碍）
- 应用无法自动启用无障碍服务（Android 限制）
- 设置页面提供引导入口

## 相关文档
- @speech-recognition.md - 语音识别整体流程
- @state-management.md - 状态管理架构
