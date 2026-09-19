# 悬浮窗（闪念胶囊）架构与实现记录

> 分支：`feature/floating-window` · 最近更新：2026-09-14 · 状态：**把手 + 数据链路 + 全屏透明面板/自适应胶囊 + 召唤式交互已打通**（音量键手势槽位召唤悬浮窗并自动展开、收起后可配置秒数自动彻底隐藏、显示时再触发立即隐藏、展开/收起推屏滑动动画；卡片标注换色已落地；把手支持长按拖动调整纵向位置；**悬浮窗整体为 Pro 付费功能**——设置页门禁 + 原生手势拦截双层，见"Pro 门禁"小节）

## 功能概述

系统级悬浮窗（锤子"闪念胶囊"样式），收起态为贴屏幕停靠缘（右缘为默认，可在设置页切换左缘，见"停靠侧左右切换"小节）的竖长**药丸双色胶囊把手**（窗口 28×88dp，胶囊本体向内缩一圈 ≈24×80dp 视觉缩小、触控面积不变；上半白/下半绿中间一道接缝横线，外围 1dp 细白描边与笔记卡片同款，⚡ 图标 + 竖排"闪记"居上半/下半两区，整体静置稍透明，默认垂直居中，**长按后可上下拖动调整位置**，见"把手长按拖动"小节），点击或朝屏幕内侧滑动展开 300dp 宽侧栏面板（"随手记"日记列表）。

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
| （2026-09-09 本次提交） | 把手长按拖动调整位置：把手抽成 [overlay_handle.dart](../../lib/overlay/widgets/overlay_handle.dart)（手势识别），长按进入拖动 → 位移经 `dragHandle` 通道逐帧发给原生移窗（y 偏移 clamp 屏内），松手落盘 SharedPreferences（`flutter.overlay_handle_y_offset_dp`，dp 单位）下次建窗恢复；拖动中暂停自动隐藏计时、组件被移出树时 dispose 补发收尾（详见"把手长按拖动"小节） |
| （2026-09-11 本次提交） | 悬浮窗位置与把手解绑：真机验证发现胶囊与展开面板都沿用把手拖后的 y 跟着漂移（录音胶囊跑到屏幕上方、全屏笔记面板被推离顶部露空），定夺二者**位置恒定**——resize 对胶囊尺寸（312×64）与展开全屏（哨兵 -1）一律 y=0，把手/贴边竖线从 prefs 恢复拖存位置；dragHandle/endHandleDrag 加把手宽度守卫，打断进胶囊的在途消息不挪胶囊、不覆盖存档 |
| （2026-09-13 本次提交） | 把手改「药丸双色胶囊」皮肤 + 缩小一号：上半白（#F5F6F3）/下半绿（#2E9F5C）正中 hard-stop 渐变硬切 + 1dp 中缝接缝横线（半透明黑），外围细白描边改**常驻**（与笔记卡片 cardBorderWidth 同语言，拖动态加粗 1.5 作反馈）；整体静置稍透明（0.93，用户要求"稍微透明一点点"），拖动态回满不透明（沿用"拖动 = 满不透明"分层语言）；文案"记一笔"→"闪记"、闪电图标 16→13 / 字号 11→10 缩小；**窗口保持 28×88 不动**（原生 HANDLE_WIDTH_DP 硬编码副本 + 语音胶囊 84<88 硬不变量 + 触控面积三重理由），胶囊本体以 `handleInset*`（横 2 / 纵 4）向内收缩实现视觉缩小；图标取下半绿同色落在白半区呼应成对（配色授权自选，用户定夺风格：白上绿下 + 中缝横线） |
| （2026-09-13 本次提交） | 滑动展开补两档线性马达触感：胶囊把手朝屏内滑展开 = tick 轻档、线态贴边竖线朝屏内滑展开 = heavy 强档（用户定夺"线态反馈强一点、胶囊态弱一点"），都走 `performHaptic` 通道 → 原生 `VibrationEffect.createPredefined`（同日记页录音开始 `_haptic('heavy')` 的既有线性马达家族，与 Vibration 包自定振幅的普通震动区分）；详见"滑动展开的两档触感反馈"小节 |
| （2026-09-14 本次提交） | 贴边竖线难触发修复 + 点按回把手：线态窗口 4→20dp（透明触摸缓冲区，视觉线仍 4dp 贴停靠缘）——首版触摸区 4dp 手指起点很难按中、按偏的边缘滑动被系统当返回手势（真机反馈"难触发、与侧滑冲突"）；透明缓冲不牺牲下层触摸（贴边 ~24dp 本是系统手势区），推翻当年"窗口宽=线宽防挡下层"决策；点按竖线改为回把手胶囊（轻唤醒，扩窗方向走完整空白帧协议防旧纹理重投影，回把手后重排自动隐藏），侧滑维持直接展开面板；设置页新增「点按竖线展开把手」开关（`overlay_edge_line_tap_enabled`，默认开，关闭后仅侧滑/音量键可展开）；Kotlin 线态宽度判定阈值 `EDGE_LINE_WIDTH_THRESHOLD_DP` 12→24 同步（音量键 toggle 分流，双侧硬编码副本）；测试 345 全过（新增 exitEdgeLine 状态流转与常量约束 3 用例）+ analyze 0 error + compileDebugKotlin 通过；详见"贴边竖线驻留（线态）"小节 |
| （2026-09-14 本次提交） | 竖线配色改「明暗渐变」解决白底不可见：旧单一半透明白（0x73FFFFFF）在白色/浅色背景下数学上恒为白（白+白=白）不可见（真机反馈白底难识别、暗底良好）；「自动随背景变色」不可行（悬浮窗拿不到下层像素：BackdropFilter 只作用窗口内 / FLAG_BLUR_BEHIND 是模糊非取色且 Android 12+/ROM 受限 / 截屏取色需 MediaProjection 授权）→ 让线自带明暗两成分：屏内端深灰（0xD9464646）→ 贴缘端浅灰（0xD9C8C8C8）横向渐变、方向随停靠侧镜像，白底看深端（6.1:1）、黑底看浅端（9.0:1），任何背景至少一端可见（⚠️ 纯灰背景 ≈#808080 两端都弱 ≈2:1 属已知取舍）；方案对比评估（A 加不透明度白底无效 / B 中性灰纯灰底失效 / C 黑心白边夹心 / D 明暗渐变）与可交互预览见 docs/previews/edge_line_contrast_preview.html，用户拍板 D；flutter analyze 0 error + 345 测试全过 |
| （2026-09-14 本次提交） | 滑动展开两档触感按小米 15 真机体感对调（把手 heavy / 竖线 tick）——用户真机反馈"把手重、竖线轻"与设计相反，加调试日志（Dart 调用点 + Kotlin performHaptic 打印 type/SDK/hasAmplitudeControl）定性：链路 type 正确到达，是 HyperOS 对 EFFECT_TICK/EFFECT_HEAVY_CLICK 预设波形映射非标（实测 TICK 体感反而比 HEAVY_CLICK 重；标准 AOSP 排序 TICK<HEAVY_CLICK），用户拍板直接对调以主力机体感为准；⚠️ 档位看似反直觉勿"修正"回去（详见"滑动展开的两档触感反馈"小节）；调试日志保留便于后续调档；flutter analyze 0 error + 373 测试全过 |
| （2026-09-15 本次提交） | 语音速记支持「说完自动停止」：录音中检测到说完话后静音满设定秒数（3/5/8 档，设置页「音量键快捷操作」新开关+秒数选择器，默认关）自动停止并转写——实时 Silero VAD 逐窗 isDetected 进静音状态机（说过话才计时，一次都没说话不自动停，防空录音），触发后走 stop() 既有链路含 voiceMemoStopped 回执，Kotlin 零改动；与主 App 快速录音共用实现 lib/utils/quick_record_auto_stop.dart（配置/状态机/测试），详见 @speech-recognition.md「说完自动停止」；flutter analyze 0 error + 385 测试全过 |
| （2026-09-15 本次提交） | 静音倒计时可视化（用户拍板补充）：静音倒计时进行中录音胶囊把 mm:ss 换成「N 秒后自动停」（恢复说话自动回计时），胶囊宽度按 voiceMemoAutoStopMinWidth=170dp 下限兜底防短录音早期文字截断；状态机 SilenceTimer 暴露 countingDown/remainingSeconds（说话进行中不算倒计时，剩余秒数向上取整）；主 App 快速录音 statusText 同步显示「N 秒后自动停止」（流回调整数秒变化才 setState 节流）；新增 7 状态查询用例，flutter analyze 0 error + 392 测试全过 |
| （2026-09-16 本次提交） | 悬浮窗说完自动停止失灵根治 + 主 App 倒计时文案不显示修复：①浮动按钮锁定录音态硬编码「点击停止」短路 statusText，倒计时文案经 isSilenceCountdown getter 优先显示；②真机日志确诊 VAD 初始化抛 "Please initialize sherpa-onnx first"——overlay engine 是独立 isolate，sherpa-onnx FFI 绑定指针表各 isolate 独立缓存（项目铁律），主 engine main() 调过的 initBindings 对其无效，修复 overlayMain() 入口补调 initBindings()（对齐 main.dart:55 惯例）；悬浮窗自动停止三个关键节点日志接 AppLogger 文件缓冲（print 只进 logcat 应用内导出看不到）；flutter analyze 0 error + 392 测试全过 |
| （2026-09-17 本次提交） | 语音速记触感按真机反馈再调两处：①开始录音震感 heavy→click——小米 15 上 heavy 体感太轻，对齐日记页手动长按录音按钮的开始震感（主 App 快速录音 lockedMode 开始 `_haptic('heavy')` 同步改 click，Kotlin triggerVoiceMemoOverlay 同步 `performHaptic("click")`）；②转写成功震让位规则：手动停（停止按钮/音量键 toggle）且录音 <30s 跳过成功震——停止操作震刚响过、短录音转写快会贴脸干扰（`stop(manualStop:)` 区分手动/自动停，VAD 自动停与上限停恒震；判定抽静态纯函数 `shouldHapticOnTranscribeSuccess` + 常量 `voiceMemoSuccessHapticMinSeconds=30`，4 用例单测）；flutter analyze 0 error + 398 测试全过 + compileDebugKotlin 通过 |
| （2026-09-17 本次提交） | 开始震感再升一档 click→tick + 删快速录音开机嗡（用户真机反馈：click 清脆仍偏弱，且音量键快速录音开始有「嗡+清脆」两下重叠）：①快速录音 lockedMode 开始与悬浮窗语音速记开始统一 `tick`（该机最重清脆档，实测体感 heavy<click<tick）；②删 triggerQuickRecord 的 vibrateOneShot(100,70)——本函数开始/录音中双击停录共用，嗡与 Dart 侧震感叠两下，删除后开始触感只剩 diary_tab 一记 tick、停止走 stopListening 既有 heavy（预设档位不可调强度参数，只能换档枚举——用户询问"清脆能否更强"的技术答案）；flutter analyze 0 error + 398 测试全过 + compileDebugKotlin 通过 |
| （2026-09-17 本次提交） | 触感定版「开始嗡、停止清脆」（用户真机试 tick 开始后拍板改向）：①triggerQuickRecord 按 isRecording() 互斥桥分流——非录音中（开始）震 vibrateOneShot(50,50) 嗡（悬浮窗旧停止震同款 one-shot）、录音中（双击/长按 toggle 停录）震 performHaptic("tick") 清脆；②悬浮窗 triggerVoiceMemoOverlay 对调：开始改 50,50 嗡、toggle 停止改 tick；③悬浮窗停止按钮 heavy→tick 同档（overlay_voice_memo_bar，单测断言同步）；④删 diary_tab lockedMode 开始的 _haptic('tick')——触感收敛到按键侧一下防重叠（开始震移 Kotlin 即时反馈）；30s 成功震让位规则自动适配（短录音手动停=tick 一记）；主 App 音量键停止=Kotlin tick + stopListening 既有 heavy（轻，保留，复测嫌叠再删）；flutter analyze 0 error + 398 测试全过 + compileDebugKotlin 通过 |

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
- 头部按钮条（无标题，深色半透明工具条，见下）：新增笔记（+，插占位行进编辑态）/ 全部展开·收起（空列表不渲染）/ **打开随手记**（2026-09-13 起，`Icons.book` 与主 App 底部导航「随手记」同图标，见「跳回主 App 日记页」小节）/ 收起 chevron（指向停靠边缘）
- **深色半透明工具条**（2026-09-13，[overlay_panel_header.dart](../../lib/overlay/widgets/overlay_panel_header.dart)）：此前四个按钮裸放透明面板上、图标色跟主题（ext.textHint），垫在白色背景的应用上看不清（用户实测反馈）。改为黑 72% 半透明底 + 白图标 + 朝屏内侧柔影——与录音胶囊/停止提示胶囊同视觉家族（白图标对黑 72% 底，垫纯白背景等效底 ≈#4a4a4a，对比度 ≈8:1，跨背景都可读），也是闪念原型「黑色半透明工具条」设计的正式落地。组件纯渲染：回调上抛、停靠侧镜像（贴停靠缘 Align / chevron 朝向 / 阴影方向）与条件渲染（空列表）由参数驱动；渲染契约锁在 `overlay_panel_header_test`（按钮渲染条件/回调接线/家族配色/两侧镜像 6 用例）
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

### 把手长按拖动（2026-09-09，收起态纵向位置调整）

**分工**：手势识别全在 Dart（[overlay_handle.dart](../../lib/overlay/widgets/overlay_handle.dart)，从 overlay_home._buildHandle 抽出的 StatefulWidget），移动真值在原生窗口 LayoutParams——收起态窗口只有 28×88，Dart 拿不到也不该管窗口位置。

- **通道消息**（Dart → Kotlin，`accessibility_overlay` 通道）：`beginHandleDrag`（长按识别成功，Kotlin 缓存当前 y 作基线）→ `dragHandle{dy}`（onLongPressMoveUpdate 逐帧转发，dy = 自按下原点的累计位移，逻辑像素）→ `endHandleDrag`（松手，Kotlin 把当前位置折算 dp 落盘 `flutter.overlay_handle_y_offset_dp`）
- **为什么窗口跟手后手指不丢**：原生 updateViewLayout 把窗口挪到手指下方，手指始终留在 28×88 窗口内，后续 move 事件不丢——"Dart 发位移、原生挪窗"方案成立的前提
- **原生位移计算**：`params.y = 基线 + dpToPx(dy)`，clamp 到 `±(屏高 - 窗高)/2`（窗口完整留在屏内；MATCH_PARENT 高度时 y 无语义直接跳过）。不逐帧累加，丢一条中间消息也不偏
- **恢复与位置分流**（2026-09-11 用户真机反馈定夺）：把手/贴边竖线始终停在拖存位置，语音胶囊窗口与展开的笔记面板**位置恒定**（最初版本胶囊/全屏窗口都沿用把手拖后的 y，真机验证否决——录音胶囊漂到屏幕上方、全屏面板被推离屏幕顶部露空）。实现上 y 不在窗口实例间沿用，每次 resize/建窗都重设：胶囊尺寸（312×84）与展开全屏（哨兵 -1，`FLAG_LAYOUT_NO_LIMITS` 下全屏帧同样会被 y 推偏）→ y=0；其余非全屏（把手/贴边竖线）→ `handleYOffsetPxClamped`（读落盘偏移 + clamp 屏内，旋转等屏高变化兜底）。语音胶囊/面板会话把 y 归零后，收起回把手从这里取回原位置
- **拖动只作用于把手**：`dragHandle` / `endHandleDrag` 以「窗口宽 == 把手宽（HANDLE_WIDTH_DP=28）」为守卫——拖动中旬被打断进语音胶囊（窗口已 resize 成 312×84）时，Dart 组件尚未随帧移除、在途的拖动消息不得挪动胶囊，残留的收尾也不得把胶囊的居中位置覆盖进拖存档
- **交互细节**：拖动开始暂停自动隐藏计时（`_hideScheduleGeneration++`，否则计时到期会在指下缩成竖线）+ tick 震感；松手/取消恢复计时（`_scheduleAutoHide` 内部守卫挡掉录音/转写场景）；拖动态视觉 = 满不透明（静置态 0.93）+ 白描边加粗 1.5（静置态已常驻 1dp 卡片同款白描边，2026-09-13 起，拖动反馈改为"透明度回满 + 描边加粗"的差量；刻意不用放大——放大超出 28×88 窗口会被窗口边缘硬裁剪，同"无 boxShadow"决策）；点按展开与长按拖动由 Flutter 手势竞技场自然分流，互不影响
- **⚠️ 框架坑：组件在手势中旬被移出树不回调 onLongPressCancel**（识别器随 GestureDetector 直接销毁，无 cancel 指针事件可达）——`_OverlayHandleState.dispose` 检查 `_dragging` 补发 onDragCancel（对应语音速记打断把手切胶囊 UI 的路径），父层走与松手对称的收尾
- **⚠️ 框架坑：横向拖动竞技场接纳事件本身不产生 update 回调**——首个超 slop 的 move 只完成接纳，位移要等接纳之后的 move 事件才逐帧上报，"单事件超阈值"判定（左滑展开）只在接纳后的后续事件上生效（widget 测试探针验证；既有逻辑，迁移时保持行为不变，测试按多帧真实滑动编写）

### 滑动展开的两档触感反馈（2026-09-13 首版，2026-09-14 真机对调）

「朝屏幕内侧滑展开」是盲手势（目标小、无视觉确认），补震动反馈；同一手势在把手/竖线两态拉开强度差（用户定夺：线态强、胶囊态弱）：

- **胶囊把手**（`_buildHandle` 的 `onSwipeInward` 包装）：`performHaptic('heavy')` = 用户主力机上的**轻档**
- **线态贴边竖线**（`_buildEdgeLine` 的滑动展开分支）：`performHaptic('tick')` = 用户主力机上的**重档**
- **⚠️ 档位映射看似反直觉，勿"修正"回去**：标准 AOSP 强弱排序 TICK < HEAVY_CLICK，但小米 15 HyperOS 对 `VibrationEffect.createPredefined` 预设波形的实现非标——真机实测 EFFECT_TICK 体感反而比 EFFECT_HEAVY_CLICK 重。2026-09-14 加调试日志定性（Dart 两个调用点 + Kotlin `performHaptic` 打印 type/SDK/hasAmplitudeControl）：链路 type 正确到达、体感相反，排除代码问题，用户拍板直接对调、以主力机体感为准。换回标准映射的机型上两档体感会反转（当前无此设备，接受）
- **点按展开刻意不震**：点按有明确视觉目标（胶囊/线的位置已知），是确认性操作，触感留给盲手势
- **震感家族**：都走 `AccessibilityOverlay.performHaptic` 通道 → Kotlin Service `performHaptic` 映射表 → `VibrationEffect.createPredefined`（系统预设触感原语，线性马达质感，SDK < O 降级固定时长）——同日记页 `_haptic` / 悬浮窗复制按钮 EFFECT_TICK 的既有家族；刻意不用 `Vibration.vibrate(duration, amplitude)`（自定振幅波形，普通转子马达的"嗡"感）。注：语音速记/快速录音的触感 2026-09-17 定版「开始嗡（Kotlin 侧 50,50 one-shot）、停止清脆（tick，该机最重清脆档）」，预设档位经 heavy→click→tick 三轮真机试档后收敛

### 贴边竖线驻留（线态：触摸缓冲区 + 点按/侧滑分流，2026-09-14）

**何时进入**：收起后自动隐藏计时到期 + 设置开关「隐藏后保留贴边竖线」（`overlay_edge_line_enabled`，默认开）打开 → `_enterEdgeLine` 把窗口从把手（28×88）缩成线态（20×64）；关闭则维持旧行为 closeOverlay 彻底移除窗口（只能音量键召唤）。

**形态 = 视觉线窄、触摸区宽**：窗口 20×64dp（`edgeLineWindowWidth` = 透明触摸缓冲区），视觉线 4dp（`edgeLineWidth`，用户定夺 ≈1mm）贴停靠缘绘制（Align 贴缘），GestureDetector `HitTestBehavior.opaque` 整窗可命中。为什么加宽：首版窗口宽=线宽=4dp，手指起点（接触面 8~10mm）很难按中，按偏后落在窗口外的边缘滑动被系统当作返回手势——用户感知为"竖线难触发、和侧滑返回冲突"。透明缓冲不牺牲下层触摸：贴边 ~24dp 本来就是系统返回手势区（systemGestureInsets），手势导航下该条带触摸到不了下层应用（三键导航只挡边缘无可点控件的条带）。市面产品调研（微信浮窗/悬浮球类）均为"窄视觉+宽触摸"路数；第三方无法用 `setSystemGestureExclusionRects` 抢边缘手势（该 API 对 overlay 窗口普遍无效，官方仅支持 Activity 内 view）。

**配色 = 明暗渐变（2026-09-14，用户拍板方案 D）**：屏内端深灰（`edgeLineGradientDeep` 0xD9464646）→ 贴缘端浅灰（`edgeLineGradientLight` 0xD9C8C8C8）的横向 `LinearGradient`，方向随停靠侧镜像（右缘 = 左深右浅，左缘反之）。动机：更早的单一半透明白（0x73FFFFFF）在白色/浅色背景上数学上恒为白不可见（白+白=白，加 alpha 无解）；「自动随背景变色」不可行——悬浮窗拿不到下层像素（Flutter BackdropFilter 只作用窗口内；原生 FLAG_BLUR_BEHIND 是模糊非取色且 Android 12+/部分 ROM 禁用；截屏取色需 MediaProjection 每次授权）。渐变让线自带明暗两成分：白底看深端（WCAG 6.1:1）、黑底看浅端（9.0:1），任何背景至少一端可见（地图/字幕同思路）。⚠️ 纯灰背景（≈#808080）两端对比都弱（≈2:1），属已知取舍。方案对比（加不透明度 / 中性灰 / 黑心白边夹心 / 明暗渐变）与可交互预览：[docs/previews/edge_line_contrast_preview.html](../previews/edge_line_contrast_preview.html)。

**三种展开路径**：

| 动作 | 行为 |
|---|---|
| 点按 | 回把手胶囊（轻唤醒——线近乎隐形，先唤出显眼把手，是否展开面板交用户下一步）；设置开关「点按竖线展开把手」（`overlay_edge_line_tap_enabled`，默认开）关闭后点按无反应；不震（有明确视觉目标，同把手点按不震的定夺） |
| 朝屏幕内侧滑 | 直接展开面板（heavy 强触感，见上节） |
| 长按音量键 | 直接展开面板（Kotlin `isOverlayInEdgeLineState` 按窗口宽 ≤ `EDGE_LINE_WIDTH_THRESHOLD_DP`(24) 判定线态做 toggle 分流——线态长按=重新展开而非隐藏；⚠️ 该阈值与 Dart `edgeLineWindowWidth` 是双侧硬编码副本，改窗口宽须同步） |

**点按回把手的实现要点**（`_onEdgeLineTap` → `_exitEdgeLine`）：async 先 reload prefs 读开关（跨 engine 惯例，读失败按开启兜底）→ 扩窗方向必须走完整空白帧协议（挂 `_metricsStage` 守卫 → `await _waitForBlankFramePresented` → `controller.exitEdgeLine()` 触发 resize(28,88)）——缩窗方向靠 fade-in 起步遮错位帧可不同步，扩窗方向 `_maybeAdvanceMetricsStage` 直接满显，旧竖线纹理会被 TextureView 重投影拉伸，必须空白先行（同 `_expand` 主路径防闪烁原理）；落地后 `_scheduleAutoHide` 重排——把手不再被操作时到期照常缩回竖线/彻底隐藏。controller 新增 `exitEdgeLine()`（`enterEdgeLine` 的对偶，非线态幂等 no-op）。

### 停靠侧左右切换（2026-09-13，设置页 overlay_side_left）

**设置入口**：设置页「悬浮窗」卡片新增「停靠侧」选择器（屏幕右缘 / 屏幕左缘 ChoiceChip，同走悬浮窗 Pro 门禁），写 `OverlayConstants.overlaySideLeftPrefKey = 'overlay_side_left'`（bool，缺省 false = 右缘，历史行为）。

**三端共读同一 key，各管各的镜像面**：

- **原生窗口 Gravity**（Kotlin `horizontalEdgeGravity()`）：`buildOverlayParams` / `resizeOverlay` 每次建窗/resize 实时读 `flutter.overlay_side_left`（Flutter SharedPreferences 落盘带 `flutter.` 前缀），分流 `Gravity.END` / `Gravity.START`——把手、贴边竖线、语音胶囊窗口、展开全屏帧全部随侧落位。无缓存即无跨端状态同步
- **overlay engine Dart 镜像**（`OverlayHome._sideLeft`，`_refreshSide()` reload 后读）：把手/竖线的 Align、缩窗把手回位与面板推屏动画的平移符号（`Offset((1-t)×(±1), 0)`，左缘取 -x）、面板锚点 `topRight`/`topLeft`、面板「朝停靠边缘滑收起」与把手/竖线「朝屏幕内侧滑展开」的方向判定（统一走 `OverlayConstants.swipeExceeds(towardLeft:)` 纯函数）、header 按钮聚拢侧与收起 chevron 朝向、卡片划走归档方向（`SwipeDismissCard.dismissDirection`：右缘=左滑归档/左缘=右滑归档，反方向快滑经 `onSwipeCollapse` 转发收起——回调名已从 `onSwipeRight` 改中性）、录音胶囊贴屏端（`OverlayVoiceMemoBar.dockLeft`：对齐、距屏边距、停止钮与分隔线钉靠屏端、阴影投射方向）
- **卡片几何锚定**（`OverlayDiaryCard.dockLeft`）：胶囊外层对齐（centerRight/centerLeft）、展开↔收起过渡的 Switcher 叠放锚与 OverflowBox 锚、收卷窗口 `_CollapseWindowClipper.alignLeft` 固定缘。卡内文字/按钮的阅读排版保持 LTR 不镜像（时间行、勾选框、底部按钮条两种停靠下一致）

**方向镜像口诀**：一切"朝屏幕内侧"的手势与"停靠边缘"的锚定随侧翻转——把手/竖线朝屏内侧滑=展开、卡片朝屏内侧滑=归档、面板朝停靠边缘滑=收起；把手的纵向拖动与拖存档（`flutter.overlay_handle_y_offset_dp`）左右共用，切侧不丢上下位置。

**生效时机**：设置切换后悬浮窗的**下一次状态转换**（展开/收起/语音速记启动）整体换侧——`_refreshSide` 挂在 engine 冷启动、每次 `_expand`（await，赶在滑入动画前）、`_scheduleAutoHide`（收起顺带读）、语音速记启动 handler（await，赶在胶囊揭示首帧前）、`_resetFromNative`（窗口移除后补读）；原生侧 Gravity 每次建窗/resize 直读。已显示中的收起把手不瞬移（跨 engine 无推送通道，不做轮询）——用户感知即"下一次打开就在另一侧"。

**为什么不立即生效**：设置页在主 App engine，悬浮窗在独立 engine，两个 engine 的 messenger 互不相通（MethodChannel 各自注册在各自 engine），没有主 App → 悬浮窗的推送通道；SharedPreferences 也无跨 isolate 通知。轮询是坏味道，状态转换时机读是零成本挂载。

**测试**：把手镜像（`overlay_handle_test` dockLeft 右滑展开/左滑不误触）、卡片镜像划走方向（`swipe_dismiss_card_test` dismissDirection=right 三用例）、胶囊贴屏端镜像（`overlay_voice_memo_bar_test` dockLeft 停止钮左端）、卡片镜像对齐与过渡锚（`overlay_diary_card_test` dockLeft 两用例）。

### 跳回主 App 日记页（2026-09-13，header「打开随手记」按钮）

悬浮窗此前没有跳回主 App 的入口，header 新增「打开随手记」按钮（`Icons.book`，tooltip「打开随手记」）补齐。落地页 = 主 App 底部导航索引 2（`DiaryTab`「随手记」，悬浮窗面板本身就是这份随手记的速记视图）。

**点击时序**（`OverlayHome._openDiaryPage`，先收再跳）：

1. 编辑中先 `_saveEdit()`（空内容视同取消删占位行，同既有语义；写库失败留在编辑态放弃跳转——不保存就跳走会静默丢用户输入）
2. `_collapse()` 收起面板并等 `_collapseSettled`（缩窗 resize 发出时完成，1.2s 超时兜底放行）——**先收再跳的原因**：展开面板是全屏模态层、空白区吞触摸（见「展开面板视觉」的两个触摸事实），不等缩窗完成主 App 首屏约 1s 点不动；同 `_onCardAlarm` 权限路径的时序考虑
3. `AccessibilityOverlay.openDiaryPage()` 原生拉起主 App

**跨 engine 路由链**（复用悬浮窗闹钟 grant_calendar 的既有机制）：

- overlay 通道 `openDiaryPage` → Kotlin Service handler：`getLaunchIntentForPackage`（当前 enabled 的 launcher component，图标包 alias 路由）+ `FLAG_ACTIVITY_NEW_TASK` + `putExtra("type", "open_diary")`，失败 Toast + false
- `MainActivity.extractShortcutType` 识别 `open_diary` → `onShortcutLaunch` 推给主 engine → `main.dart _handleOpenDiaryPage`：`_currentIndex = 2` + `Future.microtask` 里 `refreshEngine()` / `refreshList()`（底部导航 onTap 同款节奏；悬浮窗侧增删改经 DiarySyncBridge 写库，列表须重查才可见）。**不加防重复标志**：切 tab 幂等，与 quick_record 的"只准触发一次"语义不同
- 冷启动/热启动分别走 `handleShortcutIntentOnColdStart` / `onNewIntent`，机制与 grant_calendar 完全一致
- `applyLockScreenFlagsIfNeeded` 排除 `open_diary`：`setShowWhenLocked(true)` 是 sticky 的（保留到下次息屏被 ACTION_SCREEN_OFF 清除），非锁屏场景不点亮；`grant_calendar` 既有放行行为不动

**悬浮窗自身去向**：跳转即收起回把手，`_scheduleAutoHide` 照常计时（默认 10s 缩竖线/彻底隐藏）——用户在主 App 里操作时悬浮窗自动让路，把手常驻语义不变。拉起失败（`getLaunchIntentForPackage` null，仅剩图标包 alias 异常边角）面板已收起，点把手可重试，不做回滚展开。

## 关键文件与行号（2026-08-29 核对）

### lib/main.dart
- **L23-26**：保活 import `overlay/overlay_main.dart as overlay_entry`
- **L28-36**：根库转发函数 `overlayMain()`（核心修复）

### lib/overlay/overlay_constants.dart
- **L8 / L11**：`handleWidth = 28` / `handleHeight = 88`（dp，闪念胶囊尺寸）
- **L14**：`handleLabel = '记一笔'`（竖排文案，改文案只动这里）
- **L17 / L20**：`handleIconSize = 16.0` / `handleFontSize = 11.0`
- **L73**：`panelSlideDuration = 240ms`（面板推屏滑动动画时长）
- **L136 / L142**：`voiceMemoWindowWidth = 312` / `voiceMemoWindowHeight = 84`（语音速记冷启动隐藏窗口直建尺寸，Kotlin 侧有硬编码副本须同步；84 = 胶囊 44 居中带 + 下部提示条带，须 < handleHeight 88——见「停止提示胶囊」小节）
- **线态常量**：`edgeLineWidth = 4`（视觉线宽）/ `edgeLineWindowWidth = 20`（窗口宽 = 触摸缓冲区）/ `edgeLineHeight = 64` / `edgeLineGradientDeep·Light`（明暗渐变双色，见「贴边竖线驻留」小节配色段）/ `edgeLineEnabledPrefKey`（驻留开关）/ `edgeLineTapEnabledPrefKey`（点按回把手开关）——线态窗口宽与 Kotlin `EDGE_LINE_WIDTH_THRESHOLD_DP`(24) 是双侧副本
- **语音速记停止提示**：`voiceMemoStopHintMaxShows = 2` / `voiceMemoStopHintCountPrefKey = 'overlay_voice_memo_hint_shown_count'` / `voiceMemoHintGap = 3`（见「停止提示胶囊」小节）

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
- **L72-73 常量**：`VOICE_MEMO_OVERLAY_WIDTH_DP = 312` / `VOICE_MEMO_OVERLAY_HEIGHT_DP = 84`（隐藏窗口直建尺寸硬编码副本，唯一真值在 Dart overlay_constants.dart，改尺寸须双侧同步）
- **L110-121 字段**：`dartReady` / `pendingAutoExpand`（握手状态，见"自动展开"小节）/ `pendingVoiceMemoReveal`（隐藏窗口标记，L129 附近）
- **L377 `vibrateOneShot()`**：单次震动封装（triggerQuickRecord / triggerShowOverlay 共用，含 SDK < O 降级）
- **L454 `triggerShowOverlay()`**：长按直连入口——toggle 判断 + `showOverlay(autoExpand = true)`，已废弃 startActivity 绕路
- **L640 `showOverlay(autoExpand, hidden)`**：显示浮窗；hidden=true 时**直建胶囊尺寸隐藏窗口**（addView 312×84 + alpha=0 + NOT_TOUCHABLE）；`wm.addView` 后 `if (autoExpand) notifyDartExpand()`
- **L671 起**：accessibility_overlay channel 服务端（resizeOverlay / updateFlag / closeOverlay / **dartReady** / **voiceMemoUiReady**——揭示延迟 2 vsync / **beginHandleDrag·dragHandle·endHandleDrag**——把手拖动移窗与落盘，见"把手长按拖动"小节）
- **`HANDLE_Y_OFFSET_KEY`**（companion object）：把手纵向偏移落盘 key `flutter.overlay_handle_y_offset_dp`（int，dp），写入方 endHandleDrag / 读取方 buildOverlayParams
- **L804 `notifyDartExpand()`**：dartReady 直接发 expand，否则挂起 pendingAutoExpand
- **L816 `hideOverlay()`**：removeView + detach + **发 reset 复位 Dart**（须在 channel 引用置 null 之前），不销毁 engine（热启动复用）
- **L847 `getOrCreateOverlayEngine()`**：独立缓存 key `shengwuji_accessibility_overlay`；FlutterEngineGroup + DartEntrypoint("overlayMain") 创建；**复用分支置 dartReady=true / 新建置 false**
- 窗口 LayoutParams：TYPE_ACCESSIBILITY_OVERLAY，`Gravity.CENTER_VERTICAL or Gravity.END` 右缘垂直居中，非隐藏路径初始尺寸 dpToPx(28)×dpToPx(88)（隐藏路径直建 312×84），FLAG_NOT_FOCUSABLE + FLAG_LAYOUT_NO_LIMITS 等

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
- `resizeOverlay` 的 `enableDrag` 参数被原生忽略，整窗拖动未实现（收起把手的**纵向**拖动已于 2026-09-09 实现，见"把手长按拖动"小节；横向/整窗拖动仍无）
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

悬浮窗形态的"闪念"语音速记：不进主 App、不解锁思路，长按音量键即录，松手转写落库。录音期间浮窗为**变长录音胶囊**（`OverlayVoiceMemoBar`：宽度随秒数增长 80dp + 40dp/s、上限 300dp，显示 mm:ss 计时），停止后切**三点跳动胶囊**（转写中），转写完成回到展开面板出新卡。前 2 次速记录音会在胶囊下方附「再次长按音量上键，停止并转写」提示胶囊（见「停止提示胶囊」小节）。

### 交互矩阵

| 动作 | 行为 |
|---|---|
| 隐藏态长按音量键（长按槽位动作=悬浮窗录音） | 唤醒屏幕 + 100ms 震 → 浮窗出现（**冷启动隐藏窗口**，见下）+ `startVoiceMemo` → Dart 开麦录音 |
| 录音中再长按 | 50ms 短震 → `stopVoiceMemo` → Dart 停麦转写（**toggle 状态机**：`voiceMemoActive` 以 Dart 回执复位，3s 超时兜底） |
| 录音中说完话静音满设定秒数（2026-09-15 起，设置页「说完自动停止」开启时） | **自动停止并转写**——实时 Silero VAD 判定（说过话才计静音，一次都没说话不自动停），静音倒计时中胶囊把 mm:ss 换成「N 秒后自动停」实时提示（恢复说话自动回计时），触发后走 `stop()` 同链路（含 `voiceMemoStopped` 回执），与主动长按停止对 Kotlin 侧无差别；档位 3/5/8s，实现与主 App 快速录音共用 `lib/utils/quick_record_auto_stop.dart`，详见 @speech-recognition.md |
| 录音达 300s（5 分钟）上限 | Dart 侧上限 Timer 自动停（防按忘；原对齐锤子闪念胶囊 60s 设计，后放宽到 5 分钟），流程同主动停止 |
| 转写中隐藏浮窗 | **数据不丢**——WAV 已落盘 + 占位行已入库，转写 Future 在后台 isolate 继续跑完回填 |
| 主 App 正在录音时长按 | **麦克风互斥让位**（三道检查）：Kotlin `isRecording()` 读 `flutter.is_recording` → 退回"显示浮窗"；Dart `start()` 里 reload 再查 → 让位 false；主 App 侧 `diary_tab.startListening` / `record_tab._enterMoveMode` 第三道守卫 → SnackBar「悬浮窗正在录音，请先结束」+ return（防 Android 10+ 并发采集静默一路） |

### 「再次长按音量上键，停止并转写」提示胶囊（2026-09-13）

停止录音有两条路（贴屏端停止钮 / 再次长按音量上键），后者没有任何界面可见性——不看说明书的用户只知道按钮一条路。故在**录音胶囊正下方**追加一枚提示胶囊（`_StopHintPill`，文案「再次长按音量上键，停止并转写」），只在前 2 次速记录音展示（教育目的是"知道有这回事"，常驻反而喧宾夺主）：

- **展示计数跨会话持久化**：prefs key `overlay_voice_memo_hint_shown_count`（int，写入方/读取方均为 overlay engine 的 `OverlayVoiceMemoController.start`——开录时读（判定纯函数 `shouldShowStopHint(count)` = `count < 2`），开录成功即自增落盘（哪怕秒停/空录音丢弃也计为"已展示"，防反复打扰）；读取失败按"不再展示"兜底（宁缺勿扰）。只在录音态渲染，进转写即撤（`stop()`/`fail()` 复位 `showStopHint`）
- **窗口加高 64→84**（`voiceMemoWindowHeight`，Kotlin `VOICE_MEMO_OVERLAY_HEIGHT_DP` 硬编码副本同步）：84 = 胶囊 44 垂直居中带 + 下部提示条带（提示胶囊 ≈21dp + 间距 3dp）。展示提示时"胶囊+提示"整块在窗口内垂直居中，胶囊仅比历史位置上移 ~8dp；**84 必须 < 把手高 88**——build 硬不变量按「窗口高 < 把手高」判定 idle 帧渲染空白，≥88 会让 pre-gate 帧误渲染把手
- **配色 = 录音胶囊同款黑 72% 半透明底 + 白字 11 号**：悬浮窗下垫任意壁纸/应用，浅灰字裸放会在白色背景的应用上直接消失，自带深色底才有跨背景对比度保障（垫纯白背景时等效底色 ≈#4a4a4a，白字对比度 ≈8:1），且与录音胶囊构成同一视觉家族。提示胶囊贴屏端边缘与录音胶囊对齐（二者同带 12dp 停靠侧边距，随 `dockLeft` 镜像），不随胶囊变长移动
- **措辞强调「长按」**：启动与停止都是长按音量上键（短按是系统音量条），含糊的"再按"会诱导用户短按 → 只看到音量条、录音没停，反而制造新困惑
- 测试：`test/overlay_voice_memo_bar_test.dart`（展示/不展示/转写态不展示/左右缘贴屏端对齐/`shouldShowStopHint` 纯函数）

### 冷启动隐藏窗口（2026-08-29 第四轮修复：直建胶囊尺寸根治把手闪现）

语音速记从隐藏态冷启动时走 `showOverlay(hidden = true)`。**第四轮修复的根治思路：窗口直接以胶囊尺寸（312×84）创建隐藏窗口**——把手尺寸的窗口在此路径中不存在，无 resize、无把手帧，把手像素物理上不可能出现；同时删除依赖"窗口约束变化检测"的摘门逻辑（它有"resize 先落地、门后挂"的时序缺陷，基准会被记成胶囊尺寸导致门永不摘）。

```
showOverlay(hidden=true) → 窗口直接以胶囊尺寸 312×84 立即 addView（Kotlin 常量
                           VOICE_MEMO_OVERLAY_WIDTH_DP/HEIGHT_DP，唯一真值在 Dart 侧
                           overlay_constants.dart voiceMemoWindowWidth/voiceMemoWindowHeight），
                           alpha=0 + FLAG_NOT_TOUCHABLE（不可见、不挡触摸），
                           置 pendingVoiceMemoReveal
→ Dart engine 冷启动（~1.8s）全程在不可见状态完成；engine attach 瞬间 /
  startVoiceMemo 到达前的 pre-gate 帧（state 仍 idle）由 build 的硬不变量渲染
  纯透明空白（把手高度 88 > 窗口高度 84 永不合法，见下）
→ onStartVoiceMemo handler 顶部（hiddenReveal=true）立即挂揭示门——门挂上之前的
  await 链（权限/prefs/开流，20~80ms）期间 state 仍是 idle，挂门期 build 渲染
  纯透明空白（SizedBox.shrink），把手/胶囊像素不进帧
→ 录音开始（state 离开 idle）→ build 挂门短路处摘门 + 该帧构建完发 voiceMemoUiReady
  （确定性事件锚定"录音态首帧已构建"——窗口本就是胶囊尺寸，本帧即正确尺寸帧）
→ 原生收到后延迟 2 个 vsync（Choreographer.postFrameCallback 嵌套两层）才
  alpha=1 + 清 NOT_TOUCHABLE 揭示——构建完 ≠ 已呈现，光栅化 + SurfaceFlinger
  合成可能晚 1~2 vsync，多等一帧是便宜保险；首个可见帧即正确尺寸录音胶囊
```

Dart 侧另有一条不依赖时序的**硬不变量**（build 顶层，语音速记分支之前）：`_voiceMemo.state == idle && constraints.maxHeight < handleHeight` → 渲染纯空白。把手（88dp 高）永远不可能合法出现在胶囊高度（84dp）的窗口里，attach 瞬间/消息到达前的 pre-gate 帧物理上渲染不出把手。

清空方：`voiceMemoUiReady` 揭示 / `hideOverlay` / `destroyOverlayEngine`；防御兜底：pending 期间收到展开尺寸（width==-1，转写完成切面板）时 `resizeOverlay` 顺带揭示，防 voiceMemoUiReady 漏收后面板永远不可见；`triggerShowOverlay` 的 toggle 判断要求 `!pendingVoiceMemoReveal`（隐藏中用户不可见，不算"已显示"）。`_onVoiceMemoChanged` 的 `resizeOverlay(312,84)` 保留不动——把手在屏上开录的暖路径仍需要；冷路径是同尺寸 updateViewLayout，幂等无害。

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

- `isProUnlocked()`：读落盘 prefs `flutter.is_pro_unlocked` **或** `flutter.pro_trial_deadline_ms`（试用截止，未到即放行；与 Dart ProGate 同 key 同语义，2026-09-19 起双层判定。与 `isRecording()` 同款读取模式，每次按键现读，无 MethodChannel）
- `blockOverlayIfProLocked()`：不可用 → 50ms 短震 + **「暂未解锁」提示胶囊** + return
- **提示胶囊**（2026-09-19，替代旧 Toast）：复用语音速记隐藏窗直建机制，在原录音胶囊位置（312×84）弹提示——`showProLockedHint()` 直建隐藏窗 + `notifyDartProLockedHint()` 走 dartReady 挂起补发握手 → Dart `OverlayHome._proHintShown` 渲染 `ProLockedHintPill`（黑 72% 胶囊 +「暂未解锁，无法使用」）→ 首帧发 `voiceMemoUiReady` 揭示（提示窗保持 `FLAG_NOT_TOUCHABLE`）→ 3 秒 Kotlin 收窗。⚠️ 渲染分支必须排在揭示门与「84<88 硬不变量」判定之前（提示态 voiceMemo 仍 idle，排后会被吞成空白）；`proHintActive` 清零唯一入口在 `hideOverlay`（防借提示窗绕出完整悬浮窗/标志残留）；建窗失败或已有浮窗在场回退 Toast 兜底
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
| [android/.../VolumeKeyAccessibilityService.kt](../../android/app/src/main/java/com/shengwuji/app/VolumeKeyAccessibilityService.kt) | `isProUnlocked` / `blockOverlayIfProLocked` / `showProLockedHint` + 3 个 trigger 函数门禁挂点 |
| [lib/overlay/widgets/pro_locked_hint_pill.dart](../../lib/overlay/widgets/pro_locked_hint_pill.dart) | 「暂未解锁」提示胶囊组件 |
| [pro-license.md](pro-license.md) | Pro 授权码体系 + 7 天试用权威文档 |

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
