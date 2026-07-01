# 锁屏隐私保护 + 键盘焦点重试 Bug 链复盘

## 背景

原始需求：用户锁屏时长按音量键能快速录音，双击音量键能新建文本笔记，APP 显示在锁屏界面之上。

commit `0bdbd2ca` 给 MainActivity 加了静态 `showWhenLocked="true"` 和 `turnScreenOn="true"` 实现这个功能，但引入了**隐私漏洞**：用户停留在 APP 页面 → 锁屏 → 点亮屏幕 → **绕过锁屏界面直接看到 APP 内容**（日记、物品清单暴露）。

修复隐私漏洞的过程中，又连续触发了 4 个串联 bug，每个修复都对另一个场景造成回归。整个修复链花了 6 次 commit 才收敛。

---

## Bug 清单

### Bug 1：静态 Manifest 属性导致锁屏绕过

**现象**：用户主动打开 APP → 锁屏 → 点亮 → 直接看到 APP 页面，没有锁屏界面。

**根因**：`android:showWhenLocked="true"` 是 AndroidManifest 的**静态永久属性**，对所有启动方式生效。无论是用户主动打开 APP，还是音量键快捷触发，MainActivity 都会显示在锁屏之上。

**正确做法**：移除静态属性，改为运行时按需启用：
- 快捷方式触发时（`applyLockScreenFlagsIfNeeded`）：`setShowWhenLocked(true)` + `setTurnScreenOn(true)`
- 屏幕熄灭时（`ACTION_SCREEN_OFF` 接收器）：`setShowWhenLocked(false)` + `moveTaskToBack(true)` 退后台

**教训**：把"应该按需启用的能力"写成"全局永久属性"是经典的权限放大错误。Android Activity flag 凡是涉及显示/锁屏/方向的，默认都该走运行时控制。

---

### Bug 2：录音停止后 APP 被锁屏遮挡

**现象**：锁屏 → 长按音量键录音 → 长按音量键停止 → **APP 立即被锁屏界面盖住**，看不到转写结果。

**根因**：修复 Bug 1 时，在 `stopListening()` 和编辑面板关闭路径里调用了 `clearLockScreenFlags()`。这相当于"用户刚说完话，就立刻把 APP 推到锁屏后面"。

**正确做法**：**只在 `ACTION_SCREEN_OFF` 接收器里清 flag**。用户主动锁屏（按电源键）或自动息屏时才清，停止录音时不清。

**教训**：**清理动作的时机要匹配用户预期**。用户主动锁屏 = 隐私保护应生效；用户停在 APP 看结果 = 隐私保护应等待。一个广播接收器统一管理 > 散落在多个业务回调里。

---

### Bug 3：锁屏双击音量键键盘不显示

**现象**：锁屏 → 点亮 → 双击音量键 → APP 显示文本笔记编辑面板，但**键盘不弹起来**。

**根因**：Bug 2 修复时，加了一个 `_isOpeningFromShortcut` 标志位，在 `startNewTextNote()` 设置为 true，让 `didChangeAppLifecycleState` 的键盘重试分支**跳过执行**。设计意图是"避免桌面场景重试造成抖动"，但锁屏场景**正是依赖这个重试**才能拉起键盘（首次 `requestFocus` 因 `windowFocus=false` 失败）。

**教训**：**不能为了解决一个场景的副作用，把另一个场景必需的逻辑也屏蔽掉**。一个标志位解决不了两个场景的矛盾，必须找到能区分两种场景的真正依据。

---

### Bug 4：桌面双击音量键键盘弹起 2 次

**现象**：APP 最小化到桌面 → 双击音量键 → **键盘起来→下去→起来**（视觉抖动）。

**根因**：去掉 `_isOpeningFromShortcut` 后，桌面场景下：
1. `_showEditSheet` 内 300ms `requestFocus` 成功（`windowFocus=true`）
2. `didChangeAppLifecycleState` 500ms 后无条件执行 `unfocus()` + 100ms + `requestFocus()`
3. `unfocus` 触发 `hideSoftInput`，`requestFocus` 又触发 `showSoftInput` → 抖动

### Bug 4 第一次修复（失败）：用 `MediaQuery.of(context).viewInsets.bottom` 判断

**思路**：500ms 时检查 widget tree 的 viewInsets，键盘已可见就跳过重试。

**失败**：日志显示 500ms 时 `MediaQuery.of(context).viewInsets.bottom` 返回 0，即使 Android 层 `ime mVisible=true` 已报告。

**根因**：`MediaQuery.of(context).viewInsets` 依赖 widget rebuild 才能更新。在 `didChangeAppLifecycleState` 的 `Future.delayed` 回调中读取时，widget tree 可能还没 rebuild 完最新值。

### Bug 4 第二次修复（失败）：用 `_editFocusNode!.hasFocus` 判断

**思路**：focus node 已 focus 说明首次 requestFocus 成功，跳过重试。

**失败**：日志显示锁屏场景中 `hasFocus=true`，但 IME **完全没启动**：
```
onFailed at PHASE_CLIENT_VIEW_SERVED
Ignoring showSoftInput() as view=FlutterView is not served
servedView=null, focus=true, windowFocus=false, hasImeFocus=true
```

**根因**：**Flutter `focusNode.hasFocus` 和 Android `windowFocus` 是两套完全独立的系统**：
- Flutter `hasFocus=true` 只代表 focus node 在 Flutter 框架内拿到焦点
- Android `windowFocus=false` 会让 IME 拒绝 showSoftInput
- 两者可以同时为 true 和 false，没有蕴含关系

### Bug 4 第三次修复（成功）：用引擎层 viewInsets 判断 + 恢复 unfocus+requestFocus

**最终方案**：
```dart
Future.delayed(const Duration(milliseconds: 500), () {
  if (!mounted || _editFocusNode == null) return;
  // 直接从引擎层取最新 viewInsets（绕过 widget tree 重建延迟）
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final keyboardAlreadyVisible = view.viewInsets.bottom > 0;
  if (keyboardAlreadyVisible) {
    return;  // 桌面场景：首次 requestFocus 成功，跳过
  }
  // 锁屏场景：首次 requestFocus 失败，必须 unfocus+requestFocus
  // （focusNode.hasFocus=true 但 IME 未起，单纯 requestFocus 会 early return 无效）
  _editFocusNode!.unfocus();
  Future.delayed(const Duration(milliseconds: 100), () {
    _editFocusNode?.requestFocus();
  });
});
```

**为什么这次有效**：
- `platformDispatcher.views.first.viewInsets` 直接从 Flutter 引擎读取，**不依赖 widget rebuild**，总是返回最新值
- 场景 A（锁屏，IME 未启动）：viewInsets.bottom = 0 → 重试
- 场景 B（桌面，IME 已显示）：viewInsets.bottom > 0 → 跳过

---

## 核心教训

### 1. Flutter 焦点系统的关键区分

| API | 反映什么 | 可靠性 |
|---|---|---|
| `focusNode.hasFocus` | Flutter 框架内 focus node 状态 | ⚠️ 与 IME 实际显示脱钩 |
| `MediaQuery.of(context).viewInsets.bottom` | widget tree 看到的 IME 高度 | ⚠️ 异步回调中可能拿到旧值 |
| `WidgetsBinding.instance.platformDispatcher.views.first.viewInsets.bottom` | 引擎层 IME 高度 | ✅ 最可靠，绕过 widget 重建 |

**判断键盘是否真的显示，永远用第三种**。

### 2. Android 12+ 后台恢复 showSoftInput 失败的处理

**症状**：logcat 看到 `onFailed at PHASE_CLIENT_VIEW_SERVED` + `servedView=null` + `windowFocus=false`。

**原因**：APP 从后台恢复时，window focus 还没拿到就调 showSoftInput，IME 直接拒绝。

**处理**：必须在 lifecycle `resumed` 之后延迟重试。重试方式不能用单纯 `requestFocus()`（focusNode 已 hasFocus 时会 early return），必须 `unfocus()` 强制触发 `_handleFocusChanged`，再 `requestFocus()` 重新走 `openInputConnection → showTextInput`。

### 3. unfocus+requestFocus 的双刃剑

| 场景 | unfocus+requestFocus 效果 |
|---|---|
| focusNode 已 focus + IME 已显示 | ❌ 强制走 hide→show，造成视觉抖动 |
| focusNode 已 focus + IME 未显示 | ✅ 必要，强制触发 _handleFocusChanged |
| focusNode 未 focus | ✅ 安全（unfocus 是 no-op） |

**结论**：unfocus+requestFocus 是"重锤"，只在该用的时候用。判断"该不该用"的依据是引擎层 viewInsets，不是 hasFocus。

### 4. 修复链式 bug 时要画场景矩阵

每次修复前，列出所有受影响的场景和预期行为：

| 场景 | 用户动作 | 修复后期望行为 | 修复是否破坏？ |
|---|---|---|---|
| A | 锁屏 + 长按音量键录音 | 录音停止后留在 APP | ✓ |
| B | 锁屏 + 双击音量键文本笔记 | 键盘正常弹起 | ✓ |
| C | 桌面 + 双击音量键文本笔记 | 键盘只弹 1 次 | ✓ |
| D | 主动打开 APP + 锁屏 + 点亮 | 看到锁屏界面（不绕过） | ✓ |
| E | 录音中按电源键锁屏 | 退到后台，不暴露内容 | ✓ |

**每次提交前对一遍矩阵**，比靠记忆管理 5 个场景可靠得多。

### 5. 不要为单一场景加状态标志位

`_isOpeningFromShortcut` 这种标志位的本质是"为了解决场景 X 的副作用，但副作用又波及场景 Y"。**正确做法是找到能真正区分场景的客观依据**（如 viewInsets），而不是用主观标志位遮盖。

---

## 一句话指令模板

遇到类似问题时，用这些指令让 Claude 一次做对：

**Flutter 键盘/焦点问题**：

> "Flutter 键盘行为异常，错误是 [粘贴 logcat 关键行]。请先用 `WidgetsBinding.instance.platformDispatcher.views.first.viewInsets.bottom` 检查引擎层键盘状态，不要用 `MediaQuery.of(context).viewInsets` 或 `focusNode.hasFocus`——前者有 widget rebuild 延迟，后者与 Android windowFocus 脱钩。"

**Android 后台恢复键盘不弹**：

> "APP 从后台恢复时 showSoftInput 报 `onFailed at PHASE_CLIENT_VIEW_SERVED`。请检查 `didChangeAppLifecycleState` 中是否有 unfocus+requestFocus 重试逻辑，重试前用引擎层 viewInsets 判断键盘是否已显示，已显示就跳过避免抖动。"

**修复涉及多场景回归**：

> "我修了 [场景 A]，但破坏了 [场景 B]。请先列出所有受影响的场景矩阵（用户动作 / 期望行为 / 当前实际行为），再判断修复方向，不要直接加状态标志位。"

---

## 关键 API 模式

### 引擎层键盘可见性检查（最可靠）

```dart
// 直接从 Flutter 引擎读取，绕过 widget tree 重建延迟
final view = WidgetsBinding.instance.platformDispatcher.views.first;
final keyboardVisible = view.viewInsets.bottom > 0;
```

### Android 12+ 后台恢复键盘重试

```dart
if (_wasInBackground &&
    state == AppLifecycleState.resumed &&
    _editFocusNode != null) {
  Future.delayed(const Duration(milliseconds: 500), () {
    if (!mounted || _editFocusNode == null) return;
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    if (view.viewInsets.bottom > 0) return;  // 已显示，跳过

    _editFocusNode!.unfocus();  // 强制 _handleFocusChanged
    Future.delayed(const Duration(milliseconds: 100), () {
      _editFocusNode?.requestFocus();
    });
  });
}
```

### Android 锁屏 flag 动态管理

```kotlin
// 启用（快捷方式触发时）
private fun applyLockScreenFlagsIfNeeded(intent: Intent?) {
    if (isQuickAction(intent)) {
        setShowWhenLocked(true)
        setTurnScreenOn(true)
    }
}

// 清除（屏幕熄灭时统一管理，绝不在业务回调里清）
// 在 ACTION_SCREEN_OFF 接收器里调用
screenOffReceiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        if (intent?.action == Intent.ACTION_SCREEN_OFF) {
            clearLockScreenFlags()
            moveTaskToBack(true)
        }
    }
}
```

---

## 相关文件

- [lib/diary_tab.dart](../../lib/diary_tab.dart) - `didChangeAppLifecycleState` 键盘重试逻辑（line ~265）
- [android/app/src/main/AndroidManifest.xml](../../android/app/src/main/AndroidManifest.xml) - MainActivity 配置（已移除静态 showWhenLocked）
- [android/app/src/main/java/com/shengwuji/app/MainActivity.kt](../../android/app/src/main/java/com/shengwuji/app/MainActivity.kt) - 锁屏 flag 动态管理 + SCREEN_OFF 接收器

## 相关 commit

- `3dbb755` - 移除静态 showWhenLocked/turnScreenOn + 加 SCREEN_OFF 接收器
- `c3216fb` - stopListening/编辑面板关闭不再清 flag（统一由 SCREEN_OFF 负责）
- `eb9b665` - 移除 `_isOpeningFromShortcut` 标志位（让重试对所有场景生效）
- `67816b3` - 改用 viewInsets.bottom 判断（失败）
- `b0b35b9` - 改用 hasFocus 判断 + 去掉 unfocus（失败）
- `30c4e08` - 最终方案：引擎层 viewInsets + 恢复 unfocus+requestFocus
