# 声物记

> 完全离线、纯本地的 Flutter 语音助手 —— 物品管理 + 闪念胶囊。
> 所有功能在本地处理，无需联网，**不上传任何用户数据**。

<p align="center">
  <img src="docs/img/搬家app1.webp" width="720" alt="声物记应用概览" />
</p>

使用 Flutter 开发，目前仅安卓端。内置 Sherpa-ONNX **SenseVoice** 离线语音模型（打包在 APK 中，首次启动自动部署），所有识别均在本地完成。

**核心场景：** 语音存 / 查物品、搬家模式解放双手、闪念胶囊式快速记笔记。

<p align="center">
  <img src="docs/img/快速录音高清.webp" width="280" alt="快速录音演示" />
</p>

---

## ✨ 功能演示

### 🗣️ 语音物品管理

- **语音存物品**：长按录音说「洗发露在 3 号箱子」「牙刷在厨房小推车」，自动拆分为「物品 — 位置」并存档，不用打字。
- **语音查询（双重查询）**：着急找东西时直接问 ——
  - 「电风扇在哪」→ 电风扇在桌子上
  - 「客厅里有什么」→ 客厅里有收音机
- **热词替换**：普通话不标准？可自定义纠错映射（如把识别错的「冰响」自动替换成「冰箱」）。

<p align="center">
  <img src="docs/img/存物品.webp" width="280" alt="语音存物品演示" />
    
  <img src="docs/img/查物品.webp" width="280" alt="语音查物品演示" />
</p>

### 📦 搬家模式 · 解放双手

双手腾不出来按按钮？搬家模式下把手机放一旁即可：

- **持续录音 + Silero VAD 智能切段**，边放物品边说话，不用来回按按钮；
- **TTS 语音反馈**：识别成功会朗读「已把牙刷放入绿色箱子」，识别失败有提示音，**不用盯屏幕**；
- 说「不对 / 撤销」可自动删除上一条记录。

<p align="center">
  <img src="docs/img/搬家模式高清.webp" width="280" alt="搬家模式演示" />
</p>
- ▶️ **搬家模式演示视频**（声音较大，注意调低音量）：https://www.bilibili.com/video/BV11yM96nE23/

### ⚡ 闪念胶囊 · 快速记笔记

怀念锤子的闪念胶囊？声物记把它复刻进了 app：

- **长按音量键** → 快速启动 app 并开始录音，再次长按即转写为文字；
- **双击音量键** → 直接新建文本笔记，键盘自动拉起；
- 亮屏即可触发，**未解锁状态下也能正常录音并转写**；
- 笔记中识别到时间（如「周三下午 6 点」）→ 文字变蓝可点击 → 一键创建提醒；
- 从其他 App 选中文字 → 分享到「声物记」，直接保存为文本笔记；
- 一键复制笔记内容并跳转 **ChatGPT / DeepSeek / Kimi** 继续对话（声音不外传）。

<p align="center">
  <img src="docs/img/闪念-快速录音笔记.webp" width="280" alt="闪念胶囊快速录音" />
</p>

> 快速录音需开启无障碍权限；app 完全开源、无任何联网功能，可放心开启。不开也不影响其他功能，仅影响快速录音 / 文本笔记。
> 不同手机权限要求不同：可能需要额外开启：锁屏展示、后台弹出页面、自启动、省电策略-无限制

### 📝 与 Obsidian 搭配

笔记可导出为 Markdown 文件，绑定 Obsidian 的文件夹，即可在手机上快速语音录入笔记到 Obsidian，补齐 Obsidian 移动端无离线语音录入、启动慢的短板。

<p align="center">
  <img src="docs/img/ob同步导入.webp" width="480" alt="Obsidian 同步导入" />
</p>

---

## 🎯 适用场景

- 平时总找不到东西放哪里的；
- 想做物品管理，但嫌打字太慢、效率低的；
- 搬家收纳时把物品放入某个箱子，到新家却忘了在哪个箱子；
- 封箱时塞了填充杂物（如锅碗箱里顺手塞了洗发露）却忘记标注，复原时找不到；
- 想临时记个笔记，却嫌「解锁 → 找 app → 新建 → 打字」步骤太多的。

---

## 📥 下载与源码

- **源码仓库**：https://github.com/fantasyao/shengwuji
- **下载 APK**：https://github.com/fantasyao/shengwuji/releases （下载 apk 安装即可）

## 🔒 数据 · 用户掌握

- 所有数据完全在本地，app 无联网功能；
- 支持 **ZIP 全量备份 / 恢复**（含日记、物品、录音文件、热词配置）。

---

## 📝 更新日志

> 同步于 App 内「设置 → 关于 → 版本更新日志」。

**v1.0.17**（2026-08-18）

- 日记页录音按钮支持上滑-快速新建文本笔记
- 设置页将「静音提示」开关与「按音量减保持静音」开关整合在一起
- 原生无障碍服务与日记页联动响应 keep_muted_on_volume_down 开关
- 隐藏日记卡片底部未实现的爱心图标，等待后续功能完善

**v1.0.16**（2026-08-12）

- 随手记 / 日记卡片归档后可一键恢复（新增恢复入口）
- 日记卡片「单击 / 长按」交互支持自定义交换
- 接收系统分享：从其他 App 选文字分享到声物记，直接存为笔记
- 热词配置纳入全量备份 / 恢复

**v1.0.15**（2026-08-07）

- 日记卡片改版：日期 / 时长移至顶部，补全年份与时分格式
- 播放按钮升级为带响度波纹的可拖动进度条（支持拖动跳转 / 暂停继续）
- 转写中按钮区禁用态；修复进度条游标「先走再跳回」与暂停后续播虚高
- 搬家模式智能分割失败提示改为可左滑消除的自绘提示条（含手动保存按钮）

**v1.0.14**（2026-08）

- 主题系统改版（4 套皮肤预设 + Android 桌面图标包切换，Pro 门禁）
- 搬家模式增强（TTS 语音播报 + 说「不对/撤销」语音撤销 + 屏幕常亮省电遮罩）
- 录音防丢失（先落盘再转写，失败可重新转写）
- 长录音 VAD 自动切分保护
- 清单触发词门禁（「代办/待办」开头才识别，避免正常说话误判）
- 锁屏隐私保护与音量键键盘修复
- 物品列表浮动语音查询按钮
- Pro 弹窗接入真实付款码
- 录入/日记页按钮钉底便于单手操作
- 修复窄屏卡片底部信息栏溢出
- 补齐霞鹜文楷字体 OFL 开源协议

**v1.0.13**（2026-06）

- 日记一键转物品（浅橙横条转存按钮）
- 设置页新增 Pro 付费解锁弹窗（支持作者）
- 录音按钮样式统一
- 修复双击音量键键盘抖动

**v1.0.12**（2026-06）

- 日记页语音查找物品：说「游戏机在哪儿」自动在卡片下方展示物品位置答案，多匹配显示 +N 跳转列表

**v1.0.11**（2026-06）

- 日记页首次启动内置 7 条功能说明卡片

**v1.0.10**（2026-06）

- 应用改名「东西放哪儿了 → 声物记」，包名更新为 com.shengwuji.app

---

## 开源许可

本项目源码以 **Apache License 2.0** 开源，详见 [LICENSE](LICENSE) 文件。

本 app 使用 **Flutter** 开发，语音框架为 **sherpa_onnx**，语音模型为 **SenseVoice**。

开源字体：

- [霞鹜文楷 LXGW WenKai](https://github.com/lxgw/LxgwWenKai) —— 中文字体，基于 SIL Open Font License 1.1 协议，协议全文见 App「设置 → 关于 → 开放源代码许可」。

灵感来源：

- 热词替换 —— **CapsWriter**
- 音量键长按录音 —— **idea note**
- 侧滑删除动效 —— **小宇宙的订阅列表**
- 闪念胶囊 —— **锤子科技**

<!-- ============ 以下为开发者内容 ============ -->

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
- `lib/theme/app_theme.dart` / `lib/theme/app_theme_extension.dart` — 主题/皮肤系统（4 套预设 + ThemeExtension）
- `lib/utils/icon_pack_switcher.dart` — Android 图标包切换桥接
- `android/app/src/main/java/com/shengwuji/app/` — 原生层（音量键无障碍服务、闹钟、MethodChannel 桥接）

完整架构和开发指南见 [docs/](docs/)。

## 模型文件下载

本仓库不含 SenseVoice 语音识别模型（229MB，超 GitHub 单文件限制）。

1. 前往 [Releases 页面]([https://github.com/fantasyao/shengwuji/releases/tag/v1.0)
2. 下载 `model.int8.onnx`
3. 放到 `assets/model.int8.onnx`
4. 运行 `flutter pub get && flutter run`
