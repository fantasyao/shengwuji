# 悬浮窗（闪念胶囊）架构与实现记录

> 分支：`feature/floating-window` · 最近更新：2026-10-28 · 状态：**把手 + 数据链路 + 全屏透明面板/自适应胶囊 + 召唤式交互已打通**（音量键手势槽位召唤悬浮窗并自动展开、收起后可配置秒数自动彻底隐藏、显示时再触发立即隐藏、展开/收起推屏滑动动画；卡片标注换色、面板下拉刷新 WebDAV 同步、header 剪贴板一键存为笔记已落地（2026-10-28 起音量键手势也能直接存剪贴板，不展开面板）；把手支持长按拖动调整纵向位置；**悬浮窗整体为 Pro 付费功能**——设置页门禁 + 原生手势拦截双层，见"Pro 门禁"小节）

## 功能概述

系统级悬浮窗（锤子"闪念胶囊"样式），收起态为贴屏幕停靠缘（右缘为默认，可在设置页切换左缘，见"停靠侧左右切换"小节）的竖长**药丸双色胶囊把手**（窗口 28×88dp，胶囊本体向内缩一圈 ≈24×80dp 视觉缩小、触控面积不变；上半白/下半绿中间一道接缝横线，外围 1dp 细白描边与笔记卡片同款，⚡ 图标 + 竖排"闪记"居上半/下半两区，整体静置稍透明，默认垂直居中，**长按后可上下拖动调整位置**，见"把手长按拖动"小节；**视觉大小可在设置页三档调整（标准/小/迷你，迷你档只渲染闪电图标），竖线高度跟随缩**，见"把手大小档位"小节），点击或朝屏幕内侧滑动展开 300dp 宽侧栏面板（"随手记"日记列表）。

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
| （2026-09-22 本次提交） | 把手大小可调（三档，用户反馈"把手胶囊有点大"）：设置页悬浮窗二级页新增「把手大小」ChoiceChip 标准（100%，历史视觉）/ 小（75%）/ 迷你（50%，胶囊 12×40 放不下竖排文字、只渲染闪电图标 handleIconSizeMini=9），prefs `overlay_handle_size_percent`（int，非法值兜底 100）；**方案 A「只缩视觉不缩窗口」**——窗口恒 28×88（原生 HANDLE_WIDTH_DP 副本 + 语音胶囊 84<88 不变量 + dragHandle 宽守卫 + EDGE_LINE_WIDTH_THRESHOLD_DP=24 分流四者联动，真缩到一半宽 14<24 还会与竖线态撞车），胶囊本体=基准 24×80×档位、内缩派生 (2,4)/(5,14)/(8,24)，触控面积不变；竖线视觉高度跟随档位等比缩 64/48/32（用户定夺"把手变小竖线同步缩、只缩高"——宽 4dp 是可见性下限不缩），窗口 20×64 触摸缓冲区不动；读取方 _refreshSide/_scheduleAutoHide（跨 engine reload 惯例，下一次展开/收起状态转换生效，已显示中的把手不瞬变，同停靠侧心智）；Kotlin 零改动；新增 overlay_handle_size_test（纯函数三档派生 + widget 迷你档无文字/75% 档保留 8 例），flutter analyze 0 error + 564 测试全过；详见"把手大小档位"小节 |
| （2026-09-22 本次提交） | 把手主题三套 + 文字仅标准档（真机复验反馈"小档文字很挤"）：①文字显示收窄为仅标准档——`handleShowsLabel(percent, theme)` = 标准档且非拟物主题（首版迷你档隐藏文字，复验 75% 档 18×60 竖排文字也挤，档位与主题正交）；②新增「把手主题」三选一（prefs `overlay_handle_theme` string=enum name 坏串兜底 duo）：双色药丸（默认历史视觉）/ 蓝紫（笔记卡片色系——上=卡片默认蓝 defaultCardColor #6F9AF0、下=灵感标注紫 #AE82E4，测试断言引用 defaultCardColor 钉死一致性）/ 拟物胶囊💊（白+珊瑚红 #E0524E 纯造型无图标无文字——中缝+左侧高光条+下半暗部渐变三层出立体感），渲染属性集中 HandleThemeVisuals extension；③_refreshSide 改名 _refreshOverlayConfig（现管停靠侧+大小+主题三项，4 调用点全在本文件私有零外部风险）；设置页选择器 avatar 用上下双色 16dp 小圆直接预览配色；Kotlin 零改动；新增 overlay_handle_theme_test 8 例，flutter analyze 0 error + 584 测试全过；详见"把手主题"小节 |
| （2026-09-22 本次提交） | 息屏自动隐藏悬浮窗（AOD 防残留，用户反馈"录完音不管它，息屏后把手/竖线跟着息屏时钟一直杵在 AOD 上"）：复用锁屏即重锁的 ACTION_SCREEN_OFF receiver（IntentFilter 追加 ACTION_SCREEN_ON，同 receiver 兼管两态），SCREEN_OFF 时窗口 visibility=GONE、SCREEN_ON 恢复 VISIBLE + engine 手动 appIsResumed 兜底——ACTION_SCREEN_OFF 在息屏时刻即发出（AOD 属非交互态），「屏幕变黑」与「进入 AOD」都被覆盖，无需专门 AOD 检测 API；选 GONE 而非 hideOverlay 移窗：窗口/Dart engine/录音转写链路/自动隐藏计时全保留，亮屏各形态（把手/竖线/胶囊/面板）原样回归、Dart 全程无感知，且与 alpha（隐藏窗揭示期 0 / 认证让位 0.15）正交不泄露未揭示窗口；`overlayHiddenByScreenOff` 标志限定 SCREEN_ON 只撤销"因息屏而 GONE"的隐藏；录音中息屏录音不中断；Kotlin 单文件改动，Dart 零改动，compileDebugKotlin 通过 + flutter analyze 0 error + flutter test 全过；详见"息屏自动隐藏（AOD 防残留）"小节 |
| （2026-09-22 本次提交） | 息屏收起到驻留终态（真机用后升级诉求"亮屏后把手/面板也不该恢复"→用户拍板语义「进 AOD 必须收」）：SCREEN_OFF 在 GONE 之外追加发 screenAutoHide（dartReady && !proHintActive 守卫）→ Dart OverlayHome._onScreenAutoHide 立即收起——竖线开关开 → _enterEdgeLine 缩成贴边竖线、关 → closeOverlay 彻底移除，此后亮屏/解锁只会看到竖线（或录音中的胶囊），把手/面板不复活；「永久」档息屏不生效（只管亮屏常驻）；跳终态不走 _collapse 推屏动画——息屏后窗口 GONE、vsync 停、AnimationController 不跑，等 dismissed 回调会卡到亮屏，黑屏下空白帧协议天然满足，_enterEdgeLine 的 awaitingResize 守卫照挂、亮屏后首个 build 由 _maybeAdvanceMetricsStage 解除竖线淡入；守卫：录音/转写中跳过（活动会话不打断）、编辑中先 _saveEdit（失败留编辑态不丢输入，同 _openDiaryPage 先例）、先作废挂起的自动隐藏 Timer；SCREEN_ON 恢复 VISIBLE 保留（竖线显示的前提）+ overlayHiddenByScreenOff 标志/appIsResumed 兜底不变；flutter analyze 0 error（142 info 含新增 2 处 print）+ 585 测试全过 + compileDebugKotlin 通过；详见"息屏自动隐藏（AOD 防残留，2026-09-22 两轮）"小节 |
| （2026-09-22 本次提交） | 标注三色按钮上提时间行一级直出 + 时间格式改横杠（用户需求：标注在二级菜单操作太深，时间行右侧有空隙）：①展开卡时间文本后紧凑直出 ❗⭐💡 三按钮（`_buildInlineTagButton` 32×32 命中区相邻不加间距、选中白底圆 24+标注色图标 15，未选中白图标 17）——替代首版「底条标注入口 label_outline → 底行整行替换 ❗⭐💡✗」两步交互，二级菜单机制整体删除（`isTagPicking`/`onTagEntry`/`onTagPickCancel`/`_tagPickingIds` 及 6 处清理挂点，`_setDiaryTag` 去退出选择态分支）；②时间格式 `yyyy年M月d日 HH:mm` → `yyyy-MM-dd HH:mm`（省时间行横向空间给按钮组）；③时间行布局 Expanded(Text) → Text+按钮组+Spacer+chevron（按钮紧贴时间，空隙全给 chevron 前）；命中区 32=时间行高不撑高卡片（`_estimateExpandedHeight` timeRowH 条件补 onTagToggle）；Kotlin 零改动；flutter analyze 0 error + 585 测试全过（标注测试改写为时间行直出断言 + 新增横杠时间格式断言）；详见"卡片标注"小节 |
| （2026-09-27 本次提交） | 面板字体大小五档（用户需求：以现字号为基准 ±2 档）：设置页悬浮窗二级页「字体大小」ChoiceChip 特小/小/标准/大/特大，prefs `overlay_font_size_step`（int 档位 -2~+2，`parseFontSizeStep` clamp 连续刻度语义——与把手大小的白名单语义不同），每档 1pt（0.5pt 档差真机不可辨、2pt 档差最小档跌破可读下限）；**作用范围只限日记面板文字**（卡片收起/展开/编辑/删除确认 + 已归档分隔线/空态/错误态）——把手有独立大小档位（叠加会双重缩放）、语音速记胶囊宽度预算按 15 号字调过、提示胶囊是转瞬 UI，三者均不缩放；读取方 `_refreshOverlayConfig`/`_scheduleAutoHide`（跨 engine reload 惯例，下一次状态转换生效，同把手大小心智）；⚠️ 收起态文字测量缓存 key 必须含字号（不同档位同文本宽度不同，不进 key 会串档，估算偏窄把短文字顶出省略号——046fe0b 同类坑）；查看态勾选框反缩放倍率须用缩放后字号（框架按 textScaler.scale(实际字号)/实际字号 放大，用基准值反缩放会二次偏差）；渲染与三处 painter 测量（收起宽度/展开高度/点击偏移换算）同源 `_fs()` 缩放；设置页选择器 avatar Aa 图标大小随档位递减/递增直观预览；Kotlin 零改动；新增 overlay_font_size_test 7 例（parse clamp/默认 + fontScaled + 缓存分档），flutter analyze 0 error + 632 测试全过；详见"面板字体大小档位"小节 |
| （2026-09-27 本次提交） | 硬不变量高度误判根治（Redmi miro 450dpi 真机反馈「收起后把手永不出现、点竖线后消失」，渲染分支日志实锤）：Kotlin dpToPx 截断取整 → density 2.8125 下把手窗 88dp=247.5px 截 247 → Flutter 实测 87.8 < 88，旧判定 `maxHeight < handleHeight` 把把手窗误判为胶囊高度档渲染空白（440dpi 等密度整除设备不触发故开发侧不可复现）；修复双保险——①Dart 判定改纯函数 `OverlayConstants.isCapsuleHeightWindow`，阈值取两设计高度中点 86（取整误差恒 <1px≤1dp，把手窗实测最低 ≈87.0/胶囊窗实测最高 ≈84.5，任意密度不踩界）；②Kotlin dpToPx(Int) 截断改四舍五入（roundToInt，88.18 实测回到 ≥88）；新增 overlay_window_height_threshold_test 4 例；flutter analyze 0 error + 测试全过 + compileDebugKotlin 通过；详见"冷启动隐藏窗口"下「硬不变量高度误判」小节 |
| （2026-09-28 本次提交） | 展开面板态 toggle 隐藏后再召唤只出胶囊根治（用户反馈「双击音量减显示悬浮窗，再双击消失，第三次双击出来是胶囊」）：根因 = `_lastWindowConstraints`（resize 落地检测基准）跨窗口会话陈旧——展开面板态被 toggle 隐藏时窗口以全屏尺寸移除，基准停在全屏；下次 showOverlay 以 28×88 重建后，`_expand` 的 setState(awaitingResize) 若先于首帧 build 执行（prefs reload 的 await 通常让首帧先跑则幸免，时序竞态），首帧 28×88 ≠ 陈旧全屏基准被 `_maybeAdvanceMetricsStage` 误判「resize 已落地」提前摘守卫并启动滑入 → `_waitForBlankFramePresented` 续段见 stage 已非 awaitingResize 直接中断 → `controller.expand()` 永不调用，窗口卡死把手尺寸。与揭示门「基准约束跨会话陈旧」（64b1c09）同款病理。自动隐藏路径不触发（收起态 28×88 时移除，基准恰好正确）；冷启动首次召唤不触发（基准 null 有 `last == null → return` 保护）——故仅「展开面板态 toggle 隐藏 → 再显示」一条路径中招。修复：`_resetFromNative` 补 `_lastWindowConstraints = null`（窗口移除即基准作废，下个会话首帧 `last==null` 天然不误判）；Dart 单文件改动，Kotlin 零改动；flutter analyze 0 error 且 issue 数 126 与基线持平、flutter test 656 全过 |
| （2026-09-28 本次提交） | 滑动直接删除 + 3 秒撤销（用户需求：划走归档改为可选删除，归档入口由卡片顶端圆圈保留）：设置页悬浮窗二级页新增「滑动操作」区开关「滑动直接删除笔记」（prefs `overlay_swipe_delete_enabled`，默认关=历史划走归档，同走 Pro 门禁）；开启后活跃卡划走直接删除——`_onCardSwipeDismissed` 划走回调里现场 reload 读开关（动作型开关同 `_onEdgeLineTap` 模式，即时生效）分流到 `_swipeDeleteWithUndo`：**真删库行**（墓碑由 DbHelper.deleteDiary 内置记录）+ 面板 header 下方浮现黑 72% 撤销胶囊（`UndoDeletePill`，OverlayPanelHeader 同视觉家族），`swipeDeleteUndoWindow`=3s 内点「撤销」把行全字段原样插回（`DbHelper.restoreDeletedDiary`：sync_uuid 保留跨端身份不变 + 墓碑清除防云端同 uuid 条目永不拉回，本地自增 id 重新分配、排序键 created_at 未变故卡片回到原位置）；**录音文件延迟到窗口到期才补删**（窗口内音频在盘上，撤销才能连录音一起还原）；单槽位——再次滑删/面板收起/窗口移除/dispose 都先让前一个删除落定（补删其录音）；已归档卡划走=删除的既有路径不受影响；锁定打码卡在开关开启时同样走删除语义门禁；新增 db_restore_deleted_diary_test（真删→恢复全字段+墓碑清除）与 undo_delete_pill_test 2 例；flutter analyze 0 error（+10 info 均为同款 print）+ flutter test 659 全过 |
| （2026-09-28 本次提交） | 「永久」档把手息屏解锁后消失根治（用户反馈「唤醒胶囊后息屏再解锁，胶囊和侧滑条都没了」，log2 实锤）：根因 = 09-22「进 AOD 必须收」语义**无条件**推进驻留终态且永久档不豁免——用户配置永久档+竖线开关关，息屏即走 closeOverlay 彻底移除，与「永久=把手一直在」的字面承诺正面冲突；用户拍板新语义「永久档穿越息屏」：`_onScreenAutoHide` 分流改走纯函数 `OverlayConstants.screenOffActionFor`（唯一权威）——永久档 → keepHandle（展开面板仍先无条件跳终态收回把手，面板永不穿越息屏；息屏期间仅由 Kotlin GONE 保 AOD 干净，亮屏 VISIBLE 把手原样回来，竖线开关在永久档下对息屏不生效），限时档维持「进 AOD 必须收」（竖线开→竖线/关→移除）不变；Dart 改动（分流纯函数 + overlay_home 接线），Kotlin 零改动；新增 overlay_screen_off_action_test 4 例；flutter analyze 0 error + flutter test 663 全过（659 基线+4 新增）；详见「息屏自动隐藏（AOD 防残留）」小节第三轮 |
| （2026-09-29 本次提交） | 竖线距屏幕边缘间距三档（用户反馈：贴带黑边的钢化膜后完全贴边的竖线被膜边遮住看不见，对比小米系统侧边栏有内移边距）：设置页悬浮窗二级页「贴边竖线」卡新增「距屏幕边缘间距」ChoiceChip 贴边（0，缺省=历史行为）/ 内移（4）/ 最里（8——首版 0/8/16 的 16 档用户实测内移过多，整体下调为 0/4/8，旧档位 16 落盘值按非法值兜底回 0），prefs `overlay_edge_line_margin_dp`（int，白名单解析非法值兜底 0）；**纯 Dart 视觉内移**（同把手大小「只缩视觉不缩窗口」思路）——窗口 20×64 与透明触摸缓冲区不动，竖线在窗口内经 `edgeLinePadding` 纯函数向屏内侧偏移，窗口内硬上限 16 = 窗口宽 20 − 线宽 4（⚠️ 不靠加宽窗口换更大间距：窗口宽 >24 会撞 Kotlin `EDGE_LINE_WIDTH_THRESHOLD_DP`=24 线态判定）；读取方 `_refreshOverlayConfig`/`_scheduleAutoHide`（跨 engine reload 惯例，下一次状态转换生效，已驻留竖线不瞬移），随停靠侧镜像；同走 Pro 门禁；Kotlin 零改动；新增 overlay_edge_line_margin_test 3 例（parse 兜底/padding 方向镜像/「最大档+线宽≤窗口宽」不变量），flutter analyze 0 error + 666 测试全过（663 基线+3 新增） |
| （2026-09-29 本次提交） | 滑动删除撤销胶囊贴停靠缘（用户反馈：停靠右缘左滑删除时撤销提示出现在屏幕中部，单手够不着「撤销」）——首版 `UndoDeletePill` 裸放在面板 Column（crossAxisAlignment.start）里，停靠右缘时胶囊贴面板左端=屏幕中部，停靠左缘恰好贴边，两侧不一致；修复：`UndoDeletePill` 新增 `dockLeft` 参数（overlay_home 传 `_sideLeft`），内部包 `Align(dockLeft ? centerLeft : centerRight)`——Align 在面板宽度约束内撑满、Row.min 收缩到内容宽，胶囊贴停靠缘拇指区，与 OverlayPanelHeader/录音胶囊同款镜像规则；undo_delete_pill_test 补两侧 Align 断言（3 例全过），flutter analyze 0 error |
| （2026-09-29 本次提交） | 展开面板态 toggle 隐藏后再召唤只出胶囊**二次根治**（8a2c216 修复后真机复现「还是不行」，日志实锤）：8a2c216 在 `_resetFromNative` 清 `_lastWindowConstraints = null`，但随后 `_controller.collapse()` 触发的尾帧 build 照常跑 `_maybeAdvanceMetricsStage`——此刻窗口已移除而 FlutterView metrics 仍停在移除前全屏尺寸，**null 刚清空就被同会话尾帧重新记回陈旧全屏基准**，下个会话首帧（28×88）≠ 陈旧基准又被误判「resize 已落地」提前摘守卫，同一卡死路径复现。修复：新增 `_windowRemoved` 标记——`_resetFromNative` 置位（唯一置位方），置位期间 `_maybeAdvanceMetricsStage` 直接 return 不记基准；复位点 = onExpand / onStartVoiceMemo / _onNewNote / onShowProLockedHint 四个 handler（已核对 Kotlin `showOverlay` 全部 5 个调用点都紧随这四个消息之一，即「新窗口会话开始」的 Dart 侧权威信号；⚠️ 不能在 `_expand` 里复位——转写完成于窗口移除后时 `_onVoiceMemoChanged` 也调 `_expand`，在那复位会重新打开污染窗口）。Dart 单文件改动，Kotlin 零改动；flutter analyze 0 error（136 issue 与基线持平）、flutter test 663 全过 |
| （2026-09-29 本次提交） | **卡片长按拖动排序**（用户需求：悬浮窗可以长按调节顺序，长按震动反馈，调节时其余卡片对应移动让开，仅限未展开的可长按；方案拍板 B：顺序持久化到 diary 表 sort_order 列，主 App/电脑访问全跟随）：①DB v15→v16 加 `sort_order`（仅活跃区有意义、越小越靠前、归档区恒 NULL——归档即清空/恢复回顶部/新插入置顶 min-1/撤销删除恢复原值），getDiaries 排序 `is_archived ASC, (sort_order IS NULL) ASC, sort_order ASC, created_at DESC`——漏网 NULL 行排活跃区尾部时间倒序兜底（忘赋值无害，首次重排即规范化），主 App 日记页/电脑访问服务读同一 SQL 零改动自动跟随；升级事务只做 DDL，存量回填首开幂等执行（⚠️ 迭代方向必须 created_at ASC，DESC 会把顺序整个颠倒，防再犯注释在 db_helper.dart）；②悬浮窗 UI：列表换 `ReorderableListView.builder`（`buildDefaultDragHandles: false` + 活跃+收起+非编辑中卡片条件包 `ReorderableDelayedDragStartListener`），拖起瞬间 `onReorderStart` → `performHaptic('tick')`，proxyDecorator 用 `Material(type: transparency)`（透明面板禁默认 elevation 白底浮层，既有教训），落点 clamp 与内存重排收纯函数 `reorderActiveItems`（拖到归档区位置=落活跃区末尾，归档区/分隔线不动）；内存先行 setState → `reorderActiveDiaries` 事务规范重写 0..n-1 → `DiarySyncBridge.bump()` 主 App 感知，失败回库恢复真相（照 _setDiaryTag 模式）；③周边：备份 CSV 第 8 列「排序」（放最后旧 App 兼容）、云同步 DiaryPayload 带 sortOrder 编解码宽容（下载插入空活跃区尊重远端值/非空堆顶部，两端各自重排不互相覆盖）、web server 聚合签名追加 `SUM(sort_order * id)` 加权和（纯 SUM 对 0..n-1 重排恒不变会漏检）；新增 overlay_diary_reorder_test 10 例 + db_sort_order_test 七阶段 + db_upgrade_v16_test；flutter analyze 0 error、flutter test 680 全过；详见「卡片长按拖动排序」小节 |
| （2026-10-06 本次提交） | **面板高度（可见条数档位）**（用户需求：大屏手机单手拿时，面板顶部的新建/展开按钮在屏幕上方够不着）：设置页悬浮窗二级页「字体大小」后新增「面板高度」ChoiceChip 10/9/8/7/6 条五档（默认 10 = 历史行为），prefs `overlay_panel_max_cards`（int 6~10，`parsePanelMaxCards` clamp 连续刻度语义同 fontSizeStep），单位用条数（用户拍板，比高/中/低档位直观）；**关键设计：面板是顶部锚定布局，只缩列表限高只会让底边上移、顶部按钮原地不动**——必须同时给面板顶部加等量下压偏移（`panelTopOffsetFor` = (默认档−当前档)×一张卡高，Padding 包在面板 Align child 外层），才兑现用户描述的「满列表整列底边位置不变、顶部按钮组下移进拇指区」；设计不变量 `panelTopOffsetFor(n) + panelListMaxHeightFor(n)` 为定值（测试钉住）；列表限高 `panelListMaxHeightFor(_panelMaxCards)` 替代旧常量直引（默认档结果 == panelListMaxHeight，测试钉住）；Padding 在 Align 约束内缩小可用高度，Column Flexible 列表仍被窗口剩余高度约束、矮屏不溢出；读取方 `_refreshOverlayConfig`/`_scheduleAutoHide`（跨 engine reload 惯例，下一次状态转换生效，已展开面板不瞬移），同走 Pro 门禁；设置页选择器 avatar 列表图标大小随条数递减直观预览；Kotlin 零改动；新增 overlay_panel_height_test 8 例（parse clamp/默认 + 限高递减档差 + 偏移 + 底边不变不变量 + 最低档可滚动），flutter analyze 0 error（print info 与基线同款）+ flutter test 688 全过（680 基线+8 新增）；详见「面板高度（可见条数档位）」小节 |
| （2026-10-06 本次提交） | **大爆炸分词层**（用户需求：展开卡正文长按 → 锤子 Big Bang 式全屏分词窗口，词块点选 + **滑动连选首期就要做** + 一键复制；全屏视觉而非底部弹层，用户拍板）：①入口 = 展开卡查看态正文长按（`onLongPressText`），空内容占位行/锁定打码卡不传（明文不出卡片，同 AI 对话门禁）；⚠️ 正文点按进编辑从 `onTapDown` 改 `onTapUp`——down 触发会抢在长按压住之前先进编辑态，两个回调靠手势竞技场分流的前提是 tap 等抬起；②分词复用修正对体系的 dart_jieba（`BigBangTokenizer`，词典 assets/jieba_dict.dgz 运行时拷贝），**overlay isolate 独立懒加载**（static 缓存不跨 isolate，主 engine 经 ContextCorrector 加载过的对本 isolate 无效——FFI 绑定同款铁律），jieba 失败回退字符级切分（CJK 逐字 + ASCII 归并），功能永不缺席；③手势模型：词块 onTap toggle + 外层 Listener（不抢竞技场）按下记锚点、位移超 kTouchSlop 才进连选（未超松手 = tap 照常 toggle）、锚点→当前命中区间整体置选；按下落在词块上时 physics 换 NeverScrollable 锁滚动（防边选边滚），空白/标点区按下不锁照常滚动；词块 Rect 相对词块区容器缓存（同坐标系随滚动平移不失效），命中经 globalToLocal 换算；④标点/空白降级渲染不可选但保留在序列——`joinSelected` 区间拼接把夹在选中词之间的原文带出（"苹果，牛奶 bread"），跳过可选词 = 跳跃点选直接首尾相接；⑤复制走原生 `copyText` 通道（自带 EFFECT_TICK + 剪贴板）成功后关层；选择变化/长按唤起 tick 震动 40ms 节流（AI 对话按钮同款线性马达家族）；层压在 `_buildPanel` Stack 最上层（窗口本就全屏无需 resize），`_collapse`/`_resetFromNative` 同步清零；新增 big_bang_tokenizer_test 10 例 + big_bang_layer_test 7 例（含滑动连选单 moveTo 一步铺满区间、短按落回 toggle），flutter analyze 0 error + flutter test 706 全过（689 基线+17 新增）；详见「大爆炸分词层」小节 |
| （2026-10-06 本次提交） | **大爆炸两处真机反馈修复**：①**二次滑选覆盖旧选根治**（用户反馈：开头滑选 3 个词后再到末尾滑选追加，开头的选中态丢失只剩末尾 3 个）——根因 = `_applyRange` 每轮 clear 重建 `_selected`，新一次滑选把旧选整个替换；修复 = 追加语义：本轮起步快照已有选择为基线 `_dragBase`，区间与基线取并集（松手后再次滑选/点选是追加而非覆盖），同一轮内拖回缩小区间只影响本轮新增部分；②**UTF-16 异常刷屏根治**（logcat 反复 `Invalid argument(s): string is not well-formed UTF-16`）——根因 = dart_jieba 按 UTF-16 code unit 切分，emoji 代理对被劈成高代理+低代理两个孤立 token，Text 渲染孤立代理直接抛（临时测试实锤：`测试😀一下` 切出 `d83d`/`de00` 两个单码元碎片）；修复 = `fromRawTokens` 按代理对完整性把相邻碎片并回完整字符再判可选性，"拼接==原文"不变量保持；新增 4 测试（两次滑选追加、点选+滑选混合追加、emoji 碎片合并×2），flutter analyze 0 error + flutter test 710 全过（706 基线+4 新增） |
| （2026-10-06 本次提交） | **大爆炸层高度对齐面板 header 顶**（用户反馈：全屏弹窗太高、单手够不着顶栏）——层顶边从窗口顶下移到面板 header（新增按钮所在工具条）上缘，新增 `BigBangLayer.topInset` = 状态栏固定避让（新常量 `panelHeaderTopPadding`=40，与 `_buildHeader` 同源，旧硬编码 40 双处归一）+ 面板高度档下压偏移（`panelTopOffsetFor(_panelMaxCards)`）——**随设置页「面板高度」档位联动**：档位越低层顶边越低，默认 10 档 inset=40 与旧行为一致零变化；顶边上方改透明留白（透出下层应用画面，视觉上层不再撑满全屏），留白区 opaque 命中 + onTap 就地吸收触摸（底层是面板空白区收起手势，穿透会把面板连同本层一起收掉）；层内顶部 40 避让移除（改由留白承担）、底部 48 避让不变；新增 topInset 测试 1 例，flutter analyze 0 error + flutter test 711 全过（710 基线+1 新增）；详见「大爆炸分词层」小节 |
| （2026-10-06 本次提交） | **大爆炸跳跃选择交界丢空格修复**（用户反馈：第一次滑选英文词组内部空格正常，追加第二次滑选后两段交界粘词——`touch and holdafter two hours`）：根因 = `joinSelected` 的跳跃间断（中间隔着被跳过的可选词）一律直接首尾相接，间断区两端紧贴的空白也被丢掉；修复 = 间断区原文仍不带出（跳跃语义不变），但间断区首/尾 token 是空白时交界补一个空格——英文词间空格保留，中文跳跃点选边界本无空格行为不变（`苹果，香蕉，牛奶` 跳选仍得 `苹果牛奶`）；旧用例 `苹果，牛奶 bread` 跳选 {0,4} 期望相应从 `苹果bread` 改为 `苹果 bread`（间断区尾部空格被保留，更忠实原文）；新增 2 测试（英文两次滑选交界不粘词、中文间断无空白仍首尾相接）+ 2 旧例改期望，flutter analyze 0 error + flutter test 713 全过（711 基线+2 新增） |
| （2026-10-06 本次提交） | **大爆炸底栏新增搜索按钮**（用户需求：分词窗口底部加搜索按钮打开浏览器搜索选中文字，浏览器在设置页选择、未设置用系统默认；用户拍板搜索引擎也可选）：底栏预览与复制之间插入搜索按钮（`onSearch` 可空参数 null 不渲染，旧测试零影响），`joinSelected` 拼接 → `buildSearchUrl`（新文件 `lib/utils/big_bang_search.dart`：百度/必应/Google 注册表 + prefs 读取，reload 跨 engine 惯例）→ 新增原生 `openUrl` 通道方法（`ACTION_VIEW` + 可选 `setPackage` 指定浏览器，`ActivityNotFoundException` 回落系统默认；overlay/MainActivity 两条通道各一份，overlay 侧 `FLAG_ACTIVITY_NEW_TASK`）；设置页新增「大爆炸搜索」二级页（引擎 ChoiceChip + 浏览器单选列表，浏览器枚举走新增 `getInstalledBrowsers`——`queryIntentActivities(ACTION_VIEW, https)` 只列真浏览器，图标懒加载复用 `getAppIcon`，主页入口行副标题「引擎 · 浏览器」），prefs `search_engine`/`search_browser_package`/`search_browser_name`；新增 big_bang_search_test 10 例 + big_bang_layer_test 4 例（搜索透出拼接文本/无选中禁用/null 不渲染/失败不关层）+ search_settings_page_test 4 例，flutter analyze 0 error + flutter test 全过 + compileDebugKotlin 通过；详见「大爆炸分词层」生命周期与复制小节 |
| （2026-10-06 本次提交） | **大爆炸「二次爆炸」**（用户需求：jieba 切分不合心意——如「app叫声物记」切成【app、叫声、物记】，想要单字粒度挑选；按钮位置用户拍板底栏，不做选中词上方浮出气泡）：底栏预览与搜索之间新增刀图标按钮（`Icons.content_cut` + Tooltip「再炸成单字」，锤子原版同款位置语义），点击把**选中词块**就地炸成单字（中文逐字、英文逐字母，emoji 不劈代理对——`explodeToChars` 逐 rune 切，与 `charSplit` 的「连续 ASCII 归并」回退链语义刻意分开）；炸出的单字**保持选中**（直接复制/搜索，或点掉多余单字逐字微调）；选中全是单字/无选中/分词中时按钮禁用（`_canExplode` 幂等）；不做撤销（爆炸是追加式变换，重炸成本仅一次长按）；⚠️ tokens 更换后旧 index 的命中 Rect 全部失效——`_prepareKeys` 同步清 `_rects`（setState 到 postFrame 重缓存之间 `_hitToken` 会拿旧 Rect 命中新词块）；tokenizer 新增 6 例 + layer 新增 8 例（含爆炸后滑选命中新单字词块的 Rect 重建回归），flutter analyze 0 error + flutter test 744 全过（730 基线+14 新增）；详见「大爆炸分词层」分词/生命周期与复制小节 |
| （2026-10-07 本次提交） | **大爆炸层降高 + 词块区纵向居中**（用户两条反馈：主 App 大爆炸弹窗还是全屏单手不好操作、层内文字不要从上往下要纵向居中；两侧都要居中）：①主 App 层顶边从「状态栏高度避让」改为按悬浮窗「面板高度」**8 条档位**的顶部高度取值——新常量 `OverlayConstants.bigBangMainAppTopInset` = panelHeaderTopPadding(40) + panelTopOffsetFor(8) = 152dp（`bigBangMainAppRefCards`=8 唯一真值，测试钉死数值），主 App 无档位设置项固定参照 8 条档；②词块区纵向居中收在共用组件 `BigBangLayer._buildTokenArea` 一处（主 App/悬浮窗同时生效）——`LayoutBuilder` 取视口高 → `ConstrainedBox(minHeight: 视口高−24)`（扣 ScrollView 上下 padding 12×2，矮视口 clamp 0）→ `Center` 包词块 Wrap：Center 在无界高度下收缩到内容、被 minHeight 钳到视口高，短内容居中、长内容超高时居中自然退化为可滚动；命中 Rect 相对 `_areaKey` 缓存不受影响（同坐标系随滚动平移）；新增常量测试 1 例（overlay_panel_height_test）+ 居中 widget 测试 1 例（词块中心 ≈ 词块区视口中心 ±30），flutter analyze 0 error + flutter test 746 全过（744 基线+2 新增） |
| （2026-10-07 本次提交） | **大爆炸层底部改透明关闭条**（用户反馈：复制按钮下方的 48dp 深色条带「完全盖住」底部，希望加关闭按钮让单手大拇指可关层，或者改透明点击关闭——两个方案合并实现）：底部 48dp 深色避让条带移出 Material 改 `_buildCloseStrip()`——**透明透出下层画面**（主 App 透出日记页 / overlay 透出底层应用）+ **整条点击即关闭** + 中间一枚 ✕ 圆形按钮（黑 55% 底白图标，深浅背景都可见）作视觉落点；视觉透明但 `HitTestBehavior.opaque` 吸收触摸——overlay 侧穿透会命中面板空白区收起手势把面板连同本层一起收掉，主 App 侧穿透会点到下层日记卡；高度 48 沿用原底部避让惯例（FLAG_LAYOUT_NO_LIMITS 拿不到 insets）；⚠️ 顺带修复顶部留白命中失效：`SizedBox` 只给高度在 Column（交叉轴默认 center）里收缩到 0 宽，「吸收触摸」形同虚设——补 `width: double.infinity`；关闭条 widget 测试 2 例（条带非按钮区点击关闭 / ✕ 按钮点击关闭），flutter analyze 0 error + flutter test 748 全过（746 基线+2 新增）；详见「大爆炸分词层」生命周期与复制小节 |
| （2026-10-07 本次提交） | **大爆炸层四角圆弧化**（用户需求：分词弹窗四周边缘做圆弧化处理，随手记/悬浮窗两侧都要）——收在共用组件 `BigBangLayer.build` 一处两侧同时生效：新常量 `OverlayConstants.bigBangCornerRadius`=20dp，深色主体 Material 加 `borderRadius` + `clipBehavior: Clip.antiAlias`（Material 的 borderRadius 只影响背景形状，子内容须显式 clip 才随圆角裁切），圆角缺口透出下层画面，与顶部透明留白/底部透明关闭条同一「层不撑满全屏」视觉语言；⚠️ 缺口区域外包 `GestureDetector(opaque, onTap:(){})` 吸收触摸——裁切外的角落若不接住，overlay 侧穿透会命中面板空白区收起手势（把面板连同本层一起收掉）、主 App 侧（opaque:false 路由无 barrier）穿透会点到下层日记卡；两个调用方 overlay_home/diary_tab 零改动；新增圆角 widget 测试 1 例（Material borderRadius/clipBehavior + 常量数值钉死），flutter analyze 0 error + flutter test 749 全过（748 基线+1 新增）；详见「大爆炸分词层」小节首段 |
| （2026-10-07 本次提交） | **大爆炸滑动取消**（用户需求：在已连选的词块上滑动应取消选择，对齐锤子原版——此前滑动只能追加不能取消）：连选模式由**锚点词块的选中态**决定——起步时锚点已选中 → 本轮为「滑动取消」（`_dragDeselect`），锚点→当前命中区间从基线 `_dragBase` 中剔除而非并集；锚点未选中 → 维持追加置选不变（第二轮滑选不丢旧选的既有语义不受影响，追加轮经过已选词块也不误剔——模式只看锚点）；同一轮内拖回缩小区间可恢复（基线不动，只影响本轮划到的范围），取消后新一轮在已取消词块上滑选自动回到追加模式（每轮独立判定）；改动收在 `BigBangLayer` 一处（`_applyRange` 按模式分流 + 起步判定 + 两处收尾复位），主 App/悬浮窗两侧共用同时生效，调用方零改动；新增 widget 测试 4 例（滑过取消+复制剩余 / 拖回恢复 / 追加轮不误剔 / 取消后重新追加），flutter analyze 0 error + flutter test 753 全过（749 基线+4 新增）；详见「大爆炸分词层」手势模型小节 |
| （2026-10-08 本次提交） | **大爆炸层白底浅色化 + 下层压暗遮罩**（用户需求：分词弹窗改锤子原版白色卡片视觉，顶部/底部透出下层画面处要有明暗分层；白底下文字变黑、滑选选中变白）——收在共用组件 `BigBangLayer` + `OverlayConstants` 一处两侧同时生效：①`bigBangBackground` 深色（0xFA101319）→ 近不透明白（0xFAFFFFFF），文字/控件配色整体反转——未选词块浅灰底（black 5%）深字（black87）、选中维持主题蓝底白字（滑选/点选即「变白」，对齐原版选中高亮）、标点 black38、顶栏标题/计数/全选清空/关闭钮与「分词中…」深色化、底栏预览条与禁用按钮浅灰化；②新增 `bigBangScrimColor`（35% 黑）统一铺在顶部留白、圆角缺口层、底部关闭条三处透出下层画面的区域——下层内容隐约可辨但明确退到「下一层」，白色主体浮出；吸收触摸的 GestureDetector 结构不变（遮罩只改视觉不改命中）；改动不涉及手势/分词/复制逻辑；新增浅色配色 widget 测试 1 例（白底常量钉死 + 遮罩 3 处计数 + 未选词块深字断言）、圆弧测试名对账，flutter analyze 0 error（warning 均为基线既有）+ flutter test 754 全过（753 基线+1 新增）；详见「大爆炸分词层」小节首段 |
| （2026-10-08 本次提交） | **大爆炸层深色模式适配**（用户需求：APP 深色模式下白底太刺眼，白色改黑色）——`BigBangLayer` 新增可空参数 `isDark`（null=跟随 Theme brightness）：主 App 侧经透明路由推入、Theme 已解析 system 档，不传参零改动自动跟随；悬浮窗 engine 固定浅色主题（跨背景对比度既有设计，自动判定恒浅），唤起时由 `OverlayHome._openBigBang` reload 读 `theme_mode` prefs 经 `parseThemeMode` 解析（system 档按 platformBrightness 裁决）显式传入——大爆炸层是悬浮窗侧唯一消费 theme_mode key 的组件。深色底 `bigBangBackgroundDark`=0xFA101319（浅色化前历史深色值直接复用）；9 处配色位（主/次/动作文字、未选词块底与描边、禁用底与图标、底栏预览条底与描边）走双色板辅助函数整体反转；选中词块恒主题蓝底白字、压暗遮罩与底部 ✕ 按钮深浅共用；新增深色配色 + isDark 缺省跟随 Theme 两条 widget 测试，flutter analyze 0 error（warning 均基线既有）+ flutter test 761 全过（+2 新增）；详见「大爆炸分词层」小节 |
| （2026-10-19 本次提交） | **面板 header 末位按钮：收起 chevron 换语音速记录音按钮**（用户需求：悬浮窗顶部折叠按钮换成录音按钮，点击即走会随时间变长的录音胶囊入口）——`OverlayPanelHeader` 的 `onCollapse` 参数/收起 chevron 替换为 `onStartVoiceMemo` + `Icons.mic`（tooltip「语音速记」），收起面板的职责收编到空白区点击/滑动与卡片划走手势；⚠️ 按钮**不直接调 Dart `_voiceMemo.start()`**——Kotlin 侧 toggle 状态机（voiceMemoActive）/四级 watchdog/Pro 门禁/主 App 麦克风互斥都以原生为权威，Dart 直调会让原生失联（toggle 停录失灵、watchdog 缺席）——新增通道方法 `startVoiceMemo`（Dart `AccessibilityOverlay.startVoiceMemo()` → Kotlin handler 直调 `triggerVoiceMemoOverlay()`，与音量键「悬浮窗录音」动作同一入口），原生随后经既有 `startVoiceMemo` 消息回 Dart `onStartVoiceMemo` handler 开录，面板窗口随即 resize 成录音胶囊（312×84，暖路径 hiddenReveal=false 立即揭示）；录音中 header 随窗口离屏不可达，toggle 停止分支天然不经过此按钮；header 测试 6 例改写（mic 断言/chevron findsNothing/第四回调接线/镜像只留 Align 与阴影），flutter analyze 148 issue 与基线持平 + flutter test 789 全过 + compileDebugKotlin 通过；详见「面板 header 录音按钮」小节 |
| （2026-10-19 本次提交） | **「全部展开」状态跨会话沿上次**（用户反馈：点过全部展开后下次再进面板卡片又全收起）——新增 prefs key `overlay_expand_all_cards`（bool，缺省 false=历史行为），`_toggleExpandAll` 为唯一写入方（展开全部→true/收起全部→false），`_expand` 收起态主分支在滑入动画首帧前读取并把当前 `_diaries` 全部 id 加回 `_expandedIds`；写入/读取同为 overlay engine（主 App 无入口），同 isolate prefs 缓存天然同步无需 reload；边界：恢复用上一会话残留列表（State 常驻 id 稳定），恢复后 `_syncDiariesIfChanged` 重查不清 `_expandedIds` 故不被冲掉，期间新增的卡不自动展开（转写新卡由 `_expandFirstDiaryAfterLoad` 管）；三处清空点（`_finishCollapse`/`_resetFromNative`/`_onScreenAutoHide`）照旧清内存态，持久化标记由 prefs 承担；flutter analyze 0 error（+2 info 同款 print）+ flutter test 793 全过 |
| （2026-10-20 本次提交） | **语音搜索跳转**（用户需求：语音速记/按住说话转写完说「搜索 xxx」直接打开浏览器搜，不用再手切）——转写收尾纠错后文本以「搜索/搜索一下/搜一下」严格开头（白名单前缀，同清单提取「代办/待办」思路，新检测器 `lib/utils/search_command_detector.dart`，先长后短匹配防「搜索一下」被「搜索」截留「一下」残留）即 `loadSearchConfig()` + `openUrl` 拉起浏览器搜索关键词（引擎/浏览器复用「大爆炸搜索」配置）；日记照常 updateDiary 回填原文不变；拉起成功置 controller 新标志 `consumeExpandOnFinish`，`_onVoiceMemoChanged` 的 transcribing→idle 分支读即清并跳过 `_expand`（用户已被带去浏览器，面板不该弹出抢焦点），拉起失败不置标志回落正常切面板；判定放在纠错之后减少「搜索」被识别错的误判；设置开关 `voice_search_jump_enabled`（默认开，悬浮窗二级页「语音搜索跳转」卡，同走 Pro 门禁），overlay engine 转写收尾现场 reload 读、读取异常按关闭兜底（宁不跳不误跳打扰）；主 App 录音（diary_tab/record_tab）不受影响；新增 search_command_detector_test 10 例（触发词命中/先长后短/不在开头/无关键词/剥离后为空/首尾标点清理），flutter analyze 0 error + flutter test 全过 |
| （2026-10-21 本次提交） | **语音搜索触发词可配置 + 随全量备份走**（用户需求：触发词在设置页悬浮窗二级页可配，且配置可导入导出）——①配置真值收在 `lib/utils/search_command_detector.dart`：默认白名单常量 `kDefaultVoiceSearchTriggers`（搜索一下/搜索/搜一下）+ prefs key `kVoiceSearchTriggersKey = 'voice_search_triggers'`（String，换行分隔的规范化结果）+ 纯函数 `normalize`（按换行/英文逗号/中文逗号/顿号拆分 → trim/去空/去重 → 按长度降序，先长后短）与 `parseTriggers`（空/非法回落默认，老版本无 key 行为不变）；②设置页「语音搜索跳转」卡新增触发词行（当前列表「搜索一下 / 搜索 / 搜一下」展示 + 编辑按钮弹多行对话框，保存前 `normalize`、空列表拒绝保存；同走 Pro 门禁）；③overlay 转写收尾读 `parseTriggers(prefs.getString(...))` 传入 `detect`，空/非法回落默认，自定义后原默认触发词不再生效（宁缺勿误）；④全量备份 ZIP 新增 `voice_search_triggers.txt`（每行一个，导出的是当前**实际生效**列表，未配置即默认白名单），导入按备份覆盖（`normalize` 后写 prefs），老版本备份无此文件或内容为空时保留本机配置不动——不回落默认，避免误清用户配置；README 同步说明；`detect` 对传入 triggers 内部再排序，调用方不必保证顺序；新增 detector 单测 9 例（normalize 拆分/去重/降序、parseTriggers 兜底、自定义触发词命中与默认词失效、乱序输入），flutter analyze 0 error（+1 info 为新增 print 同款）+ flutter test 813 全过（804 基线+9 新增） |
| （2026-10-21 本次提交） | **加锁功能总开关**（用户需求：设置页可开关随手记/悬浮窗的加锁功能）——设置页「日记智能与交互」卡首位新增「笔记锁定」开关（prefs `note_lock_enabled`，默认开=历史行为，免费功能无 Pro 门禁；新文件 `lib/utils/note_lock_settings.dart` 统一读写，读前 reload 跨 engine 惯例，读异常按开启兜底）；关闭后**非破坏性**：`diary.is_locked` 标记原样保留，只在展示/认证层按未加锁处理——主 App 随手记与悬浮窗卡片隐藏锁按钮、跳过打码与认证门禁（锁定笔记按明文展示），局域网电脑访问同步（出网不再打星号、PUT/DELETE/`/audio/{id}` 不再 403），重新开启立即恢复全部保护；关闭时同步 `NoteUnlockSession.revoke()` 结束当前解锁会话；跨 engine 生效靠设置页写后 `DiarySyncBridge.bump()` → 悬浮窗 `_loadDiaries` 展开时重读，主 App `refreshList` 与回前台重读；新增 note_lock_settings_test 3 例 + diary_lock_sync_test 1 例（开关关闭时 JSON 按明文返回且标记仍保留），flutter analyze 0 error（+2 info 同款 print）+ flutter test 817 全过（813 基线+4 新增）；详见「笔记锁定」小节末段 |
| （2026-10-21 本次提交） | **卡片截图附件**（用户需求：展开卡长按复制按钮 → 先收起悬浮窗 → 截图存进该卡附件 → 展开时右侧显示缩略图，点击可查看）——①原生：无障碍服务新增 `captureScreenshot` 通道（API 30+，`CAPABILITY_CAN_TAKE_SCREENSHOT` 能力判定；截图前把悬浮窗 alpha 置 0 隐藏 64ms 防自拍，成功/失败/3s 超时三路恢复 alpha，`screenshotBusy` 防连按，HardwareBuffer → ARGB_8888 Bitmap → JPEG 85 落盘）+ `showToast` 原生 Toast（收起后窗口只剩把手，SnackBar 无载体）；`accessibility_service_config.xml` 加 `canTakeScreenshot="true"`（已启用服务需重开一次加载新配置）；②数据：DB v16→v17 加 `diary.image_path`，`updateDiaryImage` 写入/清空且**不 bump 云同步**——图片只存 `docs/diary_images/`，不进备份 ZIP/CSV、不参与云同步；每卡一张，重截先写新文件再删旧文件；③交互：`OverlayDiaryCard` 复制按钮 tap=复制 / long press=截图（`onCopyLongPress`），展开查看态正文右侧 44dp 缩略图（`onImageTap`），点开面板内全屏预览（`InteractiveViewer` 4 倍）；截图后保持收起 + 原生 Toast；锁定打码卡不渲染缩略图、截图/预览走解锁门禁；归档保留图片，五条真实删除/转存路径同步清文件；新增 db_upgrade_v17_test + overlay_card_image_attachment_test 5 例，flutter analyze 0 error + flutter test 823 全过（817 基线+6 新增）；详见「卡片截图附件」小节 |

| （2026-10-21 本次提交） | **截图附件交互优化（震动 + 预览返回手势）**（用户反馈：①长按复制无震动，不知按多久才触发截图；②点缩略图开预览无震动；③预览只能点右上角关闭，不能侧滑/单击返回）——①`_onCardCopyLongPress` 入口先 `performHaptic('click')`（长按判定成立即反馈，与 tap 复制的 tick 区分；截图成功的 tick 保留）；②`_openImagePreview` 打开预览时 `performHaptic('tick')`（轻档）；③预览层抽成 `lib/overlay/widgets/overlay_image_preview.dart`（原 `_buildImagePreview` 私有方法移出）：单击图片/黑底、右滑超过 88dp 均可关闭（未过阈值 AnimatedContainer 160ms 回弹），右上角 ✕ 保留；侧滑用 `Listener` 原始指针而非外层 onHorizontalDrag——InteractiveViewer 的子层手势识别器会截走拖拽竞技场；放大态（scale>1）与多指期间不响应侧滑，避免误退出/打断缩放；父层收起/重锁/息屏清理路径不变；新增 overlay_image_preview_test 5 例（单击/✕/右滑过阈值/未过阈值回弹/左滑不关），flutter analyze 0 error（166 issue 与基线持平）+ flutter test 全过 |
| （2026-10-22 本次提交） | **标签外观可自定义（4 槽位图标 + 颜色，用户需求：不是所有用户都想要紧急/收藏/灵感这三类，希望自定义）**——用户拍板方案 B（不做改名/自定义图标库，固定 4 槽位 + 精选图标/颜色库）：①`lib/utils/diary_tag.dart` 重写为唯一真值：槽位 id 固定 `urgent/star/idea/task`（第 4 个是新增稳定 id，避免 DB/CSV/云同步迁移）、24 个精选图标 `kTagIconChoices`（工作/生活/灵感/出行）+ 10 色 `kTagColorChoices`、默认外观 `kDefaultTagStyles`、`DiaryTagStyleConfig` 编解码（坏项跳过、缺槽位补默认、颜色强制不透明）、`DiaryTagStyles`（prefs `diary_tag_styles_v1` + 进程内 `ValueNotifier`，保存后 `DiarySyncBridge.bump()` 跨 engine）；②新增设置页「外观 → 标签外观」二级页 `lib/settings/tag_style_settings_page.dart`（4 槽位列表 + 图标/颜色底部弹层 + 单槽恢复默认 + 全部恢复默认，说明不可改名）；③悬浮窗时间行 4 按钮收紧到 28×32/相邻 2dp（时间文本 `FittedBox(scaleDown)` 兜底窄屏、chevron 32×32），`OverlayHome._refreshOverlayConfig` reload 后显式传 `tagStyles` 给卡片；④主 App 筛选行改「全部 + 普通 + 4 槽位图标」，外边距 20→16/间距 8→6 + 整行横向滚动，监听 notifier 即时重绘；⑤全量备份 ZIP 新增 `tag_config.json`（导入覆盖语义，老备份无文件保留本机配置）；⑥电脑访问服务 `GET /api/notes` 附带 `tagConfig`（codePoint + 浅底/深字 hex），页面用新增 `/tag-icons.otf` 路由（App 打包的 MaterialIcons 字体）渲染图标，手机端换肤即刻同步到网页；不参与云同步（用户明确先不做 WebDAV）；新增 diary_tag_style_test 7 例 + 卡片自定义图标/颜色断言 + web tagConfig 断言 + task 筛选断言，flutter analyze 0 error（169 issue 与基线持平）+ flutter test 838 全过（829 基线+9 新增）；详见「卡片标注」小节 |

| （2026-10-21 本次提交） | **截图后展开笔记卡片开关**（用户需求：截图后希望能直接看效果或二次编辑，但不想每次都被唤出，用设置开关切换两种收尾）——设置页悬浮窗二级页新增「截图附件」分区开关（prefs `overlay_screenshot_expand_card`，默认关=历史行为，同走悬浮窗 Pro 门禁）；`_onCardCopyLongPress` 成功收尾现场 reload 读：关 → Toast「截图已保存为附件」+ 保持收起；开 → Toast 后唤醒面板并 `_expandedIds.add(id)` + `_expand()`（先落展开集合保证展开首帧即展开态；缩略图因先静默重查已就绪），核对截图/继续编辑一步到位；读取异常按关闭兜底；新增 overlay_settings_screenshot_expand_test 1 例，flutter analyze 0 error（166 issue 与基线持平）+ flutter test 全过 |
| （2026-10-24 本次提交） | **面板下拉刷新云同步**（用户需求：手机端悬浮窗与随手记都要能下拉刷新 WebDAV）——日记列表、空态、错误态统一包 `RefreshIndicator`（空态/错误态经 `_buildRefreshablePlaceholder` 用 `SingleChildScrollView` + `AlwaysScrollableScrollPhysics` 撑出可下拉区域，空库首次同步主要靠它；列表本体补 `AlwaysScrollableScrollPhysics` 让条目不足一屏也能下拉）；下拉调 `OverlayDataClient.syncFromCloud()`——overlay engine 内自建 `CloudSyncService(dbHelper: DbHelper(), processor: TextProcessor())`，与主 App 设置页同一套同步引擎、直连同一 `items.db`，热词走本地 `user_hotwords.txt`；落库后直接 `_loadDiaries(showLoading: false)` 重查（不等展开时的 DiarySyncBridge 脏检查）；结果走 `AccessibilityOverlay.showToast` 原生 Toast（收起后面板不可见，Flutter 侧无可见载体），文案与随手记共用 `CloudSyncResult.pullRefreshMessage`；未配置时只提示「设置 → 云端同步」不联网；两 engine 各持一份 `_syncing` 防重入、同时下载最坏多传一次相同数据（沿用既有边界）；新增 cloud_sync_pull_refresh_message_test 1 例（3 断言），flutter analyze 0 error（166 issue 与基线持平）+ flutter test 877 全过（876 基线+1 新增）；详见「展开面板视觉」下拉刷新条目与 @cloud-sync.md「下拉刷新入口」 |
| （2026-10-24 本次提交） | **卡片截图随云同步到电脑**（用户需求：手机端截图同步到电脑，适配电脑端 v2 附件模型）——截图**只手机 → 电脑**：手机侧把 `image_path` 按笔记 sync_uuid 编成根目录 `image_index.json`（每设备每笔记一条，sha256/mime/size/updated_at），图片字节 PUT 进电脑端同一 `v2/assets/<sha前两位>/<sha256>.<ext>`；电脑端同步读索引，为对应笔记挂 `origin='mobile'` 的 image 附件（不改 `updated_at`，避免与手机 v1 投影打架），字节走既有 `_syncAssets` 下载并落本地 blobs；索引按 `(note_uuid, device_id)` 所有权合并、本机条目先发后写（上传失败/超批/文件缺失保留旧条目，下次续传），下载来的 `diary_sync_*` 文件不再回传（防接收端复活旧图）；每次最多 80 张、失败只记统计不拖垮文本同步；`updateDiaryImage` 改为 bump `CloudSyncDataVersion`；新增 image_sync 相关单测 9 例、电脑端 codec/merge/e2e 测试 7 例；详见 @docs/architecture/cloud-sync.md「截图附件同步」 |
| （2026-10-24 本次提交） | **电脑端多图同步到手机 + 图集左右切换**（用户需求：电脑上的图片手机也要能看到，多张时悬浮窗显示数量、点开可左右切换；随手记仅有图的笔记显示图片图标）——索引升级为双向：条目按 `(note_uuid, device_id, sha256)` 唯一、带 `position`/`source`，电脑端以 `source='desktop'` 发布自有图片，手机回写时原样透传；手机把电脑端多图全部下收到新增 v18 `diary_images` 表（不在 `diary.image_path` 里塞多值），`getDiaries` 计算 `image_count` 与首图 `primary_image_path`（本机截图优先，否则按 position）；悬浮窗缩略图改 Stack 叠数量角标（>1 才显示），点击把本机截图+下收多图合并成列表进图集；`OverlayImagePreview` 改 PageView：右滑不再关闭（改翻页）、页码指示「2 / 5」、翻页手势用原始 `Listener` 驱动（InteractiveViewer 会抢水平拖拽）、每页复位缩放；随手记卡片日期行仅有图笔记显示图片图标+数量，点击打开同一图集（`fullscreenDialog` 路由）；锁定打码卡沿用图片隐藏规则。新增/修改单测：多图集合/下载/裁剪、图集合规手势 7 例；详见本文件「卡片截图附件」与 @docs/guides/ui-patterns.md「图片附件图标」 |
| （2026-10-25 本次提交） | **图集内删除截图按钮**（用户需求：悬浮窗截图完也要能单独丢图，不动笔记；位置与删除范围用户拍板）——`OverlayImagePreview` 顶栏由「右上角单个 ✕」改成 `Row(spaceBetween)` 左右两格：左 = 🗑（48×48 opaque 命中区，与 ✕ 同款），右 = ✕。**只删手机自拍那张**（`diary.image_path`）：`image_index.json` 按设备所有权合并，本机摘别人（电脑端）的条目会被来源端下轮重发布、删不干净，故电脑端图不给删除入口——`ownImagePath` 为空（这组里本没有本机截图）连按钮都不渲染；翻到电脑端那张点 🗑 走 `onForeignImageTap` → 原生 Toast「这张来自电脑端，请在电脑端删除」；主 App 日记页共用本组件但不传删除参数，行为不变。点 🗑 不立即删：左上整格替换成「确认删除？✓✗」（复用卡片删除确认行先例，✗ 只退出确认不关预览，翻页作废确认态）。✓ → `OverlayHome._onDeleteOwnPreviewImage`：先 `updateDiaryImage(id, null)` 再删文件（顺序不可反，写库失败时图仍在，不留破图）+ `DiarySyncBridge.bump()` + tick 震动与 Toast + 静默重查（缩略图/角标随即消失）；`_deletingImageIds` 按 id 防抖；删完关图集（翻页/缩放状态在组件内，列表收缩不重算会停在越界页）。下轮同步本机索引条目自然消失 → 电脑端摘掉对应附件。`_openImagePreview` 新增 `_previewDiaryId`/`_previewOwnImagePath` 归属参数（与 `_previewImageIndex` 同生命周期）；overlay_image_preview_test 增至 12 例（原 7 例手势不变 + 不渲染/确认态 ✓✗/翻页作废/电脑端页只提示 5 例）；flutter analyze 0 error（169 issue = 基线 167 + 新增 2 条 avoid_print）+ flutter test 950 全过；详见「卡片截图附件」小节 |
| （2026-10-27 本次提交） | **header 剪贴板一键存为笔记**（用户需求：悬浮窗顶部「新增」右边加剪贴按钮，点一下就把系统剪贴板最近一条内容直接存成笔记，省掉新增→粘贴→保存三步）——`OverlayPanelHeader` 新增 `onSaveClipboard` + `Icons.content_paste`（白图标，tooltip「剪贴板存为笔记」），顺序变为「新增 / 剪贴板 / 全部展开 / 打开随手记 / 语音速记」，空列表 4 个（展开照旧不渲染）；链路 `OverlayHome._saveClipboardToNote` → 新通道 `readClipboard` → Kotlin `readClipboardWithFocus` 读首条纯文本 → `insertDiary(trim)`（统一入口 min-1 置顶）→ `DiarySyncBridge.bump()` → 静默重查 + 新卡加入 `_expandedIds` → 原生 Toast「已保存到随手记」。⚠️ **Android 10+ 只允许有输入焦点的应用读剪贴板**，而展开面板刻意 `NOT_FOCUSABLE`：原生在非聚焦时临时摘掉该 flag → 等 `onWindowFocusChanged(true)`（最多 500ms）→ 读 `getPrimaryClip` → 立刻还原；**还原前比对当前 flags 是否仍为本次提权值**，避免把编辑态（focuspointer）/录音态窗口踢回不可聚焦。边界：空/非文本/系统拒绝统一 Toast 不落库；编辑中提示「先完成当前编辑」；录音转写中忽略；`_savingClipboard` 防连点（500ms 焦点等待窗口期比普通写库长）。新增 overlay_read_clipboard_test 3 例（通道契约）、header 测试改 8 例（多按钮渲染/顺序/回调接线）；模拟器 Android 16 实测点击后 DB 新行 sort_order=-14 置顶、面板新卡展开、Toast 正常；flutter analyze 0 error（172 issue = 基线 169 + 新增 3 条 print）+ flutter test 979 全过 + compileDebugKotlin 通过；详见「剪贴板存为笔记」小节 |
| （2026-10-27 本次提交） | **面板按钮位置可切到底部**（用户需求：把悬浮窗顶部按钮切换到悬浮窗底部，便于单手操作）——设置页悬浮窗二级页「面板高度」后新增「按钮位置」两档 ChoiceChip（顶部 = 默认/历史行为，底部），prefs `overlay_panel_buttons_bottom`（bool，缺省 false，同走 Pro 门禁）。**关键：不能只挪按钮条**——面板是顶部锚定布局，只把 Column 里 header 挪到列表下方的话条目少时面板整体仍在屏幕上方、按钮停在半空；底部模式必须把面板锚点一起换成停靠侧下角（`OverlayConstants.panelAlignment` → bottomRight/bottomLeft），按钮条才真正贴到屏幕底部拇指区。布局差异全部收进纯函数：`panelHeaderPadding` 顶部避状态栏（top=40/bottom=4）/底部避导航栏（top=4/bottom=48），`panelListBottomPadding` 顶部 48/底部 8（导航栏由按钮条自身避让）；底部模式不叠加「面板高度」的顶部下压偏移（面板已贴底），列表限高仍按档位生效；大爆炸层 `topInset` 在底部模式回到只避让状态栏。读取方 `_refreshOverlayConfig`/`_scheduleAutoHide`（下一次状态转换生效），Kotlin 零改动；新增 overlay_panel_buttons_position_test 7 例（key/默认 + 锚点四向 + 内边距两模式 + 列表底距）；详见「按钮位置（顶部/底部）」小节 |
| （2026-10-28 本次提交） | **音量键直接存剪贴板**（用户需求：把手势绑到音量键，按一下就把最近复制的内容存进随手记，不用先展开面板点剪贴按钮）——新动作 `overlay_clipboard_note`（Dart `VolumeGestureAction.overlayClipboardNote` ↔ Kotlin `ACTION_OVERLAY_CLIPBOARD_NOTE`，合法值 7→8），落库完全复用 header 的 `_saveClipboardToNote`（`haptic:false`，原生触发时已震一次）。⚠️ **不展开面板就没有可借焦点的窗口**（Android 10+ 读剪贴板需输入焦点）：浮窗已显示 → 复用现有窗走 `readClipboardWithFocus`；浮窗不存在 → 直建 `alpha=0 + NOT_TOUCHABLE` 临时隐藏窗（`showOverlay` 新增 `revealOnUiReady=false`，不置 `pendingVoiceMemoReveal`），Dart 回执 `clipboardNoteDone` 收窗 + 10s 超时兜底，收窗按 `clipboardNoteView` View 身份比对（等待期间重建的浮窗不误关）；`dartReady` 前挂起 `pendingClipboardNote` 补发（负载 `{ephemeral}`）；录音中先于 Pro 门禁 Toast 不建窗；新增 overlay_read_clipboard_test 3 例（saveClipboardNote 负载解析/clipboardNoteDone 方法名）+ volume_key_clipboard_note_action_test 3 例（4 行都提供该 chip/写 `volume_gesture_long_press_up`/Pro 未解锁不写 prefs 且弹窗）+ 配置 1 例；flutter analyze 0 error（175 issue = 基线 173 + 新增 2 条 print）+ flutter test 992 全过（985 基线 + 7）+ compileDebugKotlin 通过；⚠️ `alpha=0` 临时窗能否拿到输入焦点未真机验证（拿不到会 500ms 超时安全降级并收窗）；详见「剪贴板存为笔记·音量键入口」小节 |

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
  - **写方**：任一 engine 写 diary 成功后 `DiarySyncBridge.bump()`（key `diary_change_counter`，int 单调递增；bump 内先 reload 再 +1 防双 engine 并发覆盖）。悬浮窗侧挂点：归档/恢复、删除、标注、编辑保存、新增笔记、占位行删除（overlay_home.dart）+ 语音速记占位插入与转写回填（overlay_voice_memo.dart）；主 App 侧挂点：diary_tab.dart 全部 insert/update/delete/archive 写点 + 云同步下载合并有实际插入（`CloudSyncService.mergeDownloadedText`，2026-10-23——否则电脑端同步来的日记随手记可见、悬浮窗不刷新）
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
- **固定默认色 + 标注换色**（2026-09-02 起，替代旧的 index % 6 轮换色板）：无标注活跃卡恒用 `OverlayConstants.defaultCardColor`（#6F9AF0）；标注后整卡换该槽位配置色（4 槽位外观唯一真值在 [lib/utils/diary_tag.dart](../../lib/utils/diary_tag.dart) 的 `DiaryTagStyles`，2026-10-22 起可在设置页「外观 → 标签外观」换图标/颜色，主 App 日记页小色点与网页端共用）；已归档卡片不参与取色，固定灰 + 删除线（归档卡允许标注入库，恢复后显示标注色）。4 个标注按钮 2026-09-22 起一级直出展开卡时间行（时间文本后紧凑排列；首版底条入口→二级选择态的两步交互已删除），详见"卡片标注"小节
- 头部按钮条（无标题，深色半透明工具条，见下；默认在列表上方，设置页「按钮位置」可切到列表下方并让面板贴屏幕下角，见「按钮位置（顶部/底部）」小节）：新增笔记（+，插占位行进编辑态）/ **剪贴板存为笔记**（2026-10-27 起，`Icons.content_paste`，紧挨「新增」右侧；一键读系统剪贴板最后一条文本直接落库，省掉新增→粘贴→保存三步，详见「剪贴板存为笔记」小节）/ 全部展开·收起（空列表不渲染；状态持久化 prefs `overlay_expand_all_cards`，下次打开面板沿上次直接展开，2026-10-19 起）/ **打开随手记**（2026-09-13 起，`Icons.book` 与主 App 底部导航「随手记」同图标，见「跳回主 App 日记页」小节）/ **语音速记录音**（2026-10-19 起，`Icons.mic`，替代原收起 chevron——收起面板改由空白区点击/滑动承担；点击经通道调原生 `triggerVoiceMemoOverlay` 走音量键「悬浮窗录音」同一链路开录，窗口随状态机 resize 成录音胶囊，详见「面板 header 录音按钮」小节）
- **深色半透明工具条**（2026-09-13，[overlay_panel_header.dart](../../lib/overlay/widgets/overlay_panel_header.dart)）：此前按钮裸放透明面板上、图标色跟主题（ext.textHint），垫在白色背景的应用上看不清（用户实测反馈）。改为黑 72% 半透明底 + 白图标 + 朝屏内侧柔影——与录音胶囊/停止提示胶囊同视觉家族（白图标对黑 72% 底，垫纯白背景等效底 ≈#4a4a4a，对比度 ≈8:1，跨背景都可读），也是闪念原型「黑色半透明工具条」设计的正式落地。组件纯渲染：回调上抛、停靠侧镜像（贴停靠缘 Align / 阴影方向）与条件渲染（空列表）由参数驱动；渲染契约锁在 `overlay_panel_header_test`（按钮渲染条件/按钮顺序/回调接线/家族配色/两侧镜像 8 用例）。
- 日记列表区域限高约 10 张卡高度（`OverlayConstants.panelListMaxHeight`），超出部分区域内滚动查看全部记录（2026-09-02 起；原为 `maxVisibleDiaryCards` 条数硬截断只显示最新 10 条）
- **下拉刷新云同步（2026-10-24）**：日记列表（含空态/错误态）包 `RefreshIndicator`，下拉即在 overlay engine 内跑一次 WebDAV 同步（同一 `items.db` + 独立 `TextProcessor` 读写热词文件），落库后直接 `_loadDiaries` 重查，结果走原生 Toast（收起后 Flutter 侧无可见载体）；空库首次同步主要靠这个入口；未配置时只提示「设置 → 云端同步」不联网；详见 @cloud-sync.md「下拉刷新入口」

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
| 收起面板（空白区点击/任意方向滑动，推屏滑出动画；2026-10-19 前面板 header 还有收起按钮，此后改由空白区手势承担） | 回到把手，**10s 后自动彻底隐藏**（设置页可选 5/10/30s 或永久常驻） |
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

### 息屏自动隐藏（AOD 防残留，2026-09-22 两轮 + 2026-09-28 永久档穿越）

用户场景：录完音不管悬浮窗，手机息屏后把手/贴边竖线（竖线驻留开关默认开）仍显示在 **AOD 息屏时钟**画面上——`TYPE_ACCESSIBILITY_OVERLAY` 特权层在 AOD 上继续参与合成。

**第一轮（GONE 暂藏）**：SCREEN_OFF 时窗口 `visibility=GONE`、SCREEN_ON 恢复。真机使用后用户升级诉求：亮屏后悬浮窗"恢复"出把手/面板也不想要——**第二轮定版语义「进 AOD 必须收」**：息屏瞬间即推进到驻留终态，此后亮屏/解锁都只会看到贴边竖线（开关开）或什么都没有（开关关），把手/面板不复活。**第三轮（2026-09-28，用户拍板）**：「进 AOD 必须收」收窄为仅限时档——「永久」档用户反馈"息屏解锁后把手没了"（log2 实锤：永久+竖线关被无条件推进 closeOverlay），永久的字面承诺就是把手一直在，改为把手驻留穿越 AOD。

- **检测 = `ACTION_SCREEN_OFF` 广播**，复用笔记锁定「锁屏即重锁」的同一个 receiver（`onServiceConnected` 注册，IntentFilter 追加 `ACTION_SCREEN_ON`；两 action 均为受保护系统广播，仅系统可发，registerReceiver 无需 export flag）——ACTION_SCREEN_OFF 在息屏时刻即发出，AOD 属非交互态，「屏幕变黑」与「进入 AOD」都被它覆盖，无需专门的 AOD/DOZE 检测 API（各 ROM 的 doze 监听不统一，也不必用）
- **息屏动作两步**：①`visibility=GONE`（Kotlin `setOverlayGoneForScreen`，AOD 立即干净，录音/转写链路与自动隐藏计时不受影响——录音中息屏录音不中断）；②发 `screenAutoHide` 消息（`dartReady && !proHintActive` 守卫）→ Dart `OverlayHome._onScreenAutoHide` 先把展开面板跳终态收回把手（面板永不穿越息屏），再按纯函数 `OverlayConstants.screenOffActionFor` 分流——**「永久」档（overlay_auto_hide_seconds=-1）把手驻留穿越 AOD**（不推进竖线/移除，竖线开关在永久档下对息屏不生效）；限时档维持「进 AOD 必须收」——「隐藏后保留贴边竖线」开关开 → `_enterEdgeLine()`（缩成 20×64 线态驻留）、关 → `closeOverlay()` 彻底移除
- **为什么跳终态而不走 `_collapse` 推屏动画**：息屏后窗口 GONE、vsync 停、AnimationController 不跑，等 dismissed 边界回调会卡到亮屏才缩窗；黑屏期间无人在看，空白帧协议（防旧纹理重投影被用户看见）在 GONE 下天然满足。`_enterEdgeLine` 的 `awaitingResize` 守卫照挂——息屏期间 viewport metrics 可能不回调，亮屏后首个 build 由 `_maybeAdvanceMetricsStage` 解除，竖线淡入
- **守卫**：录音/转写中跳过推进（活动会话不打断；黑屏期间窗口 GONE 不可见，录音结束后自然走既有自动隐藏链，亮屏恢复看到的是录音现场）；Pro 提示窗跳过（3 秒自收窗）；编辑中先 `_saveEdit()`（失败留在编辑态放弃收起，不丢输入，同 `_openDiaryPage` 先例）；息屏推进先作废挂起的自动隐藏 Timer（防遗留计时到期空转/串扰）
- **亮屏 = `ACTION_SCREEN_ON` 恢复 VISIBLE**（`overlayHiddenByScreenOff` 标志只撤销"因息屏而 GONE"的隐藏 + engine 手动 `appIsResumed()` 同 `getOrCreateOverlayEngine` 复用分支先例防画面冻结）——恢复的是分流后的驻留形态：限时档只有竖线/录音现场（把手/面板在息屏瞬间已被收掉，不存在"复活"）；永久档是把手原样回来（窗口未被移除，GONE→VISIBLE 即回归）。悬浮窗在锁屏上可见是产品既有行为（「笔记锁定」小节威胁模型，有打码兜底）
- **正交性**：visibility 与 alpha（隐藏窗揭示期 0 / 认证让位 0.15）是两个维度，恢复 VISIBLE 不会泄露 alpha=0 的未揭示窗口；窗口已移除（overlayView 空 = 悬浮窗本就彻底隐藏）时 no-op
- 回归点：录完音不管 → 息屏（AOD 无残留）→ 亮屏锁屏页只有竖线 → 解锁主屏也只有竖线；展开面板态息屏同此；录音中息屏 → 亮屏录音/转写链路完整；竖线态息屏 → 亮屏竖线原样；贴边竖线开关关的用户息屏 → 亮屏什么都没有（音量键可重新召唤）；**「永久」档用户息屏 → 解锁把手原样回来**（不缩竖线不移除；若息屏前面板展开，回来的是把手而非面板）

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

### 把手大小档位（2026-09-22，三档视觉缩放）

用户反馈"把手胶囊有点大"可调。设置页悬浮窗二级页「把手大小」三档 ChoiceChip：**标准（100%，历史视觉）/ 小（75%）/ 迷你（50%）**，prefs `overlay_handle_size_percent`（int 百分比，非法值兜底 100，`parseHandleSizePercent` 唯一出口）。

- **方案 A「只缩视觉不缩窗口」**：窗口恒 28×88，胶囊本体 = 基准 24×80 × 档位（100% → 24×80 / 75% → 18×60 / 50% → 12×40），内缩按（窗口−视觉）/2 派生。**为什么不真缩窗口**：原生 HANDLE_WIDTH_DP 硬编码副本（dragHandle 宽守卫）、语音胶囊 84<88 不变量（`overlay_home` build 按「窗口高 < 把手高」判 idle 帧渲染空白，把手窗高缩到 44 后判定反转、冷启动把手闪现复发）、Kotlin `EDGE_LINE_WIDTH_THRESHOLD_DP=24` 宽度分流（真缩到一半宽 14 < 24 与竖线态撞车，且竖线窗口宽 20 与最小把手宽 14 之间无分离区间）——三者联动，动窗口任一都破。触控面积不变反而是优点（把手越小越难点，命中区保住窗口整面积，同"视觉小命中大"哲学）
- **文字显示规则（2026-09-22 两轮定夺）**：首版仅迷你档（50%，12×40 放不下文字）隐藏文字只渲染图标（`isMiniHandleSize` 判定，图标缩为 `handleIconSizeMini=9`）；真机复验「小」档（75%，18×60）竖排文字也太挤，收窄为**仅标准档显示文字**——`handleShowsLabel(percent, theme)` = 标准档（≥100）且非拟物主题。不显示文字的档位下半区留空、三段结构与中缝位置保持不变（视觉语言连续）
- **竖线跟随缩高**：把手变小后竖线 64 高会反超把手（视觉层级颠倒），用户定夺同步缩、**只缩高不缩宽**——视觉高 = 64 × 档位（64/48/32），窗口 20×64 触摸缓冲区与宽 4dp（可见性下限，2026-09-14 渐变对比度专项基于此）都不动，视觉线在窗口内垂直居中
- **生效时机**：同停靠侧——跨 engine 无推送通道，`_refreshOverlayConfig`（原 `_refreshSide`，现管停靠侧+大小+主题三项）/ `_scheduleAutoHide`（reload prefs）顺带读配置，悬浮窗下一次展开/收起状态转换生效，已显示中的把手不瞬变
- **⚠️ 命中环坑（2026-09-22 真机反馈"缩小后点空隙唤不出"）**：GestureDetector 默认 `deferToChild`，命中区=有 decoration 的胶囊本体而非整窗——档位越小透明内缩环越宽（75% 档纵向空隙 14dp），用户点视觉胶囊附近的透明区全部落空，感知为"触发区变小/有空隙"（窗口 28×88 本身没变、Kotlin 零关系）。修复 `behavior: HitTestBehavior.opaque` 整窗命中（同 _buildEdgeLine 竖线窗口 20×64 整窗可点中的既有做法），兑现"触控面积不随档位缩"；历史 tap 测试点胶囊中心测不出此坑，回归用例改用胶囊外偏移 tapAt（overlay_handle_size_test）
- **纯函数派生集中在 OverlayConstants**（`handleCapsuleWidth/Height`、`handleInsetXxxOf`、`edgeLineVisualHeight`、`isMiniHandleSize`、`handleShowsLabel`、`parseHandleSizePercent`、`parseHandleTheme`）：设置页与 overlay engine 共用唯一真值，不变量「视觉 + 2×内缩 = 窗口」有测试钉住

### 把手主题（2026-09-22，三套皮肤）

设置页悬浮窗二级页「把手主题」三选一，prefs `overlay_handle_theme`（string = enum name，坏串兜底 duo，`parseHandleTheme` 唯一出口）。大小档位与主题正交，渲染属性（色值/显隐）集中在 `HandleThemeVisuals` extension：

- **双色药丸（duo，默认）**：历史视觉——上暖白 / 下绿，闪电图标取下半色落白半区呼应成对
- **蓝紫（bluePurple）**：与悬浮窗笔记卡片色系一致——上 = 卡片默认蓝 `defaultCardColor`(#6F9AF0)、下 = 灵感标注紫(#AE82E4)；上下皆饱和彩色，图标文字用白色
- **拟物胶囊💊（pill3d）**：白 + 珊瑚红(#E0524E) 立体药丸，纯造型**无图标无文字**（任何档位）——中缝分界 + 左侧高光条（白 0.65→0 竖渐变，`capsuleWidth×0.2` 宽）+ 下半暗部渐变（50% 起加深、上半白不受影响）三层叠出立体感
- **色系一致的钉子**：bluePurple 色值测试直接断言 `defaultCardColor`——卡片默认色将来改动此处会红，提示同步决策把手是否跟随

### 面板字体大小档位（2026-09-27，五档）

设置页悬浮窗二级页「字体大小」五档 ChoiceChip（特小/小/标准/大/特大），prefs `overlay_font_size_step`（int 档位 -2~+2，`parseFontSizeStep` clamp 到连续刻度——与把手大小的白名单语义不同），**每档 1pt**（用户需求 ±2 个字号：0.5pt 档差真机不可辨，2pt 档差最小档跌破可读下限，故取 1pt）。

- **作用范围只限日记面板文字**：卡片收起态单行/展开正文/时间行/重放录音/锁定打码/编辑输入框/删除确认 + 面板「已归档」分隔线/空态/错误态。三处刻意不缩放：把手（有独立大小档位，叠加会双重缩放）、语音速记胶囊（宽度预算按 15 号字调过）、临时提示胶囊（转瞬 UI）
- **实现**：基准 + 档位统一走 `OverlayConstants.fontScaled`（卡片侧 `_fs()` 简写 / OverlayHome 侧同名简写）；渲染与三处 painter 测量（`_estimateCollapsedWidth`/`_estimateExpandedHeight`/`_charOffsetAt`）同源缩放——046fe0b「测量环境必须与实际渲染一致」的延伸
- **⚠️ 测量缓存 key 必须含字号**：`_kCollapsedTextWidthCache` 不同档位同文本宽度不同，不进 key 会串档，估算偏窄把短文字顶出省略号
- **⚠️ 勾选框反缩放倍率用缩放后字号**：框架按 `textScaler.scale(正文字号)/字号` 放大 WidgetSpan 子项，倍率计算若用未缩放基准，档位非 0 时勾选框尺寸二次偏差
- **生效时机**同把手大小：`_refreshOverlayConfig`/`_scheduleAutoHide` reload 读取，下一次状态转换生效，已显示中的面板不瞬变；同走 Pro 门禁（设置页 chip 点击 `_ensureOverlayPro`）

### 面板高度（可见条数档位，2026-10-06，五档）

用户需求：大屏手机单手拿时，面板顶部的新建/展开按钮在屏幕上方、大拇指够不着。设置页悬浮窗二级页「面板高度」五档 ChoiceChip（10/9/8/7/6 条，默认 10 = 历史行为），prefs `overlay_panel_max_cards`（int 6~10，`parsePanelMaxCards` clamp 连续刻度语义同 fontSizeStep）。单位用**条数**（用户拍板：比高/中/低档位直观，改几条就是少看几条）。

- **⚠️ 关键设计：面板是顶部锚定布局，只缩列表限高不能让顶部按钮下移**——面板贴停靠侧上角（Align topRight/topLeft），单纯把列表限高调小只会让面板底边上移，header 按钮组原地不动，够不着的问题依旧。正确做法 = **列表限高按档位缩 + 面板顶部等量下压偏移**：`panelTopOffsetFor(n)` =（默认档 − 当前档）×（卡片高+间距），以 Padding 包在面板 Align child 外层。兑现用户描述的「满列表整列底边位置不变、顶部按钮组逐档下移进拇指区」
- **设计不变量**：`panelTopOffsetFor(n) + panelListMaxHeightFor(n)` 对任意档位为定值（满列表底边不动，测试钉住）；默认档限高 == 旧常量 `panelListMaxHeight`（历史行为零变化，测试钉住）
- **⚠️ 差一条修正（2026-10-06 真机实测：10 档见 11 张 / 6 档见 7 张）**：ListView/SliverPadding 的 padding **只计入滚动范围、不裁剪视口**——滚动到顶时视口内卡片可见区 = 限高 − top padding（8），底部 padding 48 是滚动范围末尾的留白、要滚到底才出现。历史限高公式把 +48 也算进去，可见区多出 48 > 卡高 46，第 N+1 张卡完整露出。修正：限高只加顶部 padding 8（`cards × (卡片高+间距) + 8`），视口卡片可见区恰好 N 张、第 N+1 张 0 像素（测试钉住）；底部 padding 48 保留不动（滚到底避让导航栏的既有职责）
- **矮屏安全**：Padding 在 Align（StackFit.expand 给的满窗紧约束）内缩小可用高度，Column 的 Flexible 列表仍被窗口剩余高度约束，下压后底部不溢出
- **生效时机**同把手大小：`_refreshOverlayConfig`/`_scheduleAutoHide` reload 读取，下一次状态转换生效，已展开的面板不瞬移；同走 Pro 门禁；Kotlin 零改动

### 按钮位置（顶部/底部，2026-10-27）

用户需求：把悬浮窗顶部按钮切到悬浮窗底部，便于单手操作。设置页悬浮窗二级页「面板高度」后新增「按钮位置」两档 ChoiceChip（顶部 = 默认/历史行为，底部），prefs `overlay_panel_buttons_bottom`（bool，缺省 false），同走 Pro 门禁。

- **⚠️ 不能只挪按钮条**：面板是顶部锚定布局（`Align.topRight/topLeft`），只把 Column 里的 header 挪到列表下方，条目少时面板整体仍在屏幕上方、按钮停在半空——单手问题没解决。底部模式必须把面板锚点一起换成停靠侧**下角**（`OverlayConstants.panelAlignment` → `bottomRight`/`bottomLeft`），按钮条才真正贴到屏幕底部拇指区
- **布局差异**（全部收在 `OverlayConstants` 纯函数，测试钉住）：`panelHeaderPadding` 顶部模式避状态栏（top=40 / bottom=4）、底部模式避导航栏（top=4 / bottom=48，与列表历史底部 padding 同值）；`panelListBottomPadding` 顶部 48（导航栏避让，历史行为）、底部 8（导航栏由下方按钮条自身避让，再留 48 会多出一大段空白）
- **与「面板高度」的关系**：底部模式面板已贴底，`panelTopOffsetFor` 的顶部下压偏移不叠加（下压无意义）；列表限高仍按可见条数档位生效（少看几条 = 面板从顶部方向收缩，底边不动）
- **大爆炸层顶边**：按钮位置 = 底部时 header 已在屏幕底部、不用让位，`BigBangLayer.topInset` 回到只避让状态栏（`panelHeaderTopPadding`=40），不再叠加面板高度档偏移
- **键盘**：原生窗口早已设 `SOFT_INPUT_ADJUST_RESIZE`（见 Kotlin 建窗注释），编辑时窗口被键盘抬高的部分裁掉，底部模式面板随窗口下缘上移、按钮条不会被键盘盖住
- **生效时机**同面板高度：`_refreshOverlayConfig`/`_scheduleAutoHide` reload 读取，下一次状态转换生效；Kotlin 零改动（面板是全屏窗口内的 Dart 布局）

### 笔记锁定（2026-09-22，悬浮窗/锁屏防偷看）

悬浮窗在锁屏上可见（`TYPE_ACCESSIBILITY_OVERLAY` 系统放行），锁屏页亮着时旁人不解锁手机就能看到笔记内容——笔记锁定功能的威胁模型即此。diary 加 `is_locked` 列（v15，用户手动锁定，免费功能无 Pro 门禁），主 App 与悬浮窗全链路打码 + 设备凭据认证后可看；完整数据层/主 App 侧设计见 @docs/architecture/database.md v15 行。

**认证双路径**（`NoteUnlockCoordinator` + `NoteUnlockActivity`，主 App 与悬浮窗共用一条链路）：

- **锁屏中**（`KeyguardManager.isKeyguardLocked`）：指纹/面部传感器由系统 Keyguard 持有，App 内 BiometricPrompt 会与锁屏抢传感器（秒失败/对话框被压在锁屏后）——改走 `requestDismissKeyguard` 弹系统解锁界面，用户指纹解锁手机即视为通过。副作用：看锁定笔记 = 顺手解锁手机，符合直觉可接受
- **未锁屏**：androidx.biometric 标准对话框，`BIOMETRIC_WEAK | DEVICE_CREDENTIAL`（指纹/面部优先、锁屏密码兜底；无自设密码故无忘密码丢数据问题）。⚠️ androidx.biometric 1.1.0 的常量类是 `BiometricManager.Authenticators`（嵌套在 BiometricManager，**不是** `BiometricPrompt.Authenticators` 也不是独立 `androidx.biometric.auth` 包——后两者是 1.2.0+ 的 API，写成它们编译期 unresolved）
- 承载 Activity 必须是 `FragmentActivity`（androidx.biometric 要求；MainActivity 是 FlutterActivity 不动它）+ AppCompat 透明主题（API<28 兼容对话框要求）。悬浮窗发起：overlay 通道 `requestUnlockAuth` → 服务 startActivity（NEW_TASK）；结果异步经 `notifyNoteUnlockResult` 回发对应 engine
- **认证让位（2026-09-22 用户反馈）**：指纹弹窗是系统窗口（`TYPE_BIOMETRIC_PROMPT`），层级低于无障碍悬浮窗（特权层压在绝大多数窗口之上，第三方无法把系统弹窗提到悬浮窗之上）——`requestUnlockAuth` 拉起认证前把窗口整体降到 `OVERLAY_AUTH_DIM_ALPHA`=0.15 让位（用户定夺整体降透明而非只透下半；留 0.15 保隐约在场感，恢复无闪现），结果回发恢复 1f（先恢复透明度再回发，Dart 收到结果即 setState 展开卡片，窗口必须已可见）。拉起失败立即恢复；恢复分支跳过语音速记隐藏窗揭示期（alpha 归揭示机制管，提前置 1 会闪把手帧）；窗口已移除时 no-op（重建窗口 alpha 恒 1 不残留）

**锁屏即重锁**：`onServiceConnected` 注册 ACTION_SCREEN_OFF receiver（服务常驻，MainActivity 的 receiver 在主 App 未启动时不存在；2026-09-22 起同一 receiver 兼管息屏自动隐藏悬浮窗，见「息屏自动隐藏（AOD 防残留）」小节）——直接清零 `flutter.notes_unlock_until_ms`（Flutter prefs putLong，⚠️ Dart setInt 落盘即 Long，Kotlin 读必须 getLong）+ `relockNotes` 事件通知悬浮窗 Dart 收起已展开的锁定卡。

**解锁会话**（[note_unlock_session.dart](../../lib/utils/note_unlock_session.dart)）：认证成功后续期 5 分钟，主/悬浮窗两 engine 共享同一 prefs key（读写前 reload，DiarySyncBridge 同款纪律）。会话 ≠ 解除锁定：会话过期卡片重新打码但 is_locked 不动。两条入口语义不同（2026-09-22 用户反馈两步语义反直觉后定版）——**点锁按钮（解除锁定）→ 认证成功后直接解除该卡锁定**（意图 pendingUnlockReleaseId 异步消费，主/悬浮窗一致）；**点卡片本体查看 → 只开临时会话**，锁定标志不动、锁图标保持（与 Apple 备忘录「解锁查看后列表仍带锁图标」一致）。

**悬浮窗打码范围**：收起态单行文本、展开态正文（`OverlayDiaryCard.lockedHidden`，明文一帧不进组件树）、播放行隐藏；宽度估算用打码文本（不泄露笔记长度）。门禁入口（`OverlayHome._ensureNoteUnlocked`）：展开/编辑/复制/AI 对话/播放/删除/闹钟（闹钟会读正文做时间解析）；划走归档放行、已归档划走（=删除）门禁；锁定/解锁按钮在卡片底条（`onLockToggle`）。认证前点开的卡记住意图，认证成功自动展开。

**加锁功能总开关（2026-10-21，用户要求）**：设置页「日记智能与交互」卡新增「笔记锁定」开关，prefs `note_lock_enabled`（**默认开 = 历史行为**，免费功能无 Pro 门禁），读写统一走 [note_lock_settings.dart](../../lib/utils/note_lock_settings.dart)。**关闭语义是非破坏性的**：落库的 `diary.is_locked` 标记一律保留不动，只在展示/认证层按「未加锁」处理——主 App 随手记与悬浮窗卡片不再渲染锁按钮（悬浮窗 `onLockToggle` 传 null 即不渲染）、`_isLockedHidden` 恒 false 按明文展示、`_ensureNoteUnlocked` 直接放行，局域网电脑访问同步解除脱敏与 403（见 @docs/architecture/web-server.md）；重新开启后原有锁定立即恢复全部保护（无需逐条重锁）。关闭开关时同步 `NoteUnlockSession.revoke()` 结束当前 5 分钟解锁会话。跨 engine 生效无推送通道：设置页写库后 `DiarySyncBridge.bump()`，悬浮窗在 `_loadDiaries`（展开时脏检查重查链路）重读；主 App 在 `refreshList`（含切回日记页）与回前台时重读；读取失败按开启兜底（安全侧）。

**加锁前置检查（2026-10-08，用户要求）**：点锁按钮**加锁**前先查设备是否已设锁屏凭据（`KeyguardManager.isDeviceSecure`，PIN/图案/密码）——未设置时不允许锁定：锁定后没有任何认证手段能看回内容，锁定形同虚设反而误导用户以为已保护。两个加锁入口（主 App `DiaryTabState._toggleDiaryLock` / 悬浮窗 `_OverlayHomeState._toggleDiaryLock`）在写库前各自经本 engine 的通道查询（新增通道方法 `isDeviceSecure`，MainActivity 与无障碍服务双通道各一份实现），未设置则弹引导对话框「未设置锁屏密码」（「去设置」经新增 `openSecuritySettings` 拉起系统安全设置页，悬浮窗侧 NEW_TASK；「取消」什么都不做），**本次不加锁**。通道异常按「未设置」失败关闭（安全侧兜底）。解除锁定不受影响（解锁认证链路 `NoteUnlockActivity` 本来就有 `isDeviceSecure` 兜底拦截）。封装：主 App `NoteLockAuth.isDeviceSecure/openSecuritySettings`、悬浮窗 `AccessibilityOverlay.isDeviceSecure/openSecuritySettings`；通道封装单测见 `test/note_lock_auth_test.dart`。

### 滑动展开的两档触感反馈（2026-09-13 首版，2026-09-14 真机对调）

「朝屏幕内侧滑展开」是盲手势（目标小、无视觉确认），补震动反馈；同一手势在把手/竖线两态拉开强度差（用户定夺：线态强、胶囊态弱）：

- **胶囊把手**（`_buildHandle` 的 `onSwipeInward` 包装）：`performHaptic('heavy')` = 用户主力机上的**轻档**
- **线态贴边竖线**（`_buildEdgeLine` 的滑动展开分支）：`performHaptic('tick')` = 用户主力机上的**重档**
- **⚠️ 档位映射看似反直觉，勿"修正"回去**：标准 AOSP 强弱排序 TICK < HEAVY_CLICK，但小米 15 HyperOS 对 `VibrationEffect.createPredefined` 预设波形的实现非标——真机实测 EFFECT_TICK 体感反而比 EFFECT_HEAVY_CLICK 重。2026-09-14 加调试日志定性（Dart 两个调用点 + Kotlin `performHaptic` 打印 type/SDK/hasAmplitudeControl）：链路 type 正确到达、体感相反，排除代码问题，用户拍板直接对调、以主力机体感为准。换回标准映射的机型上两档体感会反转（当前无此设备，接受）
- **点按展开刻意不震**：点按有明确视觉目标（胶囊/线的位置已知），是确认性操作，触感留给盲手势
- **震感家族**：都走 `AccessibilityOverlay.performHaptic` 通道 → Kotlin Service `performHaptic` 映射表 → `VibrationEffect.createPredefined`（系统预设触感原语，线性马达质感，SDK < O 降级固定时长）——同日记页 `_haptic` / 悬浮窗复制按钮 EFFECT_TICK 的既有家族；刻意不用 `Vibration.vibrate(duration, amplitude)`（自定振幅波形，普通转子马达的"嗡"感）。注：语音速记/快速录音的触感 2026-09-17 定版「开始嗡（Kotlin 侧 50,50 one-shot）、停止清脆（tick，该机最重清脆档）」，预设档位经 heavy→click→tick 三轮真机试档后收敛

### 贴边竖线驻留（线态：触摸缓冲区 + 点按/侧滑分流，2026-09-14）

**何时进入**：收起后自动隐藏计时到期 + 设置开关「隐藏后保留贴边竖线」（`overlay_edge_line_enabled`，默认开）打开 → `_enterEdgeLine` 把窗口从把手（28×88）缩成线态（20×64）；关闭则维持旧行为 closeOverlay 彻底移除窗口（只能音量键召唤）。

**形态 = 视觉线窄、触摸区宽**：窗口 20×64dp（`edgeLineWindowWidth` = 透明触摸缓冲区），视觉线 4dp（`edgeLineWidth`，用户定夺 ≈1mm）贴停靠缘绘制（Align 贴缘），GestureDetector `HitTestBehavior.opaque` 整窗可命中。**距屏幕边缘间距三档可调**（2026-09-29，`overlay_edge_line_margin_dp`：0 贴边/4/8 最里，设置页「贴边竖线」卡选择器）——纯 Dart 视觉内移（竖线在窗口内经 `edgeLinePadding` 向屏内侧偏移），窗口与触摸缓冲区不动，窗口内硬上限 16 = 窗口宽 − 线宽；读取/生效时机同把手大小（下一次状态转换），随停靠侧镜像。为什么加宽触摸区：首版窗口宽=线宽=4dp，手指起点（接触面 8~10mm）很难按中，按偏后落在窗口外的边缘滑动被系统当作返回手势——用户感知为"竖线难触发、和侧滑返回冲突"。透明缓冲不牺牲下层触摸：贴边 ~24dp 本来就是系统返回手势区（systemGestureInsets），手势导航下该条带触摸到不了下层应用（三键导航只挡边缘无可点控件的条带）。市面产品调研（微信浮窗/悬浮球类）均为"窄视觉+宽触摸"路数；第三方无法用 `setSystemGestureExclusionRects` 抢边缘手势（该 API 对 overlay 窗口普遍无效，官方仅支持 Activity 内 view）。

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
- **overlay engine Dart 镜像**（`OverlayHome._sideLeft`，`_refreshSide()` reload 后读）：把手/竖线的 Align、缩窗把手回位与面板推屏动画的平移符号（`Offset((1-t)×(±1), 0)`，左缘取 -x）、面板锚点 `topRight`/`topLeft`、面板「朝停靠边缘滑收起」与把手/竖线「朝屏幕内侧滑展开」的方向判定（统一走 `OverlayConstants.swipeExceeds(towardLeft:)` 纯函数）、header 按钮聚拢侧、卡片划走归档方向（`SwipeDismissCard.dismissDirection`：右缘=左滑归档/左缘=右滑归档，反方向快滑经 `onSwipeCollapse` 转发收起——回调名已从 `onSwipeRight` 改中性）、录音胶囊贴屏端（`OverlayVoiceMemoBar.dockLeft`：对齐、距屏边距、停止钮与分隔线钉靠屏端、阴影投射方向）
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

### 面板 header 录音按钮（2026-10-19，收起 chevron 换语音速记）

用户需求：悬浮窗顶部工具条的「折叠悬浮窗」chevron 换成录音按钮，点击直接开始录音，走「会随时间变长的录音胶囊」入口。改动与链路：

- **UI**：`OverlayPanelHeader` 构造参数 `onCollapse` → `onStartVoiceMemo`，末位按钮 `Icons.chevron_*` → `Icons.mic`（白图标，tooltip「语音速记」），按钮顺序变为「新增笔记 / 全部展开·收起 / 打开随手记 / 语音速记录音」（2026-10-27 起在「新增」右侧插入「剪贴板存为笔记」，见下节）。**收起面板的职责收编到空白区点击/任意方向滑动与卡片划走手势**（既有手势本就覆盖收起，chevron 是冗余入口）
- **⚠️ 启动必须走原生入口**：Dart 侧**不直接调 `_voiceMemo.start()`**——Kotlin 侧 toggle 状态机（`voiceMemoActive`）、四级 watchdog、Pro 门禁、主 App 麦克风互斥都以原生为权威，Dart 直调 controller 会让原生失联（音量键 toggle 停录失灵、watchdog 不挂钩）。链路：按钮 → `OverlayHome._startVoiceMemoFromHeader` → 新通道方法 `AccessibilityOverlay.startVoiceMemo()` → Kotlin channel handler `startVoiceMemo` 直调 `triggerVoiceMemoOverlay()`（与音量键「悬浮窗录音」动作**同一入口**，门禁/互斥/toggle/watchdog 全部复用）→ 原生经既有 `notifyDartStartVoiceMemo` 消息回 Dart `onStartVoiceMemo` handler → controller.start() 开录
- **窗口切换**：面板态点击时 `overlayView != null`，走非隐藏窗暖路径（hiddenReveal=false，Dart 录音态首帧即发 voiceMemoUiReady，Kotlin 非 pending 时收到是 no-op）；`_onVoiceMemoChanged` 照常 resize 面板窗口为录音胶囊（312×84）
- **边界**：录音中 header 随窗口变为胶囊离屏不可达，按钮的 toggle 停止分支天然不存在（停止仍走音量键 toggle / 胶囊停止钮 / 说完自动停）；主 App 录音中点击走 `isRecording()` 互斥，按既有语义退回「显示浮窗」（罕见边角，接受）；面板高度档位的顶部下压偏移随 header 整体生效，无需改动

### 剪贴板存为笔记（2026-10-27，header 新增按钮）

用户需求：悬浮窗顶部「新增笔记」右边加一个剪贴按钮，点一下就把系统剪贴板最近一条内容直接存成笔记，省掉「新增 → 粘贴 → 保存」三步。

- **UI**：`OverlayPanelHeader` 新增参数 `onSaveClipboard`，按钮 `Icons.content_paste`（白图标，tooltip「剪贴板存为笔记」）紧挨「+」右侧，顺序变为「新增笔记 / 剪贴板存为笔记 / 全部展开·收起 / 打开随手记 / 语音速记录音」；空列表只剩 4 个按钮（展开/收起照旧不渲染）
- **链路**：点击 → `OverlayHome._saveClipboardToNote` → 原生通道 `AccessibilityOverlay.readClipboard()` → Kotlin handler `readClipboard` 读剪贴板首条纯文本 → Dart `insertDiary(text.trim())`（统一入口自动取 min-1 sort_order 置顶）→ `DiarySyncBridge.bump()` 让主 App 感知 → 静默刷新并把新卡加入 `_expandedIds`（即时看到存了什么，想改再点正文进编辑）→ 原生 Toast「已保存到随手记」
- **⚠️ Android 10+ 剪贴板焦点限制**（本功能的核心难点）：系统只允许**持有输入焦点**（或默认输入法）的应用读剪贴板，而展开面板刻意是 `FLAG_NOT_FOCUSABLE` 窗口（不抢用户当前 App 的焦点与键盘，见「展开面板视觉」）。因此 Kotlin `readClipboardWithFocus` 在非聚焦时做一次**临时提权**：摘掉 `NOT_FOCUSABLE` → 等 `onWindowFocusChanged(true)`（最多 500ms，同 `awaitWindowFocusThenReply` 的兜底）→ 读 `getPrimaryClip` → 立刻还原原 flags。编辑态窗口本就可聚焦（focuspointer），直接读、不折腾
- **⚠️ 还原不能无条件写回旧 flags**：等待期间 Dart 可能已进入编辑态（focuspointer）、开始语音速记（叠 `KEEP_SCREEN_ON`）或隐藏窗口重设 flags。还原前比对当前 flags 是否仍等于本次提权值，只有仍是才写回，否则放过——避免把编辑态窗口踢回不可聚焦（有光标无键盘）
- **边界**：剪贴板为空/图片等非文本/系统拒绝读取统一 Toast「剪贴板里没有可保存的文字」不落库；编辑中点击提示「先完成当前编辑」（静默刷新会重建列表打断编辑）；录音/转写中面板不可达直接忽略；`_savingClipboard` 防连点重复入库（读剪贴板含最多 500ms 焦点等待，窗口期比普通写库长）；内容 `trim()` 后存，空白不上库

#### 音量键入口（2026-10-28，不展开面板也能量）

用户需求：把手势绑到音量键，按一下就把最近复制的内容存进随手记，**不用先展开面板再点剪贴按钮**。动作值 `overlay_clipboard_note`，落库链路完全复用上面的 `_saveClipboardToNote`（只把震动从 Dart 侧关掉，原生触发时已震一次）。

- **浮窗已显示**（把手/竖线/面板）：直接复用现有窗口，走同一套 `readClipboardWithFocus`（含面板不可聚焦时的临时提权）
- **浮窗不存在**：没有任何窗口可借焦点（Android 10+ 限制），Kotlin `triggerOverlayClipboardNote` 直建一个 **`alpha=0 + NOT_TOUCHABLE` 的临时隐藏窗**（`showOverlay(hidden=true, revealOnUiReady=false)`，312×84 直建，复用语音速记冷启动机制），Dart 处理完回执 `clipboardNoteDone` 收窗；10s 超时兜底（`CLIPBOARD_NOTE_TIMEOUT_MS`）。用户全程看不到浮窗，只有一条 Toast
- **⚠️ 临时窗永不揭示**：`showOverlay` 新增 `revealOnUiReady` 参数（默认 true，语音速记/按住说话/Pro 提示胶囊行为不变）；剪贴板临时窗传 false，不置 `pendingVoiceMemoReveal`——否则后续动作会把"隐藏窗在场"误判成待揭示状态
- **⚠️ 收窗按 View 身份比对**：等待 Dart 的这段时间里用户可能用别的动作重建了浮窗（`showOverlay` 先 hide 再 add），`clipboardNoteView` 只收本次那个 View；所有移窗路径（`hideOverlay` / `destroyOverlayEngine`）清空临时窗与挂起请求
- **Dart 未就绪**：`pendingClipboardNote` + `pendingClipboardNoteEphemeral` 挂起（与 `pendingNewNote` 同机制），`dartReady` 后补发 `saveClipboardNote`（负载 `{ephemeral: bool}`，Dart 只用于日志）
- **录音中**：先于 Pro 门禁直接 Toast「录音中，先结束录音再存剪贴板」不建窗（避免提示胶囊顶掉正在录的胶囊）
- **Dart 侧**：`OverlayHome._onSaveClipboardNoteFromGesture` → `_saveClipboardToNote(haptic: false)` → finally 回执 `clipboardNoteDone`（成功/失败/空剪贴板都要回）
- **未验证风险（需真机确认）**：`alpha=0` 临时窗能否拿到输入焦点理论上可行（焦点判定与 alpha 无关）；万一拿不到，`readClipboardWithFocus` 500ms 等焦点超时后安全降级为「剪贴板里没有可保存的文字」并收窗，不会卡死。详见 @volume-key-shortcuts.md「剪贴板笔记」小节

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
- **线态常量**：`edgeLineWidth = 4`（视觉线宽）/ `edgeLineWindowWidth = 20`（窗口宽 = 触摸缓冲区）/ `edgeLineHeight = 64` / `edgeLineGradientDeep·Light`（明暗渐变双色，见「贴边竖线驻留」小节配色段）/ `edgeLineEnabledPrefKey`（驻留开关）/ `edgeLineTapEnabledPrefKey`（点按回把手开关）/ `edgeLineMarginPrefKey` + `parseEdgeLineMargin` / `edgeLinePadding`（距屏幕边缘间距三档 0/4/8，纯 Dart 视觉内移，见「贴边竖线驻留」小节）——线态窗口宽与 Kotlin `EDGE_LINE_WIDTH_THRESHOLD_DP`(24) 是双侧副本
- **语音速记停止提示**：`voiceMemoStopHintMaxShows = 2` / `voiceMemoStopHintCountPrefKey = 'overlay_voice_memo_hint_shown_count'` / `voiceMemoHintGap = 3`（见「停止提示胶囊」小节）

### lib/overlay/overlay_home.dart
- **L31 相位枚举**：`_PanelAnimPhase { idle, expanding, collapsing }`（推屏动画编排，见"展开/收起推屏滑动动画"小节）
- **L101 揭示门字段**：`_revealGatePending`（隐藏窗口揭示门，第四轮修复语义见"冷启动隐藏窗口"小节；旧 `_revealGateConstraints` 约束基准已删除）
- **initState L140 起**：动画控制器创建 + `setupNativeChannel`（onExpand 防御性 resize + `_expand()`；onReset → `_resetFromNative`；**onStartVoiceMemo L183 起——hiddenReveal 挂门在 handler 顶部**；onSaveClipboardNote → 手势剪贴板笔记（2026-10-28，处理完回执 clipboardNoteDone））+ `notifyDartReady()` 握手
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
- **`_buildPanel`（L885 起）**：展开态 Stack 布局——`Positioned.fill` 空白区垫底 + 自适应面板包动画层（AnimatedBuilder child 缓存整块 + FractionalTranslation/Opacity）。面板锚点默认贴停靠侧上角（`panelAlignment`；「按钮位置 = 底部」时贴下角）；header 按钮条（top padding 40 避状态栏；底部模式在列表下方、bottom 48 避导航栏）；日记 ListView `shrinkWrap` 高度收缩，bottom 48 避导航栏（底部模式改 8，导航栏由按钮条避让），条目多时内部滚动；动画期间叠加把手

### lib/overlay/overlay_data_client.dart
- overlay isolate 的数据客户端，直连 sqflite（`DbHelper().getDiaries()`）。旧的跨 engine 服务端 `overlay_data_bridge.dart` 已删除

### android/.../VolumeKeyAccessibilityService.kt
- **L72-73 常量**：`VOICE_MEMO_OVERLAY_WIDTH_DP = 312` / `VOICE_MEMO_OVERLAY_HEIGHT_DP = 84`（隐藏窗口直建尺寸硬编码副本，唯一真值在 Dart overlay_constants.dart，改尺寸须双侧同步）
- **L110-121 字段**：`dartReady` / `pendingAutoExpand`（握手状态，见"自动展开"小节）/ `pendingVoiceMemoReveal`（隐藏窗口标记，L129 附近）
- **L377 `vibrateOneShot()`**：单次震动封装（triggerQuickRecord / triggerShowOverlay 共用，含 SDK < O 降级）
- **L454 `triggerShowOverlay()`**：长按直连入口——toggle 判断 + `showOverlay(autoExpand = true)`，已废弃 startActivity 绕路
- **L640 `showOverlay(autoExpand, hidden, revealOnUiReady = true)`**：显示浮窗；hidden=true 时**直建胶囊尺寸隐藏窗口**（addView 312×84 + alpha=0 + NOT_TOUCHABLE）；`revealOnUiReady=false`（剪贴板笔记临时窗）不置 `pendingVoiceMemoReveal`；`wm.addView` 后 `if (autoExpand) notifyDartExpand()`
- **`triggerOverlayClipboardNote()` / `notifyDartSaveClipboardNote()` / `onClipboardNoteDone()`**（2026-10-28）：音量键「剪贴板笔记」动作——浮窗不存在时直建临时隐藏窗借焦点，Dart 回执收窗 + 10s 超时兜底，收窗按 `clipboardNoteView` View 身份比对（等待期间重建的浮窗不会被误关）；见「剪贴板存为笔记·音量键入口」
- **L671 起**：accessibility_overlay channel 服务端（resizeOverlay / updateFlag / closeOverlay / **clipboardNoteDone**——收临时隐藏窗 / **dartReady** / **voiceMemoUiReady**——揭示延迟 2 vsync / **beginHandleDrag·dragHandle·endHandleDrag**——把手拖动移窗与落盘，见"把手长按拖动"小节）
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
- **窗口加高 64→84**（`voiceMemoWindowHeight`，Kotlin `VOICE_MEMO_OVERLAY_HEIGHT_DP` 硬编码副本同步）：84 = 胶囊 44 垂直居中带 + 下部提示条带（提示胶囊 ≈21dp + 间距 3dp）。展示提示时"胶囊+提示"整块在窗口内垂直居中，胶囊仅比历史位置上移 ~8dp；**84 必须 < 把手高 88**——build 硬不变量按 `isCapsuleHeightWindow`（阈值=两高度中点 86）判定 idle 帧渲染空白，≥88 会与把手窗高度档重叠、pre-gate 帧误渲染把手
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

Dart 侧另有一条不依赖时序的**硬不变量**（build 顶层，语音速记分支之前）：`_voiceMemo.state == idle && OverlayConstants.isCapsuleHeightWindow(constraints.maxHeight)` → 渲染纯空白。把手（88dp 高）永远不可能合法出现在胶囊高度（84dp）的窗口里，attach 瞬间/消息到达前的 pre-gate 帧物理上渲染不出把手。判定阈值取两设计高度中点 86（`handleWindowHeightThreshold`），⚠️ 不能直接 `< handleHeight`——dpToPx 取整误差会让把手窗实测小于 88（见下节「硬不变量高度误判」）。

#### 硬不变量高度误判（2026-09-27 修复，真机反馈「把手不显示、点竖线后消失」）

**症状**：Redmi（miro，Android 16/HyperOS，450dpi）用户收起面板后把手永不出现、点贴边竖线回把手后竖线"消失"（窗口变成 28×88 隐形空白），只有滑动竖线能展开面板。渲染分支追踪日志显示每次缩窗回把手后都是「resize 已落地 27.7x87.8 → 硬不变量空白」。

**根因**：Kotlin `dpToPx` 对 88dp 截断取整——density 2.8125（1080px/384dp）下 88×2.8125=247.5px 截成 247px，Flutter 侧量到的窗口高 = 247/2.8125 = **87.8 < 88**，把手窗口自己被硬不变量误判为胶囊高度档，把手像素永远不进帧。竖线能渲染是因为判定带 `!isEdgeLine` 例外；440dpi（density 2.75，88dp→242px→88.0 整）等密度整除的设备不触发，开发侧复现不了。

**修复（双保险）**：

1. **Dart 主修复**：判定改走纯函数 `OverlayConstants.isCapsuleHeightWindow(maxHeight)`，阈值 `handleWindowHeightThreshold` = 把手高与胶囊窗高的中点（(88+84)/2 = 86）。安全性论证：dp→px 取整误差恒 <1px（≤1dp，mdpi 极端也就 1dp），把手窗实测最低 ≈87.0、胶囊窗实测最高 ≈84.5，86 落在两侧安全区正中，任意密度不踩界。测试 `test/overlay_window_height_threshold_test.dart`（83.0/83.9/84.0 → true，87.0/87.8/88.0 → false，竖线 64 → true 但由 isEdgeLine 例外放行）。
2. **Kotlin 配套**：`dpToPx(Int)` 截断（`.toInt()`）改四舍五入（`.roundToInt()`），247.5→248px→88.18，把手窗实测回到 ≥88，减少其他「== 把手宽/高」类判定的踩坑概率（拖动守卫等比较双侧同函数换算，一致性不受影响）。

**教训**：用「实测窗口尺寸 vs 设计常量」做分类判定时，比较必须带取整容差——实测值 = round/trunc(dp×density)/density，与设计值最多差 1px；两个设计值间距（4dp）远大于误差上界（1dp）时，取中点阈值是最稳的判定。

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

## 卡片标注（标签换色，2026-09-02；2026-09-22 上提时间行一级直出；2026-10-22 扩成 4 槽位可换图标/颜色）

展开卡**时间行**直出 4 个标注按钮（默认 ❗urgent / ⭐star / 💡idea / ✓task，时间文本后紧凑排列，命中区 28×32、相邻 2dp，时间文本由 `FittedBox(scaleDown)` 兜底窄屏），点按即换色/取消，无二级菜单。首版（2026-09-02）为两步交互——底部按钮条标注入口（`Icons.label_outline`）→ 底行整行替换标注选择态「❗ ⭐ 💡 ✗返回」，2026-09-22 用户要求上提一级（时间行右侧原有空隙 + 时间格式改横杠省出的空间刚好放下），二级菜单机制（`isTagPicking`/`onTagEntry`/`onTagPickCancel`/`_tagPickingIds`）整体删除。标注持久化到 diary 表 `tag` 列（TEXT 可空，DB v9→v10 新增），悬浮窗与主 App 共用同一数据库。

**4 槽位只换皮肤不改 id**（2026-10-22 用户定夺）：槽位 id 固定 `urgent/star/idea/task`（第 4 个是新增的稳定 id），设置页「外观 → 标签外观」只允许从 **24 个精选图标 + 10 个颜色**里换图标/颜色，不提供改名——CSV/云同步/旧数据零迁移。配置唯一真值在 [lib/utils/diary_tag.dart](../../lib/utils/diary_tag.dart) 的 `DiaryTagStyles`（prefs key `diary_tag_styles_v1`，JSON `[{tag,icon,color}]`；坏项跳过、缺槽位补默认、颜色强制不透明）。生效链路：主 App 保存 → `ValueNotifier` 即时重绘日记页筛选行/色点 → `DiarySyncBridge.bump()` → 悬浮窗下次展开前 `_refreshOverlayConfig` reload prefs 并显式传 `tagStyles` 给卡片；电脑访问服务每次 `GET /api/notes` 附带 `tagConfig`（图标 `codePoint` + 浅底/深字 hex），网页用 `/tag-icons.otf`（App 打包的 MaterialIcons）按 codePoint 渲染。配置随全量备份 ZIP 的 `tag_config.json` 走（导入为覆盖语义；老备份无此文件时保留本机现值），不参与云同步（用户明确暂不做 WebDAV）。

### 交互与状态

- **时间行标注按钮**（`_buildInlineTagButton`）：当前已标注的按钮加视觉强调（白底圆 24 + 图标换配置色 15，未选中白图标 17，对齐 `_buildCheckbox` 勾选态视觉语言的缩小版）；**点击已选中的 tag = 取消标注**（toggle 回默认色）；命中区 28×32（4 槽位比原三色横向收紧 4dp）= 时间行高，`_estimateExpandedHeight` 的 timeRowH 分母不变；收起 chevron 同步收紧到 32×32
- **写库**：`OverlayHome._setDiaryTag(id, tag)` → `DbHelper.updateDiaryTag` → 内存列表按 id 局部更新（⚠️ sqflite 查询结果是只读 QueryRow，须 `{...row, 'tag': tag}` 物化替换）；不整表 reload
- **归档卡**：允许标注（tag 正常入库），视觉仍固定灰色，恢复后显示标注色
- **主 App 筛选行**（`diary_tab._buildTagFilterRow`）：普通 + 4 个槽位；纯图标（tooltip 普通/「标签 N」），外边距 16、芯片间距 6，窄屏整行可横向滚动。2026-10-22 用户要求去掉「全部」芯片（中字号下行宽放不下）：改为点一次选中筛选、再点已选中芯片取消筛选（恢复全部）

### 取色规则（替代旧的 index % 6 轮换色板）

| 状态 | 颜色 |
|---|---|
| 归档卡 | 固定灰 `blueGrey.shade300` α0.5 + 删除线（不变） |
| 活跃卡无标注 | 固定默认色 `OverlayConstants.defaultCardColor` #6F9AF0 |
| 活跃卡已标注 | 该槽位配置色（默认 urgent #FF6B6B / star #FEA545 / idea #AE82E4 / task #2E9F5C） |

tag→外观映射唯一真值在 [lib/utils/diary_tag.dart](../../lib/utils/diary_tag.dart)，**主 App 日记页共用**：主 App 不改卡片背景，只在卡片顶部时间行前渲染 8dp 彩色小圆点（归档卡也显示）。CSV 全量备份导出加「标注」列（放最后），导入兼容旧备份（缺列/非法值按无标注处理）。

### 关键文件

| 文件 | 说明 |
|---|---|
| [lib/utils/diary_tag.dart](../../lib/utils/diary_tag.dart) | 4 槽位 id + 24 图标/10 颜色白名单 + `DiaryTagStyleConfig` 编解码 + `DiaryTagStyles` prefs/notifier（双 engine 共用） |
| [lib/settings/tag_style_settings_page.dart](../../lib/settings/tag_style_settings_page.dart) | 「标签外观」二级页：槽位列表 + 图标/颜色底部弹层 + 恢复默认 |
| [lib/overlay/widgets/overlay_diary_card.dart](../../lib/overlay/widgets/overlay_diary_card.dart) | 取色逻辑 + `tagStyles`/`onTagToggle` 参数 + 时间行 `_buildInlineTagButton` |
| [lib/overlay/overlay_home.dart](../../lib/overlay/overlay_home.dart) | `_setDiaryTag` + `_refreshOverlayConfig` 读入 `_tagStyles` 并透传 |
| [lib/db_helper.dart](../../lib/db_helper.dart) | diary.tag 列（v9→v10 迁移）+ `updateDiaryTag` |
| [lib/diary_tab.dart](../../lib/diary_tab.dart) | 主 App 卡片 8dp 标注小色点 + 4 槽位筛选行（notifier 监听重绘） |
| [lib/web_server/diary_web_server.dart](../../lib/web_server/diary_web_server.dart) | `/api/notes` 的 `tagConfig` 投影 + `/tag-icons.otf` 字体路由 |

## 卡片长按拖动排序（2026-09-29）

展开面板的**收起态活跃卡**长按进入拖动排序：拖起瞬间 tick 震动，拖动中其余卡片对应移动让开，松手落位后持久化。**已展开卡、归档区卡、编辑中的卡片不可拖**（长按落回 onTap 展开/滑走归档既有手势，互不冲突）；锁定卡允许拖。顺序持久化到 diary 表 `sort_order` 列（方案 B 拍板：双端一致），主 App 日记页与电脑访问服务读同一 getDiaries SQL 自动跟随——字段语义/迁移/回填细节见 @database.md v16 行。

### 实现要点

- **列表换 `ReorderableListView.builder`**（其余参数与原 ListView 等价：shrinkWrap/padding 不动）：`buildDefaultDragHandles: false` 关掉默认短按手柄，itemBuilder 里仅对满足条件（活跃 && 未展开 && 非编辑中）的卡片包 `ReorderableDelayedDragStartListener(index:)`——编辑中整列禁拖与既有 `SwipeDismissCard(enabled: _editingDiaryId == null)` 同款语义；key 落在外层 listener 上（ReorderableListView 直接 child 必须有 key）
- **震动**：`onReorderStart` → `AccessibilityOverlay.performHaptic('tick')`（拖起瞬间，与把手/竖线滑动展开同触感家族）
- **proxyDecorator = `Material(type: MaterialType.transparency)`**：面板背景透明，默认拖拽反馈的 Material elevation 会画出白色底块+阴影（透明面板禁 boxShadow 的既有教训同款）
- **落点 clamp 收纯函数** `reorderActiveItems`（[lib/overlay/overlay_diary_reorder.dart](../../lib/overlay/overlay_diary_reorder.dart)）：拖到归档区位置 = 落到活跃区末尾，归档区整体与「已归档」分隔线（钉在归档首卡 Column 内）不动；归档卡被拖/原位放置原样返回同一 List 实例，调用方 `identical` 判 no-op（不 setState 不落库）
- **持久化纪律**（`_onReorderDiary`）：内存先行（setState 立即落位，拖动/动画期不查库）→ `DbHelper.reorderActiveDiaries(活跃区 id 序)`（事务内规范重写 0..n-1，漏网活跃行续排尾部、归档行不动，内部 bump 云同步数据版本）→ `DiarySyncBridge.bump()`（主 App 日记页感知）；失败 catch + `_loadDiaries(showLoading: false)` 回库恢复真相（照 `_setDiaryTag` 模式）
- **真机回归点**：长按活跃收起卡可拖、展开/归档/编辑卡拖不动、拖到最底落活跃区末尾、归档分隔线不乱、主 App 日记页回前台顺序同步

## 卡片截图附件（2026-10-21；2026-10-24 双向多图 + 图集）

展开卡底部**复制按钮长按 = 截图存为附件**（tap 仍是复制，两手势由 GestureDetector 竞技场自然分流）：先收起悬浮窗避免自拍，等窗口缩回把手尺寸后调原生无障碍截图，落盘后写入该日记 `image_path`，展开卡正文右侧显示 44dp 缩略图，点缩略图在面板内唤起全屏预览（`InteractiveViewer` 最大 4 倍，单击/右滑/右上角 ✕ 均可关闭）。长按判定成立瞬间给 `click` 触觉反馈（用户要求：此前无震动，不知按多久才触发），缩略图点击给轻档 `tick` 反馈。截图成功后的去向由设置「截图后展开笔记卡片」控制：**默认关**（历史行为）= 只 Toast 提示并保持收起；**开启** = Toast 后重新唤出面板并展开该卡，方便核对截图效果或继续编辑。**首次长按会失败**：截图能力依赖无障碍服务配置 `android:canTakeScreenshot="true"`，已启用服务的用户需在系统设置里关闭再重开本服务才会加载新配置（Toast 提示「请重新开启无障碍服务」）。

**多图（2026-10-24）**：电脑端同步来的图片落在 v18 `diary_images`，与本机截图一起构成该笔记的图集。缩略图显示 `primary_image_path`（本机截图优先，否则电脑端按 `position` 第一张），张数 > 1 时右下角叠数量角标；点击把「本机截图 + 下收多图（按 position）」合并成路径列表送入图集。图集可左右滑动切换、底部显示「当前 / 总数」，右滑不再直接关闭（避免翻页误退），关闭仍走 ✕/单击/黑底；单图时保留右滑关闭。文件被外部清理的路径在打开前过滤，全空时提示「图片文件已不存在」。

**图集内删图（2026-10-25，用户要求：截图完也要能单独丢图）**：预览层左上角 🗑（与右上角 ✕ 同款 48×48 opaque 命中区，顶栏改 `Row(spaceBetween)` 左右各一格）。**只删手机自拍的那张**（`diary.image_path`）——电脑端同步来的图不给删除入口：`image_index.json` 按设备所有权合并，本机摘掉别人的条目会被来源端下轮重发布，删不干净（见 @cloud-sync.md「删除边界」）。因此按钮只在这组里确有本机截图时才渲染（`ownImagePath` 为空即不渲染，主 App 日记页共用本组件但不传删除参数、行为不变）；翻到电脑端那张再点 🗑 走 `onForeignImageTap` → 原生 Toast「这张来自电脑端，请在电脑端删除」。点 🗑 不立即删：左上角整格替换成「确认删除？✓✗」（复用卡片删除确认行的整行替换先例，✗ 只退出确认态、不关预览；翻页即作废确认态——确认的是上一页那张）。✓ → 父层 `_onDeleteOwnPreviewImage`：先 `updateDiaryImage(id, null)` 再删文件（顺序不可反，写库失败时图仍在，不留破图）→ `DiarySyncBridge.bump()` → 清预览态 → tick 震动 + Toast「截图已删除」→ 静默重查列表（缩略图/角标随即消失）。删完**关掉图集**：路径列表由父层持有，组件的翻页/缩放状态不随列表收缩重算，留在原地会停在越界页。`_deletingImageIds` 按 id 防抖（写库+删文件是异步的，连点 ✓ 会重复走链路并多 bump 一次）。下轮手动同步时本机索引条目自然消失 → 电脑端摘掉对应附件。

### 原生截图链路（Android 11+ / API 30）

- **能力判定**：`AccessibilityServiceInfo.CAPABILITY_CAN_TAKE_SCREENSHOT`（⚠️ 不存在 `FLAG_REQUEST_TAKE_SCREENSHOT`，曾照网络示例写错编译失败）；`Build.VERSION.SDK_INT < R` 直接返回 `unsupported_os`
- **自拍规避**：`takeScreenshot` 会截到悬浮窗自身 → 先保存原 `LayoutParams.alpha`，设 0 + `updateViewLayout` 隐藏，等 64ms（约 3 帧）再截图，`onSuccess`/`onFailure`/3s 超时三路都必须恢复 alpha（`restoreOverlay()` 幂等）
- **结果转换**：`ScreenshotResult.hardwareBuffer` + `colorSpace` → `Bitmap.wrapHardwareBuffer(...).copy(ARGB_8888, false)` → **立刻 close buffer** → JPEG 85 后台线程落盘
- **并发守卫**：`screenshotBusy`（`AtomicBoolean.compareAndSet`）防连按；失败码映射（`interval_time_short` = 截图太频繁、`no_capability` = 服务需重开等）在 Dart 侧转中文 Toast
- **Toast 载体**：收起后 overlay 窗口只剩 28×88 把手，Flutter SnackBar 无可见落点 → 走原生 `Toast.makeText`（channel 方法 `showToast`）

### 存储与展示规则

- 文件：`getApplicationDocumentsDirectory()/diary_images/diary_<id>_<ms>.jpg`（同 `diary_audio/` 约定）；**本机截图每卡一张**，重截先写新文件 → 更新 `image_path` → 再删旧文件（截图/落盘失败不丢旧附件）。电脑端同步下来的图片另存 `diary_images/diary_sync_<uuid>_<sha 前 8 位>.<ext>`，行落在 `diary_images` 表（见 @database.md v18）
- **不进备份，图片随云同步双向（2026-10-24）**：不进全量备份 ZIP/CSV；`image_index.json` 只放索引、图片字节进共享 `v2/assets/<sha前两位>/<sha256>.<ext>`（内容寻址），电脑端以 `source='desktop'` 发布自有图片、手机按索引下收多图。`updateDiaryImage` 改为 bump `CloudSyncDataVersion`（替换截图算待同步变更），`batchInsertDiaries` 仍不映射该列；备份导入后的日记 `image_path` 为 NULL
- 缩略图：仅展开查看态渲染（`lockedHidden` 打码卡不渲染——图片属笔记内容；编辑态也不渲染）；取 `primary_image_path`，`cacheWidth: 176` 控内存；张数 > 1 时右下角叠半透明黑底数量角标（fontSize 9）；文件缺失走 `broken_image_outlined` 兜底
- 预览层：面板内 `Positioned.fill` 模态 `OverlayImagePreview`（照 BigBangLayer 模式，不用 `showDialog`——overlay engine 弹独立路由会脱离面板坐标系）；黑底 + `InteractiveViewer` 4 倍；多图时 PageView 左右切换（`physics: NeverScrollableScrollPhysics`，翻页由外层 `Listener` 原始指针在超过 56dp 时 `animateToPage`——InteractiveViewer 的缩放识别器会抢走 PageView 的水平拖拽），每页切换复位缩放，底部页码「n / N」；**单图**单击图片/黑底、右滑超过 88dp 关闭，多图右滑只翻页不关闭；放大态 scale>1 与多指期间不响应翻页/侧滑，避免平移图片时误翻；右上角 ✕ 始终可关；左上角 🗑 删本机自拍截图（归属判定/确认态/删除链路见上「图集内删图」）；收起/息屏/重锁/复位/删除当前卡都会清预览
- 生命周期：**归档保留图片**（用户拍板），真实删除/转存才清文件——覆盖悬浮窗删除、滑动撤销最终落库、主 App 删除/转存/取消空白新笔记、电脑访问服务删除五条路径
- 收尾去向：设置开关 `overlay_screenshot_expand_card`（悬浮窗二级页「截图附件」，默认关，Pro 门禁）由 `_onCardCopyLongPress` 在成功收尾时 reload 现场读——关=保持收起；开=再走 `_expand()` 并把该卡加进 `_expandedIds`（动作型设置即时生效，读取异常按关闭兜底）
- 锁定门禁：长按截图与点开预览前都走 `_ensureNoteUnlocked`（与复制/编辑同语义）

### 关键文件

| 文件 | 说明 |
|---|---|
| [android/.../res/xml/accessibility_service_config.xml](../../android/app/src/main/res/xml/accessibility_service_config.xml) | `canTakeScreenshot="true"` |
| [android/.../VolumeKeyAccessibilityService.kt](../../android/app/src/main/java/com/shengwuji/app/VolumeKeyAccessibilityService.kt) | `captureScreenshot`（隐藏窗口 → 截图 → 恢复 alpha → JPEG 落盘）+ `showToast` 通道 |
| [lib/overlay/accessibility_overlay.dart](../../lib/overlay/accessibility_overlay.dart) | `captureScreenshot(path)` / `showToast(text)` channel 封装 |
| [lib/overlay/overlay_home.dart](../../lib/overlay/overlay_home.dart) | `_onCardCopyLongPress`（长按 click 震动 → 收起 → 截图 → 落库 → Toast）、`_openImagePreview`（门禁 + tick 震动 + 合并本机/电脑端多图路径） |
| [lib/overlay/overlay_data_client.dart](../../lib/overlay/overlay_data_client.dart) | `getDiaryImagePaths(diary)`（本机 image_path 在前 + `diary_images` 按 position） |
| [lib/overlay/widgets/overlay_image_preview.dart](../../lib/overlay/widgets/overlay_image_preview.dart) | 图集层：PageView 左右切换 + 页码 + 单图右滑关闭 + 双指缩放 + 右上角 ✕（`Listener` 原始指针驱动翻页）+ 左上角 🗑 删本机截图（确认态整格替换；`ownImagePath` 为空不渲染） |
| [lib/overlay/widgets/overlay_diary_card.dart](../../lib/overlay/widgets/overlay_diary_card.dart) | `onCopyLongPress` / `onImageTap` 参数 + 44dp 缩略图 + 数量角标 + `_estimateExpandedHeight` 宽度扣减 |
| [lib/db_helper.dart](../../lib/db_helper.dart) | `diary.image_path`（v16→v17）+ v18 `diary_images` 多图读写 + `image_count`/`primary_image_path` 计算列 + `updateDiaryImage`（bump 云同步数据版本）+ `updateDiaryImagePathByUuid`（下载截图回填），迁移细节见 @database.md v17/v18 行 |
| [lib/sync/image_sync.dart](../../lib/sync/image_sync.dart) | `image_index.json` 编解码 + 索引合并/下载计划纯函数（截图同步，见 @docs/architecture/cloud-sync.md） |
| [lib/settings/overlay_settings_page.dart](../../lib/settings/overlay_settings_page.dart) | 「截图附件」分区开关 `overlay_screenshot_expand_card`（截图后展开当前卡） |
| [lib/overlay/overlay_constants.dart](../../lib/overlay/overlay_constants.dart) | `screenshotExpandCardPrefKey`（截图后展开开关的 prefs key 唯一真值） |

## 正文链接（2026-10-27）

展开卡查看态正文里的 http(s)/www 链接显示**白色下划线**，点击用系统浏览器打开（不内嵌 WebView）：

- 识别：`lib/utils/link_text.dart#findTextLinks`（主 App 与悬浮窗共用）。只认 `http://` / `https://` / `www.`（`www.` 补 `https://`）；裸域名/邮箱不识别；中文紧贴网址按 ASCII 边界截断；尾部句号/逗号/多余右括号不入链接；成对括号（Wikipedia 词条）保留。带 256 条扫描缓存，面板每帧重建不重复扫。
- 手势：正文 `TextSpan` 内 `TapGestureRecognizer` 在竞技场胜过卡片外层 `GestureDetector(onTapUp → 进编辑)`——点链接只开浏览器，不误进编辑（`overlay_card_link_test` 锁定）。链接下划线/颜色不改变字宽行高，`_charOffsetAt` / `_estimateExpandedHeight` 的纯文本 `TextPainter` 度量无需同步。
- 打开通道：`OverlayHome._onCardLinkTap` → `AccessibilityOverlay.openUrl`。悬浮窗 engine 无 Activity，`url_launcher` 的 `launchUrl` 会因缺 Activity 抛错，必须走无障碍服务原生 `startActivity(ACTION_VIEW + FLAG_ACTIVITY_NEW_TASK)`；失败原生 Toast「无法打开浏览器」。
- 收起态胶囊不渲染链接（单行预览，点卡片展开）；锁定打码卡不传 `onLinkTap`（正文不出现链接，属内容级信息）。

| 文件 | 说明 |
|---|---|
| [lib/utils/link_text.dart](../../lib/utils/link_text.dart) | `findTextLinks` 识别 + `buildLinkSpans` 切段 + 扫描缓存（主 App/悬浮窗共用） |
| [lib/overlay/widgets/overlay_diary_card.dart](../../lib/overlay/widgets/overlay_diary_card.dart) | `onLinkTap` 参数 + `_buildViewingBody` 链接段（白色下划线，归档叠加删除线） |
| [lib/overlay/overlay_home.dart](../../lib/overlay/overlay_home.dart) | `_onCardLinkTap` → `AccessibilityOverlay.openUrl` |
| [lib/overlay/accessibility_overlay.dart](../../lib/overlay/accessibility_overlay.dart) | `openUrl(url, packageName: '')`（空包名 = 系统默认浏览器） |
| [test/overlay_card_link_test.dart](../../test/overlay_card_link_test.dart) | 点链接不误进编辑 / 点正文仍进编辑 / `www.` 归一化 |

## 大爆炸分词层（2026-10-06；2026-10-07 词块区纵向居中 + 主 App 层顶边降高 + 四角圆弧；2026-10-08 白底浅色化 + 下层压暗遮罩；2026-10-08 深色模式适配）

展开卡查看态正文**长按**唤起全屏白底模态（锤子 Big Bang 式；2026-10-08 起由深色改浅色，对齐锤子原版白色卡片视觉——文字/词块配色随之反转：未选词块浅灰底深字、选中主题蓝底白字、顶栏/底栏控件同步浅色化）：正文被炸成一个个词块，点选 toggle、滑动连选区间，底栏预览选中拼接文本，一键复制后自动关层。用户拍板：滑动连选首期就要做、做全屏视觉（非底部弹层）。**词块区内容纵向居中（2026-10-07 用户拍板，主 App/悬浮窗共用本层一处生效）**：短内容在词块区居中展示而非从顶往下排，长内容超出视口仍可滚动——`LayoutBuilder` 取视口高 → `ConstrainedBox(minHeight: 视口高−上下padding)` → `Center` 包词块 Wrap（Center 在无界高度下收缩到内容、被 minHeight 钳到视口高，内容超高时居中自然退化）。**白色主体四角圆弧（2026-10-07 用户拍板，同样一处生效）**：`OverlayConstants.bigBangCornerRadius`=20dp——Material `borderRadius` + `clipBehavior: Clip.antiAlias`（Material 的 borderRadius 只影响背景形状，子内容须显式 clip 才随圆角裁切），圆角缺口透出压暗的下层画面（2026-10-08 起缺口/顶部留白/底部关闭条三处统一铺 `bigBangScrimColor` 35% 黑遮罩，明暗分层让白色主体浮出，用户拍板），同一「层不撑满全屏」的视觉语言；⚠️ 缺口区域外包 `GestureDetector(opaque, onTap:(){})` 吸收触摸——裁切外的角落若不接住，overlay 侧穿透会命中面板空白区收起手势（把面板连同本层一起收掉），主 App 侧（opaque:false 路由无 barrier）穿透会点到下层日记卡。

**深色模式适配（2026-10-08，用户需求：APP 深色模式下白底太刺眼，白色改黑色）**：层新增可空参数 `isDark`（null = 跟随 `Theme.of(context).brightness` 自动判定）——主 App 侧经透明路由推入、Theme brightness 已解析 system 档，**不传参零改动自动跟随**；悬浮窗 engine 固定浅色主题（跨背景对比度既有设计），自动判定恒为浅色，故唤起时由 `OverlayHome._openBigBang` reload 后读 `theme_mode` prefs 经 `parseThemeMode` 解析（dark → true / light → false / system → 按 `platformDispatcher.platformBrightness` 裁决），显式传入 `isDark`——大爆炸层是悬浮窗侧唯一消费 `theme_mode` key 的组件。深色底值 `OverlayConstants.bigBangBackgroundDark` = `0xFA101319`，即 2026-10-08 浅色化之前的历史深色底值直接复用；9 处配色位（主文字/次文字/动作文字/未选词块底与描边/禁用底与图标/底栏预览条底与描边）走双色板辅助函数整体反转（深字浅底 ↔ 浅字深底）；选中词块恒主题蓝底白字、`bigBangScrimColor` 35% 黑遮罩与底部 ✕ 按钮（黑 55% 底白图标）深浅共用不变。

> **主 App 随手记复用（2026-10-06 同日；2026-10-07 层顶边降高）**：`BigBangLayer` 同时挂在主 App 日记页——日记卡手势矩阵改为 单击=复制 / 双击=编辑 / **长按=大爆炸**（双击跳 AI 取消，AI 分享保留卡片底部按钮入口；「交换单击与长按」开关变为交换单击↔双击，prefs key 不变）。主 App 侧经透明 `PageRouteBuilder` 推入整层；层顶边 2026-10-07 起从「状态栏高度避让」改为**按悬浮窗「面板高度」8 条档位的顶部高度取值**（`OverlayConstants.bigBangMainAppTopInset` = panelHeaderTopPadding + panelTopOffsetFor(8) = 152dp，用户拍板——主 App 无档位设置项，固定参照 8 条档，比仅状态栏避让矮一截、单手够得着顶栏），`onHaptic` 必须注入 diary_tab 自己的 `_haptic`（缺省走悬浮窗无障碍通道，主 engine 未注册会抛 MissingPluginException），`onCopy` 复用 `_copyToClipboard`。分词器在主 isolate 独立懒加载（static 缓存不跨 isolate 铁律）。

### 入口与门禁

- **手势分流**：正文点按（进编辑、光标定位点击处）与长按（大爆炸）共存于同一个 GestureDetector——点按从 `onTapDown` 改 `onTapUp` 后，tap 等抬起、long-press 压住即触发，手势竞技场自然分流（down 触发会抢在长按之前先进编辑态）
- **门禁**：空内容转写占位行与锁定打码卡不传 `onLongPressText`——明文不出卡片，与 AI 对话/复制的锁定门禁同语义（`_isLockedHidden`）
- **唤起震动**：`performHaptic('tick')`（卡片 AI 对话按钮复制震动的同款 EFFECT_TICK 线性马达家族）；选择变化 tick 40ms 节流

### 分词（[lib/overlay/big_bang_tokenizer.dart](../../lib/overlay/big_bang_tokenizer.dart)）

- 词级切分复用修正对体系的 **dart_jieba**（词典 `assets/jieba_dict.dgz` 运行时拷到数据库目录，拷贝模式照抄 `ContextCorrector._loadSegmenter`）
- **⚠️ overlay isolate 独立懒加载**：加载结果缓存在本 isolate 的 static——主 engine 经 ContextCorrector 加载过的分词器对 overlay isolate 无效（与 sherpa-onnx FFI 绑定同款铁律）
- **回退链**：jieba 加载/切分失败一律回退字符级切分 `charSplit`（CJK 逐字、连续 ASCII 字母数字归并），大爆炸永不缺席
- **二次爆炸 `explodeToChars`**：把选中词块再炸成单字（中文逐字、英文逐字母）——与 `charSplit` 的契约差异：charSplit 是回退链语义（连续 ASCII 归并为一个词），explodeToChars 逐 rune 切、每 rune 一个 token；`String.runes` 按 code point 迭代，emoji 代理对天然不劈开（😀 整体一个不可选 token），标点/空白不可选但保留在序列，"拼接==原文"不变量保持
- **⚠️ jieba 会劈开 emoji 代理对**：dart_jieba 按 UTF-16 code unit 切分，`😀` 会被切成高代理+低代理两个 token——孤立代理不是合法 UTF-16，Text 渲染直接抛 `string is not well-formed UTF-16`（真机 logcat 刷屏根因）。`fromRawTokens` 按代理对完整性把相邻碎片并回完整字符再判可选性，"token 拼接 == 原文"不变量保持
- token 模型：含字母/数字/汉字的可选，纯标点/空白不可选但**保留在序列**——`joinSelected` 把夹在选中词之间的标点/空格原文带出（选 {0,2,4} over `苹果，牛奶 bread` → `苹果，牛奶 bread`）；跳过可选词 = 跳跃点选，间断区原文不带出，但**间断区首/尾紧贴空白时交界补一个空格**——两次滑选的英文词组交界不粘词（修复前 `touch and holdafter two hours`，真机反馈），中文跳跃点选边界本无空格行为不变

### 手势模型（[lib/overlay/widgets/big_bang_layer.dart](../../lib/overlay/widgets/big_bang_layer.dart)）

| 手势 | 实现 |
|---|---|
| 点选 | 词块自带 GestureDetector(onTap) toggle |
| 滑动连选/取消 | 外层 **Listener**（不参与手势竞技场、全量收指针事件）按下命中可选词块记锚点，位移超 **kTouchSlop**（与 tap 识别器同阈值）才进连选——未超松手 = tap 照常 toggle，互不抢；连选中按锚点→当前命中词块的 index 区间操作；**模式由锚点词块的选中态决定（2026-10-07，锤子原版语义）**——锚点未选中 = **追加置选**（本轮起步快照已有选择为基线 `_dragBase`，区间与基线取并集，松手后再次滑选/点选是追加新词而非覆盖旧选——真机反馈：先滑选开头几个词、再到末尾滑选追加时开头的会丢）；锚点已选中 = **滑动取消**（`_dragDeselect`，区间从基线剔除——在已连选的词块上滑过即取消）；同一轮内拖回缩小区间可恢复（基线不动，只影响本轮划到的范围）；划出词块区端点保持原位 |
| 滚动仲裁 | Listener 不抢竞技场，ScrollView 垂直滚动照常；按下落在词块上时 physics 换 `NeverScrollableScrollPhysics`（该次手势纯连选，防边选边滚），松手恢复；滚动起点选在词块间隙/空白区即可 |

命中换算：可选词块 GlobalKey 首帧后缓存 Rect，**相对词块区容器**（同一坐标系随滚动整体平移，滚动不失效）+ `inflate(2)` 容错；指针全局坐标经容器 `globalToLocal` 换算求交。

### 生命周期与复制

- 层 = `_buildPanel` Stack 最上层 `Positioned.fill`（展开面板态窗口本就全屏，无需 resize）；父层只存原文 `String? _bigBangText`，词块状态全在层内 State
- **层顶边对齐面板 header 上缘（2026-10-06，用户反馈全屏太高单手够不着顶栏）**：`BigBangLayer.topInset` = 状态栏固定避让（`OverlayConstants.panelHeaderTopPadding`=40，与 `_buildHeader` 同源唯一真值）+ `panelTopOffsetFor(_panelMaxCards)`——随设置页「面板高度」档位联动下移（档位越低顶边越低，顶栏/词块区整体进拇指区；默认 10 档 inset=40 与旧全屏行为一致）。**2026-10-27「按钮位置 = 底部」时** header 已在屏幕底部、不用让位，`topInset` 回到只避让状态栏（不再叠加面板高度档偏移）。顶边上方为**留白透出下层画面**（2026-10-08 起铺 `bigBangScrimColor` 压暗遮罩，明暗分层）：留白区 `HitTestBehavior.opaque` + onTap 就地吸收触摸——底层是面板空白区的收起手势，穿透会把面板连同本层一起收掉；横滑在留白区无识别器认领（空白区不在命中路径内）天然无操作。层内原顶部 40 避让移除（改由留白承担）
- **层底部改透明关闭条（2026-10-07，用户反馈底部 48dp 深色条带「完全盖住」；2026-10-08 透出部分加压暗遮罩）**：原 Material 内 `Padding(bottom: 48)` 深色避让条带移出改 `_buildCloseStrip()`——**透出下层画面（压暗遮罩 `bigBangScrimColor`）** + **整条点击即关闭**（`onTap: widget.onClose`）+ 中间一枚 ✕ 圆形按钮（黑 55% 底白图标）作视觉落点，单手大拇指在底部即可关层；视觉透明但 `HitTestBehavior.opaque` 吸收触摸（穿透到面板空白区会把面板连同本层一起收掉，主 App 侧穿透会点到下层日记卡）；高度 48 沿用原避让惯例。⚠️ 同款修复：顶部留白 `SizedBox` 只给高度时在 Column（交叉轴默认 center）里收缩到 0 宽，「吸收触摸」形同虚设——已补 `width: double.infinity`
- 清零方：✕ 按钮（顶栏/底部关闭条）/ 复制成功 / 搜索成功 / `_collapse()` / `_resetFromNative()`
- 复制：`joinSelected` 拼接 → 原生 `copyText` 通道（自带 EFFECT_TICK + 写剪贴板）→ 成功关层，失败留在原地
- **搜索（2026-10-06）**：底栏预览与复制之间新增搜索按钮（`onSearch` 可空构造参数，null 不渲染）：`joinSelected` 拼接 → `buildSearchUrl(engine, text)`（`lib/utils/big_bang_search.dart`，百度/必应/Google 注册表，`Uri.encodeComponent` 编码）→ 原生 `openUrl` 通道（`Intent(ACTION_VIEW, url)`，选过浏览器则 `setPackage` 指定，`ActivityNotFoundException` 回落系统默认——覆盖浏览器被卸载场景；overlay 侧走 accessibility_overlay 通道加 `FLAG_ACTIVITY_NEW_TASK`，主 App 侧走 app 通道）→ 成功关层，失败留在原地。**悬浮窗侧搜索成功后面板随即收起到把手（2026-10-20，用户拍板）**——用户跳去浏览器看搜索结果页，全屏模态面板继续展开会挡触摸，overlay_home 的 onSearch 回调在 openUrl 成功后调 `_collapse(source: '大爆炸搜索')`（与卡片 AI 对话按钮 launchApp 成功后收起同语义；失败不收起留在原地）；主 App 侧无此行为（路由页返回即回日记页）。引擎与浏览器在设置→「大爆炸搜索」二级页选择（prefs `search_engine`/`search_browser_package`/`search_browser_name`，默认百度+系统默认；浏览器列表来自新增通道方法 `getInstalledBrowsers`——`queryIntentActivities(ACTION_VIEW, https)` 枚举真浏览器）；读取方 `loadSearchConfig()` 先 reload（跨 engine 惯例）。无选中不搜（与复制同规则）
- **二次爆炸（2026-10-06）**：底栏预览与搜索之间的刀图标按钮（`Icons.content_cut` + Tooltip「再炸成单字」，`_buildCapsuleIcon` 与搜索按钮共用样式 helper），点击把选中词块**就地**炸成单字（`explodeToChars`，选中 index 排序后逐个替换、未选中 token 原对象搬运），炸出的可选单字 index 映射进新 `_selected` **保持选中**（用户可立刻复制/搜索，或点掉多余单字逐字微调）；禁用规则 `_canExplode` = 选中中至少一个多字词（选中全是单字/无选中/分词中禁用，幂等）；**不做撤销**——爆炸是追加式变换（可逐字点选修正），重炸成本仅一次长按；⚠️ tokens 更换后 `_prepareKeys` 连带清 `_rects`（旧 index 的命中 Rect 全部失效，setState 到 postFrame 重缓存之间 `_hitToken` 会拿旧 Rect 命中新词块）+ 连选状态（`_pressedToken/_dragAnchor/_dragBase/_scrollLocked`）防御性复位
- 测试经 `initialTokens` 直通词块跳过 jieba 异步加载、`onHaptic`/`onCopy`/`onSearch` 注入，不触平台通道

## Pro 门禁（2026-09-03）

悬浮窗整体（含语音速记、悬浮窗新增笔记、自动隐藏时长配置）为 Pro 付费功能，**双层门禁**：

### 第一层：设置页 UI（Dart，settings_tab.dart）

- **Pro 徽章**（`_buildProBadge`，金色胶囊复用主题卡片视觉）挂在：手势选择器中 4 个悬浮窗动作 chip（`show_overlay` / `overlay_record` / `overlay_new_note` / `overlay_clipboard_note`）+ "屏幕边缘随手记面板"分区标题
- **点击拦截**（`_ensureOverlayPro`）：未解锁时弹 `ProUnlockDialog` 并 return，**不写 prefs**（用户改不了槽位配置）；自动隐藏时长选择器同款门禁（不加徽章——它是配置项而非入口）
- 解锁后 `_loadProUnlockStatus()` 刷新，徽章即时消失
- 无障碍服务开关行**不标** Pro——它是免费功能（APP 内录音/笔记）共用的系统入口

### 第二层：原生手势拦截（Kotlin，VolumeKeyAccessibilityService）

设置页门禁挡不住"已配置的槽位被音量键直接触发"（包括降级回未解锁、改 SharedPreferences 文件等绕过路径），故无障碍服务在执行动作前自查：

- `isProUnlocked()`：读落盘 prefs `flutter.is_pro_unlocked` **或** `flutter.pro_trial_deadline_ms`（试用截止，未到即放行；与 Dart ProGate 同 key 同语义，2026-09-19 起双层判定。与 `isRecording()` 同款读取模式，每次按键现读，无 MethodChannel）
- `blockOverlayIfProLocked()`：不可用 → 50ms 短震 + **「暂未解锁」提示胶囊** + return
- **提示胶囊**（2026-09-19，替代旧 Toast）：复用语音速记隐藏窗直建机制，在原录音胶囊位置（312×84）弹提示——`showProLockedHint()` 直建隐藏窗 + `notifyDartProLockedHint()` 走 dartReady 挂起补发握手 → Dart `OverlayHome._proHintShown` 渲染 `ProLockedHintPill`（黑 72% 胶囊 +「暂未解锁，无法使用」）→ 首帧发 `voiceMemoUiReady` 揭示（提示窗保持 `FLAG_NOT_TOUCHABLE`）→ 3 秒 Kotlin 收窗。⚠️ 渲染分支必须排在揭示门与「84<88 硬不变量」判定之前（提示态 voiceMemo 仍 idle，排后会被吞成空白）；`proHintActive` 清零唯一入口在 `hideOverlay`（防借提示窗绕出完整悬浮窗/标志残留）；建窗失败或已有浮窗在场回退 Toast 兜底
- **四个挂点**（均在 toggle 放行分支之后）：
  | 函数 | 门禁位置 | 放行的 toggle 分支 |
  |---|---|---|
  | `triggerShowOverlay` | toggle 隐藏分支 return 之后 | 已显示时长按 = 立即隐藏（未解锁用户必须关得掉已显示的浮窗） |
  | `triggerOverlayNewNote` | 方法入口（无 toggle 语义） | — |
  | `triggerOverlayClipboardNote` | 录音中判断之后、建临时窗之前（无 toggle 语义，2026-10-28） | — |
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
