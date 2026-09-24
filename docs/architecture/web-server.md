# 电脑访问服务（日记局域网 HTTP 服务）

> 2026-09 新增。设置 →「电脑访问」开启后，手机以固定端口 9527 起一个局域网
> HTTP 服务，电脑浏览器打开 `http://<手机IP>:9527` 即可查看全部日记（含录音
> 播放），并支持在电脑上编辑 / 删除；电脑端的改动实时写回 App 数据库，手机端
> UI 即时刷新；手机端新增的日记也实时推送到浏览器。

## 组件地图

| 文件 | 职责 |
|---|---|
| `lib/web_server/diary_web_server.dart` | HTTP 服务核心：路由 / CRUD API / SSE 推送 / 端口接管 / 录音目录守护 |
| `lib/web_server/diary_web_page.dart` | 浏览器端管理页（单文件 SPA，vanilla JS，GET / 返回） |
| `lib/web_server/diary_server_controller.dart` | 生命周期编排：前台保活服务 + HTTP 起停 + prefs 开关持久化 + 冷启动自恢复 + 状态通知 |
| `lib/web_server/web_server_settings_card.dart` | 设置页「电脑访问」卡片（开关 + 地址展示 + 复制） |
| `android/.../DiaryServerService.kt` | 原生前台保活服务（只拉进程优先级，无业务逻辑） |
| `MainActivity.kt` | MethodChannel 增加 `startDiaryServerService` / `stopDiaryServerService` |
| `test/diary_web_server_test.dart` | 真实 socket 集成测试（回环 + 临时端口 + 内存假仓储） |
| `test/web_server_settings_card_test.dart` | 设置卡片 widget 测试 |

## HTTP 契约

| 方法与路径 | 说明 |
|---|---|
| `GET /` | 管理页（列表 / 播放 / 复制 / 编辑 / 删除 / SSE 实时刷新） |
| `GET /api/notes` | 全量日记 JSON（活跃在前；**不暴露文件系统绝对路径**，录音只给 `audioUrl: /audio/{id}`；**锁定笔记 content 脱敏为固定星号、audioUrl 为 null**，带 `isLocked` 标记） |
| `PUT /api/notes/{id}` | 编辑内容，body `{"content": "..."}`（**锁定笔记 403 拒绝**） |
| `DELETE /api/notes/{id}` | 删除（连带删录音文件，与日记页删除语义一致；**锁定笔记 403 拒绝**） |
| `GET /audio/{id}` | 录音流（支持 Range 206，进度条可拖动；**锁定笔记 403 拒绝**——录音内容与正文同属锁定范围） |
| `GET /api/events` | SSE 事件流，数据变化推 `data: changed`，浏览器收到重拉列表 |
| `GET /__identity` | 自家服务身份标记（端口接管探测用） |
| `POST /__shutdown` | 关停服务（**仅接受 127.0.0.1 回环请求**，局域网设备调不通） |

无鉴权：局域网内任何设备都能读写日记。个人局域网场景的取舍——零摩擦
（用户明确要求浏览器直接打开即用）；代价是公共 Wi-Fi 下不要开启。

## 端口稳定性（用户要求：9527 固定，被自家占用就关掉重开）

`DiaryWebServer.start()` 流程：

1. 本进程已有实例 → 先 `stop()`（幂等重启）；
2. 探测 `127.0.0.1:9527/__identity`（800ms 超时）——响应含身份标记
   `shengwuji-diary-web` 即为自家残留实例（如引擎重建前的旧进程）：
   `POST /__shutdown` 关停 + 轮询等端口释放（最多 ~2s）；
3. 绑定 `0.0.0.0:9527`；失败时按"此前是否探测到自家服务"分类报错：
   - 自家实例卡死 → `ownInstanceStuck`（提示稍后重试）
   - 他方应用占用 → `portBusyByOther`（设置页显示明确错误）

`__shutdown` 只放行回环地址——新实例接管走 127.0.0.1，局域网里的其他人
发不了这条指令。

## 实时刷新（双向）

**手机 → 电脑（SSE + 签名轮询）**：服务每秒对 diary 表做一次聚合签名查询
（`COUNT / MAX(id) / SUM(LENGTH(content)) / SUM(is_archived)`，一条 SQL，
千条日记亚毫秒），签名变了就向所有 SSE 客户端广播 `changed`。悬浮窗
engine 在独立 isolate 写库，主 engine 的 sqflite 连接同样能查到（同文件
WAL），所以**任何来源**的写入都会被签名捕获，不依赖各写入方纪律性的
bump。浏览器端 `EventSource` 断线自动重连，另有手动刷新按钮兜底。

**电脑 → 手机（remoteMutationTick + DiarySyncBridge）**：PUT/DELETE 直接走
主 engine 的 DbHelper（服务跑在主 isolate，可直达 GlobalKey），完成后：
1. `DiarySyncBridge.bump()`——悬浮窗 engine 展开时按计数比对重查（既有桥）；
2. `remoteMutationTick++`——main.dart 监听，`_diaryTabKey.currentState
   ?.refreshList()` 刷新日记页（IndexedStack 常驻，不在当前 tab 也能刷）；
3. SSE 广播——发起改动的浏览器与其他浏览器都重拉列表。

## 保活（前台服务）

HTTP 服务在主 engine 的 Dart isolate 里，App 退后台后进程被冻结（Android
12+ cached app freezer）服务即断。开启服务时经 MethodChannel 拉起
`DiaryServerService` 前台服务把进程优先级拉到前台级：

- 类型用 `specialUse`（与悬浮窗 OverlayService 同款，需配
  `PROPERTY_SPECIAL_USE_FGS_SUBTYPE`）：`dataSync` 类型在 Android 15+ 有
  6h/24h 运行时限，长挂会被系统掐；specialUse 无时限
- 通知渠道 `diary_server`，IMPORTANCE_LOW 不响不弹，通知 ID 与端口同号 9527
- `START_NOT_STICKY`：服务被单独重启没有意义（Dart 侧 HTTP 不会随之复活）

开关状态持久化在 prefs `diary_web_server_enabled`，冷启动由
`autoStartIfEnabled()` 自动恢复（延迟 1.5s 避开启动热路径）——重启 App 后
电脑端书签里的地址始终有效。HTTP 起失败时回滚前台服务，不留孤儿通知。

## 录音目录守护

`GET /audio/{id}` 与删除录音都校验 `audio_path` 规范化后必须落在
`<Documents>/diary_audio/` 内——备份导入可能带来任意路径字符串，不能把
手机上的任意文件暴露到局域网（403 拒绝）。

## 设置页卡片

`WebServerSettingsCard` 独立组件（照 OverlayPanelHeader 的提取惯例）：
状态单一数据源是 `DiaryServerController.status`（ValueNotifier）——开关
动作在本卡片，但自恢复发生在 main.dart，同一 notifier 保证开关显示与实际
状态一致。running 态展示 `NetworkInterface.list` 拿到的局域网 IPv4（私有
网段优先排序），每行带复制按钮；error 态显示具体错误文案。

## 测试要点（真实 socket 集成）

数据层用 `DiaryNoteRepository` 接口 + 内存假实现（服务层不直接耦合
sqflite；widget 测试也无法起 sqflite）。socket 走回环地址 + 临时端口
（`port: 0`，避免 Windows 防火墙对 0.0.0.0 的弹窗与端口冲突）：

- HTTP 契约：身份标记 / 页面 / 列表（无路径泄漏）/ 编辑 / 删除（连录音）/
  音频流（200 全量 + 206 切片）/ 目录外 403
- 端口接管：**自家旧实例真被关停、新实例绑上同一端口**（真实两条服务实例
  对打）；他方占用报 portBusyByOther
- SSE：电脑端 PUT 触发广播；手机端仓储签名轮询（50ms 档）触发广播
- widget 测试坑位备忘：
  - `AppThemeExtension.of` 必须挂 `AppThemes.defaultTheme.toThemeData()`；
  - `starting` 态的 `LinearProgressIndicator` 无限动画 → 用显式 `pump`，
    不能 `pumpAndSettle`；
  - `SharedPreferences` 必须 `setMockInitialValues({})`，否则 getInstance
    挂起、状态停在 starting；
  - `Clipboard.getData` 在 FakeAsync zone 无平台处理器会**永久挂起**（10
    分钟超时），必须 mock `SystemChannels.platform`。

## Changelog

- 2026-09-13：首版。固定端口 9527 + 自家实例接管、CRUD API、SSE 实时刷新、
  前台保活、录音目录守护、设置页开关卡片、冷启动自恢复。
- 2026-09-15：管理页卡片新增「📋 复制」一键复制全文（toast 反馈）。页面经
  `http://<手机IP>:9527` 访问不是安全上下文，`navigator.clipboard` 不存在，
  降级 `document.execCommand('copy')`（须在用户手势同步栈内执行，分支内不
  经 await）；localhost / HTTPS 下走标准 Clipboard API。
- 2026-09-22：笔记锁定全链路脱敏（diary.is_locked v15）。锁定行 content
  出网即脱敏为固定星号、audioUrl 置 null，PUT/DELETE 回 403，`/audio/{id}`
  直构 URL 也 403（录音内容=笔记内容）——局域网是悬浮窗/锁屏之外的第三个
  泄露面，锁定即三面同防；电脑端要编辑/收听先在手机上解除锁定。
