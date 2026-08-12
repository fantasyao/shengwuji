# UI 设计模式

## 布局架构

### 主脚手架（Main Scaffold）
- **键盘处理**: `resizeToAvoidBottomInset: true`
- 适配软键盘弹出时的界面调整
- **退出逻辑**: 双击返回键退出（调用 `moveTaskToBack`）

### 启动页（SplashScreen）
- **文件**: lib/splash_screen.dart
- 冷启动时显示，完成初始化后自动消失
- **视觉设计**：
  - 深蓝背景（`#2C3E50`）
  - 圆角应用图标（120x120）
  - 应用名称 + "使用离线语音模型在本地完成识别，不上传任何数据"标语
- **三阶段进度条**：
  - 0% → "正在准备语音模型..."
  - 33% → "请求麦克风权限..."
  - 66% → "加载语音识别引擎..."
  - 100% → 显示主界面

### 浮动按钮定位
使用 `Positioned` widget 放置在外层 `Stack` 中：
- **目的**: 避免键盘弹出时按钮位置偏移
- **位置**: 固定在屏幕底部中央
- **两种模式**：
  - **锁定模式（isLockedRecording）**: 点击停止录音
  - **正常模式**: 长按开始录音，松开停止
- **视觉风格**: 黏土拟态（Clay Morphism），阴影质感
- **状态颜色**：
  - 灰色：禁用（模型未就绪）
  - 暗青色：模型未加载
  - 青色：就绪
  - 红色：录音中
  - 橙色：处理中

### 标签页特性

#### Record Tab（录制标签）
- **颜色主题**: 蓝色（Blue）
- **键盘处理**: 继承主脚手架设置

#### List Tab（列表标签）
- **颜色主题**: 橙色/青色（Orange/Teal）
- **功能**: 物品列表展示和搜索过滤

#### Diary Tab（日记标签）
- **颜色主题**: 青色（Teal）
- **键盘处理**: `resizeToAvoidBottomInset: false`（无文本输入框）
- **日记卡片交互**：
  - 单击：复制内容到剪贴板（静默，无 Toast）
  - 双击：分享到 AI 应用
  - 长按：弹出底部编辑面板
  - 侧滑：归档（活跃日记）或删除（已归档日记）
  - **侧滑动效**：圆圈闭合动画，进度>60%图标渐变为柔红色，快速划动触发删除，动画完成后彻底隐藏防止幽灵卡片
- **查询答案区**：检测到"XX在哪儿"等查询语句时，卡片正文下方独立显示物品位置预填答案（详见下文"查询答案预填模式"）
- **归档分区**: 已归档条目单独显示在分割线下方

#### Settings Tab（设置标签）
- 模型管理（内置状态 + 可选导入）
- 热词编辑（动态热词替换，已并入全量备份/恢复，不再单独提供导入/导出按钮）
- 备份与恢复
- AI 应用选择
- 外观设置：主题/皮肤选择 + Android 图标包切换（均支持 Pro 门禁）
- 无障碍服务开关 + 音量键监听配置
- **支持作者分区**：Pro 付费解锁入口（诊断区与关于区之间）

## Widget 组织

### 关键文件
- [lib/main.dart](../lib/main.dart) - 应用入口、标签导航、浮动按钮定位
- [lib/splash_screen.dart](../lib/splash_screen.dart) - 启动页
- [lib/record_tab.dart](../lib/record_tab.dart) - 语音录制界面
- [lib/list_tab.dart](../lib/list_tab.dart) - 物品列表界面
- [lib/diary_tab.dart](../lib/diary_tab.dart) - 语音日记界面
- [lib/settings_tab.dart](../lib/settings_tab.dart) - 设置界面
- [lib/theme/app_theme.dart](../lib/theme/app_theme.dart) - 主题定义注册表（4 套预设）
- [lib/theme/app_theme_extension.dart](../lib/theme/app_theme_extension.dart) - 语义化色槽 ThemeExtension
- [lib/utils/icon_pack_switcher.dart](../lib/utils/icon_pack_switcher.dart) - Android 图标包切换 MethodChannel 桥接
- [lib/widgets/checklist_widget.dart](../lib/widgets/checklist_widget.dart) - 清单 markdown 渲染组件
- [lib/widgets/swipe_dismiss_card.dart](../lib/widgets/swipe_dismiss_card.dart) - 侧滑删除组件（圆圈闭合动画）
- [lib/widgets/location_answer_widget.dart](../lib/widgets/location_answer_widget.dart) - 查询答案预填区组件（3 种状态）
- [lib/widgets/item_transfer_widget.dart](../lib/widgets/item_transfer_widget.dart) - 物品转存横条组件（浅橙）
- [lib/widgets/pro_unlock_dialog.dart](../lib/widgets/pro_unlock_dialog.dart) - Pro 付费解锁弹窗（金边 Dialog + 微信/支付宝真实付款码）
- [lib/utils/query_detector.dart](../lib/utils/query_detector.dart) - 查询语句检测器（正则+填充词剥离）

### AI 应用选择
设置页面允许用户选择首选的 AI 应用进行日记分享：
- **支持应用**: ChatGPT, DeepSeek, Kimi, WeChat 等
- **启动方式**: `external_app_launcher` 包
- **持久化**: SharedPreferences

### 应用快捷方式
支持 Android 静态快捷方式：
- **"快速录音"** (`quick_record`)
- **"新建文本笔记"** (`quick_text_note`)
- **定义位置**: `android/app/src/main/res/xml/shortcuts.xml`
- **管理器**: `ShortcutManager` 单例
- **注册方式**: 静态注册（动态注册已停用）

## 触觉反馈

### 库
- `vibration: ^3.1.5`

### 震动模式详表

| 操作 | 时长 | 振幅 | 说明 |
|------|------|------|------|
| 日记保存 | 20ms | 40 | 轻柔确认 |
| 日记归档 | 20ms | 50 | 侧滑确认 |
| 日记删除 | 20ms | 50 | 侧滑确认 |
| 复制到剪贴板 | 30ms | 40 | 轻触反馈 |
| 短录音完成 | 50ms | 50 | 录音过短提示 |
| 长按触发录音（音量键） | 100ms | 70 | 原生层触发 |
| 录音停止（音量键） | 100ms | 70 | 原生层触发 |
| 双击触发文本笔记 | 50+50+50ms | 80 | 波形震动 |

### 优化
- `_hasVibrator` 在 `initState` 时缓存，避免重复平台调用
- 归档/删除反馈在侧滑手势完成那一刻触发

## 时间实体高亮

日记内容中的时间表达式自动高亮并可设置闹钟：

### 组件
- **TimeAwareText** (`lib/widgets/time_aware_text.dart`) - 富文本渲染，时间表达式蓝色高亮
- **DartChronoParser** (`lib/utils/dart_chrono_parser.dart`) - 纯 Dart 中文时间解析器
- **AlarmDialog** (`lib/widgets/alarm_dialog.dart`) - 闹钟确认对话框

### 交互流程
```
日记内容 → DartChronoParser 解析时间表达式
        → TimeAwareText 蓝色高亮显示
        → 用户点击高亮文字
        → 弹出 AlarmDialog 确认
        → AlarmManager 定时触发 AlarmReceiver
        → MediaPlayer 循环响铃 + 通知栏控制（停止按钮 / 点击打开APP）
        → 3分钟无操作自动停止
```

### 支持的时间格式
- 相对时间："明天"、"后天"、"下周一"
- 绝对时间："下午3点"、"明天早上8点"

## 查询答案预填模式

日记卡片正文下方独立显示物品位置查询答案，**不修改 content 字段**。设计上与"时间实体高亮"完全对称（同样的懒加载缓存机制）。

### 组件
- **QueryDetector** (`lib/utils/query_detector.dart`) - 正则检测查询语句 + 剥离填充词
- **LocationAnswerWidget** (`lib/widgets/location_answer_widget.dart`) - 卡片下方独立答案区

### 渲染流程
```
日记卡片 build → _parseQueryAnswer(diaryId, content)（懒加载，1 帧后异步触发）
              → QueryDetector.detect(content) 检测是否为查询语句
              → 是 → DbHelper.searchItemsByName() 查询 items 表
              → 结果缓存到 _queryAnswerCache[diaryId]
              → setState 触发重渲染
              → LocationAnswerWidget 显示在文本之后、底部信息栏之前
```

### 三种显示状态

| 状态 | 视觉 | 内容 |
|------|------|------|
| 无匹配 | 灰色背景 | `❓ 没找到「物品名」` |
| 单匹配（1 条） | 浅青背景 | `📍 物品名 → 位置` |
| 多匹配（≥2 条） | 浅青背景 + 胶囊标签 | `📍 物品名 → 最新位置  +N` |

- "+N" 标签 N = matches.length - 1
- 点击 "+N" → 触发 `widget.onJumpToSearch(itemName)` → 跳转 ListTab 并预填搜索词
- `refreshList()` 时清空 `_queryAnswerCache` 和 `_queryingDiaryIds`（与 `_timeEntitiesCache` 同步）
- **长句跳过**：cleanText 长度 > `kDiaryShortTextMax`（默认 15 字）的日记不进行查询检测，避免长句里的"在哪里"被误判（详见"物品转存横条模式"的互斥规则）

## 物品转存横条模式

日记卡片正文下方独立显示"物品+位置"拆分预览，用户点击「转存」按钮后写入 items 表并删除原日记（含录音）。设计上与"查询答案预填模式"完全对称（同样的懒加载缓存机制）。

### 组件
- **ItemSplitter** (`lib/utils/item_splitter.dart`) - 静态工具类，`detect()` 返回 `ItemSplitResult?`，与录入页 `_smartSplit` 共用同一逻辑
- **ItemTransferWidget** (`lib/widgets/item_transfer_widget.dart`) - 浅橙背景的横条，左侧 `📦 物品 → 位置` 预览，右侧「转存」按钮

### 渲染流程
```
日记卡片 build → _parseItemSplit(diaryId, content)（懒加载，1 帧后异步触发）
              → ItemSplitter.detect(content) 检测是否为"物品+位置"模式
              → 命中 → 结果缓存到 _itemSplitCache[diaryId]
              → setState 触发重渲染
              → ItemTransferWidget 显示在查询答案区之后、底部信息栏之前
```

### 视觉与交互

| 元素 | 样式 |
|------|------|
| 背景 | 浅橙 `#FFF3E0`（区别于查询答案区的浅青 `#E0F2F1`） |
| 文字 | 深橙 `#E65100`，物品名加粗 |
| 图标 | `📦`（左侧 14px） |
| 转存按钮 | 橙色胶囊，白字 |

点击转存按钮：
1. `DbHelper.insertItem(itemName, location)` 写入 items 表
2. `DbHelper.queryAllDiaries()` 取 audio_path
3. `DbHelper.deleteDiary(diaryId)` 删数据库行
4. `File(audioPath).delete()` 删录音文件（try-catch 容错）
5. 清缓存 + `_haptic('tick')` 震动 + `refreshList()` + SnackBar 提示

### 互斥规则（优先级从高到低）
- **长句跳过**（最高优先级）：cleanText 长度 > `kDiaryShortTextMax`（默认 15 字，定义在 diary_tab.dart 顶部）的日记，**转存和查询检测都跳过**。用户长句意图发散，强行拆分容易误命中——"长句 = 普通日记"
- **清单日记**：ChecklistWidget 优先，跳过转存检测
- **查询语句**：QueryDetector 命中时（如"游戏机在哪里"），`_parseItemSplit` 直接 return，不显示转存横条。否则 ItemSplitter 会把"在哪里"误拆为 location="哪里"

### 长句跳过的边界用例

| 输入 | cleanText 长度 | 判定 |
|------|---------------|------|
| `钥匙放在桌子上` | 7 | ✅ 处理 |
| `游戏机在哪里` | 6 | ✅ 处理 |
| `今天天气也不错，钥匙放在桌子上` | 13 | ✅ 处理（短复合句） |
| `今天天气也不错，哎，我突然想找一下我的钥匙，我的钥匙在哪里` | >15 | ❌ 跳过 |
| `我刚才把手机放在书包里然后就去做饭了` | 17 | ❌ 跳过 |

调整阈值只需改 `kDiaryShortTextMax` 一行常量。

- `refreshList()` 时清空 `_itemSplitCache` 和 `_parsingItemSplitIds`（与 `_queryAnswerCache` 同步）

## 全局加载遮罩（BlurLoadingOverlay）

- 全屏背景模糊（BackdropFilter, sigma 15）
- 随机加载文案（每次显示随机选择）
- 沙漏图标（静态，避免动画占用 CPU）
- 用于模型加载、后台恢复引擎预热
- 由 `MainScaffold` 管理显示/隐藏

## 字体系统

- **内置字体**: 霞鹜文楷等宽屏幕版（`LXGWWenKaiMonoGBScreen.ttf`）
- **位置**: `assets/LXGWWenKaiMonoGBScreen.ttf`
- **应用方式**: 所有 TextTheme 样式显式配置（避免 Roboto 回退）

## 屏幕唤醒
- **库**: `wakelock_plus: ^1.2.8`
- 保持录制过程中屏幕常亮

## 外观设置

设置页"外观"分区集中管理主题皮肤和 Android 桌面图标包，均支持 Pro 门禁。

### 主题 / 皮肤系统

- **4 套预设**：默认青（Teal）、暖橙（Warm Orange）、墨绿（Forest Green）、黑金（Black Gold，Pro）
- **实现**：`AppThemeExtension`（25 个语义化色槽）+ `AppThemeDefinition` 注册表 + `AppRoot.themeNotifier` 全局切换
- **持久化**：`selected_theme`（SharedPreferences），冷启动恢复
- **Pro 门禁**：黑金主题未解锁时点击调起 `ProUnlockDialog`

### Android 图标包切换

- **4 套图标包**：默认、暖色、节日红（Pro）、极简白（Pro）
- **实现**：`activity-alias` 声明在 `AndroidManifest.xml`，`IconPackSwitcher` 通过 MethodChannel 调用原生 `setComponentEnabledSetting` 切换
- **持久化**：由 Android 系统持久化，`getCurrentIconPack()` 反查；prefs 中的 `selected_icon_pack` 仅用于 UI 显示
- **注意**：切换后 Android 会在 1-3 秒内杀死 APP 进程，UI 需明确告知用户此现象

### 关键文件
- [lib/theme/app_theme.dart](../lib/theme/app_theme.dart) - 主题定义注册表
- [lib/theme/app_theme_extension.dart](../lib/theme/app_theme_extension.dart) - 语义化色槽
- [lib/utils/icon_pack_switcher.dart](../lib/utils/icon_pack_switcher.dart) - 图标包 MethodChannel 桥接
- [lib/utils/pro_gate.dart](../lib/utils/pro_gate.dart) - Pro 门禁工具
- [android/app/src/main/AndroidManifest.xml](../android/app/src/main/AndroidManifest.xml) - activity-alias 声明

## 系统分享接收

从其他 Android App（如浏览器、微信、备忘录等）选中文字 → 系统"分享"菜单 → 选择「声物记」→ 直接保存为日记文本笔记。

### 触发条件

MainActivity + 3 个 `activity-alias` 均声明 `ACTION_SEND` / `text/plain` intent-filter。

### 处理流程

```
系统分享菜单 → MainActivity.onCreate/onNewIntent
           → handleShareIntent() 解析 EXTRA_TEXT + 来源应用
           → MethodChannel "onReceiveSharedText" → MainScaffold
           → 切换到日记页（索引 2）
           → DiaryTab.saveSharedTextNote(text, source)
           → 写入 diary 表（audio_path = null）
```

### 来源应用名（仅日志记录，不再附加正文）

原生层仍通过 `EXTRA_PACKAGE_NAME` → `getReferrer()` → `getCallingPackage()` 三级回退尝试获取来源包名并转为应用标签名，经 MethodChannel 传给 Flutter，仅写入运行日志（`source=...`），**不再附加到日记正文**。

> 历史：曾有"展示分享来源"开关（`append_share_source`）控制是否在正文前加 `"来自XXX："`。2026-08-11 移除——经系统分享面板（ChooserActivity）转发的 App（酷安/微信/QQ 等绝大多数），Android 出于隐私设计会抹空来源包名，三级回退全为 null，开关时灵时不灵（仅直接 startActivity 的如 Via 才能拿到），体验割裂。为行为一致，对所有来源停用附加。

### 关键文件
- [android/app/src/main/java/com/shengwuji/app/MainActivity.kt](../android/app/src/main/java/com/shengwuji/app/MainActivity.kt) - Intent 解析与 MethodChannel 通知
- [lib/main.dart](../lib/main.dart) - MethodChannel 监听与页面切换
- [lib/diary_tab.dart](../lib/diary_tab.dart) - `saveSharedTextNote()`

## Pro 付费解锁弹窗

设置页"支持作者"分区入口（诊断区与关于区之间），点击调起金边 Dialog。弹窗展示作者寄语 + 微信/支付宝真实付款码缩略图 + 解锁按钮。已接入 Pro 功能门禁：主题/皮肤系统中的黑金主题、图标包切换中的节日红/极简白为 Pro 专属，未解锁时点击会调起弹窗。

### 组件
- **ProUnlockDialog** (`lib/widgets/pro_unlock_dialog.dart`) - `showDialog` + 自定义 Container（不用 AlertDialog，便于做精致金边）

### 视觉结构（从上到下）
| 元素 | 样式 |
|------|------|
| 外框 | 白底 + 暖金边框 `#E6C158` 1.5px + 圆角 20 + elevation 8 |
| 徽章 | 圆形 60×60，浅金底 `#FFF8E7`，`workspace_premium` 图标 |
| 标题 | "解锁 Pro"，17pt 粗体 blueGrey |
| 正文 | 作者寄语 4 句，13pt 黑 0.87 透明度，行高 1.7，居中 |
| 付款码 | 两张 90×90 金边圆角缩略图并排（微信 + 支付宝），点击放大，长按保存到相册 |
| 解锁按钮 | 暖金 `#D4A437` 白字，已解锁后变灰禁用 |
| 关闭按钮 | TextButton 灰字 |

主色常量：`_kGoldColor #D4A437` / `_kGoldLight #FFF8E7` / `_kGoldBorder #E6C158`

### 状态流转
- **入口按钮文案**（settings_tab.dart `_buildSecondaryBtn`）：未解锁"付费解锁 Pro 功能"（金色边框）→ 已解锁"Pro 已解锁 ✓"
- **State 字段**：`_isProUnlocked`，`initState` 读 `prefs.getBool('is_pro_unlocked')`
- **解锁动作**：弹窗内点"直接解锁全部功能" → `prefs.setBool('is_pro_unlocked', true)` → SnackBar 感谢提示 → 700ms 后 pop → 设置页 `_loadProUnlockStatus()` 刷新按钮文案
- **重启行为**：杀掉 APP 重进，按钮仍是"Pro 已解锁 ✓"（持久化生效）

### 后续扩展点
- **更多付费功能门禁**：读 `is_pro_unlocked` 控制具体 Pro 功能可用性

