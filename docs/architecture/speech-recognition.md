# 语音识别架构

## 语音识别流程

```
录音 → 识别 → 纠错 → 清单提取 → 智能分割 → 存储
```

### 1. 录音阶段（Record Package）
- **库**: `record: ^6.1.2`
- **格式**: PCM16
- **采样率**: 16kHz
- **声道**: Mono（单声道）
- 通过录音流实时捕获音频数据

### 2. 识别阶段（Sherpa-ONNX）
- **库**: `sherpa_onnx: ^1.12.21`
- **模型**: SenseVoice (离线)
- **语言**: 中文优化
- **组件**: `OfflineRecognizer`

### 3. 文本处理（TextProcessor）

两阶段纠错系统：

#### 第一阶段：正则规则
- **配置文件**: assets/rules.txt
- **用途**: 基于模式的替换（如 "毫安时" → "mAh"）
- **特点**: 打包在应用中，只读

#### 第二阶段：热词修正
- **配置文件**: assets/hotwords.txt
- **用途**: 简单的错误=正确 映射
- **特点**: 用户可通过设置界面编辑，保存到应用文档目录

### 4. 清单提取（ListExtractor）
- **文件**: lib/list_extractor.dart
- 纠错后、智能分割前执行
- **必须以"代办"或"待办"开头才触发**（2026-06-29 加入的白名单机制，替代旧的评分制——评分制有子串重叠 bug 导致正常叙述句被误判，比如"刚刚地震了，还有点吓人"被拆成 2 条 TodoItem）
- 命中后剥离触发词，剩余内容拆分为多条 TodoItem，转 markdown 存入 diary 表
- 未命中 → 走普通日记路径（不进入清单流程）
- 详情见 @architecture/list-extractor.md

### 5. 智能分割
使用关键词分割物品和位置：
- "放在"
- "在"
- "再"

例如：`"钥匙放在客厅"` → 物品：`"钥匙"`，位置：`"客厅"`

> **复用说明**：分割逻辑已抽取到 `lib/utils/item_splitter.dart`（`ItemSplitter.detect()`），录入页和日记页"物品转存横条"共用同一套逻辑。返回 `ItemSplitResult?`，未命中返回 null。

### 6. 存储
- **库**: `sqflite: ^2.3.0`
- 识别结果保存到 SQLite 数据库
- 根据 @architecture/database.md 中的表结构存储

## 录音触发方式

应用支持三种录音触发方式：

### 浮动按钮（手动）
- 长按开始录音，松开停止
- 锁定模式下点击停止
- 仅在日记页显示

### 音量键（快捷）
- 长按音量键 500ms 触发快速录音
- 双击音量键 300ms 新建文本笔记
- 需启用无障碍服务
- 详情见 @architecture/volume-key-shortcuts.md

### 快捷方式（系统）
- Android 静态快捷方式：快速录音、新建文本笔记
- 桌面长按图标触发

## 搬家模式（持续录音 + VAD 切段 + TTS 播报 + 语音撤销）

搬家场景下用户双手占用、不方便按按钮。开启搬家模式后：
1. 持续录音（PCM 流不 stop-then-start）
2. Silero VAD 自动切段（minSilenceDuration 0.6s / maxSpeechDuration 15s）
3. 每段独立送 OfflineRecognizer 识别
4. ItemSplitter 智能分割「物品+位置」后写库（返回 rowid 用于撤销）
5. TTS 播报"已保存X到Y"
6. 10s 窗口内说"不对"/"撤销"等关键词 → 自动删上一条 + TTS 回显"已撤销"

### 录音状态机（6 态）

- 待机 / 初始化中 / 持续录音 / 识别中 / TTS 播放中 / 退出中
- 屏幕常亮（wakelock_plus）+ 10s 闲置降亮遮罩（OLED 省电）

### 回采屏蔽三层防御

TTS 播报时喇叭声音会回采到麦克风，必须屏蔽避免识别出 TTS 内容：
1. **PCM 入口**（`_onMoveModePcm`）：`_isTtsPlaying=true` 直接 return 丢 PCM
2. **VAD 段拉取**（`_drainVadSegments`）：`_isTtsPlaying=true` return
3. **识别入口**（`_recognizeAndSave`）：`_isTtsPlaying=true` return
4. **VAD 清空**：TTS 开始前 `vad.clear()` 防已 accept 样本混入

### 语音撤销命令

TTS 念错时（如"电扇"→"电脑"），用户不方便看屏幕点撤销按钮。在 `_recognizeAndSave` 拿到识别文本后做前置分流：

```
识别文本 → _isUndoCommand 检测
  ├─ 命中（白名单 + ≤5 字 + 短包含容错）→ _handleUndoCommand
  │   ├─ _recentSaves 空 → TTS"没有可撤销的记录"
  │   ├─ 上一条 >10s → TTS"上一条已超时，无法撤销"
  │   └─ 窗口内 → _undoSave 删除 + TTS"已撤销"
  └─ 未命中 → ItemSplitter 正常保存（不阻塞录入）
```

**关键设计**：撤销命令和正常录入是**同一路径的前置分流**，不是互斥状态机。10s 窗口内说新物品仍正常保存。

**白名单**：`{"不对", "撤销", "错了", "取消", "删掉", "不是这个"}`，纯中文 + 长度 ≤5，支持短包含容错（应对 SenseVoice 输出"嗯不对"前缀噪声）。

**关键文件**：
- [lib/record_tab.dart](../../lib/record_tab.dart) - 搬家模式 + 撤销命令全部实现
- [lib/vad_singleton.dart](../../lib/vad_singleton.dart) - Silero VAD 单例
- [lib/tts_singleton.dart](../../lib/tts_singleton.dart) - TTS 单例（含串行化锁）

## 智能语音检测

RecordTab 包含智能日记检测功能：

**触发关键词**：
- "记录一下"
- "记一下"

**处理逻辑**：
1. 检测语音输入是否以关键词开头
2. 如果是，去除关键词前缀
3. 将内容保存到 `diary` 表而非 `items` 表

示例：
```
输入: "记录一下今天天气不错"
→ 去除前缀: "今天天气不错"
→ 保存到: diary 表
```

## 查询语句检测（DiaryTab）

DiaryTab 在卡片渲染时对内容做查询检测，与上面 RecordTab 的智能日记检测**完全独立**：

**组件**：`QueryDetector` (`lib/utils/query_detector.dart`)

**触发关键词**（正则）：
- "在哪儿"、"在哪"、"在哪里"、"在什么地方"
- "什么地方"、"什么位置"
- "哪儿了"、"哪去了"、"放哪了"、"放在哪"

**处理逻辑**：
1. 正则匹配命中即视为查询语句
2. 提取关键词前的部分作为物品名
3. 剥离填充词前缀（"帮我说"、"我的"、"那个"等 12 个）
4. 后台调用 `DbHelper.searchItemsByName()` 查询 items 表
5. 结果缓存到内存（参考 `_timeEntitiesCache` 模式），渲染在卡片下方
6. **content 字段永不修改**——查询结果只存在内存缓存里

示例：
```
输入: "帮我说游戏机在哪儿"
→ 提取物品名: "游戏机"
→ 查询 items 表（LIKE '%游戏机%'，按 id DESC）
→ 卡片下方显示: 📍 游戏机 → 客厅电视柜
```

详见 @guides/ui-patterns.md 的"查询答案预填模式"。

## 录音期间媒体静音

快捷录音时自动静音其他媒体音频，避免干扰：
- 开始录音时保存当前媒体音量并设为 0
- 录音结束后智能恢复：
  - 如果用户在录音期间按了音量减键，保持静音（用户主动选择）
  - 否则恢复原始音量
- 通过 MethodChannel 调用原生 AudioManager
- 关键文件：`MainActivity.kt`（muteMedia/restoreMedia）

## 模型管理

### 内置模型（默认）
- SenseVoice 模型打包在 APK 的 `assets/` 目录中
- 首次启动自动拷贝到应用文档目录 `bundled_model/`
- 后续启动检测文件已存在则跳过拷贝
- 关键方法：`RecognizerSingleton._ensureBundledModel()`

### 用户导入（可选覆盖）
- 用户可通过设置页面导入自定义模型
- 模型文件复制到 `getApplicationDocumentsDirectory()/external_model/`
- 路径保存在 `SharedPreferences` 的 `custom_model_path` 键中

### 优先级
用户导入模型 > 内置模型

### 关键属性
- `hasModel` - 检查模型文件是否存在（不加载）
- `preloadModelPath()` - 预读模型路径缓存
- `isReady` - 识别器是否已初始化
- `hasEverInitialized` - 是否曾经初始化过（判断冷/热启动）

## 启动流程

```
main() → RecognizerSingleton.preloadModelPath()
       → SplashScreen(child: MainScaffold)
       → SplashScreen._doInit():
           1. preloadModelPath()（确保内置模型已拷贝）
           2. Permission.microphone.request()
           3. RecognizerSingleton.instance.initialize()
       → MainScaffold 显示
```

### 启动页（SplashScreen）
- **文件**: lib/splash_screen.dart
- 冷启动时显示，完成初始化后自动消失
- 三阶段进度条：0% → 33% → 66% → 100%
- 展示应用图标、名称和"完全离线 · 无需联网"标语

### 模型文件
- `model.int8.onnx` - 模型权重（SenseVoice）
- `tokens.txt` - Token 列表
