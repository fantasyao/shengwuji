# 状态管理架构

## State Management Pattern

应用使用 `GlobalKey` 访问子 widget 状态，父 `MainScaffold` 可以调用子组件的公共方法。

## 启动初始化（SplashScreen）

`SplashScreen` 作为初始化门控，包裹 `MainScaffold`：

```dart
// main.dart
SplashScreen(child: MainScaffold())
```

- 冷启动时执行三阶段初始化：模型预加载 → 权限请求 → 引擎初始化
- 初始化完成后显示 `MainScaffold`
- 热启动跳过初始化（`hasEverInitialized` 判断）
- **文件**: lib/splash_screen.dart

### Tab State 暴露

每个 Tab 的 State 类**不是私有的**，允许父组件调用：

- **RecordTabState**
  - `refreshEngine()` - 刷新语音识别引擎
  - 负责语音录制、物品追踪和清单提取

- **ListTabState**
  - `refreshItems()` - 刷新物品列表
  - `setSearchQuery(query)` - 预填搜索词并触发过滤（日记页"+N"跳转使用）
  - 负责物品展示和搜索

- **DiaryTabState**
  - `refreshEngine()` - 刷新语音识别引擎
  - `refreshList()` - 刷新日记列表
  - `startNewTextNote()` - 新建空白文本笔记（音量键双击触发）
  - `saveSharedTextNote(text, {source})` - 保存系统分享文本为日记文本笔记
  - `isLockedRecording` - 是否处于锁定录音模式
  - 负责语音日记录音、播放、编辑、归档、导出和分享接收

### 跨 Tab 跳转：DiaryTab → ListTab（预填搜索）

DiaryTab 的 widget 字段 `onJumpToSearch(String keyword)` 由 MainScaffold 注入：

```dart
// main.dart 中 DiaryTab 的构建
DiaryTab(
  onJumpToSearch: (keyword) {
    setState(() => _currentIndex = 1); // 切换到 ListTab
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _listTabKey.currentState?.setSearchQuery(keyword);
    });
  },
)
```

触发场景：日记卡片下方"查询答案区"的"+N"标签点击（多匹配时跳转列表看全部）。详见 @guides/ui-patterns.md 的"查询答案预填模式"。

## Tab 切换逻辑

当用户通过 `bottomNavigationBar` 的 `onTap` 切换标签时：

```dart
// main.dart 中的切换逻辑
onTap: (index) {
  switch (index) {
    case 0: // Record Tab
      _recordTabKey.currentState?.refreshEngine();
      break;
    case 1: // List Tab
      _listTabKey.currentState?.refreshItems();
      break;
    case 2: // Diary Tab
      _diaryTabKey.currentState?.refreshEngine();
      _diaryTabKey.currentState?.refreshList();
      break;
  }
}
```

## 全局加载状态（BlurLoadingOverlay）

`MainScaffold` 管理全局模糊加载遮罩：

- `showGlobalLoading()` / `hideGlobalLoading()` 通过回调从子 Tab 触发
- 全屏背景模糊（sigma 15）+ 随机加载文案
- 用于模型加载、后台恢复引擎预热等场景
- **文件**: lib/widgets/blur_loading_overlay.dart（如果存在）或 lib/main.dart

## Singleton Pattern

核心服务使用单例模式实现高效资源共享：

### RecognizerSingleton
- 全局语音识别器实例
- 避免重复初始化模型
- 管理识别器生命周期
- **新增属性**：
  - `isReady` - 识别器是否已就绪
  - `hasEverInitialized` - 是否曾经初始化过（冷/热启动判断）
  - `isInitializing` - 是否正在初始化中
- **新增方法**：
  - `preloadModelPath()` - 静态方法，预读模型路径缓存
  - `_ensureBundledModel()` - 确保内置模型已从 assets 拷贝到本地
- **文件**: lib/recognizer_singleton.dart

### ShortcutManager
- 集中管理应用快捷方式
- **当前状态**：动态快捷方式已停用，仅使用静态快捷方式
- 静态快捷方式定义在 `android/app/src/main/res/xml/shortcuts.xml`
  - `quick_record` - 快速录音
  - `quick_text_note` - 新建文本笔记
- 冷启动处理：`handleShortcutIntentOnColdStart()`（MainActivity.kt）
- `_hasHandledShortcutLaunch` 标志防止重复触发

### AIApp
- AI 应用注册表和查找
- 管理支持的外部 AI 应用列表（ChatGPT、DeepSeek、Kimi、WeChat 等）
- 处理应用选择和启动
