# 性能与可优化点审查报告（lib/ 全量）

- **日期**：2026-09-05
- **范围**：`lib/` 下全部 49 个 Dart 文件（约 2.1 万行）
- **性质**：只读探索审查，本文档只记录问题与建议，不含代码改动
- **严重度图例**：🔴 高（泄漏风险 / 用户可感知卡顿 / 耗电）　🟡 中（可感知开销 / 数据量增长后线性劣化）　🟢 低（锦上添花）
- 每条均为可勾选的待办，修复一条勾一条。
- **修复进度与改动明细见 [performance-fix-log.md](./performance-fix-log.md)**（本文档只反映勾选状态，不记录改动细节）。

---

## 一、总体评价

架构意识整体良好：识别 decode 已下沉常驻 worker isolate（消息协议/超时/崩溃重启周全）、日记播放进度用页面级 ValueNotifier 避免高频整页重建、overlay 模块资源清理（Timer/订阅/控制器配对释放）几乎无可挑剔、批量插入已用 batch、双 engine 同步用计数器脏检查。

短板集中在五类模式（详见第二节）：

1. **「包一层 Future 就不阻塞」的误解**——TTS 同步 FFI 合成、ZIP 压缩、WAV/PCM 解码等重计算实际仍跑在主 isolate；
2. **build 路径上的同步 IO 与重测量**——卡片内 `existsSync`、TextPainter 全文测量无缓存；
3. **整页 setState 粒度过粗**——搜索每键、录音状态每次翻转、拖拽每帧都重建 IndexedStack 四页；
4. **DB 访问粗放**——diary 核心表零索引、单条操作前全表 `SELECT *`、导出逐条 UPDATE；
5. **常驻空转**——全局 2s prefs 轮询、overlay 双动画控制器永不停止。

---

## 二、修复优先级 Top 14（建议按此顺序处理）

| # | 状态 | 问题 | 位置 | 严重度 |
|---|------|------|------|--------|
| 1 | ✅ | TTS 合成同步 FFI 仍在主 isolate，搬家模式播报卡顿 | `tts_singleton.dart:353` | 🔴 |
| 2 | ✅ | 备份 ZIP 编解码在主 isolate + 全部音频字节进内存 | `settings_tab.dart:546/734/514` | 🔴 |
| 3 | ✅ | 搜索框每敲一键 = 全量查库 + 清空四级缓存 + 4×N 卡片级联重建 | `diary_tab.dart:3172/757` | 🔴 |
| 4 | ⬜ | 日记卡片 build 路径内每卡 2 次 `existsSync()` 同步 IO | `diary_tab.dart:2007/2019` | 🔴 |
| 5 | ✅ | 全局 2 秒 Timer 永久 `prefs.reload()`，贯穿整个生命周期 | `main.dart:206` | 🔴 |
| 6 | ✅ | 浮动按钮拖拽/录音状态回调 → MainScaffold 整页 setState（IndexedStack 四页陪跑） | `main.dart:769/442` | 🔴 |
| 7 | ✅ | overlay 收起卡每次 build 用 TextPainter 对全文做 shaping 测量，无缓存 | `overlay_diary_card.dart:832` | 🔴 |
| 8 | ✅ | overlay 录音条双 AnimationController 同时无限 repeat，各态空转一个 | `overlay_voice_memo_bar.dart:40` | 🔴 |
| 9 | ⬜ | 「再次转写」整读 WAV 并在主 isolate 逐 sample 转 Float32 | `diary_tab.dart:2084` | 🔴 |
| 10 | ⬜ | diary 核心表零索引，主查询每次全表扫描+排序 | `db_helper.dart:32` | 🟡 |
| 11 | ⬜ | 录音 PCM 用无界 `List<double>` 累积 + 多次全量拷贝（长录音数百 MB 峰值） | `diary_tab.dart:191` 等 | 🔴 |
| 12 | ⬜ | TimeAwareText 每次 build 新建 TapGestureRecognizer 且从不 dispose（累积泄漏） | `time_aware_text.dart:60` | 🔴 |
| 13 | ⬜ | SettingsTab 启动首帧即跑 12 个异步 loader，各自 setState 整页重建 | `settings_tab.dart:67` | 🟡 |
| 14 | ⬜ | 长录音喂 VAD 的紧循环留在主 isolate | `diary_tab.dart:1817` | 🟡 |

---

## 三、跨模块共性问题（模式级）

### 模式 A：整页 setState 粒度过粗

- [ ] 🔴 `diary_tab.dart:230` `_updateState` = 整页 setState + 通知外层；状态文案每变一次（~20 处调用）全页重建。→ 状态文案/按钮态拆 ValueNotifier + ValueListenableBuilder，只重建局部。
- [x] 🔴 `main.dart:769` 浮动按钮拖拽每帧 setState 重建整个 MainScaffold（`main.dart:427` IndexedStack 挂载全部 4 个 tab，四页 build 全部重跑）。→ 拖拽偏移下沉独立小 widget / ValueNotifier。（✅ 2026-09-06 Top6：拖拽状态下沉 widgets/diary_floating_button.dart 自有 State，明细见修复日志）
- [x] 🔴 `main.dart:442/448/455` 三个 tab 的 `onStateChanged: () => setState(() {})`，录音状态每次翻转全 app 重建。→ 浮动按钮三态抽成独立监听组件。（✅ 2026-09-06 Top6：onStateChanged 改递增三个 tick ValueNotifier，三个外层浮动组件各自 ValueListenableBuilder 局部重建）
- [ ] 🟡 `overlay/overlay_home.dart:378` `_onVoiceMemoChanged` 对 100ms tick 无条件根级 setState。→ 只在状态真变化时 setState，tick 由胶囊内部 ListenableBuilder 消化。
- [ ] 🟡 `list_tab.dart:433` 搜索每键双重 setState（`_filterItems` 内部一次 + 外层又一次）。→ 去掉外层多余 setState。
- [ ] 🟡 `settings_tab.dart` 所有开关/ChoiceChip 点击都重建 2800 行整页（1371/1390/1417/159/178/288 等）。→ 每个开关抽独立 StatefulWidget。
- [ ] 🟡 `diary_tab.dart:634/1002/1052/1107` refreshList 清缓存后每卡最多 4 个 `addPostFrameCallback` 解析完成各调一次整页 setState（4×N 次重建）。→ 合并批量刷新或卡片级监听。

### 模式 B：重计算留在主 isolate（应下沉 compute / worker isolate）

- [x] 🔴 `tts_singleton.dart:353` `Future(() => _tts!.generate(...))` 的闭包仍在主 isolate 同步执行，Piper 合成期间 UI 冻结数百 ms~秒级。→ 照 `recognition_service.dart` 架构把 OfflineTts 挪进 worker isolate。（✅ 2026-09-06 Top1：新建 `tts_service.dart`，合成结果 worker 内落盘 WAV 不跨 isolate，明细则见修复日志）
- [x] 🔴 `settings_tab.dart:546` `ZipEncoder().encode(archive)` 主 isolate 同步压缩；`settings_tab.dart:734` 导入同步解压。→ `compute`/`Isolate.run`，进一步用 `InputFileStream` 流式编解码。（✅ 2026-09-06 Top2：建档/压缩/解压/音频落盘全下沉 `Isolate.run` 顶层函数；流式编解码留作后续可选优化）
- [ ] 🔴 `diary_tab.dart:2084-2100` 再转写：`readAsBytes` + `sublist(44)` + 逐 sample 转 Float32 全在主 isolate（10 分钟录音 ≈ 960 万 sample）。→ 下沉 isolate。
- [ ] 🟡 `diary_tab.dart:1817-1836` VAD 喂料 512-sample 窗口同步循环（60s+ 音频累计占用主线程秒级，`Future.delayed(0)` 只是缓解）。→ 整体下沉 worker。
- [ ] 🟡 `overlay/overlay_voice_memo.dart:456` `_pcmBytesToFloat32` 主 isolate 循环（300s ≈ 480 万次迭代 + 19MB 分配）。→ compute 或直接在 worker 内转换。
- [ ] 🟡 `utils/waveform_extractor.dart:20-70` 整读 WAV + `sublist(44)` 拷贝 + 逐样本循环全在主线程，首次刷新对 N 条音频日记连续执行（`diary_tab.dart:632`）。→ compute + `ByteData.sublistView` 免拷贝。
- [ ] 🟡 `overlay/overlay_voice_memo.dart:371` → `recognition_service.dart:52` 300s 录音 19MB Float32List 跨 isolate 为拷贝传输。→ `TransferableTypedData` 零拷贝转移。
- [ ] 🟡 `settings_tab.dart:2768` `_getDirectorySize` 递归同步 `listSync` + `lengthSync` 阻塞 UI。→ Isolate.run 或去掉 size 统计。

### 模式 C：正则 / DateFormat / 解析器未静态化（提为 static final）

- [ ] 🟡 `utils/dart_chrono_parser.dart:134/151/178/212/233/253/273/314` 8+ 个 RegExp 在函数体内每次新建，且每张日记卡片都要跑一遍（`diary_tab.dart:997`）。
- [ ] 🟡 `list_extractor.dart:460/648` 同一模式两处重复构造；`532/567/607` 每次调用重建；`607` enumPattern 硬编码与 `135` `_enumConnectors` 重复（改一处漏一处）。
- [ ] 🟡 `diary_tab.dart:1212`、`record_tab.dart:848/999`、`utils/query_detector.dart:109`、`utils/item_splitter.dart:72/94`、`text_processor.dart:91` 各处 RegExp 每次新建。
- [ ] 🟢 `overlay/overlay_diary_card.dart:539`、`diary_tab.dart:459/873/886` DateFormat 每次 build 新建（构造含 pattern 解析 + locale 查找）。→ 提为顶层 `static final`。
- [ ] 🟢 `diary_tab.dart:998` 每卡 new `DartChronoParser()`；`diary_tab.dart:1912` 每次识别 new `ListExtractor()`。
- [ ] 🟢 `widgets/blur_loading_overlay.dart:26` 每次调用 new `Random()`。

### 模式 D：数据库访问

- [ ] 🔴 `db_helper.dart:459` + 调用点 `diary_tab.dart:1126/2211/2260`：删除/归档/转存前 `queryAllDiaries()`（全表 SELECT * + ORDER BY）再 `firstWhere` 找一行。→ DbHelper 加 `getDiaryById(id, {columns})`。
- [ ] 🟡 `db_helper.dart:32` 建表无任何索引：`ORDER BY is_archived ASC, created_at DESC`（主列表高频）与未导出查询都走全表扫描+排序。→ migration 加 `CREATE INDEX idx_diary_created ON diary(is_archived, created_at)`；搜索需求大可评估 FTS5。
- [ ] 🟡 `diary_tab.dart:846` 导出循环逐条 `markDiaryExported`（每条一个事务 = 一次 fsync，500 条 = 500 次）。→ batch 或 `UPDATE ... WHERE id IN (...)`。
- [ ] 🟡 `overlay/overlay_data_client.dart:15` `SELECT * FROM diary` 无 LIMIT 含全部已归档行。→ 加 LIMIT/分页或排除归档。
- [ ] 🟢 `db_helper.dart:12` db getter 未缓存 Future（靠 singleInstance 兜底）。→ `Future<Database>? _dbFuture` 模式。
- [ ] 🟢 `db_helper.dart:97` v7→v8 迁移逐条 rawInsert 无 batch；`db_helper.dart:497` clearAllData 两条 delete 未包 transaction。

### 模式 E：同一逻辑多份拷贝（改一处漏一处风险）

- [ ] 🔴 `_convertBytesToFloat32` 三份且实现不一致：`diary_tab.dart:1990`、`list_tab.dart:379`（`bytes.buffer.asInt16List()` 版有 offset 未对齐 RangeError 隐患，当前靠冗余拷贝侥幸安全）、`record_tab.dart:612`（修正版，注释实锤过该 bug）。→ 收敛为单一工具函数（`data is Uint8List` 直用 + `ByteData.sublistView`），同时消除 PCM 回调里 `Uint8List.fromList(data)` 的每 chunk 全量拷贝（`diary_tab.dart:1510`、`list_tab.dart:209`、`record_tab.dart:395`）。
- [ ] 🟡 录音 PCM 用无界 `List<double>` 累积 + `Float32List.fromList` 识别时再拷一份：`diary_tab.dart:191/1493/1773`、`record_tab.dart:60/395`、`list_tab.dart:45/211`。diary_tab 还同时持有 bytes（`_pcmBuilder`）双份存储，且 `diary_tab.dart:1602/1952` `toBytes()` 后又 `Uint8List.fromList` 再拷。→ 累积改 BytesBuilder、删冗余拷贝、录完即释放。
- [ ] 🟡 内置模型拷贝三份同构实现：`recognizer_singleton.dart:76`、`tts_singleton.dart:106`（目录带 v2 的历史差异）、`vad_singleton.dart:46`。→ 抽公共 `ensureAssetFile(asset, target)`。
- [ ] 🟢 WAV 写入两份：`utils/wav_file.dart:16` 与 diary_tab 内保留的 `_writeWavFile`（文件头注释自认未迁移）。
- [ ] 🟢 并发初始化 100ms 轮询等待两份：`recognizer_singleton.dart:193`、`tts_singleton.dart:256`（最坏白等 30 秒）。→ 改 `Completer<bool>` 广播。（TTS 半边已随 Top1 ✅ 改 Completer 归并；ASR 侧待做）
- [ ] 🟢 句子切分正则三处字面量重复：`query_detector.dart:109`、`item_splitter.dart:72/94`。

### 模式 F：日志门控与常驻开销

- [x] 🔴 `main.dart:206-213` 全局 2 秒 Timer：每 2 秒 `SharedPreferences.getInstance()` + `prefs.reload()`（平台通道往返 + 全量解析），永不停止且不管闹钟是否在用。→ 原生闹钟触发时经 MethodChannel 事件推送（`com.shengwuji.app/app` 通道现成），或仅有活动闹钟时才轮询。（✅ 2026-09-06 Top5：AlarmReceiver 推 `onAlarmRinging`/`onAlarmStopped` 事件 + 冷启动 `restoreOnce` 读标志兜底，轮询删除，明细见修复日志）
- [ ] 🟢 `diary_tab.dart:2168-2203` 静音提示 500ms 轮询 SharedPreferences `reload()`（磁盘 IO）+ 每 500ms 一条 log。→ 改事件推送，至少 release 关日志。
- [ ] 🟡 overlay/主 app 大量 `print` 无门控：`overlay/overlay_home.dart:312/392`（每次状态通知 2-4 条）、`overlay_data_client.dart` 全部方法、`main.dart:333`、`settings_tab.dart:160/289/377`、`widgets/swipe_dismiss_card.dart:179`（dismiss 后每次 build 刷屏）。→ AppLogger 内 `kDebugMode` 门控 print（缓冲 2000 条上限已有，问题只在 logcat 写入）。
- [ ] 🔴 `record_tab.dart:764-796` 搬家模式 PCM 回调里为诊断日志做两轮全样本扫描（每段 RMS + 静音检测），纯日志用途却常驻主 isolate；`record_tab.dart:732` 每 30 帧再算一次。→ `kDebugMode` 门禁。
- [ ] 🟡 `utils/diary_sync_bridge.dart:18` `bump()` 每次写 diary 都 reload + setInt 落盘（连存多件物品时每件 2 次磁盘 IO）。→ 可内存计数 + 微 debounce。

### 模式 G：图片与视觉开销

- [ ] 🟡 `diary_tab.dart:3338` 滚动列表每张可见卡挂一个 `BackdropFilter blur(10,10)`（每帧 saveLayer+模糊 ×N 张卡）；`diary_tab.dart:3147` 搜索框同款。→ 卡片改半透明纯色，或每卡 RepaintBoundary + 降 sigma。
- [ ] 🟡 `widgets/blur_loading_overlay.dart:44` 全屏 sigma 15 BackdropFilter，恰与引擎初始化 CPU 高峰叠加。→ 降 sigma 或纯半透明遮罩。
- [ ] 🟢 所有 `Image.asset` 无 cacheWidth/cacheHeight（按原图分辨率解码）：`splash_screen.dart:148/282`、`settings_tab.dart:2241/2457/1792`、`widgets/blur_loading_overlay.dart:59`、`widgets/pro_unlock_dialog.dart:300`（90×90 缩略图解码付款码原图）。→ 按显示尺寸 `cacheWidth`。
- [ ] 🟢 `diary_tab.dart:3074-3134` 三个 blurRadius 60-80 的大模糊 BoxShadow 静态层无 RepaintBoundary，随整页 setState 反复重栅格化。→ 抽 const/独立 widget + RepaintBoundary。
- [ ] 🟢 `main.dart:474` 底栏外包 `Theme.of(context).copyWith` 每次重建新建 ThemeData。→ 先消除高频 setState（模式 A），或下沉样式到 item。

---

## 四、分模块明细

### 4.1 main.dart / splash_screen.dart（启动与全局）

- [ ] 🔴 `main.dart:51/54` runApp 前两个互不依赖的 await 串行阻塞首帧；且 `preloadModelPath` 在 `splash_screen.dart:47` 又做一遍。→ `Future.wait` 并行；删 splash 重复调用。
- [ ] 🟡 `splash_screen.dart:47-58` seed 数据库写操作串行排在权限检查前，拉长白屏。→ `Future.wait` 并行或 `_finishInit` 后 `unawaited`。
- [ ] 🟡 `main.dart:427` IndexedStack 常驻：SettingsTab 首帧即 initState 12 个异步 loader（`settings_tab.dart:67-82`，含 `PackageInfo.fromPlatform`、MethodChannel 无障碍检查、图标包读取、`Directory(path).existsSync()` 同步 IO），每个完成各 setState → 设置页启动头几秒被整页重建约 10 次。→ 懒挂载（首次切到才构建）；loader 合并为一次 prefs 批量读 + 单次 setState。
- [ ] 🟡 `settings_tab.dart:1316` FutureBuilder 的 future 在 build 内联创建（`SharedPreferences.getInstance().then(...)`），页内任意 setState 都重发请求、开关值闪回默认。→ initState 读一次存字段。
- [ ] 🟡 `settings_tab.dart:43` `_hotwordController` 从不 dispose（dispose 只移除了 observer）。→ 补 dispose。
- [ ] 🟢 `recognizer_singleton.dart:171` `hasModel` 每次 build 做 2 次 `existsSync`（调用点 6 处：`main.dart:710/919/1036`、`diary_tab.dart:1455`、`list_tab.dart:161`、`record_tab.dart:364`，FAB build 高频触发）。→ preload 时缓存 bool。
- [ ] 🟢 `main.dart:1158` 返回键双击退出用 `await Future.delayed(2s)`（已有 mounted 防护，逻辑安全，改 Timer 更清晰）。
- [ ] 🟢 `main.dart:389` `_checkColdStartShortcut` 死代码，确认 ShortcutManager 覆盖后删除。
- [ ] 🟢 `record_tab.dart:1171` `_moveButtonColor/_moveButtonChild` 死代码（按钮已迁 main.dart）。

### 4.2 diary_tab.dart（日记页）

- [x] 🔴 `diary_tab.dart:3172` 搜索框 `onChanged` 直接 `refreshList()`：每 keystroke 一次 LIKE 查库 + `diary_tab.dart:757` 清空 `_timeEntitiesCache/_queryAnswerCache/_itemSplitCache/_peaksCache` 四级缓存 + 每卡 4 个 postFrame 解析级联重建（波纹解析还要重新读音频文件 `diary_tab.dart:625`）。打 5 个字母 ≈ 5 次查库 + 20×可见卡数次整页 rebuild。→ 250-300ms 防抖 + 缓存按 diaryId+内容指纹失效 + 解析结果下沉卡片级 ValueNotifier。（✅ 2026-09-06 Top3：250ms 防抖 + `refreshList(clearParseCaches)` 开关等价替代指纹方案；「ValueNotifier 下沉」仍开放，属模式 A）
- [ ] 🔴 `diary_tab.dart:2007/2019` 卡片 build 内 `File(audioPath).existsSync()` ×2（itemBuilder `diary_tab.dart:3372` 内），任何整页 setState 都让所有可见卡重跑磁盘 stat。→ refreshList 时异步探测一次存入数据 map，build 只查内存。
- [ ] 🔴 `diary_tab.dart:2084` 再转写主 isolate 全文件解码（见模式 B）。
- [ ] 🔴 `diary_tab.dart:191/1493` PCM 无界 `List<double>` 累积 + 多次全量拷贝（见模式 E）。
- [ ] 🔴 `diary_tab.dart:3338` 每卡 BackdropFilter（见模式 G）。
- [ ] 🟡 `diary_tab.dart:1622/1730/1936` 一轮录音触发 2-3 次全量 refreshList（每次 = 查库 + 整页 setState + 清空四级缓存）。→ 占位行本地插入、完成后原地更新该行。
- [ ] 🟡 `diary_tab.dart:321` `_loadSmartSwitches` await 后 setState 无 mounted 守卫（对照 `:317` 已有守卫的写法）；`record_tab.dart:154/164/171` 同问题。→ 统一加 `if (!mounted) return;`。
- [ ] 🟡 `diary_tab.dart:1032/1035` 与 `1084/1096` 同一 content 的 `QueryDetector.detect` 和 `cleanPunctuation` 各跑两遍（两个解析函数互不知晓）。→ 合并一次 detect 结果共用。
- [ ] 🟡 `diary_tab.dart:2695-3001` `_buildNormalCard` 约 300 行、`stopListening` 约 220 行——解析调度、IO、UI 混杂，难以拆 const/局部重建单元。→ 卡片抽独立 widget，解析触发挪出 build。
- [ ] 🟢 `diary_tab.dart:2983` `Visibility(visible:false)` 常驻隐藏子树 → 直接删除节点。
- [ ] 🟢 `diary_tab.dart:1510` 录音 stream.listen 未保存引用（无法显式 cancel，只靠 recorder.dispose 断流）。→ 保存 subscription。

### 4.3 record_tab.dart / list_tab.dart

- [ ] 🟡 `record_tab.dart:668-679` VAD → 识别 → TTS 三个独立引擎初始化串行 await，进搬家模式白屏时间 = 三者之和（TTS 已有降级 catch 可单列）。→ `Future.wait`。
- [ ] 🟡 `record_tab.dart:1197` 重写 `setState` 每次都通知 main.dart 重建外层按钮栏，状态文案 ~20 处变化全放大为整页 + 外层重建（见模式 A）。
- [ ] 🟢 `record_tab.dart:291-307` dispose 缺 `_splitErrorTimer?.cancel()`（回调有 mounted 守卫，最多悬挂 8 秒）。
- [ ] 🟢 `record_tab.dart:299` RecordTab.dispose 无条件销毁共享 VAD 单例，与 DiaryTab 长录音 VAD（`diary_tab.dart:1804/1866`）切 tab 时序上互相拆台。→ 单例引用计数。
- [ ] 🟢 `list_tab.dart:464` 列表项无 key（对照 `diary_tab.dart:3275` 已做）。→ `key: ValueKey(item['id'])`。

### 4.4 settings_tab.dart（设置页）

- [x] 🔴 备份导出/导入（见模式 B + 模式 D 的逐条 UPDATE）：`settings_tab.dart:514` 循环内 `readAsBytes` 把 N 个音频全部读进内存（内存峰值 ≈ 备份体积 2 倍+）→ 流式添加；`:546` 同步压缩 → isolate；`:734` 同步解压 → isolate + 流式恢复；`:883` 逐个解压写盘。（✅ 2026-09-06 Top2：读音频/压缩/解压/写盘全下沉 `Isolate.run`；流式留作可选优化。「逐条 UPDATE」是 Markdown 导出路径的独立问题，见模式 D 未勾项）
- [ ] 🟡 `settings_tab.dart:978-995` `_parseCsvLine` 逐字符 `current += char` 拼接，String 不可变 → O(n²)，长日记正文大备份导入明显变慢。→ StringBuffer。
- [ ] 🟡 `settings_tab.dart:101` initState 链路 `Directory(path).existsSync()` 同步 IO。→ `await exists()`。
- [ ] 🟡 `settings_tab.dart:1019-1804` 大 ListView 用 `children:` 一次性构造全部 widget 配置（含更新日志 ExpansionTile 约 20 个版本条目），页大 rebuild 成本线性叠加。→ ListView.builder 按 section 索引，或更新日志条目提 `static final`。
- [ ] 🟢 `settings_tab.dart:1812/1882/2302/2398/2045` options 列表、IconPacks/AppThemes map 出的卡片列表每次 build 重建。→ static const / 缓存。
- [ ] 🟢 `settings_tab.dart` 各 `_buildXxx` 辅助方法各自 `Theme.of(context)`/`AppThemeExtension.of(context)`，单次 rebuild 累计上百次 dependOnInherited。→ build 顶部取一次作参数传入。

### 4.5 overlay 悬浮窗模块（独立 engine、常驻、覆盖其他应用，开销更敏感）

- [x] 🔴 `overlay/widgets/overlay_voice_memo_bar.dart:40-47` `_blinkController..repeat(reverse:true)` 与 `_dotsController..repeat()` 同时无限转，build 二选一渲染（`:58-68`），不用的那个全程空转驱动逐帧重绘；叠加 `voiceMemoStarted` 点亮的屏幕常亮，是纯浪费的动画/电量。→ `didUpdateWidget` 里 stop 不用的控制器，或录音/转写拆两个独立子 widget 随分支挂载销毁。（✅ 2026-09-06 Top8：拆两个子 widget 随分支挂载销毁，任一时刻只有一个控制器在转，可见动画一帧不变，明细见修复日志）
- [x] 🔴 `overlay/widgets/overlay_diary_card.dart:832-869` `_estimateCollapsedWidth` 对**整篇正文**（非截断摘要）`TextPainter.layout()` 单行 shaping；面板宽度补间（`overlay_home.dart:1448`，0.72→0.92 约 200ms）期间约束逐帧变，每卡每帧重测；归档/删除等全量刷新同样每卡重测。→ 按 (content, textScaler, showPlayButton) 顶层 Map 缓存 + 长文超阈值直接短路返回 maxWidth（`:868` 本来就会 clamp）。（✅ 2026-09-06 Top7：按 (content, textScaler, fontFamily) 缓存 intrinsic 宽，512 条上限；逐帧 clamp 照做，补间像素不变，明细见修复日志）
- [ ] 🟡 `overlay/overlay_voice_memo.dart:164` 100ms tick + `overlay_home.dart:378` 根级 setState + `overlay_voice_memo_bar.dart:83` AnimatedContainer 300ms 补间每 100ms retarget——录音全程窗口无帧空闲。→ 胶囊内部 ListenableBuilder 自管重建，根只响应真状态变化。
- [ ] 🟡 `overlay/overlay_home.dart:491/576/626/887` 归档/删除/标注/保存/新增后已做乐观 UI 原地更新，收尾却又 `_loadDiaries` 全表重查 + 整列表换引用全量重建（叠加 TextPainter 重测）。→ 内存内 reorder（排序键都在本地）+ 静默落库。
- [ ] 🟡 `overlay/overlay_home.dart:1468` 外层约束已有界仍用 `shrinkWrap: true`，ShrinkWrappingViewport 每帧多一遍估高测量。→ 去掉 shrinkWrap。
- [ ] 🟡 `overlay/widgets/overlay_diary_card.dart:764-809` `_charOffsetAt` 的 TextPainter 未 dispose（同类 `:853/:932` 都有）。→ try/finally 补上。
- [ ] 🟢 `overlay/overlay_home.dart:1220/662` 每次收起/分享 `SharedPreferences.getInstance()+reload()`（跨 engine 隔离所致，低频可接受）。→ 设置变更时主动失效缓存。
- [ ] 🟢 `overlay/widgets/overlay_voice_memo_bar.dart:114` 每次 build（100ms 一次）新建 Tween/CurvedAnimation。→ 预建字段。
- [ ] 🟢 `overlay/overlay_home.dart:1774/964` 每次 build 全表 `map+toSet` 两处重算。→ 顺手缓存。
- [ ] 🟢 `overlay/overlay_home.dart:167` AudioPlayer 常驻单例空闲持有原生资源（量级小，可 lazy）。

### 4.6 服务层（识别 / TTS / VAD / 数据）

- [x] 🔴 `tts_singleton.dart:353` TTS 合成主 isolate 阻塞（见模式 B，搬家模式播报卡顿的最大嫌疑）。（✅ 2026-09-06 Top1：下沉常驻 worker isolate，同文件 `:386-402` speak 错误路径结构性收窄——generate 失败不再创建播放器、空音频删临时 WAV——但 `onPlayerComplete.first` 挂起风险仍在，下一项保持未勾选）
- [ ] 🔴 `tts_singleton.dart:386-402` speak 错误路径：player 抛异常时未 release、临时 wav 未删、`onPlayerComplete.first` 可能永不触发。→ catch 中 release + 删 wav。
- [ ] 🟡 `recognizer_singleton.dart:104-121` 首次启动 `rootBundle.load` 整个 229MB 模型进 Dart 堆再写盘，低内存设备可能 OOM。→ 分块流式写盘。
- [ ] 🟡 `recognizer_singleton.dart:193`、`tts_singleton.dart:256` 100ms 轮询等待初始化（见模式 E）。
- [ ] 🟢 `tts_singleton.dart:124/184` 每次 initialize 都跑铺平扫描 + espeak 数据诊断 `listSync/lengthSync`（同步 IO）。→ 加 `_flattenedOnce` 标志。
- [ ] 🟢 `recognition_service.dart:256` 预热 `List.filled` 再 `fromList` 双重分配。→ 直接 `Float32List(sampleRate ~/ 10)`。

### 4.7 公共 widgets

- [ ] 🔴 `widgets/time_aware_text.dart:60-71` 每次为每个时间实体新建 `TapGestureRecognizer` 且从不 dispose（官方要求必须释放，闭包持有 State 泄漏）；`onTapDown` setState 整段 Text.rich 重建、全部 recognizer 重建。→ recognizer 缓存于 State 按 index 管理，dispose/didUpdateWidget 逐个释放。
- [ ] 🟢 `widgets/swipe_dismiss_card.dart:218` 拖拽 Transform 每帧重绘整卡子树未包 RepaintBoundary；`:179` build 内日志。
- [ ] ✅ 无需改：`diary_play_bar.dart`（ValueNotifier + CustomPainter.shouldRepaint 精细比较是高频更新正确姿势）、`alarm_dialog.dart`、`checklist_widget.dart`（正则已 static final）、`location_answer_widget.dart`。

### 4.8 主题

- [ ] 🟢 `theme/app_theme.dart:37` 每次主题切换 `ColorScheme.fromSeed`（HCT 计算毫秒级，低频可接受）。→ 懒缓存 `late final`。

---

## 五、已确认做得好的点（审查过，无需「修复」）

- 识别 decode 已下沉常驻 worker isolate，消息协议、pending 超时清理、崩溃风暴防护完善（`recognition_service.dart`）。
- overlay 模块资源清理：Timer/StreamSubscription/AnimationController/TextEditingController/FocusNode/AudioPlayer 订阅 dispose 全部配对且顺序有注释论证；HardwareKeyboard handler 进出配对；动画普遍用 AnimatedBuilder child 缓存重子树。
- `DiaryPlayBar` 播放进度用页面级单 ValueNotifier，20Hz 进度不触发整页重建。
- 双 engine（主 app ↔ 悬浮窗）数据同步用计数器脏检查（`DiarySyncBridge` + 展开路径计数比对），无变更零查询。
- DB 批量插入已用 batch（`db_helper.dart` batchInsertItems/batchInsertDiaries/seedTutorial）；dismissed splits 用内存 Set 避免每卡片查库。
- overlay 收起卡明确不做 `existsSync` 预检（`overlay_diary_card.dart:153` 注释）；识别模型有 120s idle 释放策略（~229MB）。
- 模型延迟加载：splash `_finishInit` 明确不加载引擎。
- 文本主题与主题表全 const（`app_theme.dart`）。

---

## 六、建议的修复批次

1. **第一批（高收益低成本，局部改动）**：Top2 ZIP、Top4 existsSync、Top5 prefs 轮询、Top8 动画空转、Top10 索引、Top12 recognizer 泄漏、`_convertBytesToFloat32` 三份收敛。
2. **第二批（局部重构）**：Top1 TTS worker、Top3 搜索防抖+缓存指纹、Top7 TextPainter 缓存、Top6/模式A 拖拽与状态回调下沉、Top9/14 再转写与 VAD 下沉 isolate、overlay 全量 reload 改内存 reorder。
3. **第三批（结构性重构，可拆期做）**：SettingsTab 懒挂载 + loader 合并 + 开关组件化、diary_tab `_buildNormalCard` 拆分与卡片级通知、正则/DateFormat 全面静态化、模型拷贝公共化。
