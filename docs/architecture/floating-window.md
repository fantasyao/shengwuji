# 悬浮窗（闪念胶囊）架构与实现记录

> 分支：`feature/floating-window` · 最近更新：2026-09-03 · 状态：**把手 + 数据链路 + 全屏透明面板/自适应胶囊 + 召唤式交互已打通**（音量键手势槽位召唤悬浮窗并自动展开、收起后可配置秒数自动彻底隐藏、显示时再触发立即隐藏、展开/收起推屏滑动动画；卡片标注换色已落地；**悬浮窗整体为 Pro 付费功能**——设置页门禁 + 原生手势拦截双层，见"Pro 门禁"小节）

## 功能概述

系统级悬浮窗（锤子"闪念胶囊"样式），收起态为贴屏幕右缘垂直居中的竖长胶囊把手（28×88dp，全圆角，⚡ 图标 + 竖排"记一笔"），点击或左滑展开 300dp 宽侧栏面板（"随手记"日记列表）。

基于 **TYPE_ACCESSIBILITY_OVERLAY** 窗口类型实现（不走 `SYSTEM_ALERT_WINDOW` 悬浮窗权限——该路径在小米/HyperOS 上被系统拦截），由无障碍服务 `VolumeKeyAccessibilityService` 创建窗口并承载独立 FlutterEngine 渲染。

## 本轮提交记录（2026-08-24 ~ 08-26）

| 提交 | 内容 |
|---|---|
| `8d4cbcb` | 长按音量上键直连召唤+自动展开+收起后延时彻底隐藏（dartReady 握手 + reset 复位，详见"触发与生命周期"小节） |
| `e6aed90` | 把手改闪念胶囊样式（竖排文字+全圆角+移除黄色调试背景） |
| `0c5b1a6` | overlayMain 保活 import + 无障碍服务独立 engine 缓存 key |
| `6ffd647` | main.dart 根库转发函数 overlayMain（最终修好显示） |
| `55712d5` | 展开面板空列表修复：overlay engine 直连 sqflite 查库，废弃 overlay_bridge 跨 engine 通道 |
| `d022ec2` | 展开面板改版：铺满全屏（哨兵值原生解释）+ 彩色胶囊卡片（色板轮换） |
| `53e0d85` | 面板背景透明 + 左侧空白区点击/左滑关闭 + 胶囊宽度随内容自适应（min 60dp / max 面板宽-margin） |
| `47b1c87` | 空白区手势加 `HitTestBehavior.opaque` 修复收起失灵（透明 SizedBox 默认 deferToChild 永不命中 hit-test） |
| `7030d00` | 面板高度改为随日记条数自适应：Stack 全屏空白区垫底 + 面板贴右上（Column min + ListView shrinkWrap） |
| （08-29 提交） | 语音速记冷启动根治把手闪现（第四轮修复）：隐藏窗口直建胶囊尺寸 312×64 消除 resize 竞态 + 揭示门挂门提前至 handler 顶部 + 摘门改"录音态首帧"确定性事件 + idle 态胶囊窗硬不变量渲染空白（详见"冷启动隐藏窗口"小节） |
| （2026-09-02 本次提交） | 卡片标注（标签换色）：色板轮换 → 固定默认色 #6F9AF0 + 3 种标注整卡换色（紧急! #FF6B6B / 收藏⭐ #FEA545 / 灵感💡 #AE82E4），标注持久化到 diary.tag 列（DB v9→v10），主 App 日记页显示 8dp 小色点（详见"卡片标注"小节） |
| （2026-09-02 本次提交） | 收起胶囊内容贴顶回归修复：a36800b 把卡片外层 Switcher 的 Stack 锚点改 topRight（收起动画旧内容顶缘连续所需），但收起静止态 currentChild（单行 Row ~24dp）比 Stack（容器 minHeight 撑到 46）矮被钉在胶囊顶部、底部空 22dp——收起分支 Row 包 `ConstrainedBox(minHeight: cardHeight)` 撑满胶囊高，Row 自身 crossAxisAlignment.center 接管垂直居中（含回归测试） |

## 核心架构

### 双 engine 结构

- **主 engine**：入口 `main()`，由 MainActivity（FlutterActivity）创建，跑完整 App
- **overlay engine**：入口 `overlayMain()`，由无障碍 Service 用 `FlutterEngineGroup.createAndRunEngine` 创建，只跑悬浮窗 UI（独立 isolate，与主 App 不共享状态）

### 入口函数的三连坑（重要教训，改动入口相关代码前必读）

1. **保活 import**：Dart 编译器只编译从 `main()` 可达的代码。`lib/overlay/overlay_main.dart` 必须被 main.dart import（[main.dart:23-26](../../lib/main.dart)），否则函数根本不进 kernel
2. **根库查找**：原生 `DartExecutor.DartEntrypoint(path, "overlayMain")` **只在根库（main.dart 对应的库）里查找入口函数**，不搜全 kernel。定义在独立库里的 `overlayMain` 永远找不到，报 `Could not resolve main entrypoint function` → engine 空壳。修复：main.dart L28-36 加根库转发函数：
   ```dart
   @pragma('vm:entry-point')
   void overlayMain() => overlay_entry.overlayMain();
   ```
3. **插件抢占缓存**：`flutter_overlay_window` 插件在主 Activity attach 时（`onAttachedToActivity`）就抢先创建 engine 塞进 `FlutterEngineCache` 的 `"myCachedEngine"`，且其 Dart 入口同样解析失败（空壳）。无障碍服务必须用独立缓存 key `shengwuji_accessibility_overlay`（[VolumeKeyAccessibilityService.kt:455](../../android/app/src/main/java/com/shengwuji/app/VolumeKeyAccessibilityService.kt)）

**诊断手法**：logcat 全历史 grep 入口函数的启动 print（`🚀 [overlayMain]`）——零命中即 Dart 从未执行；View 背景色可见 ≠ Flutter 在渲染。

### MethodChannel 三条

| Channel | 方向 | 用途 | 状态 |
|---|---|---|---|
| `com.shengwuji.app/accessibility_overlay` | **双向**（overlay Dart ↔ 原生服务） | Dart→原生：resizeOverlay / updateFlag / closeOverlay / **dartReady**（握手）/ copyText / shareText / **launchApp**（AI 对话拉起，见"卡片 AI 对话按钮"小节）；原生→Dart：**expand**（自动展开）/ **reset**（隐藏后复位）。服务端在 Kotlin L391-421 | ✅ 正常（2026-08-26 起双向） |
| `com.shengwuji.app/overlay_bridge` | ~~overlay Dart ↔ 主 isolate~~ | ~~queryDiaries 日记数据查询~~ | 🗑 **已废弃**（2026-08-24 改为 overlay engine 直连 sqflite，见"数据链路"小节） |
| 主 CHANNEL（MainActivity） | 主 Dart ↔ 原生 | ~~设置页 `showAccessibilityOverlay` 开关 → `Service.showOverlay()`~~ | 🗑 已废弃（2026-08-29 随 4 手势槽位重构删除 `showAccessibilityOverlay` / `hideAccessibilityOverlay` / `openOverlaySettings` 三个方法及设置页浮窗测试按钮；浮窗显示/隐藏只剩无障碍服务手势槽位一条链路） |

### 数据链路（2026-08-24 起：直连 sqflite）

展开面板的日记列表**不走 MethodChannel**——overlay engine 直接实例化 `DbHelper` 查 `items.db`：

- [lib/overlay/overlay_data_client.dart](../../lib/overlay/overlay_data_client.dart)：`getDiaries()` → `DbHelper().getDiaries()`，失败 rethrow（面板 UI 有错误态 + 点击重试）
- 可行性依据：`FlutterEngineGroup.createAndRunEngine` 默认自动注册所有插件，overlay engine 上 sqflite 原生侧就绪；`DbHelper` 无 context / SharedPreferences 依赖，可直接复用
- **独立性**：主 engine 随 Activity 生死，overlay engine 查库不依赖主 App 存活（App 被杀后浮窗仍有数据）
- **新鲜度（2026-09-04 起：DiarySyncBridge 计数器桥）**：跨 engine 无推送通知，靠 SharedPreferences 计数器脏检查同步（复用 `is_recording` / `is_pro_unlocked` 同款 prefs 桥惯例）：
  - **写方**：任一 engine 写 diary 成功后 `DiarySyncBridge.bump()`（key `diary_change_counter`，int 单调递增；bump 内先 reload 再 +1 防双 engine 并发覆盖）。悬浮窗侧挂点：归档/恢复、删除、标注、编辑保存、新增笔记、占位行删除（overlay_home.dart）+ 语音速记占位插入与转写回填（overlay_voice_memo.dart）；主 App 侧挂点：diary_tab.dart 全部 insert/update/delete/archive 写点
  - **读方（双向）**：主 App 日记页 resumed 时 `_syncDiaryChangesFromOverlay()` reload 比对内存计数，变了才 `refreshList()`——用户从悬浮窗记完回主 App 无感出新卡；悬浮窗 `_expand()` 调 `_syncDiariesIfChanged()` 替代旧的无条件重查，无变更零开销
  - 计数器而非时间戳：防同毫秒覆盖丢信号；读取方记录计数在查库**前**——查库期间另一 engine 再 bump 时本批数据未含该变更，记旧值下次仍触发刷新（不丢变更）
  - 详见 [lib/utils/diary_sync_bridge.dart](../../lib/utils/diary_sync_bridge.dart)
- **并发**：双 engine 各持 SQLite 连接读写同一文件，Android 默认 busy timeout 2.5s 可挡短暂锁；浮窗当前只读

### 展开面板尺寸：哨兵值机制（2026-08-25）

展开面板**窗口铺满全屏**（宽高均 MATCH_PARENT），窗口内的画面布局由 Dart 决定：

- Dart（[overlay_state_controller.dart](../../lib/overlay/overlay_state_controller.dart) `panelSize`）：展开态返回 `Size(-1, -1)`；收起态返回 28×88dp（具体值）
- Kotlin（`resizeOverlay`）：`width/height == -1` → 均 `MATCH_PARENT` 铺满全屏
- **面板占屏宽 72%** 由 Dart 侧 `_buildPanel` 的 `LayoutBuilder + Stack` 绘制控制（空白区 `Positioned.fill` 垫满窗口 + 72% 宽面板贴右上、高度随内容自适应），比例唯一真值是 `OverlayConstants.expandedWidthRatio`（0.72），Kotlin 不再持有比例
- gravity 随高度切换：展开（MATCH_PARENT）用 `Gravity.END`；收起（88dp 把手）用 `Gravity.CENTER_VERTICAL or Gravity.END`（把手必须垂直居中）

**根因（为什么不能在 Dart 侧算尺寸）**：overlay engine 里 `PlatformDispatcher.instance.views.first.physicalSize` 是**悬浮窗窗口自身尺寸**而非屏幕尺寸——收起态窗口只有 28×88dp，Dart 侧算"屏高 × 0.85"会得到 88×0.85≈75dp 的扁条窗口，导致展开面板一直是 ~300×75dp（一条卡片都放不下的那个 bug）。屏幕真实尺寸只有原生 WindowManager 拿得到。

### 展开面板视觉（2026-08-25，闪念胶囊原型）

- **窗口铺满全屏、面板背景透明、高度随内容自适应**：Stack 结构——空白区 `Positioned.fill` 垫满整个窗口，72% 宽面板贴右上（`Column mainAxisSize.min` + `ListView shrinkWrap` 包 `Flexible`）：条目少时面板只包住卡片，条目多时被窗口高度约束、列表内部滚动。透明背景上不能留 boxShadow（会画出奇怪阴影框），层次感由卡片自身阴影提供；FLAG_LAYOUT_NO_LIMITS 会画到状态栏/导航栏下，头部 top padding 40dp、列表 bottom padding 48dp 固定避让（overlay 窗口拿不到系统 insets）
- **空白区手势**（`_buildBlankArea`，垫满窗口、面板以外全部区域）：点击 → 收起；任意方向水平滑动 >4dp 松手 → 收起（`primaryDelta.abs() > 4`，左滑右滑均可，2026-08-28 起；标记字段 `_willCollapse`）。空白区事件能被 Flutter 收到的前提就是**窗口本身铺满全屏**——窗口外区域 Flutter 拿不到事件
- **⚠️ 两个触摸相关的关键事实**（2026-08-25 教训）：
  1. GestureDetector 包透明区域（如 `SizedBox.expand`）必须显式 `behavior: HitTestBehavior.opaque`，默认 `deferToChild` 对透明 child 永远不命中 hit-test，手势静默失灵（曾导致空白区收不起、展开即整屏触摸死锁，`47b1c87` 修复）
  2. 展开态窗口没有 `FLAG_NOT_TOUCHABLE`，FlutterView 在窗口层面一律消费触摸（与 Dart 层 hit-test 结果无关）——展开面板本质是**模态层**，底下 App 收不到触摸，用户唯一自救通道是空白区收起手势；未来若要触摸透传，需原生侧动态加 `FLAG_NOT_TOUCHABLE` + 空白区手势改原生处理
- 卡片（[overlay_diary_card.dart](../../lib/overlay/widgets/overlay_diary_card.dart)）：横向长纵向短胶囊，固定高 46dp 全圆角，白字单行左对齐（字号 15），间距 10dp，轻阴影；1dp 细白描边（`OverlayConstants.cardBorderWidth`，2026-09-04 对齐闪念原型"彩色胶囊+白描边+柔影"分层——原型采样的 3 层边缘像素是白边两侧抗锯齿混色非 3 条描边。⚠️ Border.all 计入 Container 有效内边距，宽度/高度估算三处已同步 ±2×border 补偿，收起态内层 minHeight 补偿维持总高=46 不变量）
- **收起态内容纵向居中**（2026-09-02 贴顶回归修复）：靠收起分支 Row 外包 `ConstrainedBox(minHeight: cardHeight)` 撑满胶囊高度实现（Row 自身 crossAxisAlignment.center 居中）——外层 Switcher 的 Stack 锚点 topRight 只服务过渡动画的旧内容顶缘连续，不能让裸 Row 直接靠它定位（Row 比 Stack 矮会贴顶，a36800b 引入、真机反馈"胶囊变粗内容挤在顶部"）
- **卡片宽度自适应**：`BoxConstraints(minWidth: 60, maxWidth: 面板宽-28)`——短内容短胶囊、超长省略号，左对齐排列
- **固定默认色 + 标注换色**（2026-09-02 起，替代旧的 index % 6 轮换色板）：无标注活跃卡恒用 `OverlayConstants.defaultCardColor`（#6F9AF0）；标注后整卡换标注色（映射唯一真值在 [lib/utils/diary_tag.dart](../../lib/utils/diary_tag.dart) 的 `DiaryTag.colors`，主 App 日记页小色点共用）；已归档卡片不参与取色，固定灰 + 删除线（归档卡允许标注入库，恢复后显示标注色）。展开卡底部按钮条末尾为标注入口（`Icons.label_outline`），点击进入标注选择态后底行整行替换为「❗ ⭐ 💡 ✗返回」（对齐删除确认态的整行替换先例），详见"卡片标注"小节
- 头部：保留"随手记"标题 + 收起按钮（原型里的黑色半透明工具条暂不做）
- 日记列表区域限高约 10 张卡高度（`OverlayConstants.panelListMaxHeight`），超出部分区域内滚动查看全部记录（2026-09-02 起；原为 `maxVisibleDiaryCards` 条数硬截断只显示最新 10 条）

### 展开/收起推屏滑动动画（2026-08-28）

收起时卡片**横向滑出屏幕右缘渐隐**、随后把手浮现；展开时面板从右缘滑入渐显、把手渐隐——推屏效果，仿佛卡片住在屏幕右侧的空间可滑进滑出。

**为什么必须编排 resize 时机（折返跑根因）**：旧实现 `_collapse()` 同步触发 `controller.collapse()` → `_onStateChanged` 同步块里发 `resizeOverlay(28,88)` + setState。原生 `updateViewLayout` 瞬时缩窗 + gravity 从 `END` 跳 `CENTER_VERTICAL|END`（顶边 y=0 → 屏中），全屏帧的面板内容被压进 28×88 小窗口；且 resize 消息异步落地期间 Dart 已换枝渲染裸把手（28×88 无定位包裹）画在仍全屏的帧**左上角**一瞬——两段跳变叠加成"先缩小跑左上角、再折返回把手"的折返跑。

**编排原理：窗口尺寸切换只发生在动画边界**（动画期间窗口始终保持全屏）：

- `_PanelAnimPhase { idle, expanding, collapsing }` 相位机，不变量：`phase != idle ⇒ controller.isExpanded`（窗口全屏）
- 单 `AnimationController`，value 语义 = 面板滑入进度（1=就位，0=整块滑出窗口右边界）；`forward()` 滑入（easeOutCubic）/ `reverse()` 滑出（easeInCubic），中断从当前进度反向续播（快速点按零 resize 抖动）；时长 `OverlayConstants.panelSlideDuration`（240ms）
- **收起**：`_collapse()` 只置 phase=collapsing + `reverse()`（面板 FractionalTranslation 右移 + Opacity 渐隐，叠加把手在右缘垂直居中渐显）→ `dismissed` 边界回调（`_onPanelAnimStatus`）才调 `controller.collapse()`（触发 resize(28,88)，此刻窗口里只剩右缘居中把手 = 新窗口落点，位置连续）+ `_scheduleAutoHide()`（其 isCollapsed 检查此刻才通过）
- **展开**：`_expand()` 先 value=0 + phase=expanding，再 `controller.expand()`（resize 全屏，首帧渲染"面板全隐+把手渐显位"初始位姿，两种窗口尺寸下像素一致不闪现），最后 `forward()` 滑入
- **防左上角跳变**：build 的收起分支把手包 `Align(centerRight)`——窗口=把手尺寸时恒等，仅 resize 未落地的一两帧把把手钉在全屏帧右缘垂直居中
- **动画层结构**（`_buildPanel` Stack）：空白区垫底（动画中可点 = 中断收起入口）→ 面板 `AnimatedBuilder`（child 缓存 IgnorePointer+SizedBox+Column 整块，builder 只包 FractionalTranslation + Opacity，tick 不重建 ListView）→ 动画期间叠加把手（`if (phase != idle)` 条件渲染，Align centerRight + 1-t 渐显，最上层）
- **边界 guard**：`_resetFromNative`（窗口已移除）stop + phase 先归 idle + value=0（吞掉 value setter 补发的 dismissed 回调，不重放缩窗链）；`_onVoiceMemoChanged` 进入录音/转写时冻结动画（防 dismissed 回调把语音胶囊窗口 resize 回把手）；`_expand` 的"稳定展开态再展开"分支防御性 `resizeOverlay(-1,-1)`（语音转写完成路径 controller 幂等不 resize，顺带修复"从展开态录音、转写完成后窗口卡胶囊尺寸"既有隐患）
- **手势**：空白区点击 / 任意方向水平滑动 >4dp 松手触发动画收起；动画中点渐显把手 = 中断反向滑回

### 触发与生命周期（2026-08-26 改版：召唤式交互；2026-08-29 起随音量键手势槽位重构改配置方式）

平时完全无浮窗（零打扰零误触），交互矩阵：

| 动作 | 行为 |
|---|---|
| 长按音量键 500ms（长按槽位动作=显示悬浮窗，隐藏态） | 唤醒屏幕 + 100ms 震动 → 浮窗出现**并自动展开面板** |
| 悬浮窗显示中（把手/面板态）长按同一音量键 | 50ms 短震 → **立即彻底隐藏**（toggle 兜底，不用等自动隐藏） |
| 收起面板（空白区点击/任意方向滑动/收起按钮，推屏滑出动画） | 回到把手，**10s 后自动彻底隐藏**（设置页可选 5/10/30s 或永久常驻） |
| 时限内再展开 | 取消自动隐藏计时（把手不会中途消失） |

- 长按链路（Kotlin `triggerShowOverlay`）**直连本服务 `showOverlay(autoExpand = true)`**。旧链路是 startActivity 拉起主 App → 主 engine → flutter_overlay_window 插件（小米被拦的那条路），已废弃——MainActivity 侧 `show_overlay` intent 分支保留但无生产调用方，待后续清理
- toggle 判断必须在 `showOverlay()` 之前做（`showOverlay` 开头会强制重建已存在的浮窗，否则"已显示时长按"会变成重建而非隐藏）
- 触发配置：设置页"音量键快捷操作"分区将任一**长按槽位**（音量加/减）动作设为「显示悬浮窗」（`show_overlay`，prefs key `volume_gesture_long_press_up` / `volume_gesture_long_press_down`）。Service Kotlin 手势状态机 `executeGestureAction` 分发到 `triggerShowOverlay`，每次按键直接读落盘 prefs，详见 @volume-key-shortcuts.md（旧的 `overlay_volume_up_long_press` 开关 / `overlay_volume_up_action` 动作选择器已随 4 槽位重构移除，仅作迁移 fallback 输入源）

### 自动展开：dartReady 握手（2026-08-26）

原生 → overlay Dart 的消息（expand/reset）依赖 Dart 侧 handler 已注册。engine 冷启动时 Dart 入口刚起步，原生 `invokeMethod` 会被 Dart 静默丢弃（不 crash），因此用握手兜底：

- **Dart**（overlay_home.dart initState L42-50）：`setupNativeChannel` 注册 handler → 发 `dartReady`
- **Kotlin**（Service.kt）：`dartReady` 字段语义 = "Dart handler 已注册" = "engine 是复用的"
  - `getOrCreateOverlayEngine()` **复用分支置 true**（关键：无障碍 service 可能被系统销毁重建、字段清零，而 Dart 只在 initState 发一次 dartReady——不在复用分支重新置位，新 service 实例的自动展开会永远挂起）
  - 新建分支置 false；`showOverlay(autoExpand=true)` 时未就绪则挂起 `pendingAutoExpand`，收到 dartReady 后补发

**⚠️ 坑：展开态隐藏后 Dart 状态残留**。hideOverlay 时 Dart 停留在 expanded；下次 showOverlay 以 28×88 重建后原生发 expand，`controller.expand()` 幂等**不触发 notifyListeners** → `resizeOverlay(-1,-1)` 永远不被调 → 窗口卡死把手尺寸。修复（双保险）：

1. `hideOverlay()` 移除窗口后主动 `invokeMethod("reset")`（L484，统一覆盖 toggle 隐藏 / closeOverlay / onDestroy 三条路径），Dart 收到后取消计时 + `collapse()`（触发的 resize(28,88) 被原生 `overlayView ?: return` 空守卫吞掉，安全）
2. Dart 的 onExpand 分支防御性先 `resizeOverlay(-1, -1)` 再 `_expand()`

### 自动隐藏（收起后延时彻底关闭）

- Dart 侧 `_scheduleAutoHide()`（overlay_home.dart L413）：收起时排定 Timer，到期 `closeOverlay()` → 原生 hideOverlay → 发 reset 复位，链路自洽（2026-08-28 起调用点移入动画 dismissed 回调——收起滑出到位才算"收起态"，计时整体后移 240ms，语义不变）
- 时长 key `overlay_auto_hide_seconds`（默认 10，设置页 5/10/30s + 「永久」ChoiceChip，同音量键手势选择器的样式；「永久」写哨兵值 `OverlayConstants.autoHideNeverSeconds`（-1）进同一 key，`_scheduleAutoHide` 读到即 return 不起 Timer——收起态把手常驻，改回限时档后下次收起自然恢复计时）。**每次收起时 `await prefs.reload()` 再读**——主 engine 写、overlay engine 读，两个 isolate 的 prefs 内存缓存隔离，不 reload 读到旧值
- 竞态防护：`_hideScheduleGeneration` 计数——reload 的 await 期间用户又展开/收起，generation 不一致则本次排定作废，避免"展开的面板被误关"

## 关键文件与行号（2026-08-29 核对）

### lib/main.dart
- **L23-26**：保活 import `overlay/overlay_main.dart as overlay_entry`
- **L28-36**：根库转发函数 `overlayMain()`（核心修复）

### lib/overlay/overlay_constants.dart
- **L8 / L11**：`handleWidth = 28` / `handleHeight = 88`（dp，闪念胶囊尺寸）
- **L14**：`handleLabel = '记一笔'`（竖排文案，改文案只动这里）
- **L17 / L20**：`handleIconSize = 16.0` / `handleFontSize = 11.0`
- **L73**：`panelSlideDuration = 240ms`（面板推屏滑动动画时长）
- **L136 / L142**：`voiceMemoWindowWidth = 312` / `voiceMemoWindowHeight = 64`（语音速记冷启动隐藏窗口直建尺寸，Kotlin 侧有硬编码副本须同步）

### lib/overlay/overlay_home.dart
- **L31 相位枚举**：`_PanelAnimPhase { idle, expanding, collapsing }`（推屏动画编排，见"展开/收起推屏滑动动画"小节）
- **L101 揭示门字段**：`_revealGatePending`（隐藏窗口揭示门，第四轮修复语义见"冷启动隐藏窗口"小节；旧 `_revealGateConstraints` 约束基准已删除）
- **initState L140 起**：动画控制器创建 + `setupNativeChannel`（onExpand 防御性 resize + `_expand()`；onReset → `_resetFromNative`；**onStartVoiceMemo L183 起——hiddenReveal 挂门在 handler 顶部**）+ `notifyDartReady()` 握手
- **L567 `_onPanelAnimStatus`**：动画边界回调——dismissed 才调 `controller.collapse()`（缩窗）+ `_scheduleAutoHide()`，completed 回稳定展开态
- **L603 / L660**：`_expand`（主路径 / collapsing 中断反向 / expanding 幂等 / 稳定展开态防御重播——语音转写完成路径）/ `_collapse`（反向收起，缩窗延迟到 dismissed）
- **L684 `_resetFromNative`**：reset 复位（开头三行动画跳终态：stop → phase 归 idle → value=0；含清揭示门）
- **L722 `_scheduleAutoHide`**：reload 读配置 + generation 防竞态 + Timer 到期 closeOverlay
- **build 揭示门/硬不变量（L761-777 附近）**：挂门短路（录音态首帧摘门 + 发 voiceMemoUiReady）+ idle 态胶囊窗硬不变量渲染空白
- **L819 `_buildHandle`**：收起态胶囊把手
  - 全圆角 `BorderRadius.circular(handleWidth / 2)`（半径随宽度自适应）
  - `Icons.bolt` 闪电图标（"闪念"语义）
  - `handleLabel.characters.join('\n')` 中文逐字竖排（`String.characters` 由 material.dart 透出，无需额外 import）
  - 手势：onTap 展开、onHorizontalDrag 左滑 >4dp 松手展开
- **`_buildPanel`（L885 起）**：展开态 Stack 布局——`Positioned.fill` 空白区垫底 + 贴右上的自适应面板包动画层（AnimatedBuilder child 缓存整块 + FractionalTranslation/Opacity）+ 动画期间叠加把手（header"随手记"+ 收起按钮，top padding 40 避状态栏；日记 ListView `shrinkWrap` 高度收缩，bottom 48 避导航栏，条目多时内部滚动）

### lib/overlay/overlay_data_client.dart
- overlay isolate 的数据客户端，直连 sqflite（`DbHelper().getDiaries()`）。旧的跨 engine 服务端 `overlay_data_bridge.dart` 已删除

### android/.../VolumeKeyAccessibilityService.kt
- **L72-73 常量**：`VOICE_MEMO_OVERLAY_WIDTH_DP = 312` / `VOICE_MEMO_OVERLAY_HEIGHT_DP = 64`（隐藏窗口直建尺寸硬编码副本，唯一真值在 Dart overlay_constants.dart，改尺寸须双侧同步）
- **L110-121 字段**：`dartReady` / `pendingAutoExpand`（握手状态，见"自动展开"小节）/ `pendingVoiceMemoReveal`（隐藏窗口标记，L129 附近）
- **L377 `vibrateOneShot()`**：单次震动封装（triggerQuickRecord / triggerShowOverlay 共用，含 SDK < O 降级）
- **L454 `triggerShowOverlay()`**：长按直连入口——toggle 判断 + `showOverlay(autoExpand = true)`，已废弃 startActivity 绕路
- **L640 `showOverlay(autoExpand, hidden)`**：显示浮窗；hidden=true 时**直建胶囊尺寸隐藏窗口**（addView 312×64 + alpha=0 + NOT_TOUCHABLE）；`wm.addView` 后 `if (autoExpand) notifyDartExpand()`
- **L671 起**：accessibility_overlay channel 服务端（resizeOverlay / updateFlag / closeOverlay / **dartReady** / **voiceMemoUiReady**——揭示延迟 2 vsync）
- **L804 `notifyDartExpand()`**：dartReady 直接发 expand，否则挂起 pendingAutoExpand
- **L816 `hideOverlay()`**：removeView + detach + **发 reset 复位 Dart**（须在 channel 引用置 null 之前），不销毁 engine（热启动复用）
- **L847 `getOrCreateOverlayEngine()`**：独立缓存 key `shengwuji_accessibility_overlay`；FlutterEngineGroup + DartEntrypoint("overlayMain") 创建；**复用分支置 dartReady=true / 新建置 false**
- 窗口 LayoutParams：TYPE_ACCESSIBILITY_OVERLAY，`Gravity.CENTER_VERTICAL or Gravity.END` 右缘垂直居中，非隐藏路径初始尺寸 dpToPx(28)×dpToPx(88)（隐藏路径直建 312×64），FLAG_NOT_FOCUSABLE + FLAG_LAYOUT_NO_LIMITS 等

## 已知问题

### ✅ 已修：展开面板日记列表为空（原 queryDiaries 跨 engine 不通）

原症状：

```
❌ [OverlayDataClient] queryDiaries 失败: MissingPluginException
   (No implementation found for method queryDiaries on channel com.shengwuji.app/overlay_bridge)
```

根因：`overlay_bridge` 服务端（主 engine）与客户端（overlay engine）在两个独立 FlutterEngine 里，**messenger 互不相通**，MethodChannel 消息到不了对面。

**最终修法（2026-08-24，第三条路）**：放弃跨 engine 通道，overlay engine 直连 sqflite 查库（见"数据链路"小节）。悬浮窗由此独立于主 App 存活；主 engine 侧 `OverlayDataBridge` 的注册代码（原 main.dart）与文件已一并移除。

### 其他待优化

- [main.dart `_showFloatingOverlay`](../../lib/main.dart)（L285-314 附近）：旧 flutter_overlay_window 插件路径仍在（小米被拦后的备用链路），可考虑清理
- MainActivity 的 `show_overlay` intent 旧链路（`handleShortcutIntent` / `notifyFlutterShowOverlay`）：2026-08-26 长按直连改造后无生产调用方，可一并清理
- `resizeOverlay` 的 `enableDrag` 参数被原生忽略，整窗拖动未实现
- 收起/展开切换时窗口尺寸跳变无动画过渡
- 左右侧切换（计划中）：胶囊已按停靠边贴屏幕边缘对齐（当前右侧，见 overlay_diary_card.dart 卡片级 Align），切换时需镜像三处：Kotlin 窗口 gravity（END→START）、展开面板 Stack 的 Alignment.topRight→topLeft、卡片对齐 centerRight→centerLeft

## 验证方法

1. 模拟器/真机开无障碍服务（系统设置 → 无障碍 → 声物记），设置页"音量键快捷操作"分区将任一长按槽位动作设为"显示悬浮窗"
2. 触发：长按对应音量键 500ms
3. 成功标志（logcat 过滤 `Accessibility`）：
   ```
   ✅ [Accessibility] 已创建 overlay engine
   🚀 [overlayMain] 悬浮窗引擎已启动
   ✅ [Accessibility] 无障碍浮窗已显示 (TYPE_ACCESSIBILITY_OVERLAY + Flutter)
   ✅ [Accessibility] 长按音量上键：悬浮窗已显示(自动展开)
   ⏳ [Accessibility] Dart 未就绪，自动展开请求已挂起   ← 仅首次冷启动，dartReady 后补发
   ```
4. 交互回归点：
   - 长按 → 面板**直接展开**（非把手）；点空白区收起 → 10s 后彻底消失；时限内再点把手 → 展开且不中途消失
   - 显示态再长按 → 立即彻底隐藏（短震）；再长按 → 重新展开，首帧把手随即铺满（**无残影/卡把手尺寸** = 坑 2 回归点）
   - 杀无障碍服务再重开（service 重建）→ 长按仍能自动展开（**坑 1 回归点**：dartReady 复用分支置位）
   - 锁屏熄屏长按 → 亮屏 + 面板可见
5. 展开面板显示主 App 已有日记；主 App 新写日记 → 浮窗收起再展开即可见；杀掉主 App 进程后浮窗仍能查到数据

## 语音速记（2026-08-27）

> 开启方式：设置页"音量键快捷操作"分区将任一**长按槽位**（音量加/减）动作设为 **「悬浮窗录音」**（`overlay_record`，prefs key `volume_gesture_long_press_up` / `volume_gesture_long_press_down`，槽位矩阵详见 @volume-key-shortcuts.md）。无障碍 Service 的 `getLongPressAction()` 每次按键直接读落盘 SharedPreferences 分流，无需 MethodChannel 通知。

悬浮窗形态的"闪念"语音速记：不进主 App、不解锁思路，长按音量键即录，松手转写落库。录音期间浮窗为**变长录音胶囊**（`OverlayVoiceMemoBar`：宽度随秒数增长 80dp + 40dp/s、上限 300dp，显示 mm:ss 计时），停止后切**三点跳动胶囊**（转写中），转写完成回到展开面板出新卡。

### 交互矩阵

| 动作 | 行为 |
|---|---|
| 隐藏态长按音量键（长按槽位动作=悬浮窗录音） | 唤醒屏幕 + 100ms 震 → 浮窗出现（**冷启动隐藏窗口**，见下）+ `startVoiceMemo` → Dart 开麦录音 |
| 录音中再长按 | 50ms 短震 → `stopVoiceMemo` → Dart 停麦转写（**toggle 状态机**：`voiceMemoActive` 以 Dart 回执复位，3s 超时兜底） |
| 录音达 300s（5 分钟）上限 | Dart 侧上限 Timer 自动停（防按忘；原对齐锤子闪念胶囊 60s 设计，后放宽到 5 分钟），流程同主动停止 |
| 转写中隐藏浮窗 | **数据不丢**——WAV 已落盘 + 占位行已入库，转写 Future 在后台 isolate 继续跑完回填 |
| 主 App 正在录音时长按 | **麦克风互斥让位**（三道检查）：Kotlin `isRecording()` 读 `flutter.is_recording` → 退回"显示浮窗"；Dart `start()` 里 reload 再查 → 让位 false；主 App 侧 `diary_tab.startListening` / `record_tab._enterMoveMode` 第三道守卫 → SnackBar「悬浮窗正在录音，请先结束」+ return（防 Android 10+ 并发采集静默一路） |

### 冷启动隐藏窗口（2026-08-29 第四轮修复：直建胶囊尺寸根治把手闪现）

语音速记从隐藏态冷启动时走 `showOverlay(hidden = true)`。**第四轮修复的根治思路：窗口直接以胶囊尺寸（312×64）创建隐藏窗口**——把手尺寸的窗口在此路径中不存在，无 resize、无把手帧，把手像素物理上不可能出现；同时删除依赖"窗口约束变化检测"的摘门逻辑（它有"resize 先落地、门后挂"的时序缺陷，基准会被记成胶囊尺寸导致门永不摘）。

```
showOverlay(hidden=true) → 窗口直接以胶囊尺寸 312×64 立即 addView（Kotlin 常量
                           VOICE_MEMO_OVERLAY_WIDTH_DP/HEIGHT_DP，唯一真值在 Dart 侧
                           overlay_constants.dart voiceMemoWindowWidth/voiceMemoWindowHeight），
                           alpha=0 + FLAG_NOT_TOUCHABLE（不可见、不挡触摸），
                           置 pendingVoiceMemoReveal
→ Dart engine 冷启动（~1.8s）全程在不可见状态完成；engine attach 瞬间 /
  startVoiceMemo 到达前的 pre-gate 帧（state 仍 idle）由 build 的硬不变量渲染
  纯透明空白（把手高度 88 > 窗口高度 64 永不合法，见下）
→ onStartVoiceMemo handler 顶部（hiddenReveal=true）立即挂揭示门——门挂上之前的
  await 链（权限/prefs/开流，20~80ms）期间 state 仍是 idle，挂门期 build 渲染
  纯透明空白（SizedBox.shrink），把手/胶囊像素不进帧
→ 录音开始（state 离开 idle）→ build 挂门短路处摘门 + 该帧构建完发 voiceMemoUiReady
  （确定性事件锚定"录音态首帧已构建"——窗口本就是胶囊尺寸，本帧即正确尺寸帧）
→ 原生收到后延迟 2 个 vsync（Choreographer.postFrameCallback 嵌套两层）才
  alpha=1 + 清 NOT_TOUCHABLE 揭示——构建完 ≠ 已呈现，光栅化 + SurfaceFlinger
  合成可能晚 1~2 vsync，多等一帧是便宜保险；首个可见帧即正确尺寸录音胶囊
```

Dart 侧另有一条不依赖时序的**硬不变量**（build 顶层，语音速记分支之前）：`_voiceMemo.state == idle && constraints.maxHeight < handleHeight` → 渲染纯空白。把手（88dp 高）永远不可能合法出现在胶囊高度（64dp）的窗口里，attach 瞬间/消息到达前的 pre-gate 帧物理上渲染不出把手。

清空方：`voiceMemoUiReady` 揭示 / `hideOverlay` / `destroyOverlayEngine`；防御兜底：pending 期间收到展开尺寸（width==-1，转写完成切面板）时 `resizeOverlay` 顺带揭示，防 voiceMemoUiReady 漏收后面板永远不可见；`triggerShowOverlay` 的 toggle 判断要求 `!pendingVoiceMemoReveal`（隐藏中用户不可见，不算"已显示"）。`_onVoiceMemoChanged` 的 `resizeOverlay(312,64)` 保留不动——把手在屏上开录的暖路径仍需要；冷路径是同尺寸 updateViewLayout，幂等无害。

历史包袱（第一~三轮帧级修复均未根治，详见 [悬浮窗录音闪烁.md](悬浮窗录音闪烁.md)）：第一轮 hiddenReveal 负载 + 揭示门（约束变化检测摘门）；第二轮懒基准 + 挂门期渲染空白；第三轮（提交 2034073）延迟 addView 方案引发进程级崩溃被废弃（见下）。第四轮换思路：不再修"把手帧和 resize/揭示时机的赛跑"，而是让把手尺寸的窗口根本不存在。

**⚠️ 揭示竞态修复（2026-08-29，hiddenReveal 负载 + 揭示门）**：首版隐藏窗口方案（a2b7752）里 Dart 在 `voiceMemoStarted` 回执后无条件 `addPostFrameCallback` 发 `voiceMemoUiReady`。真机实测**同一构建两次运行日志序列完全相同，一次把手一闪而过、一次干净**——确诊为呈现层竞态，根因有两层：

1. `addPostFrameCallback` 只保证帧**构建完**，不保证**已呈现**（光栅化 + SurfaceFlinger 合成还要晚 1~2 个 vsync）
2. 发信号时窗口 resize（28×88→312×64）尚未回传 Dart，刚构建的胶囊帧是按**旧尺寸**渲染的，正确尺寸帧要等 viewport metrics 回传后再构建——Kotlin 翻 alpha 时 SurfaceFlinger 手里的缓冲区是把手旧帧还是胶囊新帧纯属调度运气

修法三件套：

- **Kotlin `startVoiceMemo` 带 `hiddenReveal` 负载**（两处发送点：`notifyDartStartVoiceMemo` 直发 + dartReady 握手补发 `pendingVoiceMemoStart`）：告知 Dart 当前是否为隐藏窗口，Dart 据此决定揭示信号的发送时机
- **Dart 揭示门**（overlay_home.dart `_revealGatePending` / `_revealGateConstraints`）：hiddenReveal=true 时不在录音开始即发信号，挂门等 `_maybeAdvanceMetricsStage`（每次 build 顶层执行）检测到窗口约束已从挂门基准变为胶囊尺寸——锚定"正确尺寸帧已构建"这个确定性事件，该帧构建完（postFrameCallback）才发 `voiceMemoUiReady`。基准约束在 `onStartVoiceMemo` 入口（`start()` 之前）快照——start 尾部 notifyListeners 同步触发 resize，等 await 返回再快照可能已错过约束变化。防御性摘门：`_onVoiceMemoChanged` 进入转写态时门还挂着（秒停极端时序）立即发信号，防窗口永远隐形（watchdog T3 66s 才兜底太久）
- **Kotlin 揭示再延迟 1 个 vsync**：`voiceMemoUiReady` 分支的翻 alpha 动作包进 `Choreographer.postFrameCallback`（兜光栅化/合成残余延迟），回调内二次检查 `pendingVoiceMemoReveal`（这一帧内可能已被 hideOverlay 清掉）

把手在屏上的原地切换路径（hiddenReveal=false，含旧版本 Kotlin 发 null 的兼容）维持 a2b7752 原行为立即发——Kotlin 侧非 pending 时收到是 no-op。

**⚠️ 揭示竞态第二轮修复（2026-08-29，懒基准 + 挂门期渲染空白）**：首版揭示门真机实测仍约 50% 概率把手一闪而过。确诊两个残留洞：

1. **基准约束跨会话陈旧**：`onStartVoiceMemo` 挂门时快照 `_lastWindowConstraints`，但 overlay engine 常驻、State 跨窗口会话存活——上次若从展开面板（全屏尺寸）直接隐藏，该值停在全屏；本次挂门基准错误，首个把手帧（28×88）≠ 全屏被误判"约束已变"→ 门提前摘 → 把手闪。上次若从把手态自动隐藏则基准恰好正确 → 不闪——这精确解释了 50/50 现象
2. **把手像素在挂门期间仍存在**：即使门时机正确，揭示瞬间 SurfaceFlinger 缓冲区内仍可能是把手旧帧——呈现层竞态无法 100% 靠时序兜住

修法三件套（均在 overlay_home.dart）：

- **挂门基准改懒记录**：挂门时 `_revealGateConstraints` 直接置 null，由 `_maybeAdvanceMetricsStage` 的 lazy 补记分支以挂门后**首个观测约束**为基准（此时 resize 未落地，首个观测=把手尺寸本身）——"size != 基准"在把手帧上恒 false，门不可能在把手帧误摘，只有胶囊尺寸 resize 真正落地才触发摘门+发信号
- **挂门期间渲染纯透明空白**（关键兜底）：build 中 `_maybeAdvanceMetricsStage` 调用**之后**加 `if (_revealGatePending) return const SizedBox.shrink();`——挂门期间把手/胶囊像素都不进任何一帧，即使揭示信号与翻 alpha 仍有竞态，用户看到的也是无害空窗随后胶囊出现，竞态从"闪把手"降级为"无害的空"。放在约束检测之后，不破坏门的检测链路
- **`_resetFromNative` 清门**：窗口被原生移除后 `_revealGatePending=false` + `_revealGateConstraints=null`，不留残留门影响下个会话（挂门期渲染纯空白，若带到下次 showOverlay 会导致把手永不渲染）

**⚠️ 事故教训（2026-08-29，提交 2034073 引入的进程级崩溃）**：本小节前身是"延迟 addView"方案——`showOverlay(deferAddView=true)` 创建 FlutterView 但**跳过 `wm.addView`**，等 Dart 首个 resizeOverlay 才落地。真机实测崩溃：

```
java.lang.NullPointerException: Attempt to invoke interface method
'boolean android.view.ViewParent.requestSendAccessibilityEvent(...)' on a null object reference
at io.flutter.view.AccessibilityBridge.sendAccessibilityEvent(AccessibilityBridge.java:2090)
→ [FATAL] Check failed: fml::jni::CheckException(env). → SIGABRT 杀进程
```

根因：FlutterView 未 attach 到窗口时 `getParent()` 为 null，Dart engine 启动后推送 semantics 更新，AccessibilityBridge 发事件即 NPE → JNI fatal → 进程死。**铁律：FlutterView 在 engine 渲染期间必须 attach 到窗口**——"先建后挂"类方案一律不可行，想藏窗口只能用 alpha/flags（本方案）。

**附带修复**：崩溃还暴露 `flutter.is_recording` 脏标志问题——进程被 SIGABRT 杀掉时若录音标志为 true 会永久残留落盘，下次语音速记被 `isRecording()` 误判"主 APP 录音中"让位。修复：新增 `ShengwujiApplication`（Application 子类，manifest `android:name=".ShengwujiApplication"`），进程启动时无条件清 `flutter.is_recording=false`——进程刚启动时本进程绝无录音在进行，清零无竞态。

### 四级 watchdog（救生链）

录音是系统级资源，Dart isolate 卡死时不能让麦克风永久卡住。时间轴相对录音启动时刻：

| 级别 | 时刻 | 执行方 | 判定条件 | 动作 |
|---|---|---|---|---|
| T0 | +300s | Dart（overlay_voice_memo） | 录音仍在进行 | Timer 到期自动 `stop()`（正常上限路径） |
| T1 | +300s | Kotlin | `voiceMemoActive` 仍 true | 补发 `stopVoiceMemo`（Dart 的 T0 可能没收到/没执行） |
| T2 | +303s | Kotlin | 仍 true | 再补发一次 `stopVoiceMemo` |
| T3 | +306s | Kotlin | 仍 true（判定 Dart isolate 卡死） | `hideOverlay()` 纯 Kotlin 移窗，桌面立即可用 |
| T4 | +316s | Kotlin | `is_recording` 仍 true（**读落盘 prefs，不信任回执**） | `destroyOverlayEngine()` 销毁 overlay engine 释放麦克风（record 插件随 engine destroy detach） |

挂钩规则：`voiceMemoStarted` 回执**不取消** watchdog（T1 计时必须跑满——用户可能按满上限时长）；`voiceMemoStopped` / `voiceMemoFailed` 回执和 stop 分支 3s 超时强制清时 cancel；`onDestroy` 也 cancel（防 Runnable 泄漏到已销毁的 service 实例）。

> 上限时长唯一真值在 Dart 侧 `OverlayConstants.voiceMemoMaxSeconds`（300s），Kotlin `VOICE_MEMO_MAX_DURATION_MS`（300000ms）是硬编码副本（四级 watchdog 全部相对它偏移），改值须双侧同步。

`destroyOverlayEngine()` 的代价：下次 `showOverlay` 走 cache miss 重建（几百 ms 冷启动），overlay Dart 状态全丢——救生场景可接受。

### 防丢链路（落盘 WAV + 占位入库 + worker 转写回填）

对齐主 App diary_tab 的防丢模式，`_transcribeAndSave` 顺序：

```
PCM 内存缓冲(BytesBuilder) → ① WAV 落盘 diary_audio/（主 App 可见可播可再次转写）
                          → ② insertDiary 占位行（content=''，audio_path=wav）
                          → ③ worker isolate 转写 + TextProcessor 热词纠错
                          → ④ updateDiary 回填 content → 切面板出新卡
```

- 任一步失败，**前面步骤的产物保留**：转写崩溃/识别为空 → 占位行 + WAV 保留，用户可在主 App 对该卡片"再次转写"；WAV 落盘失败 → 整条丢弃（无音频可救）
- 空录音防护：PCM < 3200B（≈0.1s）视为误触，直接丢弃不落盘
- 转写在 overlay engine 自己的 worker isolate（`RecognizerSingleton` 门面 `transcribe()`），录音期间并行预热模型

### worker idle 120s 释放

overlay engine 是独立 isolate，持有**自己的** `RecognizerSingleton` 实例（自带独立 worker，不与主 engine 共享）。速记是突发偶发场景，转写收尾后排定 120s idle Timer 自动 `dispose()` 释放第二份模型内存（主 App 的 worker 不受影响）；时限内再录音则取消释放计划，释放后再录音由 `initialize()` 重建。

### 关键文件

| 文件 | 说明 |
|---|---|
| [lib/overlay/overlay_voice_memo.dart](../../lib/overlay/overlay_voice_memo.dart) | 语音速记控制器（ChangeNotifier）：状态机 idle/recording/transcribing、PCM 累积、互斥桥读写、防丢落盘转写链、idle 释放 |
| [lib/overlay/widgets/overlay_voice_memo_bar.dart](../../lib/overlay/widgets/overlay_voice_memo_bar.dart) | 录音胶囊 UI（变长 + mm:ss）/ 三点跳动转写胶囊 |
| [lib/utils/wav_file.dart](../../lib/utils/wav_file.dart) | PCM → WAV 封装写盘工具（writeWavFile） |
| [lib/overlay/overlay_home.dart](../../lib/overlay/overlay_home.dart) | channel 转发（startVoiceMemo/stopVoiceMemo → controller）+ 回执（voiceMemoStarted/Failed/Stopped）+ 转写完成切面板 |
| android/.../VolumeKeyAccessibilityService.kt | Kotlin 侧：`triggerVoiceMemoOverlay`（toggle 状态机）`notifyDartStartVoiceMemo`（dartReady 握手挂起）`scheduleVoiceMemoStopTimeout`（3s 回执兜底）`startVoiceMemoWatchdog`/`cancelVoiceMemoWatchdog`（四级救生）`destroyOverlayEngine`（引擎销毁）`getLongPressAction`（长按槽位动作读取分流） |
| lib/diary_tab.dart / lib/record_tab.dart | 主 App 侧麦克风互斥第三道守卫（startListening / _enterMoveMode，reload 读 `is_recording`） |

## 语音笔记回放（2026-08-28）

展开面板的胶囊卡片末尾，对有录音的笔记（`audio_path` 非空且未归档，对齐主 App 播放条惯例）渲染圆形播放按钮——白底 30dp 圆 + `blueGrey.shade700` 深色图标（复选框勾选态同款视觉语言，比复选框 20dp 大一档），图标按播放态切 `play_arrow_rounded` / `pause_rounded`；命中区 40×40（`HitTestBehavior.opaque`，内层手势竞技场胜出，点按钮不冒泡触发展开）。转写失败/进行中的占位行（content=''）胶囊收缩为只有按钮，是悬浮窗内听录音的唯一入口。

### 播放状态机（OverlayHome State，照主 App diary_tab._togglePlay 简化）

- 单 `AudioPlayer` 实例 + `_playingDiaryId` + 自管 `_isPlaying`，三分支：同卡播放中→pause（再点 resume 不重头）/ 同卡已暂停→resume / 切卡或首次→stop 停旧 + `play(DeviceFileSource(path))` 播新（单实例天然"播 B 停 A"）
- 唯一订阅 `onPlayerComplete`（播完归零）；**故意不订阅 state/position 流**（audioplayers Android 上抖动回退，悬浮窗无进度条用不上）
- `stop()` 不触发 onPlayerComplete，切卡分支自己 setState 换真值
- dispose 先 cancel 订阅再 dispose player（防 use-after-free）

### 三处停播挂点（`_stopAudioPlayback`，幂等）

| 挂点 | 动机 |
|---|---|
| `onStartVoiceMemo`（`_voiceMemo.start()` 之前） | 防扬声器回采进麦克风污染识别（同主 App TTS 回采防御动机）；必须在 start 之前——start 内部多个 await 期间麦克风已可能开流 |
| `_collapse`（幂等 guard 之后） | 收起后只剩把手无暂停 UI，继续响会失控（用户确认：收起即停） |
| `_resetFromNative`（方法开头） | 浮窗彻底隐藏后无窗口不放声（自动隐藏超时兜底） |

### 关键文件

| 文件 | 说明 |
|---|---|
| [lib/overlay/widgets/overlay_diary_card.dart](../../lib/overlay/widgets/overlay_diary_card.dart) | `isPlayingAudio` / `onPlayToggle` 参数 + `_buildPlayButton`（渲染条件：audio_path 非空且未归档，收敛在卡片内部一处） |
| [lib/overlay/overlay_home.dart](../../lib/overlay/overlay_home.dart) | `_toggleAudioPlay` / `_stopAudioPlayback` + 三处停播挂点 + onPlayerComplete 订阅 + dispose 清理 |
| [lib/overlay/overlay_constants.dart](../../lib/overlay/overlay_constants.dart) | `cardPlayButtonSize 30` / `cardPlayIconSize 20` / `cardPlayButtonHitSize 40` |

## 卡片标注（标签换色，2026-09-02）

展开卡的底部按钮条末尾新增标注入口（`Icons.label_outline`），点击后底行整行替换为标注行「❗紧急 ⭐收藏 💡灵感 ✗返回」（对齐删除确认态「确认删除？✓✗」的整行替换先例；优先级：编辑态 > 删除确认态 > 标注选择态 > 查看态）。标注持久化到 diary 表 `tag` 列（TEXT 可空，DB v9→v10 新增），悬浮窗与主 App 共用同一数据库。

### 交互与状态

- **标注行**：❗=urgent / ⭐=star / 💡=idea + ✗返回；当前已标注的按钮加视觉强调（白底圆 + 图标换标注色，对齐 `_buildCheckbox` 勾选态视觉语言）；**点击已选中的 tag = 取消标注**（toggle 回默认色）
- **父层状态**：`_tagPickingIds`（Set<int> 按 diary id 管理，与 `_deleteConfirmIds` 同生命周期模式）——进入编辑态 / 删除确认态 / 收起卡片 / 面板滑出完成 / reset 复位时顺带清理，防状态残留
- **写库**：`OverlayHome._setDiaryTag(id, tag)` → `DbHelper.updateDiaryTag` → 内存列表按 id 局部更新（⚠️ sqflite 查询结果是只读 QueryRow，须 `{...row, 'tag': tag}` 物化替换）→ 退出选择态；不整表 reload
- **归档卡**：允许标注（tag 正常入库），视觉仍固定灰色，恢复后显示标注色

### 取色规则（替代旧的 index % 6 轮换色板）

| 状态 | 颜色 |
|---|---|
| 归档卡 | 固定灰 `blueGrey.shade300` α0.5 + 删除线（不变） |
| 活跃卡无标注 | 固定默认色 `OverlayConstants.defaultCardColor` #6F9AF0 |
| 活跃卡已标注 | 标注色：urgent #FF6B6B / star #FEA545 / idea #AE82E4（`DiaryTag.colors`） |

tag→颜色映射唯一真值在 [lib/utils/diary_tag.dart](../../lib/utils/diary_tag.dart)，**主 App 日记页共用**：主 App 不改卡片背景，只在卡片顶部时间行前渲染 8dp 彩色小圆点（归档卡也显示）。CSV 全量备份导出加「标注」列（放最后），导入兼容旧备份（缺列/非法值按无标注处理）。

### 关键文件

| 文件 | 说明 |
|---|---|
| [lib/utils/diary_tag.dart](../../lib/utils/diary_tag.dart) | tag 常量 + `colors` 色映射 + `isValid` 校验（双 engine 共用） |
| [lib/overlay/widgets/overlay_diary_card.dart](../../lib/overlay/widgets/overlay_diary_card.dart) | 取色逻辑 + `isTagPicking`/`onTagEntry`/`onTagToggle`/`onTagPickCancel` 参数 + `_buildTagPickRow` |
| [lib/overlay/overlay_home.dart](../../lib/overlay/overlay_home.dart) | `_tagPickingIds` + `_setDiaryTag` + 各状态清理挂点 |
| [lib/db_helper.dart](../../lib/db_helper.dart) | diary.tag 列（v9→v10 迁移）+ `updateDiaryTag` |
| [lib/diary_tab.dart](../../lib/diary_tab.dart) | 主 App 卡片 8dp 标注小色点（`_buildNormalCard` 时间行） |

## Pro 门禁（2026-09-03）

悬浮窗整体（含语音速记、悬浮窗新增笔记、自动隐藏时长配置）为 Pro 付费功能，**双层门禁**：

### 第一层：设置页 UI（Dart，settings_tab.dart）

- **Pro 徽章**（`_buildProBadge`，金色胶囊复用主题卡片视觉）挂在：手势选择器中 3 个悬浮窗动作 chip（`show_overlay` / `overlay_record` / `overlay_new_note`）+ "屏幕边缘随手记面板"分区标题
- **点击拦截**（`_ensureOverlayPro`）：未解锁时弹 `ProUnlockDialog` 并 return，**不写 prefs**（用户改不了槽位配置）；自动隐藏时长选择器同款门禁（不加徽章——它是配置项而非入口）
- 解锁后 `_loadProUnlockStatus()` 刷新，徽章即时消失
- 无障碍服务开关行**不标** Pro——它是免费功能（APP 内录音/笔记）共用的系统入口

### 第二层：原生手势拦截（Kotlin，VolumeKeyAccessibilityService）

设置页门禁挡不住"已配置的槽位被音量键直接触发"（包括降级回未解锁、改 SharedPreferences 文件等绕过路径），故无障碍服务在执行动作前自查：

- `isProUnlocked()`：读落盘 prefs `flutter.is_pro_unlocked`（与 `isRecording()` 同款读取模式，每次按键现读，无 MethodChannel）
- `blockOverlayIfProLocked()`：未解锁 → 50ms 短震 + Toast「悬浮窗是 Pro 功能，请在声物记设置页解锁」+ return
- **三个挂点**（均在 toggle 放行分支之后）：
  | 函数 | 门禁位置 | 放行的 toggle 分支 |
  |---|---|---|
  | `triggerShowOverlay` | toggle 隐藏分支 return 之后 | 已显示时长按 = 立即隐藏（未解锁用户必须关得掉已显示的浮窗） |
  | `triggerOverlayNewNote` | 方法入口（无 toggle 语义） | — |
  | `triggerVoiceMemoOverlay` | 录音中 toggle 停止分支 return 之后 | 录音中再长按 = 停止（进行中的录音必须停得掉） |

### 关键文件

| 文件 | 说明 |
|---|---|
| [lib/settings_tab.dart](../../lib/settings_tab.dart) | `_buildProBadge` / `_ensureOverlayPro` + 手势 chip / 分区标题 / 自动隐藏选择器 4 处挂点 |
| [android/.../VolumeKeyAccessibilityService.kt](../../android/app/src/main/java/com/shengwuji/app/VolumeKeyAccessibilityService.kt) | `isProUnlocked` / `blockOverlayIfProLocked` + 3 个 trigger 函数门禁挂点 |

## 卡片 AI 对话按钮（2026-09-05）

展开卡底部按钮条的分享入口（原系统分享面板，`shareText` → ACTION_SEND Chooser）替换为**主 App 日记页同款的 AI 对话按钮**：点击后复制正文到剪贴板并跳转设置页选择的 AI 应用（`selected_ai_app`，默认 ChatGPT）。

### 流程与要点

1. **读用户选择**：`prefs.reload()` 后读 `selected_ai_app`（各 engine 的 SharedPreferences 内存缓存隔离，跨 engine 读主 App 写入必须 reload，项目惯例）
2. **原生复制**：复用复制按钮的 `copyText` 通道（原生 ClipboardManager + EFFECT_TICK 震动；Dart 剪贴板通道在 overlay engine 不可靠）。**写入失败即中止跳转**——留在原地让用户改走复制按钮重试，避免跳过去粘出剪贴板旧内容
3. **原生拉起 `launchApp`**（新通道方法）：Service 无 Activity 上下文，`startActivity` 统一加 `FLAG_ACTIVITY_NEW_TASK`；启动顺序**包名 → scheme → web url** 三级兜底（对齐日记页 `_shareToAI` 的兜底链），全部失败 Toast 提示 + 返回 false（面板保持展开）。微信偏好 scheme，Dart 侧传空 packageName 跳过包名步骤。API 30+ 包可见性由 AndroidManifest `<queries>` 已声明的 4 个 AI 应用包名覆盖
4. 拉起成功后 `_collapse()` 收起面板回把手（用户已跳去 AI 应用，与原分享后收起同语义）

### 渲染守卫

AI 按钮仅在有内容且未归档的查看态渲染（空 content 占位行/已归档卡不渲染，对齐日记页 AI 按钮的渲染条件，避免送空文本/归档旧文进 AI）。图标 `Icons.chat_bubble_outline` 对齐日记页。

### 关键文件

| 文件 | 说明 |
|---|---|
| [lib/overlay/overlay_home.dart](../../lib/overlay/overlay_home.dart) | `_onCardShareToAI`（reload prefs → copyText → launchApp → _collapse） |
| [lib/overlay/accessibility_overlay.dart](../../lib/overlay/accessibility_overlay.dart) | `launchApp` 通道封装（shareText 暂留备用） |
| [lib/overlay/widgets/overlay_diary_card.dart](../../lib/overlay/widgets/overlay_diary_card.dart) | `onAiChat` 参数 + 守卫 + `_buildActionRow` 按钮渲染 |
| [android/.../VolumeKeyAccessibilityService.kt](../../android/app/src/main/java/com/shengwuji/app/VolumeKeyAccessibilityService.kt) | `launchApp` handler（NEW_TASK + 三级兜底 + Toast） |
| [lib/ai_app_model.dart](../../lib/ai_app_model.dart) | AIApp 模型（id/包名/scheme/url，双端共用） |

## 相关文档

- @volume-key-shortcuts.md — 无障碍服务与音量键体系
- @speech-recognition.md — 语音识别流程
