# 声物记

> 完全离线的 Flutter 语音识别助手 —— 物品位置追踪、语音日记、清单提取、音量键快捷操作。

使用 Sherpa-ONNX SenseVoice 模型（内置在 APK 中）实现完全离线识别，无需联网、不上传任何数据。

## 核心功能

- **物品位置追踪** — 语音记录物品存放位置，支持搜索
- **语音日记** — 录制、编辑、归档、导出为 Markdown
- **清单提取** — 自动识别购物/待办清单，批量保存
- **时间识别 + 闹钟** — 日记内容中的时间表达式自动高亮，点击可设系统闹钟
- **音量键快捷** — 长按音量键快速录音，双击新建文本笔记（需启用无障碍服务）
- **智能语音检测** — "记录一下"/"记一下" 自动转日记模式

## 构建

```bash
flutter pub get
flutter run                           # 运行
flutter build apk --split-per-abi     # 构建 APK（按 CPU 架构分包）
flutter analyze                       # 代码分析
flutter test                          # 运行测试
```

要求：Flutter 3.41.x stable、Java 17、Android SDK 34+。

## 技术栈

- **语音**：sherpa_onnx、record、audioplayers
- **数据**：sqflite、shared_preferences
- **系统**：permission_handler、vibration、wakelock_plus
- **文件**：file_picker、share_plus、archive、persistent_user_dir_access_android

## 项目结构

- `lib/main.dart` — 应用入口、4 标签页导航、快捷方式处理
- `lib/splash_screen.dart` — 启动页（冷启动初始化门控）
- `lib/recognizer_singleton.dart` — 语音识别器单例（含内置模型管理）
- `lib/db_helper.dart` — SQLite 操作（数据库 v8）
- `lib/diary_tab.dart` — 日记页（录音 / 编辑 / 归档 / 导出）
- `lib/list_extractor.dart` — 清单提取器（5 阶段管道）
- `lib/utils/dart_chrono_parser.dart` — 纯 Dart 中文时间解析器
- `android/app/src/main/java/com/shengwuji/app/` — 原生层（音量键无障碍服务、闹钟、MethodChannel 桥接）

完整架构和开发指南见 [docs/](docs/)。

## 模型文件下载

本仓库不含 SenseVoice 语音识别模型（229MB，超 GitHub 单文件限制）。

1. 前往 [Releases 页面](https://github.com/fantasyao/my_first_app_release/releases/latest)
2. 下载 `model.int8.onnx`
3. 放到 `assets/model.int8.onnx`
4. 运行 `flutter pub get && flutter run`
