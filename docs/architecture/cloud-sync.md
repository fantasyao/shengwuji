# 云同步架构（WebDAV）

## 概述

通过 WebDAV 协议把四类文本数据同步到用户自选网盘（坚果云、Nextcloud、
Alist 等）。**一个 WebDAV 后端通吃所有支持该协议的网盘**；将来接
Google Drive / OneDrive（都不支持 WebDAV，走各自 OAuth API）时在
`SyncBackend` 抽象口加适配器，同步引擎不动。

P1 边界（用户拍板）：

- **手动触发**：设置 → 云端同步 → 立即同步，App 不后台自动联网
- **同步范围**：日记（文字）、物品记录、热词、修正对；**录音文件走
  独立开关「同步录音文件」，默认关**（2026-09-23 加入，用户显式开启
  才传——WAV 约 2MB/分钟，涉及网盘流量与空间）
- **合并语义**：只做「新增条目」双向并集；**编辑、删除不跨端传播**
  （本机删除靠墓碑防复活，见下）

## 云端布局

远端目录（默认 `/shengwuji_sync`，可配置，ASCII 路径规避个别服务端
非 ASCII 路径编码差异）六个数据文件 + 一个录音子目录：

```
/shengwuji_sync/
├── manifest.json          # 软锁 + 版本 + 最后同步者 + 各类条数（诊断用）
├── diary.json             # 日记数组（uuid/content/created_at/audio 文件名/时长/归档/标注）
├── items.json             # 物品数组（uuid/name/location）
├── hotwords.txt           # 原样热词文本（与本地 user_hotwords.txt 同格式）
├── correction_pairs.json  # 修正对数组（error/correct/hit_count/created_at/last_used_at）
├── audio_index.json       # 已上传录音文件名数组（上传去重索引，开关开启才读写）
└── audio/                 # 录音本体（文件名 = 本地 diary_audio 里的 basename）
```

**少文件整包**是刻意设计：坚果云免费版限 600 请求/30 分钟（超限封
约 6 小时），Joplin「每条记录一个文件」在坚果云上首次同步即被限流。
本方案每次同步约 8~12 个请求（1 次探测 + manifest 读写 + ≤8 数据
文件读写），即使高频手动同步也远低于限额。

## 同步流程（`CloudSyncService.sync()`）

```
1. ping 鉴权 + readProps 探测远端目录（404 → mkdirAll 递归建）
2. 读 manifest.json（404 = 首次同步，视为空清单）
3. 软锁检查：他机持锁且未超时（10 分钟）→ 中止提示
   否则写 manifest 置锁 {device_id, at}
4. 下载四个数据文件（404 按空处理）
5. 合并入本地（见下节；ensureSyncUuids 先兜底补齐缺失 uuid）
5.5 录音下载（开关开启才跑）：远端带 audio 名且本地缺文件的条目，
    逐个 GET audio/ 落盘到本地 diary_audio/ 并按 sync_uuid 回填
    audio_path（404 跳过不计错）；随后的全量回传会把回填结果随
    diary.json 上云，第三台设备即可发现同名音频
6. 全量回传合并后的本地状态（四个文件 PUT）
6.5 录音上传（开关开启才跑）：本地有音频文件的行与 audio_index.json
    求差，缺的逐个 PUT 到 audio/，成功的逐个记入索引并回写
7. 写 manifest 解锁 + 更新 counts / updated_at
```

失败时尽力回写「锁=null」防死锁；没来得及释放的锁靠 10 分钟超时
自动过期兜底。WebDAV 无原子 test-and-set（坚果云不保证 ETag
If-Match），软锁只防常规误并发，极端同时点击下可能双开——后果仅是
多传一次相同数据，无一致性风险。

## 录音文件同步（独立开关，默认关）

- **限流分批**：坚果云免费版 600 请求/30 分钟、超限封约 6 小时，录音
  首批动辄数百个文件。单次同步上传/下载各限 `kAudioSyncBatchLimit`
  （80 个），超出的留待下次手动同步续传；上传靠云端 `audio_index.json`
  去重（已传名单），后续每次同步录音只占 0~2 个请求（索引读+写）
- **不拖垮文本**：录音阶段整体 try/catch，失败只往 stats 里记一条
  「录音部分失败，下次同步续传」，同步成功状态与待同步快照不受影响；
  上传中途断网也尽力把已成功文件名落盘索引（重传幂等，只浪费流量）
- **墓碑不拉回**：本机删过的日记 uuid 在墓碑表，其音频同样不下载
  （文本防复活，音频同理）；上传侧行已删自然不在候选里，云端已传的
  文件不删（删除不跨端原则的延伸）
- **上传候选以 DB 行为准**：`audio_path` 指向且文件实际存在的才算数，
  孤儿文件不传；下载落盘名过 `isSafeAudioName` 校验（无路径分隔符/
  非 `..`），防云端 JSON 被写坏后落盘逃出 diary_audio 目录
- **回填不 bump 数据版本**：音频下载成功后 `updateDiaryAudioPathByUuid`
  恢复 audio_path，属同步的附属恢复而非用户侧变更（basename 与云端
  JSON 本就一致），不触发「有新数据待同步」
- **已知边界**：云端 audio_index 说已传但文件被网盘端清理 → 不会自动
  重传（索引与实际文件不逐个核对，核对即逐文件 PROPFIND，请求量不可
  接受）；两设备同秒各录一条 → 文件名撞车后传者覆盖先者（概率极低，
  P1 不处理）

## 合并策略

| 数据 | 合并键 | 规则 | 实现位置 |
|------|--------|------|----------|
| 日记 | sync_uuid；自然键 content+created_at 辅助去重 | 缺失才插入 | `planDiaryInserts` |
| 物品 | sync_uuid；自然键 name+location | 同上 | `planItemInserts` |
| 热词 | 行级并集；字面对（错词=正词）同错词保留本地 | 本地意图优先 | `mergeHotwordContent` |
| 修正对 | (error_text, corrected_text) | hit_count 取大、last_used_at 取新 | `DbHelper.mergeRemoteCorrectionPairs` |

- **自然键辅助去重**的原因：本地备份 ZIP 导入会给复原行造新 uuid，
  只按 uuid 合并会把同一内容同步成两条；content+created_at（微秒级
  时间戳）相同即视为同一条。
- **上传全量而非增量**：合并后本地 ⊇ 远端，全量回传即达成并集，且
  顺带自愈云端历史脏数据；各端最终收敛一致。

### 删除与墓碑（防复活）

P1 删除不跨端，但本机删除必须防止下次同步被远端拉回：

- `diary`/`items` 所有删除入口（日记页左滑、悬浮窗、电脑访问服务、
  搬家模式撤销）都汇聚在 `DbHelper.deleteDiary`/`deleteItemById`，
  删除前把行上的 sync_uuid 写入 `sync_deleted` 墓碑表
- 下载合并时 uuid 命中本地墓碑的远端条目不插入
- `clearAllData()`（导入备份前清空）全量记墓碑：「替换本地」语义下
  被清掉的历史行不得复活；导入的新行是全新 uuid，不受影响
- 已删除记录因此仍留在云端与其他设备上，各端条数可能暂时不同——
  P2 传播墓碑后收敛

### 编辑为何 P1 不同步

diary/items 均无 `updated_at`，无法裁决同 uuid 双端各自编辑的新旧；
强行上传全量会引发「A 编辑 → B 原文回传覆盖」的来回翻转。P2 加
`updated_at` 列后按 LWW 解裁决。

## 模块结构

| 文件 | 职责 |
|------|------|
| [lib/sync/sync_models.dart](../../lib/sync/sync_models.dart) | 三类数据载荷 + 四文件编解码 + manifest/软锁模型 + 音频索引解码（纯函数，解码宽容：坏行跳过不抛） |
| [lib/sync/sync_merge.dart](../../lib/sync/sync_merge.dart) | 热词合并 + 日记/物品插入计划 + 录音上传/下载计划（纯函数，单测覆盖） |
| [lib/sync/cloud_sync_service.dart](../../lib/sync/cloud_sync_service.dart) | 同步引擎 + 配置存取（CloudSyncConfig）+ 录音编排（分批/容错/索引回写）+ 友好错误映射 |
| [lib/db_helper.dart](../../lib/db_helper.dart) | v14 迁移（sync_uuid 列 + sync_deleted 表 + 存量回填）、增删改钩子、远端行插入与修正对行级合并 |
| [lib/settings/cloud_sync_page.dart](../../lib/settings/cloud_sync_page.dart) | 二级页：服务配置/测试连接/立即同步/说明 |
| [test/sync_merge_test.dart](../../test/sync_merge_test.dart) | 合并裁决与编解码单测 |

依赖：`webdav_client`（dio 底层，Basic/Digest 认证）、`flutter_secure_storage`
（密码存 Android Keystore；地址/账号存 SharedPreferences 供入口行摘要同步读）、
`uuid`。设备标识 `cloud_sync_device_id`（prefs，首次生成）。

### DB 侧不变量

- **任何新增 diary/items 的路径都必须带 sync_uuid**：`insertDiary`/
  `insertItem`/`batchInsert*` 已内置生成；`_seedTutorialDiaries` 等直接
  batch.insert 的路径靠 `ensureSyncUuids()`（同步前调用）兜底
- **任何删除路径都必须记墓碑**：新代码删行要么走 DbHelper 既有删除
  方法，要么自行补 `_recordSyncTombstone`

## 待同步检测（入口行提示）

P1 无自动同步，卡片若只显示上次同步结果快照，用户同步后再新增数据会误
以为云端一致（真机反馈 2026-09-22）。机制（`lib/utils/cloud_sync_data_version.dart`，
与 DiarySyncBridge 同款跨 engine 计数纪律）：

- **写方 bump**：DbHelper/TextProcessor 所有用户侧写库路径（日记/物品的
  增删改归档标注、备份导入、修正对学习/删除、热词保存）fire-and-forget
  自增 prefs 计数 `cloud_sync_data_version`（bump 前 reload 防悬浮窗
  engine 覆盖）
- **同步成功快照**：`CloudSyncService.sync()` 在全部合并/上传完成后把当前
  计数写入 `cloud_sync_synced_data_version`；同步失败不快照，待同步态保留
- **读方判定**：`hasPending = 有上次同步记录 &&（无快照 || 当前 > 快照）`。
  入口行副标题（`CloudSyncConfig.buildEntrySubtitle` 纯函数，单测覆盖）
  与二级页状态区共享文案逻辑
- **刷新时机**（IndexedStack 保活，initState 不重跑）：切到设置 tab
  （main.dart 持 `SettingsTabKey` 调 `refreshCloudSyncSummary`）、App 回
  前台（didChangeAppLifecycleState.resumed）、从二级页返回、进入二级页

## 错误处理

`_friendlyError` 把 DioException 映射为用户文案：401/403 → 账号或
「应用密码」错误（坚果云要求在网页端「账户信息 → 安全选项」生成应用
密码，登录密码不行）；429 → 限流提示；507 → 空间不足；超时/连接错误
→ 检查地址网络。404 单列（缺文件/目录是首次同步的正常路径，不算错）。

## 未来演进

- **P2**：diary/items 加 `updated_at` + 墓碑跨端传播 → 编辑 LWW 同步、
  删除同步收敛
- **P3**：`SyncBackend` 抽象口 + Google Drive/OneDrive OAuth 适配器
  （录音文件同步已随独立开关落地，见「录音文件同步」节）

## Changelog

- 2026-09-21：首版（P1）。WebDAV 手动同步：manifest 软锁 + 四文件整包
  合并；日记/物品 sync_uuid 并集 + 自然键去重 + 本地墓碑防复活；热词行级
  并集；修正对 hit_count/last_used_at 行级合并；录音不同步、编辑删除
  不跨端（P1 拍板边界）。v14 迁移与本地 wsgidav 实测冒烟（PROPFIND/
  MKCOL/PUT/GET/404 错误面）全过。
- 2026-09-22：新增待同步检测——本地数据版本计数（用户侧写库 bump / 同步
  成功快照），入口行与二级页显示「有新数据待同步」，刷新时机：切设置 tab /
  App 回前台 / 二级页进出（真机反馈：同步后新增数据卡片仍显示一致）。
- 2026-09-23：录音文件同步（独立开关默认关）。云端新增 audio/ 子目录 +
  audio_index.json 上传索引；上传/下载各限 80 个/次防坚果云限流，超出
  下次续传；录音阶段失败不拖垮文本同步；下载按 sync_uuid 回填
  audio_path（不 bump 数据版本）、墓碑行不拉回；文件名过 isSafeAudioName
  安全校验。合并计划纯函数 planAudioUploads/planAudioDownloads 单测覆盖。
