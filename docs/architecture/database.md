# 数据库架构

## 数据库概述

使用 SQLite 通过 `sqflite` 包实现数据持久化。

### 数据库版本
- **当前版本**: 18
- **定义位置**: [lib/db_helper.dart](../lib/db_helper.dart)

## 数据表

### items 表（物品追踪）
存储用户语音记录的物品位置信息。

| 字段 | 类型 | 说明 |
|------|------|------|
| id | INTEGER | 主键，自增（本地行标识，非跨端身份） |
| name | TEXT | 物品名称 |
| location | TEXT | 存放位置 |
| sync_uuid | TEXT | 云同步全局唯一身份（v14，跨端合并键；本地自增 id 两台设备会撞，不能当合并键） |

### diary 表（语音日记）
存储用户的语音日记条目。

| 字段 | 类型 | 说明 |
|------|------|------|
| id | INTEGER | 主键，自增 |
| content | TEXT | 日记内容（语音转文字，支持 markdown 格式清单：`- [ ]` 未完成 / `- [x]` 已完成） |
| created_at | TEXT | 创建时间戳 |
| audio_path | TEXT | 音频文件存储路径 |
| duration | INTEGER | 音频时长（秒） |
| is_archived | INTEGER | 归档标记（0=活跃, 1=已归档） |
| exported_at | TEXT | 增量导出时间戳，未导出为 NULL |
| tag | TEXT | 标注（悬浮窗标注功能：'urgent'/'star'/'idea'，NULL=无标注），悬浮窗整卡换色 + 主 App 日记页小色点共用 |
| sync_uuid | TEXT | 云同步全局唯一身份（v14，跨端合并键；content+created_at 自然键在合并时辅助去重） |
| is_locked | INTEGER | 笔记锁定标记（v15，0/1；用户手动锁定，主 App/悬浮窗/局域网服务全链路打码 + 设备凭据认证后可看。锁定状态随新插入行跨端传播；2026-10-24 日记进云同步 v2 后，已有行的加/解锁也随 `updated_at` LWW 传播。2026-10-08 起加锁前置检查：设备未设锁屏密码（isDeviceSecure）时不允许锁定，弹引导跳系统安全设置页；2026-10-21 起设置页新增加锁功能总开关 prefs `note_lock_enabled`（默认开），关闭时本列标记原样保留、仅展示/认证层按未加锁处理，重新开启恢复保护，详见 @floating-window.md「笔记锁定」小节） |
| sort_order | INTEGER | 活跃区自定义排序键（v16，越小越靠前；**仅活跃区有意义，归档区行恒 NULL**——归档即清空、恢复归档回顶部）。悬浮窗长按拖动排序写入（`reorderActiveDiaries`），主 App 日记页/电脑访问服务读取同一 SQL 自动跟随。getDiaries 排序：`is_archived ASC, (sort_order IS NULL) ASC, sort_order ASC, created_at DESC`——活跃区漏网 NULL 行排活跃区尾部按时间倒序兜底（不错乱，首次重排即规范化）；归档区全 NULL 走 created_at DESC（现状不变）。本机新插入/恢复归档 = min-1 置顶；撤销删除恢复原值回原位置；**云同步远端新行按 created_at 插进现有顺序**（贴相邻行 sort_order 同值，同值靠 created_at DESC 兜底，既有行不动） |
| image_path | TEXT | **本机截图**附件路径（v17，`docs/diary_images/diary_<id>_<ts>.jpg`，NULL=无附件）。悬浮窗展开卡长按复制按钮截屏后写入：每卡一张、重截覆盖旧文件。**不进备份 ZIP/CSV**；2026-10-24 起截图随云同步**双向**（`image_index.json` + `v2/assets/` 内容寻址，见 @docs/architecture/cloud-sync.md「截图附件同步」），`updateDiaryImage` 改为 bump CloudSyncDataVersion（`batchInsertDiaries` 仍不映射本列，收到端由同步单独回填 `updateDiaryImagePathByUuid`）。⚠️ 截图替换**不 bump `updated_at`**：图片走 `image_index.json` 独立通道，塞进 v2 载荷会让每次换图都触发全量笔记重写。图片属笔记内容：锁定打码卡不渲染缩略图；真实删除/转存清文件，归档保留（删除日记不清 `diary_images`，撤销删除仍能复原，失效行由同步裁剪）。详见 @docs/architecture/floating-window.md「卡片截图附件」 |
| updated_at | INTEGER | 最后修改毫秒时间戳（v19，云同步 v2 的 LWW 裁决依据）。所有用户侧写日记的路径 bump（增删改、归档/还原、锁定、标注）；**刻意不 bump**：拖动排序（`reorderActiveDiaries`）、截图替换（`updateDiaryImage`）、同步落库本身（`applySyncV2Notes` 写的是裁决结果，时间戳随笔记带过来）。存量行首开按 `created_at` 的瞬时幂等回填（`_backfillDiaryUpdatedAt`），保证老数据有确定时间戳参与裁决。见 @docs/architecture/cloud-sync.md「v2 编辑与删除同步」 |

### sync_note_meta 表（v2 同步透传元数据，v19 新增）

手机端不解析电脑端的 `tags` / `attachments` / `extras`，整份存在本表，
写回 `v2/notes.json` 时原样带出——否则手机一回写就把电脑端的标签和图片
附件抹掉了。**键用 `note_uuid`（= `diary.sync_uuid`）**，与 `diary` 一对一。

| 字段 | 类型 | 说明 |
|------|------|------|
| note_uuid | TEXT | 主键，= `diary.sync_uuid` |
| base_hash | TEXT | 上次成功同步时该笔记的 `payloadHash`（三方合并判断「本地/远端谁改过」的基线） |
| rev | INTEGER | 协议里的本机修订号（NOT NULL DEFAULT 1，仅诊断，不参与新旧比较） |
| tags_json | TEXT | 电脑端标签数组（原样 JSON） |
| attachments_json | TEXT | 电脑端附件数组（原样 JSON，本机音频附件按 `audio:<name>` 归一后并入） |
| extras_json | TEXT | 未知扩展字段（原样 JSON，`conflict_of` 等冲突标记也在此） |

> 本表**缺行不致命**：合并时退化为「无基线 + 用远端同 uuid 记录做 seed」，
> 文本照常同步。但新增的电脑端独有字段若不经本表透传，就会在下次手机
> 回写时被抹掉。索引无（主键即够用）；`_ensureV19Schema` 每次开库执行
> `CREATE TABLE IF NOT EXISTS`（版本号不可信场景兜底）。

> `getDiaries` / `queryAllDiaries` 额外计算两列：`image_count` = 本机 `image_path` 有效（1）+ `diary_images` 中该笔记有效行数；`primary_image_path` = 本机截图优先，否则取 `diary_images` 按 `position ASC, sha256 ASC` 的第一张。主 App 卡片与悬浮窗缩略图/数量角标共用这两列，不再各自拼查询。

### diary_images 表（云同步下收的多图附件，v18 新增）
电脑端笔记图片经 `image_index.json` 同步下来的本地副本。**键用 `note_uuid` 而非本地 diary.id**——滑动删除撤销会重插行拿到新 id，用 id 关联会丢图；`(note_uuid, device_id, sha256)` 联合唯一保证重复同步幂等。

| 字段 | 类型 | 说明 |
|------|------|------|
| id | INTEGER | 主键，自增 |
| note_uuid | TEXT | 所属笔记 `diary.sync_uuid`（跨端稳定键） |
| device_id | TEXT | 图片来源设备（同一笔记多设备各存一套，互不覆盖） |
| sha256 | TEXT | 图片内容哈希（与 `v2/assets/<xx>/<sha>.<ext>` 文件名同源） |
| image_path | TEXT | 下载后的本地路径（`docs/diary_images/diary_sync_<note>_<sha 前 8 位>.<ext>`） |
| remote_name | TEXT | 云端资产文件名（`<sha>.<ext>`） |
| mime_type | TEXT | MIME（image/jpeg、image/png、image/webp） |
| byte_size | INTEGER | 字节数（下载后回写） |
| position | INTEGER | 展示顺序（电脑端附件 sortOrder 映射，多图左右切换顺序） |
| updated_at | TEXT | 远端条目更新时间（仅诊断用） |

> 索引 `idx_diary_images_note(note_uuid)`；`_ensureDiaryImagesSchema` 在每次开库时 PRAGMA 自愈（版本号不可信场景兜底）。同步裁剪规则：笔记仍在本机但 merged 索引里已无该行、或笔记已删除且进墓碑 → 删行 + 删文件；图片文件被外部清理的行也在此处清理。

### dismissed_splits 表（日记页 ✕ 学习，v9 新增）
存储用户在日记页物品转存横条上 ✕ 掉的内容（同一 content UNIQUE，避免重复入库）。

| 字段 | 类型 | 说明 |
|------|------|------|
| id | INTEGER | 主键，自增 |
| content | TEXT | 被 dismiss 的转存内容（UNIQUE） |
| created_at | TEXT | 记录时间戳 |

### sync_deleted 表（云同步删除墓碑，v14 新增）
本地删除日记/物品时记录其 sync_uuid，云同步下载合并时命中墓碑的远端条目不再插回本地（防复活）。2026-10-24 起 **`kind='diary'` 的墓碑随 `v2/tombstones.json` 跨端传播**（其他端下次同步删掉对应行；`updated_at > deleted_at` 的编辑允许复活，复活时由 `removeSyncTombstones` 清残留）；`kind='items'` 仍只在本地生效（v2 items 未落地）。见 @docs/architecture/cloud-sync.md「v2 编辑与删除同步」。

| 字段 | 类型 | 说明 |
|------|------|------|
| uuid | TEXT | 主键，被删行的 sync_uuid |
| kind | TEXT | 来源表（'diary' / 'items'） |
| deleted_at | TEXT | 记录时间戳 |

## 数据库操作

### DbHelper 类
提供所有数据库操作的封装方法：

#### 物品操作
- `getItems()` - 获取所有物品
- `addItem(name, location)` - 添加新物品
- `updateItem(id, name, location)` - 更新物品
- `deleteItem(id)` - 删除物品
- `batchInsertItems(items)` - 批量插入物品
- `searchItemsByName(keyword, {limit})` - 按物品名 LIKE 模糊查询，按 id 倒序（最近优先）。日记页"XX在哪儿"答案区使用

#### 日记操作
- `getDiaries()` - 获取所有日记
- `queryAllDiaries()` - 查询所有日记
- `addDiary(content, audioPath, duration)` - 添加新日记
- `updateDiary(id, content)` - 更新日记内容
- `updateDiaryTag(id, tag)` - 更新日记标注（'urgent'/'star'/'idea'，null=取消标注；悬浮窗标注行调用）
- `setDiaryLocked(id, locked)` - 设置/解除笔记锁定（v15；主 App DiaryTab 与悬浮窗 OverlayHome 的锁按钮共用）
- `updateDiaryImage(id, imagePath)` - 写入/清空截图附件路径（v17；2026-10-24 起 bump 云同步数据版本——截图要上云，替换即算待同步变更）
- `getDiaryImages(noteUuid)` - 查询某笔记下收的电脑端多图（v18，按 `position ASC, sha256 ASC`，只返回 `image_path` 非空的行）
- `loadDiaryImageRows()` - 全量 `diary_images` 行（同步裁剪/下载去重用）
- `upsertDiaryImage(...)` - 写入/更新一张下收图片（v18，`ConflictAlgorithm.replace` 键 `(note_uuid, device_id, sha256)`，重复同步幂等）
- `deleteDiaryImageRow(id)` / `deleteDiaryImagesForNote(noteUuid)` - 删除图片行（同步裁剪、测试清理用；主删除路径不主动调用，保证撤销可复原）
- `deleteDiary(id)` - 删除日记
- `archiveDiary(id)` - 归档日记（顺带清 sort_order，归档区不参与排序）
- `restoreDeletedDiary(row)` - 滑动删除撤销：全字段原样插回（sort_order 恢复原值回原位置，墓碑清除）
- `reorderActiveDiaries(orderedActiveIds)` - 活跃区重排（v16；悬浮窗长按拖动排序的唯一写入入口）：事务内把活跃区 sort_order 规范重写为 0..n-1（按传入顺序），漏网活跃行（如重排期间新增）按 created_at DESC 续排尾部，归档行恒不动；写完 bump 云同步数据版本（DiarySyncBridge.bump 由调用方做）

#### 导出相关
- `markDiaryExported(id)` - 标记日记已导出
- `queryUnexportedDiaries()` - 查询未导出且未归档的日记
- `clearAllExportState()` - 清除所有导出标记

#### 批量与清理
- `batchInsertDiaries(diaries)` - 批量插入日记
- `clearAllData()` - 清空所有数据（清空前全量记同步墓碑，防清掉的历史行从云端复活）

#### 云同步（v14 新增，策略见 @docs/architecture/cloud-sync.md）
- `ensureSyncUuids()` - 为 sync_uuid 为 NULL 的行补生成 UUID（同步前兜底）
- `loadSyncTombstones()` - 全量墓碑 uuid 集合
- `insertRemoteDiaries(rows)` / `insertRemoteItems(rows)` - 插入远端行（保留远端 uuid，ConflictAlgorithm.ignore 兜底）
- `getAllCorrectionPairRows()` - 修正对全量原始行（含 created_at/last_used_at）
- `mergeRemoteCorrectionPairs(entries)` - 修正对行级合并（hit_count 取大、last_used_at 取新，事务内裁决 + 500 条容量淘汰）
- `loadSyncNoteMeta()` - v2 透传元数据全表（uuid → 行，v19）
- `loadSyncTombstoneRows()` - 墓碑全量行（含 kind/deleted_at，v2 合并要按 kind 分流，v19）
- `applySyncV2Notes({upserts, deletes, metaRows})` - v2 合并结果**单事务**落库：upsert diary 行 + 覆盖 `sync_note_meta` + 按墓碑删行（v19）。⚠️ 本方法**不 bump `updated_at`**（写的是裁决结果，时间戳随笔记带过来），新行落库排序：活跃区空尊重远端原值 / 非空按 created_at 插进本机现有顺序（`_placeIncomingRowsByTime`，贴相邻行 sort_order 同值）
- `applyRemoteTombstones(entries)` / `removeSyncTombstones(uuids)` - 远端墓碑落库 / 复活时清残留（v19）

> 不变量：任何新增 diary/items 的路径都要带 sync_uuid（batch.insert 直插的靠 ensureSyncUuids 兜底）；任何删除路径都要记墓碑（走 deleteDiary/deleteItemById 已内置）；**任何改日记内容/状态的用户侧写路径都要 bump `updated_at`**（v2 LWW 的唯一裁决依据，漏 bump 等于本机编辑永远输）。

## 数据迁移

数据库版本升级时，需要：
1. 增加 `database_version` 值
2. 在 `onUpgrade()` 中添加迁移逻辑
3. 确保旧数据正确迁移到新结构

### 迁移历史

| 版本变更 | 变更内容 | 说明 |
|----------|----------|------|
| v3 → v4 | 添加 `duration` 字段 | 支持日记录音时长记录 |
| v4 → v5 | 添加 `is_archived` 字段 | 归档功能，标记日记是否已归档 |
| v5 → v6 | 添加 `exported_at` 字段 | 增量导出标记，记录导出时间戳 |
| v6 → v7 | 添加 lists 表 | 存储清单标题、条目JSON、分类 |
| v7 → v8 | 清单数据合并到日记表 | items_json 转为 markdown 格式，删除 lists 表 |
| v8 → v9 | 新增 dismissed_splits 表 | 日记页物品转存横条 ✕ 学习（同一 content UNIQUE） |
| v9 → v10 | diary 表添加 `tag` 字段 | 悬浮窗日记卡片标注（紧急/收藏/灵感整卡换色，主 App 显示小色点） |
| v10 → v11 | 新增 correction_pairs 表 | 错误-修正学习表（(error_text, corrected_text) 联合 UNIQUE，500 条按 last_used_at 淘汰） |
| v11 → v12 | 新增上下文纠错统计表 | correction_context_stats（同音词×上下文词共现）+ correction_user_words（用户词频弱先验） |
| v12 → v13 | 新增 correction_pair_contexts 表 | 修正对语境档案（左右邻接字符，提示前语境门控） |
| v13 → v14 | 云同步基础列 | diary/items 加 `sync_uuid` + sync_deleted 墓碑表（见 @docs/architecture/cloud-sync.md）。⚠️ 升级事务里只做 DDL，存量行 UUID 回填在首开成功后执行（幂等、失败下次启动/同步前重试）——回填的 Dart 循环拉长升级事务窗口是 2026-09-21 覆盖安装首启 database_closed 事故的诱因之一，配套修复：`DbHelper` 单飞打开（并发共享同一 Future）+ 瞬态打开失败重试（旧进程文件锁未完全释放时秒开会撞锁，真机复现杀后台重启自愈） |
| v14 → v15 | diary 表添加 `is_locked` 字段 | 笔记锁定功能（防锁屏悬浮窗偷看）：用户手动锁定，主 App/悬浮窗/局域网服务全链路打码展示（固定星号 `＊＊＊＊＊＊`，不泄露长度），设备凭据认证（指纹优先/锁屏密码兜底）后 5 分钟会话内可见，锁屏立即重锁。存量行默认 0 无需回填 |
| v15 → v16 | diary 表添加 `sort_order` 字段 | 悬浮窗长按拖动排序（详见 @docs/architecture/floating-window.md）。升级事务只做 DDL（v14 事故教训），存量活跃行回填在首开成功后执行（`_backfillSortOrder`，幂等）：⚠️ 迭代方向必须 created_at **ASC**——最旧行拿 min-1、最新行拿系列最小值，显示顺序与升级前（时间倒序）完全不变；按 DESC 迭代会把顺序整个颠倒（防再犯注释在 db_helper.dart）。配套 `_ensureSortOrderSchema`（PRAGMA 表结构自愈，版本号不可信场景兜底）。备份 CSV 追加第 8 列「排序」（放最后，旧 App 只读前几列天然兼容）；云同步 DiaryPayload 带 sortOrder 编解码宽容 |
| v16 → v17 | diary 表添加 `image_path` 字段 | 悬浮窗卡片截图附件（详见 @docs/architecture/floating-window.md「卡片截图附件」）。升级事务只做 DDL（v14 事故教训），存量行默认 NULL 无需回填；图片文件落 `docs/diary_images/`，不进备份，2026-10-24 起支持手机 → 电脑云同步 |
| v17 → v18 | 新增 `diary_images` 表 | 电脑端多图同步到手机（详见 @docs/architecture/cloud-sync.md「截图附件同步」）：`(note_uuid, device_id, sha256)` 联合唯一 + `position` 排序；升级事务只做 DDL + 索引，存量无需回填。`getDiaries` 增算 `image_count` / `primary_image_path`，主 App 与悬浮窗共用。⚠️ 关联键必须是 `diary.sync_uuid`（本地 id 在删除撤销后会变）；`deleteDiary` 刻意不级联删本表，失效行统一由云同步裁剪 |
| v18 → v19 | diary 添加 `updated_at` + 新增 `sync_note_meta` 表 | 日记接入云同步 v2（编辑/删除跨端传播，详见 @docs/architecture/cloud-sync.md「v2 编辑与删除同步」）。升级事务只做 DDL + 建表（v14 事故教训），`updated_at` 存量回填（取 `created_at` 毫秒瞬时，幂等）在首开成功后执行；配套 `_ensureV19Schema` 每次开库 PRAGMA 自愈。`sync_note_meta` 透传电脑端 tags/attachments/extras + 基线哈希，是「手机回写不抹掉电脑端富字段」的唯一通道——新增电脑端独有字段必须经本表透传 |

### 表结构自愈（版本号不可信）

`user_version` 在 Android 上由 sqflite 单独写出（不在建库/升级事务里），事务失败回滚后版本号仍可能已落盘。因此每次开库都按**实际表结构**自愈、不信任版本号，分两层（`_openDbOnce` 内顺序不可换——列级 ALTER 依赖表存在）：

1. **缺表自愈** `_ensureCoreTables`：查 `sqlite_master`，缺哪张就按 `_coreTables` 建哪张。`_coreTables` 是全部内置表 DDL 的唯一真值，`onCreate` 也走同一份（全部 `CREATE TABLE IF NOT EXISTS`，重复执行是空操作）。若连 `diary` 都缺 → 原库没有任何日记行，等价新装库，补回 9 条内置说明卡；日志会打「🔧 自愈：库缺表 …（user_version=…）」便于事后定位。
2. **缺列自愈**：`_ensureSyncSchema`（v14 sync_uuid）→ `_ensureSortOrderSchema`（v16 sort_order）→ `_ensureDiaryImagesSchema`（v18 表）→ `_ensureV19Schema`（updated_at + sync_note_meta），之后才是三组存量回填（sync_uuid / sort_order / updated_at）。

> 2026-10-27 事故（模拟器首启，adb 取库确认）：新建库时 onCreate 全部跑完，但 sqflite 侧 `COMMIT` 报 `Cannot perform this operation because there is no current transaction` 失败并关闭连接；版本号已独立写成 19，于是留下「版本=19 但零张表」的空库。重试打开跳过 onCreate，旧的列级自愈只会在 ALTER 上报 no such table，唯一直写 DDL 的 `diary_images` 反而建成 —— 「有 diary_images、没有 diary」，随手记每条查询都失败、页面永远停在加载中。缺表自愈就是这次事故的补救点。

配套 UI：`DiaryTab.refreshList` 读库异常不再沉默——置 `_listError` 显示失败文案 + 「重试」按钮（原来异常抛出后 `_isLoadingList` 停在 true，页面永远「加载中」）。
