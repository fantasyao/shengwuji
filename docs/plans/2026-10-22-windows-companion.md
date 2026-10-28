# 声物记 Windows 薄客户端实施计划（第一轮）

**目标:** 做一个轻量的 Windows 客户端，能在电脑上看/搜笔记、新建笔记、把新建回传手机，并能导出 Markdown 转存到 Obsidian 或其他 App；改/删已有笔记放第二轮。

**架构:** 独立 Flutter Windows 项目，直接读写主 App 的 WebDAV 同步文件（`manifest.json` / `diary.json`），复用主 App 的 P1 同步契约与纯 Dart 合并逻辑；不移植主 App 的语音、悬浮窗、数据库和 Android 专属能力。

**技术栈:** Flutter Windows + Dart、`webdav_client`（dio）、`shared_preferences`、`flutter_secure_storage`、`path_provider`、`file_selector`、`uuid`、`intl`。

---

## 0. 背景与已拍板

- 主 App 是 Android Flutter 应用，核心是离线语音/悬浮窗；WebDAV 同步为 P1：手动触发、只合并新增条目、编辑/删除不跨端。
- 局域网 9527 页面不能满足需求：要求同网，且每次要在手机上手动开启。
- 电脑端需求：看、搜、新建；新建能回传手机；能在电脑上维护/转存到其他 App。改/删已有笔记明确需要，但接受分轮做。
- 决策：新建独立 Flutter Windows 项目；**不给主 App 加 `windows` 平台**。主 App `assets/` 合计约 288 MB（语音模型 229 MB、TTS 29 MB、字体 25 MB），加 Windows 平台会全部打进包。
- 第一轮**不修改主 App**；第二轮做 P2 同步时才动主 App 的 DB 与同步层。
- 框架：Flutter Windows。若 M1 实测中文输入法或体积不可接受，再评估 Tauri/Wails；不建议选 C++（Qt 不省体积，纯 Win32 开发/维护成本最高）。

参考文档与代码：

- [云同步架构](../architecture/cloud-sync.md)
- [同步载荷模型](../../lib/sync/sync_models.dart)
- [同步合并纯函数](../../lib/sync/sync_merge.dart)
- [同步编排](../../lib/sync/cloud_sync_service.dart)

---

## 1. 第一轮范围

### 1.1 必须有

- [ ] **连接配置**：WebDAV 地址、账号、应用密码、远端目录（默认 `/shengwuji_sync`）、测试连接；密码存 Windows 安全存储。
- [ ] **拉取**：手动刷新 + 启动自动拉取 `manifest.json` / `diary.json`，本地缓存，断网可读。
- [ ] **列表**：按时间倒序；活跃/归档筛选；内容搜索；标注筛选；锁定徽标。
- [ ] **详情**：只读；锁定笔记默认遮罩，设置中可二次确认后显示。
- [ ] **新建**：多行文本 + 可选标注；保存生成 UUID 与 `created_at`，推送到 `diary.json`；推送失败落本地待同步草稿，可重试，**不能丢字**。
- [ ] **导出**：全部/单条/多条 → 选择文件夹 → 每条一个 md；frontmatter 含 title/date/time/created_at/uuid/tag；文件名 `yyyy-MM-dd_HH-mm-ss_<uuid8>.md`；不覆盖无关文件。
- [ ] **状态**：上次同步时间/结果、待同步草稿数、另一台设备持锁提示、友好错误文案。
- [ ] **安全**：日志不含正文/密码；TLS 证书校验；锁定笔记不默认明文展示。
- [ ] **打包**：release + 便携 zip；可选 Inno Setup；目标安装后 ≤ 45 MB、安装包 ≤ 25 MB。
- [ ] **测试**：单元 + 契约样例 + 本地 WebDAV 集成 + 与手机 E2E 手测。

### 1.2 第一轮明确不做

- 改/删/归档/改标注已有笔记（第二轮 P2）。
- 电脑端录音、播放、语音识别、悬浮窗、锁屏、音量键。
- 物品、热词、修正对同步；截图附件、录音文件。
- Obsidian 插件、修改局域网页面、手机后台自动同步。
- 自动更新、多账号、Pro 授权、遥测。

---

## 2. 新项目与依赖

### 2.1 项目

- 路径：`S:\CodeProject\shengwuji_desktop`（独立 git 仓库）。
- 显示名：暂定“声物记电脑版”；版本 `0.1.0`。
- 支持：Windows 10 22H2+ / Windows 11 x64。
- 中文 UI；浅色/深色跟随系统；系统字体（微软雅黑/Segoe UI），**不打包 LXGW 字体**。

### 2.2 依赖

只保留：

```yaml
dependencies:
  flutter:
    sdk: flutter
  webdav_client: ^1.2.2
  dio: 5.11.1
  shared_preferences: ^2.5.4
  flutter_secure_storage: ^10.3.4
  path_provider: ^2.1.2
  file_selector: ^1.0.3
  uuid: ^4.6.0
  intl: ^0.20.2
  # 可选：window_manager（记住窗口大小/最小尺寸）
```

**不要引入**：`sherpa_onnx`、`record`、`audioplayers`、`flutter_overlay_window`、`permission_handler`、`gal`、`quick_actions`、`wakelock_plus`、SAF、`sqflite`。

### 2.3 建议目录

```text
shengwuji_desktop/
├── lib/
│   ├── main.dart
│   ├── app.dart
│   ├── config/cloud_config.dart
│   ├── sync/
│   │   ├── diary_codec.dart      # 原始 Map 读写，保留未知字段
│   │   ├── merge.dart            # 从主 App 复制的纯函数
│   │   ├── sync_models.dart      # 从主 App 复制的模型/编解码
│   │   ├── lock.dart             # manifest 软锁
│   │   └── sync_service.dart     # 拉取/新建/推送编排
│   ├── store/local_store.dart    # JSON 缓存、草稿、备份
│   ├── models/diary_note.dart    # UI 展示模型（不负责写回）
│   ├── export/markdown_exporter.dart
│   ├── pages/
│   │   ├── notes_page.dart
│   │   ├── note_detail_page.dart
│   │   ├── note_editor_page.dart
│   │   └── settings_page.dart
│   └── widgets/
├── test/
│   ├── diary_codec_test.dart
│   ├── merge_test.dart
│   ├── lock_test.dart
│   ├── export_test.dart
│   └── fixtures/                 # 契约样例
└── windows/
```

---

## 3. 同步契约（以主 App 为准）

### 3.1 远端布局

只读写两个文件，其余文件（`items.json`、`hotwords.txt`、`correction_pairs.json`、`audio_index.json`、`audio/`）第一轮忽略：

```text
/shengwuji_sync/
├── manifest.json
└── diary.json
```

### 3.2 `diary.json` 字段

数组，每项：

```json
{
  "uuid": "UUID v4",
  "content": "正文",
  "created_at": "2026-10-22T14:30:00.123456",
  "audio": "可选，文件名",
  "duration": 0,
  "archived": 1,
  "locked": 1,
  "tag": "urgent|star|idea|task",
  "sort_order": 0
}
```

规则：

- `created_at` 用 `DateTime.now().toIso8601String()`（本地时间、无时区偏移），与手机端一致。
- PC 新建只写 `uuid` / `content` / `created_at` / `tag`；省略 `archived` / `locked` / `audio` / `duration` / `sort_order`。
- `uuid` 用 UUID v4，必须唯一。
- **保留未知字段**：读取时保存原始 `Map`，写回时只追加自己新建的行，不重新编码旧行；不要用会丢未知字段的强类型模型重写整个文件。
- 手机端 P1 合并规则：远端 uuid 本地不存在、不在墓碑、自然键 `content|created_at` 不重复 → 插入。因此 PC 新建的笔记会在手机下次手动同步时出现。

### 3.3 `manifest.json` 与软锁

结构（保留未知字段）：

```json
{
  "v": 1,
  "device_id": "最后同步设备",
  "updated_at": "ISO 时间",
  "lock": { "device_id": "持锁设备", "at": "ISO 时间" },
  "counts": { "diary": 123 }
}
```

- 读 manifest；若 `lock` 属于其他设备且未超过 10 分钟 → 中止并提示“另一台设备正在同步”。
- 获取锁：写 `{lock: {device_id: <PC 固定 UUID>, at: now}}`，保留 manifest 其他字段。
- 操作结束（含失败）在 `finally` 写回 `lock: null`，更新 `updated_at` 和 `counts.diary`。
- 10 分钟超时自动失效；PC 有自己的固定 `device_id`。
- WebDAV 无原子 test-and-set，软锁只防常规误并发；事务窗口尽量短。

### 3.4 第一轮同步流程

1. 读取远端 `diary.json`（404 视为空；解析失败**立即中止，不写回**）。
2. 写入本地缓存并展示；PC **不做全量上传**。
3. 新建笔记时，在软锁内重新拉取一次远端列表 → 追加新行 → PUT `diary.json` → 释放锁。
4. 绝不拿本地缓存覆盖远端；PC 只追加自己新建的行。
5. 写回前把当前远端 JSON 备份到本地 `backups/diary-<timestamp>.json`（保留最近 20 份）。
6. 推送成功后提示“手机下次同步即可看到”。

### 3.5 已知限制（写进 UI 说明）

- 手机上删除的笔记可能因其他设备全量回传而重新出现；PC 端不处理墓碑，这是 P2 的事。
- 手机端仍需点一次“立即同步”才能拿到 PC 新建的笔记。
- 锁定笔记在云端 JSON 中是带标记的明文；PC 端必须默认遮罩。
- 截图附件不跨端；录音默认不同步，PC 不展示。

---

## 4. 本地状态与安全

应用支持目录（`path_provider`）：

- `notes_cache.json`：最近一次拉取结果（原始 Map 列表）。
- `pending_notes.json`：推送失败的草稿。
- `backups/`：写前备份，保留最近 20 份。

配置：

- `shared_preferences`：服务器地址、账号、远端目录、设备 ID、上次同步信息、UI 设置。
- `flutter_secure_storage`：应用密码；不写日志、不进 prefs。

日志：

- 只记元数据（条数、耗时、状态码）；不记正文和密码。
- 错误文案：401/403 → 检查账号或应用密码；429 → 限流稍后再试；507 → 空间不足；超时 → 检查网络；404 → 首次同步正常路径；持锁 → 稍后再试。

锁定笔记：

- 默认遮罩为“已锁定”，不渲染正文。
- 设置中提供“显示锁定内容”开关，开启时二次确认。
- 第一轮不支持在 PC 新建锁定笔记。

---

## 5. 界面

- **设置/连接页**：配置、测试连接、设备 ID、上次同步、锁定显示开关。
- **笔记列表**：搜索框、标注筛选、归档筛选、锁定徽标、时间。
- **详情页**：只读正文、复制按钮。
- **新建页**：多行编辑、标注选择、保存；保存中禁用重复提交。
- **导出对话框**：范围选择、目录选择、结果统计。
- **窗口**：默认 1100×750，最小 800×600；浅色/深色跟随系统；中文 UI。
- **M1 必测**：微软拼音的候选窗、组合输入、长按退格、Ctrl+Z、Ctrl+A。

---

## 6. 里程碑与任务

### M0 工具链

- [ ] `flutter config --enable-windows-desktop`
- [ ] 安装 VS 2022 Build Tools「使用 C++ 的桌面开发」
- [ ] `flutter doctor` 通过
- [ ] `flutter create --platforms=windows shengwuji_desktop`，跑通 Hello World

### M1 最小闭环（Go/No-Go）

- [ ] 设置页：WebDAV 配置 + 测试连接
- [ ] 拉取 `manifest.json` / `diary.json`，列表展示
- [ ] 新建一条笔记，按软锁协议写回
- [ ] 手机点“立即同步”，确认能拉到这条笔记
- [ ] 打 release 包，记录安装后体积、安装包体积、启动时间、内存
- [ ] 测中文输入法（组合输入/候选窗/撤销）
- [ ] **Go/No-Go**：体积 > 60 MB 或 IME 不可用 → 停下评估 Tauri/Wails

### M2 MVP

- [ ] `diary_codec.dart`：原始 Map 读写，未知字段保留，坏行跳过
- [ ] `lock.dart`：软锁获取/释放/过期判定
- [ ] `sync_service.dart`：拉取、新建、推送、错误映射
- [ ] `local_store.dart`：缓存、待同步草稿、写前备份
- [ ] 列表/详情/新建/设置页面
- [ ] 搜索、标注筛选、归档筛选、锁定遮罩
- [ ] Markdown 导出（frontmatter、稳定文件名）
- [ ] 启动自动拉取、手动刷新、推送失败重试
- [ ] 日志与安全要求落地

### M3 加固与交付

- [ ] 单元测试、契约样例、本地 WebDAV 集成测试
- [ ] 与手机 E2E 手测
- [ ] 便携 zip；可选 Inno Setup
- [ ] 干净 Win10 22H2 + Win11 验证
- [ ] README、同步契约说明、已知限制
- [ ] `flutter analyze` 0 error、测试全过

### M4 第二轮（另开计划）

- 主 App P2 同步 + PC 改/删/归档/改标注，见第 9 节。

---

## 7. 测试要求

### 7.1 单元

- 日期格式、UUID、文件名生成。
- `diary_codec`：未知字段保留；缺字段/类型错误的坏行跳过；空文件/非数组容错。
- 软锁：无锁、他机锁未过期、他机锁已过期、本机锁。
- 合并：只追加、不改旧行；自然键去重语义与手机一致。

### 7.2 契约样例

- 完整 P1 `diary.json`（含未知字段、归档、锁定、标注、排序键）。
- `manifest.json`：无锁、他机锁、过期锁。
- 断言读写后未知字段不丢、旧行字节级内容不被改写（允许 JSON 格式化差异，但字段值不变）。

### 7.3 集成

- 本地 `wsgidav`（或 mock HTTP）：404、401、429、解析失败不写回、两客户端抢锁、stale 锁接管。
- 写前备份存在且可恢复。

### 7.4 E2E 手测

- 手机新建 → PC 拉取。
- PC 新建 → 手机同步拉取。
- 手机编辑 → PC 拉取可见。
- 手机删除 → PC 可能仍可见（记录为 P1 限制）。
- 断网新建 → 草稿 → 恢复后重试。
- 锁定笔记默认遮罩；截图/录音不展示。

### 7.5 数据安全

- 推送中途杀进程 → 锁过期后可恢复、远端文件完整、备份存在。
- 远端 JSON 损坏 → 不写回、不覆盖为空。
- 无正文/密码进入日志。

---

## 8. 风险与备选

| 风险 | 应对 |
|---|---|
| Flutter Windows 中文 IME 异常 | M1 第一优先验证；不行转 Tauri/Wails |
| 体积超预期 | 独立项目、不带模型/TTS/字体、系统字体；M1 实测 |
| Windows 安全存储不可用 | 测试 `flutter_secure_storage`；不行改 Windows Credential Manager/DPAPI |
| WebDAV 兼容性 | 沿用 `webdav_client`；ASCII 路径；坚果云用应用密码；429 退避 |
| 锁竞争/并发 | 事务窗口短；写前备份；10 分钟超时兜底 |
| 两套合并逻辑漂移 | 第一轮复制纯函数并加同款契约样例；稳定后抽共享 Dart 包 |
| 未签名安装包触发 SmartScreen | 个人使用先便携 zip；分发再考虑签名 |
| PC/手机时钟不一致 | 第一轮只追加，影响小；P2 LWW 前加时钟偏差提示 |

---

## 9. 第二轮 P2 设计要点（先不做）

目标：PC 能改/删/归档/改标注已有笔记，并让编辑/删除在手机与 PC 间收敛；同时修复手机↔手机的编辑/删除同步。

### 9.1 主 App DB

- v18 迁移：`diary` / `items` 加 `updated_at`；存量回填为 `created_at`。
- 所有用户侧更新写入 `updated_at`：正文、标注、归档、锁定；排序键是否纳入另行决定。

### 9.2 云端

- `diary.json` / `items.json` 条目新增 `updated_at`。
- 新增 `tombstones.json`：`[{uuid, type, deleted_at}]`。
- 请求量 +2（读/写墓碑），仍在坚果云限额内。

### 9.3 合并

- 缺失则插入（保留 P1 自然键去重）。
- 同 uuid：`updated_at` 新者胜（LWW）；相等保留本地。
- 墓碑比本地 `updated_at` 新 → 删除本地；本地墓碑上传传播。
- 下载/上传顺序与软锁沿用现有机制。

### 9.4 兼容与发布

- 缺 `updated_at` 视为 `created_at`。
- 旧 P1 客户端不认墓碑，过渡期可能在同步时复活删除行；要求 PC 与手机都升级后再依赖删除同步。
- 更新 [cloud-sync.md](../architecture/cloud-sync.md)，补 changelog 与测试说明。

### 9.5 PC 端

- 本地持久化全量笔记（JSON 或 SQLite）。
- 做完整合并，支持编辑/删除/归档/改标注，写 `updated_at` 与墓碑。
- 与手机共用同一批契约样例和合并测试。

---

## 10. 开工前默认决策（如无异议按此执行）

- 项目路径/名称：`S:\CodeProject\shengwuji_desktop`，显示名“声物记电脑版”。
- 独立仓库；第一轮不碰主 App。
- Flutter Windows + 系统字体 + JSON 缓存。
- 启动自动拉取；新建自动推送；失败落草稿。
- 第一轮导出扁平目录 + frontmatter；标注→子目录作为可选增强。
- 锁定笔记默认遮罩。
- 个人使用优先：便携 zip，暂不做自动更新/授权/签名。
- 支持 Windows 10 22H2+ / Windows 11 x64。

---

## 11. 新对话启动提示

> 按 [docs/plans/2026-10-22-windows-companion.md](./2026-10-22-windows-companion.md) 开始 M0/M1。先读主仓库 `docs/architecture/cloud-sync.md`、`lib/sync/sync_models.dart`、`lib/sync/sync_merge.dart`，再在新项目搭最小壳。第一轮不要修改主 App。每完成一个里程碑跑 `flutter analyze` 和 `flutter test`，提交中文单行 commit。
