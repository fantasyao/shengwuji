# 项目概览

## 项目名称
声物记（Flutter 语音识别助手）

## 项目简介
一个支持离线语音识别的 Flutter 应用，主要功能：
1. **物品位置追踪** - 通过语音记录物品存放位置
2. **语音日记** - 录制并保存语音日记，支持播放、编辑、归档和导出
3. **离线识别** - 使用 Sherpa-ONNX SenseVoice 模型，无需网络
4. **内置模型** - SenseVoice 模型打包在 APK 中，首次启动自动部署
5. **音量键快捷** - 长按音量键快速录音，双击新建文本笔记
6. **清单提取** - 语音说"代办"/"待办"开头才触发（白名单替代评分制，避免正常说话误判），识别后转 markdown 存入日记表
7. **时间识别+闹钟** - 日记内容自动识别时间表达式，点击可设系统闹钟
8. **日记导出** - 增量导出为 Markdown 文件到用户指定目录
9. **语音查找物品** - 日记页说"XX在哪儿"自动查询 items 表，卡片下方展示物品位置答案
10. **搬家模式** - 搬家场景双手占用时持续录音 + Silero VAD 自动切段 + 自动识别保存 + TTS 播报确认；10 秒窗口内说"不对"/"撤销"自动删除上一条 + TTS 回显"已撤销"
11. **Pro 付费解锁** - 设置页"支持作者"入口，金边弹窗展示作者寄语 + 二维码占位 + 解锁按钮，解锁状态持久化（SharedPreferences key `is_pro_unlocked`）

## 技术栈

### 核心框架
- **Flutter** - 跨平台 UI 框架
- **Dart** - 编程语言

### 关键依赖

#### 语音处理
- `sherpa_onnx: ^1.12.21` - 离线语音识别
- `record: ^6.1.2` - 音频录制（PCM 流）
- `audioplayers: ^6.0.0` - 音频播放

#### 数据持久化
- `sqflite: ^2.3.0` - SQLite 数据库
- `shared_preferences` - 键值对存储（含 Flutter-Native 状态桥接）

#### 系统集成
- `permission_handler: ^12.0.1` - 权限管理（麦克风）
- `vibration: ^3.1.5` - 触觉反馈
- `wakelock_plus: ^1.2.8` - 屏幕常亮

#### 文件与分享
- `file_picker: ^8.1.0` - 文件选择（导入模型）
- `share_plus: ^10.1.0` - 内容分享（导出数据）
- `archive: ^3.6.0` - ZIP 文件处理（备份）
- `persistent_user_dir_access_android: ^0.0.1` - SAF 持久化目录（日记导出）

#### UI 与交互
- `intl: ^0.20.2` - 国际化和日期格式化
- `quick_actions: ^1.0.8` - 应用快捷方式
- `url_launcher: ^3.0.0` - URL 启动
- `external_app_launcher: 4.0.3` - 外部应用启动（AI 应用）

## 应用结构

### 启动流程
```
main() → RecognizerSingleton.preloadModelPath()
       → SplashScreen（冷启动初始化）
           1. 内置模型拷贝（首次）
           2. 麦克风权限请求
           3. 识别引擎初始化
       → MainScaffold（4 标签页）
```

### 主要标签页
1. **Record Tab** - 录制语音，追踪物品位置，支持清单提取
2. **List Tab** - 查看所有物品，支持搜索和过滤
3. **Diary Tab** - 语音日记录音/播放，文本编辑，归档/删除，Markdown 导出，AI 分享，语音查找物品
4. **Settings Tab** - 内置模型管理（可选导入），热词编辑，备份恢复，无障碍服务配置

### 原生集成（Android）
- **VolumeKeyAccessibilityService** - 无障碍服务，监听音量键事件
- **MainActivity** - MethodChannel 桥接（静音/恢复媒体、通知权限、闹钟管理、任务后台化）
- **AlarmReceiver** - 闹钟响铃接收器（MediaPlayer 循环播放 + 3分钟超时）
- **AlarmStopReceiver** - 闹钟停止接收器（通知栏停止按钮）

## 开发命令

### 运行与构建
```bash
# 运行应用（连接设备或模拟器）
flutter run

# 构建 Release APK
flutter build apk --split-per-abi

# 清理构建产物
flutter clean
```

### 测试与分析
```bash
# 运行测试
flutter test

# 代码分析
flutter analyze

# 代码格式化
dart format .

# 获取依赖
flutter pub get
```

### 特殊命令
```bash
# 生成启动图标（修改 app_icon.png 后）
flutter pub run flutter_launcher_icons
```

## 架构概览

### 核心单例
- `RecognizerSingleton` - 语音识别器（含内置模型管理）
- `ShortcutManager` - 快捷方式管理
- `AIApp` - AI 应用注册表

### 数据库
- 版本：8
- 表：`items`（物品）、`diary`（日记）
- 详情见 @architecture/database.md

### 状态管理
- 基于 `GlobalKey` 的父子通信
- `SplashScreen` 初始化门控
- `BlurLoadingOverlay` 全局加载状态
- 详情见 @architecture/state-management.md

## 资源文件

### 语音识别配置
- [assets/rules.txt](../assets/rules.txt) - 正则纠错规则（只读）
- [assets/hotwords.txt](../assets/hotwords.txt) - 热词纠错（可编辑）

### 内置模型
- [assets/model.int8.onnx](../assets/model.int8.onnx) - SenseVoice 模型权重
- [assets/tokens.txt](../assets/tokens.txt) - Token 列表

### 字体
- [assets/LXGWWenKaiMonoGBScreen.ttf](../assets/LXGWWenKaiMonoGBScreen.ttf) - 霞鹜文楷等宽屏幕版

### 应用图标
- [assets/icon/app_icon.png](../assets/icon/app_icon.png)

## 模型管理

### 内置模型（默认）
- 模型打包在 APK 的 `assets/` 目录中
- 首次启动自动拷贝到应用文档目录 `bundled_model/`
- 后续启动检测文件已存在则跳过

### 用户导入（可选覆盖）
- 用户可通过设置页面导入自定义模型
- 模型复制到 `external_model/` 目录
- 用户导入模型优先于内置模型

### 应用生成文件
- **音频文件**：日记录音 WAV 文件
- **位置**：应用文档目录 `diary_audio/`
- **格式**：16-bit PCM, 16kHz, Mono

## 相关文档
- @architecture/ - 架构详细文档
- @guides/ - 开发指南
- @standards/ - 标准与规范
