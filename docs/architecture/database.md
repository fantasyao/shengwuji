# 数据库架构

## 数据库概述

使用 SQLite 通过 `sqflite` 包实现数据持久化。

### 数据库版本
- **当前版本**: 15
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
| is_locked | INTEGER | 笔记锁定标记（v15，0/1；用户手动锁定，主 App/悬浮窗/局域网服务全链路打码 + 设备凭据认证后可看。锁定状态随新插入行跨端传播，已有行不传播——合并只做新增并集） |

### dismissed_splits 表（日记页 ✕ 学习，v9 新增）
存储用户在日记页物品转存横条上 ✕ 掉的内容（同一 content UNIQUE，避免重复入库）。

| 字段 | 类型 | 说明 |
|------|------|------|
| id | INTEGER | 主键，自增 |
| content | TEXT | 被 dismiss 的转存内容（UNIQUE） |
| created_at | TEXT | 记录时间戳 |

### sync_deleted 表（云同步删除墓碑，v14 新增）
本地删除日记/物品时记录其 sync_uuid，云同步下载合并时命中墓碑的远端条目不再插回本地（防复活）。P1 删除不跨端传播，墓碑只在本地生效；跨端收敛见 @docs/architecture/cloud-sync.md。

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
- `deleteDiary(id)` - 删除日记
- `archiveDiary(id)` - 归档日记

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

> 不变量：任何新增 diary/items 的路径都要带 sync_uuid（batch.insert 直插的靠 ensureSyncUuids 兜底）；任何删除路径都要记墓碑（走 deleteDiary/deleteItemById 已内置）。

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
