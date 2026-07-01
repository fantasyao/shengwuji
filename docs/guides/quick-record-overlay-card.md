# 方案评估：长按音量键 → 轻量卡片录音（Focus Mode）

> **状态**：📝 待决策（未实施）
> **创建日期**：2026-06-28
> **决策者**：用户（还在考虑中）
> **依赖**：ee8dd7d（CATEGORY_LAUNCHER 修复）+ 0bdbd2c（方案一锁屏显示）

---

## 背景：为什么有这个方案

当前长按音量键的体验是"**粗暴切到 APP 日记页**"。用户在用其他 APP（比如微信聊天）时被强制拽走，视觉冲击大。

用户提出的真正诉求：**长按音量键时不要进 APP，只在屏幕右上角出一个胶囊，能看着微信内容同步记笔记**。

经过评估，真"悬浮在微信之上"的胶囊需要 `SYSTEM_ALERT_WINDOW + ForegroundService + 原生 AudioRecord`，工作量 3-4 天且用户需手动开悬浮窗权限（见 [方案对比](#三种方案对比) 中的方案 C）。

**折中方案**：进入 APP 但只显示一张居中卡片 + 黑色遮罩（Focus Mode 风格），减少视觉冲击。

---

## 用户诉求 vs 方案能力对照

| 用户场景 | 真悬浮窗 | 轻量卡片（本方案） | 当前体验 |
|----------|---------|--------------------|----------|
| 看得到下面的微信 | ✅ | ❌ | ❌ |
| 视觉冲击小 | ✅ | ✅ | ❌ |
| 实施工作量 | 3-4 天 | ~1 天 | 已完成 |
| 用户需开额外权限 | 悬浮窗权限 | 无 | 无 |
| 录音权限稳定性 | 需重新验证 | ✅ 沿用 ee8dd7d + 方案一 | ✅ |

**核心权衡**：轻量卡片**不能**解决"看微信"问题，只能解决"视觉冲击"问题。

---

## 三种方案对比

### 方案 1：当前体验（已完成）

```
长按音量键 → MainActivity 进前台
           → 切到 MainScaffold 的日记页（索引 2）
           → 显示完整 APP：4 个 Tab、日记列表、录音按钮
```

**视觉**：整个屏幕被 APP 占满，看到日记页全部内容
**痛点**：粗暴切走，视觉冲击大

---

### 方案 2：轻量卡片（本方案，Focus Mode）

```
长按音量键 → MainActivity 进前台（不变）
           → 不切到 MainScaffold 的日记页
           → 在 MainScaffold 之上 push 一个 OverlayRoute
           → OverlayRoute = 黑色遮罩 + 居中卡片
           → Flutter 录音/识别 → 卡片内实时显示状态和文字
           → 录完 → 卡片显示文字 → 3 秒后自动关闭 / 点击编辑
```

**视觉参照**：三星下拉通知中心、iOS 控制中心、专注模式

```
┌─────────────────────────────┐
│                             │
│                             │
│       ┌───────────┐         │
│       │ 🔴 录音中  │         │
│       │           │         │
│       │  00:05    │         │
│       │           │         │
│       │  点击停止  │         │
│       └───────────┘         │
│                             │
│                             │
│       (点击空白处取消)        │
└─────────────────────────────┘
   纯黑背景 + 居中明亮卡片
```

---

### 方案 3：真悬浮窗（不推荐，工作量过大）

需要：`SYSTEM_ALERT_WINDOW + ForegroundService + 原生 AudioRecord + WindowManager.addView`

详见 [评估文档](../../C:/Users/11219/.claude/plans/off-state-record-evaluation.md) 中的方案 B/C 部分。

---

## 关键技术澄清

### ❌ 不需要 `windowIsTranslucent=true`

我前面误把"半透明遮罩"和 Android 系统的 `windowIsTranslucent` 混在一起说了。澄清：

- **`windowIsTranslucent=true`** 是 Window 级别的属性，跨 APP（看到微信）在大多数 ROM 上不可靠（显示壁纸或黑色）
- **本方案完全不用这个属性**
- **遮罩的颜色** 是 Flutter Widget 的颜色（`Container(color: Colors.black)`），跟 Android Window 系统无关
- **遮罩颜色 100% 可控**：想多黑就多黑，想多透就多透

### 录音权限链路保持不变

| 组件 | 来源 | 状态 |
|------|------|------|
| `CATEGORY_LAUNCHER` | ee8dd7d 的 `getLaunchIntentForPackage` | ✅ 保留 |
| `showWhenLocked / turnScreenOn` | 方案一 Manifest 属性 | ✅ 保留 |
| `WakeLock`（点亮屏幕） | 方案一 AccessibilityService | ✅ 保留 |
| Flutter `record` 包录音 | DiaryTab.startListening | ✅ 保留 |

**本方案只改 UI 形态，不动核心机制**。

---

## 遮罩风格可选项

| 风格 | 遮罩颜色 | 视觉感受 | 实现复杂度 |
|------|---------|---------|-----------|
| **纯黑**（推荐） | `Colors.black`（100%） | 最干净，像通知中心 | 简单 |
| **半透黑** | `Colors.black.withOpacity(0.95)` | 略微透出底下 MainScaffold（被压暗） | 简单 |
| **毛玻璃模糊** | `BackdropFilter(sigma: 20)` + 黑色 60% | iOS 控制中心的高级感 | 中等 |

---

## 工作量拆解

| 任务 | 估时 |
|------|------|
| 新增 `QuickRecordOverlayRoute`（Stack + 遮罩 + 居中卡片） | 2h |
| 卡片内状态机 UI（录音中波形 / 识别中骨架屏 / 完成态文字） | 4h |
| 改 `_handleQuickRecord`：不切到日记页，改为 push OverlayRoute | 1h |
| 录音/识别状态接入（复用 DiaryTab 的 stream/callback） | 3h |
| 卡片交互（点遮罩=取消、点卡片=停止录音、滑掉=删除） | 3h |
| 文字显示后的"自动关闭 / 点击编辑"逻辑 | 2h |
| 视觉细节（动画、阴影、圆角、毛玻璃可选） | 3h |
| 测试（亮屏态、锁屏点亮态、连续录音） | 2h |

**总计：约 1 天（~20h）**

---

## 风险与缓解

| 风险 | 严重度 | 缓解 |
|------|--------|------|
| 录音中断（罕见） | 中 | 沿用 ee8dd7d + 方案一的所有机制 |
| 多任务键看到 APP 缩略图很怪 | 低 | 添加 `setRecentsScreenshotEnabled(false)` 或保留 MainScaffold 截图 |
| 录音中用户想取消 | 中 | 提供"划掉卡片=取消不保存"手势 |
| 录音完用户想编辑文字 | 中 | 卡片内"编辑"按钮 → 关闭 Overlay → 进 MainScaffold 日记页编辑 |
| 锁屏之上卡片看不清 | 低 | 遮罩用纯黑（保证对比度），卡片高对比配色 |

---

## 实施路径（如果决定做）

### Phase 1：MVP（最小可用版本）

1. 新建 `lib/widgets/quick_record_overlay_route.dart`
2. 实现 OverlayRoute：纯黑遮罩 + 居中卡片（3 种状态：录音中/识别中/完成）
3. 改 `main.dart` 的 `_handleQuickRecord`：移除切到日记页的逻辑，改为 `navigator.push(QuickRecordOverlayRoute())`
4. 复用 DiaryTab 的录音/识别 stream（通过 GlobalKey 或 ValueNotifier 解耦）
5. 点遮罩 = 取消（不保存），点卡片 = 停止录音

### Phase 2：交互完善

6. 录音中卡片显示波形动画
7. 识别中显示骨架屏
8. 完成态卡片：显示文字 + [编辑] [完成] 按钮
9. 自动关闭逻辑（完成态 3 秒后 fade out）
10. 滑动手势（Dismissible 包裹卡片，左滑=删除）

### Phase 3：视觉打磨

11. 卡片圆角、阴影、字体
12. 录音→识别→完成的转场动画
13. 遮罩 fade-in 动画
14. 可选：毛玻璃模糊背景

---

## 用户决策前的关键问题

在决定要不要做之前，建议先想清楚：

### 1. 你的核心痛点是什么？

- **A. "想看着其他 APP 内容同步记笔记"**
  → 轻量卡片**解决不了**，只有真悬浮窗（方案 3）能解决
- **B. "进 APP 的视觉冲击太大，想更温和"**
  → 轻量卡片**可以解决**，1 天工作量
- **C. "两者都想要"**
  → 先做轻量卡片（小工作量），未来再升级到真悬浮窗

### 2. 录音完后的"编辑入口"重要吗？

- 如果用户经常需要编辑识别结果（错别字、加清单格式等）→ 卡片必须提供"进 APP 编辑"按钮
- 如果用户绝大多数情况是录完就完 → 卡片可以更简洁

### 3. 锁屏场景的预期？

- 录音中手机点亮 → 用户看到黑底+卡片 → 录完自动关闭 → 屏幕熄灭
- 这个流程跟当前方案一一样能工作，但视觉上更克制

---

## 相关文档

- 评估：[C:\Users\11219\.claude\plans\off-state-record-evaluation.md](../../../../C:/Users/11219/.claude/plans/off-state-record-evaluation.md)
- 方案一 plan：[C:\Users\11219\.claude\plans\peppy-tumbling-wirth.md](../../../../C:/Users/11219/.claude/plans/peppy-tumbling-wirth.md)
- 当前 UI 模式：[ui-patterns.md](ui-patterns.md)
- 当前架构：[../architecture/volume-key-shortcuts.md](../architecture/volume-key-shortcuts.md)

---

## 历史 / 决策日志

- **2026-06-28**：创建评估文档。用户在权衡是否实施。
