# 性能修复进度日志

> 配套文档：[performance-review.md](./performance-review.md)（问题清单、严重度与优先级）。
>
> 分工约定：**审查文档只反映勾选状态**（每条修完打勾 + Top14 表加状态列），**本文档记录实际改动明细**——修复方式、语义变化、验证结果、真机待验项。避免审查清单被改动细节淹没，也避免改动细节散落在 commit message 里无从追溯。
>
> 记录约定：每完成一批新增一节，按「问题 → 修复方式 → 语义变化 → 验证」组织。

## 进度总览

| 审查项 | 状态 | 完成日期 | 备注 |
|---|---|---|---|
| Top1 TTS 合成同步 FFI 主 isolate 阻塞 | ✅ | 2026-09-06 | 下沉常驻 worker isolate（新建 tts_service.dart） |
| Top2 备份 ZIP 编解码主 isolate + 音频全量进内存 | ✅ | 2026-09-06 | 建档/压缩/解压/音频落盘全下沉 `Isolate.run`；流式 InputFileStream 留作后续可选项 |
| Top3 搜索每键全量查库 + 清四级缓存 + 级联重建 | ✅ | 2026-09-06 | 250ms 防抖 + 搜索路径不清解析缓存；「解析结果下沉卡片级 ValueNotifier」仍开放（属模式 A） |
| Top5 全局 2 秒 prefs 轮询贯穿全生命周期 | ✅ | 2026-09-06 | 原生事件推送（onAlarmRinging/onAlarmStopped）+ 冷启动一次性恢复，轮询删除 |
| Top6 拖拽/状态回调整页 setState（四页陪跑） | ✅ | 2026-09-06 | 拖拽状态下沉独立 widget；onStateChanged 改三个 tick ValueNotifier 局部重建 |
| Top7 overlay 收起卡全文 shaping 无缓存 | ✅ | 2026-09-06 | 按 (content, textScaler, fontFamily) 缓存 intrinsic 宽；clamp/补间逐帧像素不变 |
| Top8 overlay 录音条双控制器空转 | ✅ | 2026-09-06 | 拆两个子 widget 随分支挂载销毁，任一时刻只有一个控制器在转 |
| Top4、Top9～Top14 及各模式明细 | ⬜ | — | 待后续批次 |

---

## 2026-09-06 · 第一批：按优先级修复 Top 1-3

> 按审查文档 Top14 的优先级顺序处理（非第六节建议的批次分组：Top1/3 原属第二批，Top2 原属第一批）。
> 验证基线：`flutter analyze` 全项目 error=0、改动文件零新告警（存量 info 101→94）；`flutter test` 107 通过 / 1 失败——失败项 `dart_chrono_parser_test`（"解析多个时间"期望 3 实体实得 2）为**存量日期相关脆弱用例**，在未改动的 HEAD 上同样失败，与本次改动无关。

### Top1 🔴 TTS 合成同步 FFI 迁出主 isolate

**问题回顾**：`tts_singleton.dart:353` 的 `_tts!.generate(...)` 虽包了 `Future(...)`，但闭包仍在主 isolate 同步执行，Piper 合成期间 UI 冻结数百 ms～秒级（搬家模式播报卡顿的最大嫌疑）；且 FFI native 崩溃（SIGABRT）会直接炸掉整个 APP。

**修复方式**：照 `recognition_service.dart` 架构新建常驻 TTS worker isolate。

- 新建 `lib/tts_service.dart`（约 570 行）：
  - 消息协议：`_ReqInit(modelPath, tokensPath, dataDirPath)` / `_ReqGenerate(text, wavPath)` / `_ReqDispose` ↔ `_EvReady` / `_EvGenerated(ok, empty)` / `_EvError`，字段仅 String/int/bool，满足 isolate 传输约束；
  - worker 内 `initBindings()` 独立初始化 FFI 绑定，OfflineTts 构造（config 与迁移前逐字段一致：lexicon 空 / numThreads 2 / maxNumSenetences 2）与 generate 全在 worker 执行；
  - **合成结果不跨 isolate**：worker 内 generate 后直接 `writeWave` 落盘临时 WAV，主侧只收成败回执（避免大 Float32List 拷贝传输，顺带覆盖审查 4.6 模式 B 的跨 isolate 拷贝问题在 TTS 侧的对应面）；
  - spawn 握手 15s 超时、请求 60s 超时、死亡感知（onError/onExit 双源去重）、60s 窗口 ≥3 次崩溃放弃重启的风暴防护，全部对齐 recognition_service 既有模式。
- `lib/tts_singleton.dart` 重写为门面（422→约 420 行）：
  - 公开 API 签名不变（`initialize` / `speak` / `isReady` / `isInitializing` / `hasEverInitialized` / `preloadModelPath` / `dispose`），唯一调用方 record_tab.dart **零改动**；
  - assets 模型拷贝（`_ensureBundledTts` / 铺平 / 诊断）留在主 isolate——rootBundle 资产句柄仅主 isolate 可用；
  - `_speakLock` 串行化丢弃语义、独立 AudioPlayer + mixWithOthers 播放配置逐行保留；
  - 模型文件名收敛为 `_kModelFileName` 等三个常量（原三处硬编码字符串）。

**语义变化**：

- 对外行为一致：未就绪丢弃、播报中丢弃、合成失败丢弃本句；
- 健壮性提升：native 崩溃不再杀主 isolate，worker 自动重启恢复 TTS（旧行为是整个 APP 崩溃）；
- 顺带完成模式 E「并发初始化 100ms 轮询等待」的 **TTS 半边**：改 Completer 归并（ASR 侧 recognizer_singleton 仍待做，该项保持未勾选）；
- 审查 4.6「speak 错误路径」项**结构性收窄但未完全关闭**：generate 失败时不再创建 AudioPlayer（无泄漏面）、空音频时删临时 WAV；`onPlayerComplete.first` 播放异常时可能挂起的风险仍在，该项保持未勾选。

**验证**：analyze 零新告警、无 error。
**真机待验**：进搬家模式播报无卡顿；logcat 过滤 `🧵 [TtsService]` 观察 worker 模型加载与合成耗时；极端情况（合成中杀 worker）自动重启恢复。

### Top2 🔴 备份 ZIP 编解码迁出主 isolate

**问题回顾**：`settings_tab.dart` 导出：循环 `readAsBytes` 把全部音频读进内存（峰值 ≈ 备份体积 2 倍+）+ `ZipEncoder().encode` 主 isolate 同步压缩（`:546`）；导入：`readAsBytes` + `ZipDecoder().decodeBytes` 主 isolate 同步解压（`:734`）+ 逐个解压写盘（`:883`）。大备份期间 UI 冻结数秒。

**修复方式**：`lib/settings_tab.dart` 新增两个**顶层 worker 函数**（闭包只捕获 String/Set/int 可传输值，不捕获 State/BuildContext/DbHelper），`Isolate.run` 执行：

- `_buildBackupZip(itemsCsv, diaryCsv, readme, hotwordsContent, audioDirPath, validAudioNames)` → `(Uint8List, int)`：读音频字节 → 建档（items/diary CSV + README + 热词）→ 压缩，返回 zip 字节与孤儿文件数。孤儿文件清理、`FilePicker.saveFile` 留主 isolate。
- `_extractBackupZip(zipPath, audioDirPath)` → 命名记录 `(itemsCsv, diaryCsv, hotwords, restoredAudioCount)`：读 ZIP → 解压 → 提取 CSV/热词**文本**（不回传 ArchiveFile 对象，规避 FFI/流句柄跨界）→ 音频增量落盘（只写不存在的文件，与原「增量合并」语义一致）。缺必要 CSV 抛异常 → 主 isolate catch 弹错误框（与原行为一致）。
- DB 查询/去重/batch 插入、热词写入、UI 全留主 isolate（sqflite 平台通道）。

**语义变化**：无。导出包字节、导入合并语义、错误提示路径均与原来一致。
**验证**：analyze 零新告警；行为级验证待真机做一次「导出 → 清数据 → 导入」往返，核对物品/日记/热词/音频四类数据完整。
**后续可选项**：`InputFileStream` 流式编解码进一步压 worker 内存峰值（原审查建议中的「进一步」项，主修复已完成）。

### Top3 🔴 搜索每键全量查库 + 清四级缓存

**问题回顾**：`diary_tab.dart:3172` 搜索框 `onChanged` 直接 `refreshList()`：每 keystroke 一次 LIKE 查库 + `:757` 清空时间实体/查询答案/物品转存/波纹四级缓存 + 每卡最多 4 个 postFrame 解析级联整页重建（波纹解析还要重读音频文件）。打 5 个字母 ≈ 5 次查库 + 20×可见卡数次整页 rebuild。

**修复方式**：`lib/diary_tab.dart` 三处：

- `refreshList` 增加 `{bool clearParseCaches = true}` 参数：所有数据增删改路径（录音完成/编辑/删除/转存/悬浮窗同步等）默认不变；**搜索路径传 false**——缓存按 diaryId 键控、与过滤无关，纯过滤性刷新不清缓存，可见卡片直接命中缓存，零重解析零重读音频；
- 搜索框 `onChanged` 改 250ms 防抖 Timer（取审查建议 250-300ms 下限），连续输入只在停顿后查一次库；
- dispose 取消防抖 Timer。

**语义变化**：

- 搜索结果延迟 ≤250ms 出现（标准搜索手感）；
- 缓存失效正确性：内容变化必经「编辑保存 → refreshList(默认清缓存)」，条目增删同理；搜索路径数据不变 → 缓存天然有效；
- 原审查建议的「缓存按 diaryId+内容指纹失效」用 `clearParseCaches` 开关方案**等价替代**（更简单，无指纹哈希成本）；「解析结果下沉卡片级 ValueNotifier」（模式 A 的 4×N postFrame 级联）不在本项范围，**仍开放**。

**验证**：analyze 零新告警。
**真机待验**：连续输入搜索不再逐键卡顿；logcat 无重复解析/波纹提取日志刷屏；搜索后编辑某条日记，该条解析结果正确刷新（其余条目缓存保持）。

---

## 2026-09-06 · 第二批：Top 5 闹钟轮询改事件推送

> 每完成一项单独提交（便于定位问题）。验证口径：`flutter analyze` 改动文件零新告警；`flutter test` 112 通过 / 1 失败——失败项仍为存量 `dart_chrono_parser_test`（同第一批基线，与本次改动无关）；新增 `./gradlew :app:compileDebugKotlin` 验证原生改动编译通过。

### Top5 🔴 全局 2 秒 prefs 轮询改原生事件推送

**问题回顾**：`main.dart:206` Timer.periodic 每 2 秒 `SharedPreferences.getInstance()` + `reload()`（平台通道往返 + 全量解析磁盘文件），App 全生命周期常驻，不管有没有设闹钟。唯一消费者是 `is_alarm_ringing` 标志——原生 `AlarmReceiver` 写入、Dart 2 秒轮询发现翻转后显隐顶部红色响铃横幅。

**修复方式**：

- 新建 `lib/utils/alarm_ringing_notifier.dart`（ChangeNotifier）：
  - `handleNativeEvent(method)`：`onAlarmRinging` → 响铃 / `onAlarmStopped` → 停止，同值幂等不重复通知，未知方法名（同通道的快捷方式/分享/悬浮窗事件）忽略；
  - `restoreOnce()`：冷启动从 SharedPreferences 一次性读回标志（兜底见下）；
  - `markStopped()`：横幅「停止」按钮乐观收起，不等原生回执。
- `lib/main.dart`：删除 `_alarmCheckTimer` 轮询；initState 改 `restoreOnce()`；通道 handler 增加 `onAlarmRinging`/`onAlarmStopped` 分支；响铃横幅从 `if (_isAlarmRinging)` 整页条件改 **ListenableBuilder 局部订阅**——响铃显隐只重建横幅子树，不再整页 setState。
- `android/.../MainActivity.kt`：companion 新增静态 `flutterChannel`（`configureFlutterEngine` 注册、`onDestroy` 置空防悬挂）+ `notifyFlutterAlarm(ringing, alarmId)`。Receiver 与 Activity 同进程（Manifest 无 android:process），静态可达；invokeMethod 全部调用点均在主线程。
- `android/.../AlarmReceiver.kt`：`onReceive` 响铃开始推 `onAlarmRinging`；`stopAlarmCompletely` 推 `onAlarmStopped`——一处覆盖全部停止路径（通知栏「停止响铃」按钮 / 3 分钟超时自动停 / 通知点击进 APP 停止 / Dart 横幅停止）。
- **prefs 标志读写路径保留不变**：进程被杀期间闹钟触发过、用户未点通知直接打开 APP 时无引擎可推事件，原生写入的标志由 Dart 冷启动 `restoreOnce` 兜底恢复横幅。

**语义变化**：

- 响铃发现延迟从「≤2s 轮询间隔」变为「事件即时」；停止同样即时（旧轮询最坏再等 2 秒）；
- prefs `reload()` 从「每 2 秒永续」降为「冷启动零次、运行期零轮询」；

**验证**：新增 `test/alarm_ringing_notifier_test.dart` 5 例（冷启动恢复 true/false、事件置位与幂等、未知事件忽略、markStopped 乐观收起）；`flutter analyze` 改动文件零新告警；`./gradlew :app:compileDebugKotlin` 通过（仅第三方插件既有警告）。
**真机待验**：设闹钟到点 → 横幅即时弹出；三条停止路径（通知栏停止/3 分钟超时/横幅停止）横幅即时收起；杀进程 → 闹钟触发 → 直接点图标开 APP → 横幅恢复显示。

---

## 2026-09-06 · 第三批：Top 6 拖拽/状态回调下沉独立组件

> 验证口径同前：`flutter test` 119 通过 / 1 存量失败（dart_chrono_parser，同基线）；改动文件 analyze 零新告警。

### Top6 🔴 拖拽/录音状态回调 → MainScaffold 整页 setState

**问题回顾**：① `main.dart:769` 日记页浮动按钮上滑手势（拉出「↑ Aa」徽章、松手新建文本笔记）每帧 `setState` 重建 MainScaffold，IndexedStack 四个 tab 的 build 全部陪跑；② `main.dart:442/448/455` 三个 tab 的 `onStateChanged: () => setState(() {})` 让录音状态每次翻转（record_tab 重写的 setState ~20 处调用点）全 app 重建。

**修复方式**：

- 新建 `lib/widgets/diary_floating_button.dart`：浮动麦克风按钮独立 StatefulWidget。
  - 上滑手势的全部拖拽状态（偏移/水平累计/拖拽中/激活态）下沉到组件自有 State——拖拽帧只重建「徽章+按钮+状态文字」子树；
  - 按钮三态改纯参数传入（modelAvailable/isReady/isListening/isProcessing/isLockedRecording/statusText + 开始/停止/新建三个回调），组件零业务依赖、可独立 widget 测试；
  - 手势阈值常量、Aa 徽章阻尼/渐显、按钮样式、状态文字逐行平移，视觉与手感零变化。
- `lib/main.dart`：
  - 三个 tab 的 `onStateChanged` 改为递增各自 `ValueNotifier<int>`（_recordBarTick/_listButtonTick/_diaryButtonTick）；
  - 三个外层浮动组件（日记按钮/列表按钮/录入按钮栏）各用 `ValueListenableBuilder` 包裹——tab 状态翻转只重建对应浮动组件，不再触碰 IndexedStack；
  - MainScaffold 整页 setState 只保留低频操作（切 tab/全局 loading/快捷方式跳转）；原 `_buildFloatingDiaryButton`/`_buildAaBadge`/`_resetSwipeState` 及拖拽字段删除（已平移）。

**语义变化**：交互与视觉零变化，重建范围从整页缩到浮动组件子树。顺带发现一个**既有死代码**（行为保持未动）：「水平位移 >24px 判定斜滑取消」守卫读 `details.delta.dx`，而 VerticalDragGestureRecognizer 的 update delta 做了轴向过滤——dx 恒为 0（测试实证），守卫自引入起从未生效。平移时逐行保留原逻辑；补活（改用 localPosition 差值）或删除，留产品决策。

**验证**：新增 `test/diary_floating_button_test.dart` 6 例：外层宿主拖拽帧零重建（核心回归）、渐显/激活阈值/松手新建、未达阈值复位、斜滑行为记录（delta.dx 恒 0）、锁定态禁拖拽+点击停止、长按开始松开停止。测试踩坑记录：按下后的首个 move 被竞技场消费成 dragStart（且跨过 kTouchSlop 后才接受），不产生 update——用例需两步热身（4px+30px）再断言偏移行为。
**真机待验**：上滑 Aa 手感（连续滑动/松手新建/快速上甩兜底）；录音开始/结束时浮动按钮变色无延迟；搬家模式开关按钮栏正确显隐。

---

## 2026-09-06 · 第四批：Top 7 收起卡文字测量缓存

> 验证口径同前：`flutter test` 121 通过 / 1 存量失败（dart_chrono_parser，同基线）；其中 `overlay_card_list_follow_test`（收起动画逐帧匀速收缩回归）原样通过 = 补间运动学像素级不变。

### Top7 🔴 overlay 收起卡每次 build 对全文 shaping，无缓存

**问题回顾**：`overlay_diary_card.dart` `_estimateCollapsedWidth` 每次调用都对**整篇正文**做 TextPainter 单行 shaping；该函数在 build 路径两处调用（收起态 maxWidth 补间终点 `:227` + 收卷窗口 targetWidth `:334`），面板宽度补间/归档删除/播放态切换等任意 setState 都让 N 张可见卡重测一遍。

**修复方式**：`lib/overlay/widgets/overlay_diary_card.dart`

- 顶层 `_measureCollapsedTextWidth(text, textScaler, fontFamily)`：带 Map 缓存，key = 文本+`\u0000`+textScaler+fontFamily（度量环境变化必须重测——估算值兼任稳态宽度上限，偏窄会把短文字顶出省略号）；`_estimateCollapsedWidth` 的文字测量改走此函数。
- **只缓存 shaping 结果**：padding/勾选框/播放钮的加法与 `clamp(cardMinWidth, maxWidth)` 留在调用处每次现算——勾选框有无、面板宽度逐帧变化等输入照常生效，**逐帧像素与不缓存时完全一致**（补间只是不再重复 shaping 同一个不变量）。
- 缓存 512 条上限，超出整体清空（防极端长会话反复编辑的无界增长）；
- `@visibleForTesting` 探针：`collapsedTextMeasureCount`（实际 layout 次数）+ `measureCollapsedTextWidthForTest`。

**语义变化**：无。测量数值与异常兜底路径逐字节等价；仅省掉重复 shaping。

**验证**：新增 2 例——同 (文本,textScaler,fontFamily) 只 shaping 一次/环境因子变化重测/数值随倍率变大；卡片重复 build 零新增 shaping。`overlay_card_list_follow_test` 匀速收缩回归原样通过。
**真机待验**：悬浮窗展开→收起动画观感不变；长日记（数百字）卡片在面板加宽/收窄时不再卡顿。

---

## 2026-09-06 · 第五批：Top 8 录音条动画控制器随分支挂载销毁

> 验证口径同前：`flutter test` 124 通过 / 1 存量失败（dart_chrono_parser，同基线）；改动文件 analyze 零新告警。

### Top8 🔴 overlay 录音条双 AnimationController 同时无限 repeat

**问题回顾**：`overlay_voice_memo_bar.dart` initState 里 `_blinkController..repeat(reverse:true)`（红点闪烁，录音态）与 `_dotsController..repeat()`（三点跳动，转写态）同时启动且永不停止，build 二选一渲染——不用的那个全程空转。原审查按 🔴 标注「纯浪费的动画/电量」。

**修复方式**：`OverlayVoiceMemoBar` 改 StatelessWidget 只做分支选择，录音/转写两个胶囊拆成 `_RecordingCapsule`/`_TranscribingCapsule` 两个子 widget，**各自持有自己的控制器、随分支挂载/销毁**——状态翻转时旧胶囊卸载即 dispose，新胶囊挂载即 repeat。样式/布局/动画参数逐行平移。配套给 `OverlayVoiceMemoController` 加 `@visibleForTesting setStateForTest`（测试直接迁移状态，绕过 start/stop 的资源清理路径）。

**诚实评估**（对齐用户质疑）：录音/转写两个状态下永远有一个可见动画在跑，帧本来就要逐帧出——空转控制器的单独收益是「少一个无监听 ticker 排帧 + 分支销毁即停」，属卫生级修复而非大电量项。该胶囊真正的耗电大头是审查 4.5 另一条（100ms tick + overlay_home 根级 setState + AnimatedContainer 每 100ms retarget，录音全程整窗无空闲帧），那项保持开放。

**语义变化**：可见动画一帧不变。转写态三点起跳相位从「继承录音期已推进的相位」变为「从 0 起跳」（原控制器常转、切换时相位随机；现挂载即起跳）——三点波浪循环本身无锚点语义，肉眼不可辨。

**验证**：新增 `test/overlay_voice_memo_bar_test.dart` 3 例：录音态红点闪烁运行且无转写胶囊；录音→转写切换后红点控制器随分支销毁、三点跳动运行；转写→录音反向切换。查找全部限定胶囊子树（MaterialApp 路由过渡自带 FadeTransition/Transform，不能按类型全局找）。
**真机待验**：语音速记录音→转写→完成的胶囊切换动画观感不变。

---

## 待后续批次（摘自审查文档第六节）

- **第一批剩余**：Top4 existsSync、Top10 索引、Top12 recognizer 泄漏、`_convertBytesToFloat32` 三份收敛。
- **第二批剩余**：Top9/14 再转写与 VAD 下沉 isolate、overlay 全量 reload 改内存 reorder。
- **第三批**：SettingsTab 懒挂载 + loader 合并、diary_tab `_buildNormalCard` 拆分、正则/DateFormat 静态化、模型拷贝公共化。
