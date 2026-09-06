# 复盘：语音转写卡死 UI 的七年之痒——从"假异步"到常驻 worker isolate

> 分支：feature/floating-window · 时间：2026-08-26 ~ 08-27 · 行号基于提交 `1f762f4`
>
> 配套小白版（比喻+图解）：@postmortem-recognition-worker-isolate-for-beginners.md

## 一句话总结

**2026 年 1 月判定"Dart 层无法真正异步化语音识别"的结论是错的**——当时失败的是"把识别器对象传回主线程"这个形态；正确形态（识别器常驻 worker isolate、PCM 数据传进、文本传出）在 2026-08-27 落地，根治了长录音转写期间 UI 完全冻结的问题，并支撑了悬浮窗语音速记（锤子闪念胶囊体验）。

## 问题回顾

### 症状

- **2026-01-19**：App 启动加载模型期间 UI 冻结 4.4 秒，logcat：`InputDispatcher: spent 4416ms processing MotionEvent`（底部导航完全点不动）
- **2026-01-22**：2 分钟录音松开按钮后，loading 转半圈就卡死 2~3 秒
- **长期**：1 分钟音频转写冻结约 5 秒；10 秒内音频约 0.几秒可接受

### 根因

sherpa_onnx 的 `OfflineRecognizer` 构造和 `decode()` 都是**同步 FFI 调用**，全部运行在 UI 主 isolate 上。Dart 是单线程事件循环模型，同步 FFI 执行期间主 isolate 无法渲染帧、无法响应触摸。

## 历史尝试与失败原因（.waylog/history 考古）

| 时间 | 尝试 | 结果 | 失败原因 |
|---|---|---|---|
| 2026-01-19 | `await` 直接加载 | 冻结 4s | `OfflineRecognizer(config)` 本身是同步阻塞 FFI |
| 2026-01-19 | `await Future(() {...})` 包装 | 冻结如故 | Future 只是调度到下一个事件循环，同步 FFI 仍在主 isolate 执行（**假异步**） |
| 2026-01-19 | Isolate 预加载模型（isolate_manager.dart） | 冻结如故 | 两层：① isolate 内漏 `initBindings()`；② **试图把 recognizer FFI 指针传回主线程**——FFI 对象不可跨 isolate，主线程被迫重新加载模型 = 白干。回滚（提交 976b554），落地懒加载 RecognizerSingleton（6d8eadd），删除 isolate_manager.dart |
| 2026-01-22 | `Future.microtask()` 分片三步 FFI | 技术无效 | microtask 仍在主线程，只是让 UI 先渲染一帧（3bd50e7 系列的"时序遮掩"起点） |
| 2026-01-22 | MP4 视频当 loading 动画 | 视觉可行 | 利用 ExoPlayer 跑独立原生线程的特性；残留播放器代码报错，当天回滚 |
| 2026-01-23 | 先播 1.5s 动画再识别 | ✅ 保留至今 | 不是异步化，是"把卡顿安排在动画演完之后"（现行 diary_tab 六阶段编排的由来） |
| 2026-01-26~27 | 预热/调度 6 种尝试 | 全部失败 | Future.delayed(50ms)/scheduleMicrotask/addPostFrameCallback 等，回调不执行或闪烁；4a0ba3a 禁用后台恢复预热。同期 **875f616：numThreads=1 → 模型加载从数秒降到 380ms** |
| 2026-05-31 | 模糊遮罩掩盖 | ✅ 保留 | a20fd50，同"遮掩"哲学 |
| 2026-08 | 先落盘 WAV + 占位入库 | ✅ 保留 | 24c0d23，防丢（不是异步化）；≥60s VAD 分段把一次大卡拆成多次小卡 |

### 当年的关键误判

`.waylog` 原话："**Dart 的 Isolate、Future 都无法让 native 代码在后台执行**"。

事实：Dart 的每个 isolate 跑在独立 OS 线程上，**worker isolate 里的同步 FFI 调用完全不阻塞主 isolate**。"Isolate 失败"的真实含义只是"传对象回主线程"这一种形态失败。`lib/tts_singleton.dart` 的注释"禁用 compute()——FFI 指针跨 isolate 不可用"是对的，但从中推出"Dart 层无法异步化"是错的。

另一个被批准但从未实施的方案：2026-01-22 的 Plan B"整个识别搬进 Isolate"——这正是 2026-08-27 落地的形态。

## 本次方案：常驻识别 worker isolate

### 原理

```
主 isolate（UI）                          worker isolate（识别）
┌────────────────────────┐              ┌─────────────────────────────┐
│ diary/record/list 调用   │   SendPort   │ initBindings()               │
│ recognizerSingleton ────┼─────────────▶│ OfflineRecognizer（模型×1）    │
│ （门面，语义不变）        │  Float32List │ createStream → acceptWaveform │
│ ◀──────────────────────┼──────────────│ → decode → getResult          │
│  Completer 按 id 唤醒    │   {id,text}  │ （同步 FFI，但在 worker）       │
└────────────────────────┘              └─────────────────────────────┘
```

三条边界铁律：
1. **FFI 对象（recognizer/stream）永不跨 isolate**
2. 跨界只传 `String / Float32List / int / bool`（均可跨 isolate 传输；模型路径是 String，PCM 是 Float32List）
3. 模型在 worker 内用主 isolate 传来的**目录路径**重建（路径解析留主 isolate——`_ensureBundledModel` 依赖 rootBundle）

可行性基石：sherpa_onnx 是纯 FFI 绑定（dart:ffi + 稳定 C ABI，无 MethodChannel），任意 isolate 内 `initBindings()` 后可直接使用；DynamicLibrary 同 .so 由 OS 引用计数，双 isolate 安全。

### 消息协议与容错

- 7 条消息：主→worker `_ReqInit/_ReqTranscribe/_ReqWarmup/_ReqDispose`；worker→主 `_EvReady/_EvResult/_EvError`（每条带 id，主侧 `_pending` Map 关联 Completer）
- 单请求 120s 超时；worker 崩溃（onError/onExit）时 in-flight 全部报错 + 自动重启；60s 窗口内 ≥3 次死亡放弃自动重启（风暴防护）
- worker FIFO：搬家模式连发多段不 await，到达顺序 = 识别顺序，与旧同步语义一致
- VAD 留主 isolate（轻 <1ms/窗；搬家模式 TTS 回采三层防御依赖同步 `vad.clear()`）

### 实施明细（11 个提交，函数入口行号基于 1f762f4）

**Phase A：根治卡顿**

| 提交 | 内容 | 关键入口 |
|---|---|---|
| `342364c` | worker 服务（656 行，纯新增） | [recognition_service.dart](../../lib/recognition_service.dart)：worker 入口 `_recognitionWorkerEntry` L110、`RecognitionService` L288（initialize L343 / transcribe L381 / warmup L402 / dispose L415） |
| `9edb24f` | 门面化 + 全调用点迁移 | [recognizer_singleton.dart](../../lib/recognizer_singleton.dart)：`_service` L37、门面 initialize L184、transcribe L297、warmup L301（`recognizer` getter @Deprecated 恒 null）。调用点：diary_tab `_recognizeSamplesToText`（L1869 注释处，实现在 L1879 复用）、`_warmupEngine` L1346、`_recognizeSamplesWithVad` L1802（VAD 失败兜底 L1879）；record_tab `_stopListening` / `_recognizeAndSave` L836；list_tab `_processVoiceSearch`（计划外发现的第 7 个消费点，不改会静默坏） |
| `bb769ce` | 模型热切换守卫修正 | `isServingLatestModel` L64（isReady && worker 加载目录 == 当前解析路径）；**5 层守卫**从"已就绪短路"改为"已就绪且路径未变才短路"（门面 2 + diary 3 + record 3）——不改则用户导入新模型后永远不生效 |
| `57e279a` | 文档 | docs/architecture/speech-recognition.md 新增 8 小节 |

**Phase B：悬浮窗语音速记（锤子闪念胶囊）**

| 提交 | 内容 | 关键入口 |
|---|---|---|
| `1c1fd90` | Kotlin 侧触发 | [VolumeKeyAccessibilityService.kt](../../android/app/src/main/java/com/shengwuji/app/VolumeKeyAccessibilityService.kt)：`getOverlayVolumeUpAction` L174（读 `overlay_volume_up_action` 偏好）、`triggerVoiceMemoOverlay` L418（toggle 状态机 + 麦克风互斥分流） |
| `9ba9d26` | Dart 状态机 + 变长胶囊 | [overlay_voice_memo.dart](../../lib/overlay/overlay_voice_memo.dart)：`start` L96 / `stop` L214；[overlay_voice_memo_bar.dart](../../lib/overlay/widgets/overlay_voice_memo_bar.dart) 胶囊 UI（宽度 = 80dp + 秒数×40dp，封顶 300dp） |
| `c028ffd` | 防丢落盘 | [wav_file.dart](../../lib/utils/wav_file.dart)（从 diary_tab 同构提取）；PCM → `diary_audio/` WAV + `insertDiary('', audioPath, duration)` 占位 |
| `60f711b` | worker 转写闭环 | `_transcribeAndSave` L287：initialize 兜底 → PCM→Float32 → transcribe → 热词纠错（TextProcessor 确认可复用）→ `updateDiary` 回填；idle 120s 自动 dispose 释放第二份模型 |
| `faa645f` | 主 APP 侧互斥守卫 | diary_tab.startListening / record_tab `_enterMoveMode` L678：prefs reload 读 `is_recording` → SnackBar 拒绝 |
| `69310b6` | 四级 watchdog | `startVoiceMemoWatchdog` L505、`destroyOverlayEngine` L524（T1 60s 补发 / T2 63s 再补发 / T3 66s 纯 Kotlin 移窗 / T4 76s 销毁 engine 释放麦克风——以 `is_recording` 落盘状态判定，不信任回执） |
| `1f762f4` | 设置页 + 文档 | settings_tab 动作选择器（`overlay_volume_up_action`：显示浮窗/长按直接录音） |

### 卡死救生通道（悬浮窗场景的核心保障）

即使 Dart isolate 完全卡死：
1. 长按音量上键的隐藏是**纯 Kotlin**（`hideOverlay` L689 只调 `removeView`，toggle 判断只读 Kotlin 字段 `overlayView != null`）——窗口立即可移除
2. T3（66s）自动移窗
3. T4（76s）销毁 overlay engine 释放麦克风（record 插件随 engine detach；此路径是 Dart 卡死时 mic 的唯一释放途径，真机验证项）

## 验证清单（真机）

1. **核心**：录 60s 日记，松手后转圈动画全程流畅（旧：冻结约 5s）；120s 走 VAD 路径 SnackBar"已切分为 N 段"照常
2. 搬家模式连说 10 条（旧代码 decode 期间 `📊 [搬家诊断]` 打印会停顿）
3. 杀进程后"再次转写"；设置导入新模型 → tab 切换后新模型生效（热切换）
4. 长按音量上键（action=record）：浮窗+录音+胶囊变长；再长按出卡；60s 自动停
5. 转写中隐藏浮窗 → 再展开数据不丢；杀主 APP 后浮窗录音转写仍完整
6. 互斥：主 APP 录音中长按只显示浮窗；overlay 录音中主 APP 按录被拒

## 经验教训

1. **失败结论要记录失败的"形态"而非否定整个方向**——"传对象失败"被误记成"Isolate 不行"，错误结论挡了 7 个月
2. **`await Future(...)` 对同步 FFI 无效**——Dart 单线程，Future 只是调度，CPU 密集任务不让出线程
3. **门面代理控半径**——RecognizerSingleton 公开语义全部保留，8 个调用点每处只改 3-6 行；对比"新服务逐点替换"的方案（要重写所有状态同步）
4. **守卫链的"已就绪"判定必须包含路径**——否则热切换被静默短路（本次实际抓到 5 层）
5. **救生通道保持纯度**——`hideOverlay()` 至今一行未改，任何"顺手重构"都可能堵死 Dart 卡死时的唯一出路
